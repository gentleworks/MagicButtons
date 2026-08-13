import Foundation
import CoreGraphics
import TouchKit

public enum EventInterceptorError: Error {
    /// `CGEvent.tapCreate` returned nil — almost always because Accessibility
    /// permission has not been granted. The App maps this to the permission flow.
    case tapCreationFailed
}

/// An **active** `CGEventTap` (docs/05 §Interceptor sketch). Three jobs across the
/// project:
///
/// 1. Report **physical-click state** upstream — `onPhysicalClickChange` feeds
///    `physicalClickActive` into the recognizer (the public signal chosen over
///    the private frame bit).
/// 2. Promote `mouseMoved` → `…MouseDragged` while a synthetic hold is active,
///    which is what makes tap-and-a-half dragging actually drag (Phase 8, docs/05
///    §Why drag needs the interceptor).
/// 3. **De-conflict** physical clicks against an in-flight synthetic drag — swallow a
///    physical button-down while a synthetic hold owns the pointer, plus its matching
///    up (docs/14 §Click/drag de-confliction).
///
/// The tap is created with `.defaultTap` so it can *modify* and *consume*. It is
/// pass-through **except** for those two narrow cases (the move→drag rewrite and the
/// de-confliction swallow). This is **not** Feature A's blanket suppression: outside a
/// synthetic drag, every physical click still passes through untouched (that feature is
/// deferred — docs/05 §Suppress physical clicks).
public final class EventInterceptor {
    /// Called on real hardware-click transitions with the new active state.
    public var onPhysicalClickChange: ((Bool) -> Void)?

    /// Diagnostic tee: every physical **button** event that reached the tap, as
    /// `(type, buttonNumber, swallowed)`. Fired *after* the de-confliction decision —
    /// unlike `onPhysicalClickChange`, which must reach the recognizer before it — so a
    /// consumer can see not just that a click happened but whether we consumed it.
    /// `mb-dev log-conflicts` uses it to prove the swallow; the planned diagnostics mode
    /// (docs/10) wants the same signal. Read-only: it never influences behavior, and
    /// `nil` (the production default) costs nothing. Not fired for moves.
    public var onPhysicalButtonEvent: ((CGEventType, Int64, Bool) -> Void)?

    private var tracker = PhysicalClickTracker()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The zone whose synthetic button is currently held, so physical `mouseMoved`
    /// events are rewritten into that button's `…MouseDragged`. `nil` = pass-through.
    /// Set/cleared by `beginDragPromotion`/`endDragPromotion` on the same run loop
    /// the tap callback fires on (the App's main loop), so no synchronization needed.
    private var dragZone: MouseZone?

    /// Physical button numbers whose **down** we swallowed, awaiting their **up**
    /// (docs/14 §Click/drag de-confliction). A *set*, not a flag: a user can squeeze the
    /// shell repeatedly inside one drag, and each down/up pair must balance on its own
    /// button. Deliberately **not** cleared by `endDragPromotion` — a drag can end
    /// between a swallowed down and its up, and that up must still be swallowed or the
    /// app sees a button-up it never saw go down (docs/14 scenario #4).
    private var swallowedButtons: Set<Int64> = []

    /// Down/up for all three buttons, plus `mouseMoved` for drag promotion.
    private static let observedTypes: [CGEventType] = [
        .leftMouseDown, .leftMouseUp,
        .rightMouseDown, .rightMouseUp,
        .otherMouseDown, .otherMouseUp,
        .mouseMoved,
    ]

    public init() {}

    public var isPhysicalClickActive: Bool { tracker.isActive }

    /// Install the tap on the **current** run loop. The caller must have a
    /// running run loop (the App's main loop in Phase 7).
    public func start() throws {
        let mask = Self.observedTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<EventInterceptor>
                    .fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            throw EventInterceptorError.tapCreationFailed
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
        // Any swallowed down never reached the OS, so nothing is left held — dropping the
        // pending ups is safe, and keeps a re-installed tap from inheriting stale state.
        swallowedButtons.removeAll()
    }

    /// `nil` consumes the event (docs/14 §Click/drag de-confliction); anything else
    /// passes it on, rewritten or not.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables a tap that is slow or interrupted; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Ignore our own synthesized clicks so they don't read as physical — and so we
        // can never swallow the very button-down the emitter just posted.
        if event.getIntegerValueField(.eventSourceUserData) == CGEventEmitter.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        // Track the *hardware* truth first, whether or not we go on to swallow: the user
        // really did click, so `requireNoPhysicalClick` must still see it, and the
        // tracker stays balanced across a swallowed down/up pair.
        if tracker.handle(type, buttonNumber: buttonNumber) {
            onPhysicalClickChange?(tracker.isActive)
        }
        let swallowed = shouldSwallow(type: type, buttonNumber: buttonNumber)
        if Self.isButtonEvent(type) {
            onPhysicalButtonEvent?(type, buttonNumber, swallowed)
        }
        if swallowed { return nil }
        // While a synthetic button is held, rewrite physical moves into that button's
        // dragged event (docs/05 §Why drag needs the interceptor).
        applyDragPromotion(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    /// Button down/up across all three buttons — the events de-confliction reasons about.
    /// Excludes moves, which are rewritten rather than consumed.
    private static func isButtonEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp,
             .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    /// De-confliction (docs/14 §Click/drag de-confliction, chosen approach **(c)
    /// balanced-swallow**): should this physical button event be consumed?
    ///
    /// - A **down** is swallowed only while a synthetic hold owns the pointer, so the
    ///   shell squeezed mid-drag can't post a competing press the OS reads as a drop.
    /// - An **up** is swallowed **iff we swallowed its down**. That single rule is the
    ///   balance invariant, and it is what makes the measured *straddle* safe: hardware
    ///   sessions showed the common pattern is a physical down landing *before* the hold
    ///   begins (while the contact is still arming) and its up landing *during* the hold.
    ///   Swallowing that up — whose down already reached the app — would strand a
    ///   button-down that never comes up. So the leaked down's up leaks too, and the real
    ///   click completes balanced (the accepted residual: a concurrent click, never a
    ///   corrupted drag).
    ///
    /// Note it keys on `dragZone`, not on the drag *style*: whether the hold came from
    /// `tapAndAHalf` or `pressAndHold` is the recognizer's business, and the arming-window
    /// distinction between them only mattered for the rejected approaches (a)/(b).
    /// Zone-agnostic too — a physical click is zone-less and may collide with a `middle`
    /// hold (docs/14 finding #5), so pairs are matched by button number alone.
    func shouldSwallow(type: CGEventType, buttonNumber: Int64) -> Bool {
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard dragZone != nil else { return false }
            swallowedButtons.insert(buttonNumber)
            return true
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return swallowedButtons.remove(buttonNumber) != nil
        default:
            return false
        }
    }

    /// Arm move→drag promotion for `zone`'s button: subsequent physical `mouseMoved`
    /// events are rewritten into the matching `…MouseDragged` until `endDragPromotion`.
    /// Called by the emitter's `press` alongside the synthetic button-down.
    public func beginDragPromotion(zone: MouseZone) { dragZone = zone }

    /// Disarm move→drag promotion. Called by the emitter's `release` alongside the
    /// synthetic button-up (and reached via the coordinator's safety release).
    public func endDragPromotion() { dragZone = nil }

    /// Rewrite a physical `mouseMoved` into the held button's `…MouseDragged` in place
    /// (same location/deltas, retagged type + button number, stamped with the button
    /// state a real drag carries). No-op unless a drag is armed and `type` is
    /// `mouseMoved`. Returns whether it rewrote (for tests).
    @discardableResult
    func applyDragPromotion(type: CGEventType, event: CGEvent) -> Bool {
        guard let dragZone, type == .mouseMoved else { return false }
        event.type = ButtonMapping.draggedType(for: dragZone)
        event.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(ButtonMapping.button(for: dragZone).rawValue))
        // Retyping alone is not enough. A `mouseMoved` carries no button state of its
        // own — it carries *residue* from the last real click sequence, so these fields
        // are stale rather than merely zero (a capture showed the same code path emit
        // clickState 1 and clickState 0 drags minutes apart, and a `mouseMoved` carrying
        // clickState 1 before any click in the recording). Hardware drags carry
        // clickState 1 and pressure 1.0 throughout, so stamp both to match the
        // button-down this promotion belongs to. Without it the app sees a "drag" that
        // claims no button is down and belongs to no click sequence.
        event.setIntegerValueField(.mouseEventClickState, value: Self.dragClickState)
        event.setDoubleValueField(.mouseEventPressure, value: 1.0)
        return true
    }

    /// The click-count a promoted drag reports. `1` because `CGEventEmitter.press`
    /// always opens a hold with a single-click down; if double-click-drag (docs/10)
    /// ever lands, this and that down have to move together.
    static let dragClickState: Int64 = 1
}
