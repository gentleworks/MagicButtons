import Foundation
import CoreGraphics
import TouchKit

public enum EventInterceptorError: Error {
    /// `CGEvent.tapCreate` returned nil — almost always because Accessibility
    /// permission has not been granted. The App maps this to the permission flow.
    case tapCreationFailed
}

/// An **active** `CGEventTap` (docs/05 §Interceptor sketch). Two jobs across the
/// project; **Phase 3 wires only the first**:
///
/// 1. Report **physical-click state** upstream — `onPhysicalClickChange` feeds
///    `physicalClickActive` into the recognizer (the public signal chosen over
///    the private frame bit).
/// 2. Promote `mouseMoved` → `…MouseDragged` while a synthetic hold is active,
///    which is what makes tap-and-a-half dragging actually drag (Phase 8, docs/05
///    §Why drag needs the interceptor).
///
/// The tap is created with `.defaultTap` so it can *modify* events, but it stays
/// **pass-through by default** — v1 never consumes physical clicks; it only
/// *rewrites* `mouseMoved` into the held button's dragged event during a drag.
public final class EventInterceptor {
    /// Called on real hardware-click transitions with the new active state.
    public var onPhysicalClickChange: ((Bool) -> Void)?

    private var tracker = PhysicalClickTracker()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The zone whose synthetic button is currently held, so physical `mouseMoved`
    /// events are rewritten into that button's `…MouseDragged`. `nil` = pass-through.
    /// Set/cleared by `beginDragPromotion`/`endDragPromotion` on the same run loop
    /// the tap callback fires on (the App's main loop), so no synchronization needed.
    private var dragZone: MouseZone?

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
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent> {
        // The OS disables a tap that is slow or interrupted; re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Ignore our own synthesized clicks so they don't read as physical.
        if event.getIntegerValueField(.eventSourceUserData) == CGEventEmitter.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }
        let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        if tracker.handle(type, buttonNumber: buttonNumber) {
            onPhysicalClickChange?(tracker.isActive)
        }
        // While a synthetic button is held, rewrite physical moves into that button's
        // dragged event (docs/05 §Why drag needs the interceptor) — the only case v1
        // modifies an event; everything else passes through unchanged.
        applyDragPromotion(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    /// Arm move→drag promotion for `zone`'s button: subsequent physical `mouseMoved`
    /// events are rewritten into the matching `…MouseDragged` until `endDragPromotion`.
    /// Called by the emitter's `press` alongside the synthetic button-down.
    public func beginDragPromotion(zone: MouseZone) { dragZone = zone }

    /// Disarm move→drag promotion. Called by the emitter's `release` alongside the
    /// synthetic button-up (and reached via the coordinator's safety release).
    public func endDragPromotion() { dragZone = nil }

    /// Rewrite a physical `mouseMoved` into the held button's `…MouseDragged` in place
    /// (same location/deltas, retagged type + button number). No-op unless a drag is
    /// armed and `type` is `mouseMoved`. Returns whether it rewrote (for tests).
    @discardableResult
    func applyDragPromotion(type: CGEventType, event: CGEvent) -> Bool {
        guard let dragZone, type == .mouseMoved else { return false }
        event.type = ButtonMapping.draggedType(for: dragZone)
        event.setIntegerValueField(
            .mouseEventButtonNumber,
            value: Int64(ButtonMapping.button(for: dragZone).rawValue))
        return true
    }
}
