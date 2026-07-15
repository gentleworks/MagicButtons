import Testing
import CoreGraphics
@testable import EventOutput
import TouchKit

// Phase 3 — the hardware-free seams of the event-output layer: the pure
// zone→button mapping and the physical-click state machine. Posting real events
// and installing the live CGEventTap need the attached Magic Mouse and are
// verified manually (docs/05-event-output.md, docs/11-build-plan.md §Phase 3).

@Suite struct ButtonMappingTests {
    @Test func leftZoneMapsToLeftButtonFamily() {
        #expect(ButtonMapping.button(for: .left) == .left)
        #expect(ButtonMapping.downType(for: .left) == .leftMouseDown)
        #expect(ButtonMapping.upType(for: .left) == .leftMouseUp)
        #expect(ButtonMapping.draggedType(for: .left) == .leftMouseDragged)
    }

    @Test func rightZoneMapsToRightButtonFamily() {
        #expect(ButtonMapping.button(for: .right) == .right)
        #expect(ButtonMapping.downType(for: .right) == .rightMouseDown)
        #expect(ButtonMapping.upType(for: .right) == .rightMouseUp)
        #expect(ButtonMapping.draggedType(for: .right) == .rightMouseDragged)
    }

    @Test func middleZoneMapsToCenterOtherFamily() {
        // Apps read `.center` + `.otherMouse*` (button number 2) as a middle click.
        #expect(ButtonMapping.button(for: .middle) == .center)
        #expect(ButtonMapping.downType(for: .middle) == .otherMouseDown)
        #expect(ButtonMapping.upType(for: .middle) == .otherMouseUp)
        #expect(ButtonMapping.draggedType(for: .middle) == .otherMouseDragged)
    }
}

// `handle` is `mutating`, which the `#expect` macro can't call inline, so each
// transition is captured into a local first, then asserted.
@Suite struct PhysicalClickTrackerTests {
    @Test func downThenUpTogglesActive() {
        var tracker = PhysicalClickTracker()
        #expect(!tracker.isActive)

        let becameActive = tracker.handle(.leftMouseDown, buttonNumber: 0)
        #expect(becameActive)          // transition reported
        #expect(tracker.isActive)

        let becameInactive = tracker.handle(.leftMouseUp, buttonNumber: 0)
        #expect(becameInactive)        // transition reported
        #expect(!tracker.isActive)
    }

    @Test func staysActiveWhileASecondButtonIsHeld() {
        var tracker = PhysicalClickTracker()

        let leftDown = tracker.handle(.leftMouseDown, buttonNumber: 0)
        #expect(leftDown)              // → active
        let rightDown = tracker.handle(.rightMouseDown, buttonNumber: 1)
        #expect(!rightDown)            // already active, no flip
        #expect(tracker.isActive)

        // Releasing one of two held buttons does NOT drop active.
        let leftUp = tracker.handle(.leftMouseUp, buttonNumber: 0)
        #expect(!leftUp)
        #expect(tracker.isActive)

        // Releasing the last held button flips back to inactive.
        let rightUp = tracker.handle(.rightMouseUp, buttonNumber: 1)
        #expect(rightUp)
        #expect(!tracker.isActive)
    }

    @Test func middleButtonTracksByItsNumber() {
        var tracker = PhysicalClickTracker()
        let down = tracker.handle(.otherMouseDown, buttonNumber: 2)
        #expect(down)
        #expect(tracker.isActive)
        let up = tracker.handle(.otherMouseUp, buttonNumber: 2)
        #expect(up)
        #expect(!tracker.isActive)
    }

    @Test func unrelatedEventsAreIgnored() {
        var tracker = PhysicalClickTracker()
        let moved = tracker.handle(.mouseMoved, buttonNumber: 0)
        #expect(!moved)
        #expect(!tracker.isActive)
        // A stray up with nothing pressed is a no-op, not a transition.
        let strayUp = tracker.handle(.leftMouseUp, buttonNumber: 0)
        #expect(!strayUp)
        #expect(!tracker.isActive)
    }
}

// Phase 8 — the interceptor's move→drag rewrite: while a hold is armed, a physical
// `mouseMoved` is retyped to the held button's `…MouseDragged` (with its button
// number) so apps see a real drag; otherwise events pass through untouched. Feeding
// synthetic CGEvents keeps this hardware-free; installing the live tap is verified
// manually (docs/05 §Why drag needs the interceptor, §Testability, docs/11 §Phase 8).
@Suite struct DragPromotionTests {
    private func mouseMoved() -> CGEvent {
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: .zero, mouseButton: .left)!
    }

    @Test func armedPromotionRewritesMoveToHeldButtonDragged() {
        let interceptor = EventInterceptor()
        interceptor.beginDragPromotion(zone: .middle)
        let event = mouseMoved()
        #expect(interceptor.applyDragPromotion(type: .mouseMoved, event: event))
        #expect(event.type == .otherMouseDragged)   // middle → other family
        #expect(event.getIntegerValueField(.mouseEventButtonNumber)
                == Int64(CGMouseButton.center.rawValue))
    }

    @Test func rightZoneRewritesToRightDragged() {
        let interceptor = EventInterceptor()
        interceptor.beginDragPromotion(zone: .right)
        let event = mouseMoved()
        #expect(interceptor.applyDragPromotion(type: .mouseMoved, event: event))
        #expect(event.type == .rightMouseDragged)
    }

    @Test func movesPassThroughWhenNotArmed() {
        let interceptor = EventInterceptor()
        let event = mouseMoved()
        #expect(!interceptor.applyDragPromotion(type: .mouseMoved, event: event))
        #expect(event.type == .mouseMoved)
    }

    @Test func nonMoveEventsAreNeverRewrittenEvenWhileArmed() {
        // A held button's own down/up (or any non-move) must not be retyped.
        let interceptor = EventInterceptor()
        interceptor.beginDragPromotion(zone: .left)
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                           mouseCursorPosition: .zero, mouseButton: .left)!
        #expect(!interceptor.applyDragPromotion(type: .leftMouseDown, event: down))
        #expect(down.type == .leftMouseDown)
    }

    @Test func endPromotionRestoresPassThrough() {
        let interceptor = EventInterceptor()
        interceptor.beginDragPromotion(zone: .right)
        interceptor.endDragPromotion()
        let event = mouseMoved()
        #expect(!interceptor.applyDragPromotion(type: .mouseMoved, event: event))
        #expect(event.type == .mouseMoved)
    }
}

/// Records drag-promotion arm/disarm so a test can observe whether `press`/`release`
/// proceeded, without inspecting the real events the emitter posts. Held weakly by the
/// emitter, so the test keeps its own strong reference alive.
private final class DragPromoterSpy: DragPromoting {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    func beginDragPromotion(zone: MouseZone) { beginCount += 1 }
    func endDragPromotion() { endCount += 1 }
}

// Stuck-button safeguards on the emitter (docs/05 §Press/release). Both behaviors
// live on paths that post *nothing* — press bails before the down, release bails
// before the up — so these assert through the promotion spy and never inject a real
// mouse event. The trusted press path (which posts a real button-down) is exercised
// on hardware, not here.
@Suite struct EmitterSafetyTests {
    @Test func pressWithoutAccessibilityDoesNotOpenAHold() {
        let spy = DragPromoterSpy()
        let emitter = CGEventEmitter(isTrusted: { false })
        emitter.dragPromoter = spy

        // Untrusted: the down can't post and — crucially — no drag is armed, so there
        // is no half-open hold for a later revocation to strand.
        emitter.press(.left)
        #expect(spy.beginCount == 0)

        // The mirrored release is then a clean no-op: nothing was held to disarm.
        emitter.release(.left)
        #expect(spy.endCount == 0)
    }

    @Test func releaseWithNothingHeldIsANoOp() {
        let spy = DragPromoterSpy()
        // Trusted, but no prior press: release must not disarm promotion or post a
        // stray up — the idempotence that keeps multiple safety-release paths from
        // lifting a button twice.
        let emitter = CGEventEmitter(isTrusted: { true })
        emitter.dragPromoter = spy

        emitter.release(.left)
        #expect(spy.endCount == 0)
    }
}
