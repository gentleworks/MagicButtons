import Foundation
import CoreGraphics
import ApplicationServices
import TouchKit

/// `ButtonEmitting` backed by the **public** CoreGraphics event API. Posts real
/// mouse buttons to `.cghidEventTap` (docs/05-event-output.md).
///
/// Synthesized events are stamped with `Self.syntheticMarker` in the event's
/// user-data field so `EventInterceptor` can tell our own posts from real
/// hardware clicks and not mistake a synthetic click for a physical one.
public final class CGEventEmitter: ButtonEmitting {
    /// Sentinel written to `.eventSourceUserData` on every event we post.
    /// `EventInterceptor` skips events carrying it.
    public static let syntheticMarker: Int64 = 0x4D42_4E00 // "MBN\0"

    private let source: CGEventSource?
    /// The zone whose button is currently held down by `press`, so `release`
    /// lifts the same button even if a different zone is passed.
    private var heldZone: MouseZone?

    /// Accessibility-trust check, consulted before opening a hold. Injected so
    /// tests can drive both branches; defaults to the real `AXIsProcessTrusted`.
    /// See `press` for why a hold must not begin without it.
    private let isTrusted: () -> Bool

    /// Arms/disarms move→drag promotion around a hold (docs/05 §Why drag needs the
    /// interceptor). Wired to the `EventInterceptor` in `App`; **weak** because the
    /// coordinator owns both objects for the app's lifetime and a strong link here
    /// would retain the tap. `nil` in tests (a spy drives the pipeline directly).
    public weak var dragPromoter: (any DragPromoting)?

    /// Where a fully-built event goes. Injected for the same reason as `isTrusted`:
    /// the real destination is `.cghidEventTap`, which a test can neither observe nor
    /// safely drive, so the exact fields we stamp would otherwise be unassertable.
    private let postEvent: (CGEvent) -> Void

    /// The shipping initializer, and the only one visible outside this module. Every
    /// production call site uses it; the destination is always `.cghidEventTap`.
    public convenience init(isTrusted: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.init(isTrusted: isTrusted, postEvent: { $0.post(tap: .cghidEventTap) })
    }

    /// Deliberately **internal** — reached by tests through `@testable import`, and by
    /// nothing else. The sink has to be substitutable for the posted fields to be
    /// assertable at all (`clickState` on a drag-terminating up is the whole point of
    /// `EmittedClickStateTests`), but it must not be substitutable from outside: a sink
    /// that silently dropped events would present as the app having stopped working,
    /// with no error anywhere to say so. Keeping it off the public API means that
    /// failure mode cannot be introduced by a caller.
    init(isTrusted: @escaping () -> Bool, postEvent: @escaping (CGEvent) -> Void) {
        source = CGEventSource(stateID: .hidSystemState)
        self.isTrusted = isTrusted
        self.postEvent = postEvent
    }

    public func click(_ zone: MouseZone, count: Int) {
        post(ButtonMapping.downType(for: zone), zone: zone, clickState: count)
        post(ButtonMapping.upType(for: zone), zone: zone, clickState: count)
    }

    public func press(_ zone: MouseZone) {
        // Never open a drag we might not be able to close. Posting requires
        // Accessibility, so without it the button-down wouldn't post *and* a later
        // up couldn't either — the exact asymmetry that strands a button when the
        // grant is revoked mid-hold (docs/05 §Press/release). Bail before holding
        // any state; the paired `release` then no-ops. `click` needs no such guard
        // — its down/up post atomically and can't be split by a revocation.
        guard isTrusted() else { return }
        heldZone = zone
        post(ButtonMapping.downType(for: zone), zone: zone, clickState: 1)
        // The button is down, but physical mouse *moves* won't register as a drag
        // until the interceptor rewrites them — arm that now (docs/05 §Press/release).
        dragPromoter?.beginDragPromotion(zone: zone)
    }

    public func release(_ zone: MouseZone) {
        // Idempotent: only lift a button we actually hold. Multiple safety paths can
        // reach `release` (recognizer lift, `cancelActiveHolds`, quit); guarding on
        // `heldZone` keeps a second call from posting a stray up for a button that's
        // already released. A `release` with nothing held (e.g. `press` bailed on
        // trust) is simply a no-op.
        guard let target = heldZone else { return }
        // clickState **0**, not 1 — the one field that separated our drags from the
        // hardware's. macOS marks a drag-terminating up as "no click happened here":
        // every physical drag in a Pages capture ended with clickState 0 while its down
        // carried 1. Sending 1 announces a fresh single click at the release point,
        // which is exactly what collapsed a Pages/Numbers text selection and dropped the
        // caret where the finger lifted — 100% of synthetic drags, 0% of physical ones.
        // Engines that track selection in a modal `nextEventMatchingMask:` loop (AppKit's
        // own text views) only read the event *type* and never saw it; iWork's does.
        // `click` is deliberately untouched: a real click's up carries its count, and
        // that is what makes double- and triple-click select a word and a line.
        post(ButtonMapping.upType(for: target), zone: target, clickState: 0)
        dragPromoter?.endDragPromotion()
        heldZone = nil
    }

    /// One down/up event. Location is the **current cursor** position, not the
    /// finger's shell position — the finger isn't the cursor (docs/05 §Notes).
    private func post(_ type: CGEventType, zone: MouseZone, clickState: Int) {
        let location = CGEvent(source: nil)?.location ?? .zero
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type,
            mouseCursorPosition: location,
            mouseButton: ButtonMapping.button(for: zone)
        ) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        postEvent(event)
    }
}
