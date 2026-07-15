import Testing
import Foundation
import CoreGraphics
@testable import GestureEngine
import TouchKit

// Phase 2 — the tap primitive + single click, scripted with SurfaceTouch frames
// and asserted through a spy. Pure, hardware-free (docs/03-gesture-recognition.md,
// docs/11-build-plan.md §Phase 2).

/// Collects everything the recognizer emits, so a test can assert the exact
/// gesture sequence (the "SpyEmitter" of the build plan).
private final class GestureSpy {
    private(set) var gestures: [ButtonGesture] = []
    func attach(to recognizer: MouseGestureRecognizer) {
        recognizer.onGesture = { [weak self] in self?.gestures.append($0) }
    }
}

/// A frame carrying its own physical-click state, so a script can flip the
/// hardware-click signal mid-contact.
private struct Frame {
    var touches: [SurfaceTouch]
    var physicalClickActive: Bool
}

private let device = MouseDeviceID(raw: 1)

/// One contact, at a fixed position, described phase-by-phase with timestamps.
/// `began` at `t0`, `ended` at `t0 + duration`; any interior samples are
/// `.moved`. Positions default to the same point (a pure tap).
private func tap(
    id: Int32 = 1,
    at position: CGPoint,
    t0: TimeInterval = 0,
    duration: TimeInterval = 0.10,
    size: CGFloat = 0.3
) -> [Frame] {
    [
        Frame(touches: [SurfaceTouch(deviceID: device, id: id, position: position,
                                     phase: .began, timestamp: t0, size: size)],
              physicalClickActive: false),
        Frame(touches: [SurfaceTouch(deviceID: device, id: id, position: position,
                                     phase: .ended, timestamp: t0 + duration, size: size)],
              physicalClickActive: false),
    ]
}

private func run(_ frames: [Frame], config: GestureConfig = GestureConfig()) -> [ButtonGesture] {
    let recognizer = MouseGestureRecognizer(layout: ZoneLayout(), config: config)
    let spy = GestureSpy()
    spy.attach(to: recognizer)
    for frame in frames {
        recognizer.ingest(frame.touches, physicalClickActive: frame.physicalClickActive)
    }
    return spy.gestures
}

@Suite struct TapPrimitiveTests {
    @Test func validTapEmitsSingleClick() {
        // Left zone (x 0.1 < leftEdge 0.38), well within all tap limits.
        let out = run(tap(at: CGPoint(x: 0.1, y: 0.5)))
        #expect(out == [.click(zone: .left, count: 1)])
    }

    @Test func tooLongIsRejected() {
        // Duration 0.25 s > maxDuration 0.18 s.
        let out = run(tap(at: CGPoint(x: 0.1, y: 0.5), duration: 0.25))
        #expect(out.isEmpty)
    }

    @Test func tooFarIsRejected() {
        // Moves 0.10 (> maxTravel 0.06) from origin before lifting.
        let frames = [
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.10, y: 0.5), phase: .began,
                timestamp: 0, size: 0.3)], physicalClickActive: false),
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.20, y: 0.5), phase: .ended,
                timestamp: 0.10, size: 0.3)], physicalClickActive: false),
        ]
        #expect(run(frames).isEmpty)
    }

    @Test func tooBigIsRejected() {
        // Contact size 20 exceeds maxSize 14 (palm/heel) on the major-axis scale.
        let out = run(tap(at: CGPoint(x: 0.1, y: 0.5), size: 20))
        #expect(out.isEmpty)
    }

    @Test func sizeSpikeMidContactIsRejected() {
        // Starts small, briefly balloons over maxSize, ends small: still rejected
        // because size is judged over the whole life, not just at the ends.
        let frames = [
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.1, y: 0.5), phase: .began,
                timestamp: 0, size: 0.3)], physicalClickActive: false),
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.1, y: 0.5), phase: .moved,
                timestamp: 0.05, size: 20)], physicalClickActive: false),
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.1, y: 0.5), phase: .ended,
                timestamp: 0.10, size: 0.3)], physicalClickActive: false),
        ]
        #expect(run(frames).isEmpty)
    }

    @Test func physicalClickDuringLifetimeIsRejected() {
        // A hardware click fires mid-contact → not our tap to synthesize.
        let frames = [
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.1, y: 0.5), phase: .began,
                timestamp: 0, size: 0.3)], physicalClickActive: false),
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.1, y: 0.5), phase: .moved,
                timestamp: 0.05, size: 0.3)], physicalClickActive: true),
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.1, y: 0.5), phase: .ended,
                timestamp: 0.10, size: 0.3)], physicalClickActive: false),
        ]
        #expect(run(frames).isEmpty)
    }

    @Test func zoneIsDecidedAtBegan() {
        // Lands in left zone, drifts into middle (within travel budget) before
        // lifting — the button stays the began-time zone (.left).
        let frames = [
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.36, y: 0.5), phase: .began,
                timestamp: 0, size: 0.3)], physicalClickActive: false),
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.40, y: 0.5), phase: .ended,
                timestamp: 0.08, size: 0.3)], physicalClickActive: false),
        ]
        // 0.36 < leftEdge 0.38 → .left; 0.40 would be .middle, but zone is fixed.
        #expect(run(frames) == [.click(zone: .left, count: 1)])
    }

    @Test func middleAndRightZonesMap() {
        #expect(run(tap(at: CGPoint(x: 0.5, y: 0.5))) == [.click(zone: .middle, count: 1)])
        #expect(run(tap(at: CGPoint(x: 0.9, y: 0.5))) == [.click(zone: .right, count: 1)])
    }

    @Test func contactWithoutBeganIsIgnored() {
        // A contact first seen mid-stream (no .began) has no tap primitive.
        let frames = [
            Frame(touches: [SurfaceTouch(deviceID: device, id: 1,
                position: CGPoint(x: 0.1, y: 0.5), phase: .ended,
                timestamp: 0.10, size: 0.3)], physicalClickActive: false),
        ]
        #expect(run(frames).isEmpty)
    }
}

// Phase 6 + multi-click. Taps in the same zone within `doubleTapGap` continue a
// run — `click(_, 2)`, `click(_, 3)` — up to `maxClickCount`; the first single is
// always delivered immediately, so there is no single-click latency
// (docs/03-gesture-recognition.md §The unified state machine, §Multi-click).
@Suite struct DoubleClickTests {
    private let left = CGPoint(x: 0.1, y: 0.5)

    @Test func twoTapsInGapEmitSingleThenDouble() {
        // tap1 [0,0.10] → click(1); tap2 begins 0.20 (gap 0.10 ≤ 0.30) → click(2).
        let out = run(tap(at: left, t0: 0) + tap(at: left, t0: 0.20))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2)])
    }

    @Test func secondTapPastGapIsAnotherSingle() {
        // tap2 begins 0.45; gap from tap1's end (0.10) is 0.35 > 0.30 → two singles.
        let out = run(tap(at: left, t0: 0) + tap(at: left, t0: 0.45))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 1)])
    }

    @Test func secondTapInDifferentZoneIsNotADouble() {
        // A second tap in a different zone can't complete the first zone's double;
        // each is its own single click.
        let out = run(tap(at: left, t0: 0)
                    + tap(at: CGPoint(x: 0.9, y: 0.5), t0: 0.20))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .right, count: 1)])
    }

    @Test func nonTapSecondContactLeavesFirstSingleStanding() {
        // Second contact begins in-gap (consuming WAIT_SECOND) but is too long to
        // be a tap → no double, and no spurious extra single. Just the first click.
        let out = run(tap(at: left, t0: 0)
                    + tap(at: left, t0: 0.20, duration: 0.25))
        #expect(out == [.click(zone: .left, count: 1)])
    }

    @Test func threeTapsInGapEmitSingleDoubleTriple() {
        // Each in-gap tap continues the run: click(1) → click(2) → click(3). The
        // triple downstream sets clickState = 3 (line-select in a text view).
        let out = run(tap(at: left, t0: 0)
                    + tap(at: left, t0: 0.20)
                    + tap(at: left, t0: 0.40))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2),
                        .click(zone: .left, count: 3)])
    }

    @Test func fourthTapAfterTripleResetsToSingle() {
        // The run ends at `maxClickCount` (3): a completed triple does not arm a
        // quadruple, so the fourth in-gap tap starts a fresh single-click cycle.
        let out = run(tap(at: left, t0: 0)
                    + tap(at: left, t0: 0.20)
                    + tap(at: left, t0: 0.40)
                    + tap(at: left, t0: 0.60))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2),
                        .click(zone: .left, count: 3),
                        .click(zone: .left, count: 1)])
    }

    @Test func thirdTapPastGapIsAFreshSingle() {
        // A double, then a third tap past the gap (0.30 from the double's end 0.30 →
        // begins 0.65, gap 0.35 > 0.30): the run expired, so it is a new single.
        let out = run(tap(at: left, t0: 0)
                    + tap(at: left, t0: 0.20)
                    + tap(at: left, t0: 0.65))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2),
                        .click(zone: .left, count: 1)])
    }

    @Test func maxClickCountTwoDisablesTriple() {
        // With the cap lowered to 2, the run ends at double, so a third in-gap tap is
        // a fresh single — the setting that reverts to the pre-triple-click behavior.
        var config = GestureConfig()
        config.maxClickCount = 2
        let out = run(tap(at: left, t0: 0)
                    + tap(at: left, t0: 0.20)
                    + tap(at: left, t0: 0.40),
                    config: config)
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2),
                        .click(zone: .left, count: 1)])
    }

    @Test func thirdTapInDifferentZoneIsNotATriple() {
        // A double in the left zone, then a tap in the right zone: the third tap can't
        // continue a different zone's run, so it is that zone's own single.
        let out = run(tap(at: left, t0: 0)
                    + tap(at: left, t0: 0.20)
                    + tap(at: CGPoint(x: 0.9, y: 0.5), t0: 0.40))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2),
                        .click(zone: .right, count: 1)])
    }
}

// Phase 8 — tap-and-a-half drag. A tap, then a second contact in the same zone
// held past `holdThreshold`, promotes the SECOND_ACTIVE branch to a hold:
// `holdBegan` fires on the first live frame past the threshold, `holdEnded` on
// lift. Held-still-then-lift with no interim frame emits neither (safer than a
// phantom press/release) and never a double click
// (docs/03-gesture-recognition.md §The unified state machine, docs/11 §Phase 8).
@Suite struct DragTests {
    private let left = CGPoint(x: 0.1, y: 0.5)

    /// A second contact in `left` that stays down: `.began` at `t0`, one
    /// `.stationary` sample per step until it has lived `hold`, then `.ended`.
    /// Guarantees a live frame past `holdThreshold` so promotion is observed.
    private func heldSecondContact(t0: TimeInterval, hold: TimeInterval) -> [Frame] {
        var frames: [Frame] = [
            Frame(touches: [SurfaceTouch(deviceID: device, id: 2, position: left,
                                         phase: .began, timestamp: t0, size: 0.3)],
                  physicalClickActive: false),
        ]
        // Sample every 20 ms while held (real MultitouchSource streams frames), so
        // some sample lands past holdThreshold before the lift.
        var t = t0 + 0.02
        while t < t0 + hold {
            frames.append(Frame(touches: [SurfaceTouch(deviceID: device, id: 2, position: left,
                                          phase: .stationary, timestamp: t, size: 0.3)],
                                physicalClickActive: false))
            t += 0.02
        }
        frames.append(Frame(touches: [SurfaceTouch(deviceID: device, id: 2, position: left,
                                       phase: .ended, timestamp: t0 + hold, size: 0.3)],
                            physicalClickActive: false))
        return frames
    }

    @Test func heldSecondContactBecomesDrag() {
        // tap → click(1); second contact held 0.30 s (> holdThreshold 0.18) →
        // holdBegan on lift-off from the threshold, holdEnded when it lifts.
        let out = run(tap(at: left, t0: 0)
                    + heldSecondContact(t0: 0.20, hold: 0.30))
        #expect(out == [.click(zone: .left, count: 1),
                        .holdBegan(zone: .left),
                        .holdEnded(zone: .left)])
    }

    @Test func holdBeganFiresOnceWhileHeld() {
        // Many frames past the threshold must not re-arm the drag — exactly one
        // holdBegan, then one holdEnded.
        let out = run(tap(at: left, t0: 0)
                    + heldSecondContact(t0: 0.20, hold: 0.50))
        #expect(out.filter { $0 == .holdBegan(zone: .left) }.count == 1)
        #expect(out.filter { $0 == .holdEnded(zone: .left) }.count == 1)
        #expect(out == [.click(zone: .left, count: 1),
                        .holdBegan(zone: .left),
                        .holdEnded(zone: .left)])
    }

    @Test func directLongPressWithoutFirstTapDoesNothing() {
        // A finger held without a preceding tap is a resting finger, not a drag:
        // no WAIT_SECOND exists, so it is never a second contact → no hold.
        let out = run(heldSecondContact(t0: 0, hold: 0.40))
        #expect(out.isEmpty)
    }

    @Test func heldContactPastGapIsNotADrag() {
        // The second contact begins after doubleTapGap (0.45 > 0.30), so it is a
        // fresh single-click candidate, not a second tap — holding it does not drag.
        let out = run(tap(at: left, t0: 0)
                    + heldSecondContact(t0: 0.45, hold: 0.40))
        // First tap's single, then the held contact fizzles (too long to be its
        // own tap, and not a second contact so it can't promote to a hold).
        #expect(out == [.click(zone: .left, count: 1)])
    }

    @Test func quickSecondContactIsStillADoubleNotADrag() {
        // Held only 0.10 s (< holdThreshold) → lifts as a tap → double click.
        let out = run(tap(at: left, t0: 0)
                    + heldSecondContact(t0: 0.20, hold: 0.10))
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2)])
    }

    @Test func cancelActiveHoldsReleasesAnInFlightDrag() {
        // Drive a drag to the held state (never lifting the second contact), then
        // cancel (feature disabled / app quit): holdEnded must fire so the pressed
        // button is released and can't stick (docs/05 §Press/release).
        let recognizer = MouseGestureRecognizer(layout: ZoneLayout(), config: GestureConfig())  // tapAndAHalf
        let spy = GestureSpy()
        spy.attach(to: recognizer)
        // tap → click(1); second contact begins and is held past the threshold, but
        // its `.ended` frame never arrives — the drag is in flight.
        for frame in tap(at: left, t0: 0) {
            recognizer.ingest(frame.touches, physicalClickActive: frame.physicalClickActive)
        }
        recognizer.ingest([SurfaceTouch(deviceID: device, id: 2, position: left,
            phase: .began, timestamp: 0.20, size: 0.3)], physicalClickActive: false)
        recognizer.ingest([SurfaceTouch(deviceID: device, id: 2, position: left,
            phase: .stationary, timestamp: 0.45, size: 0.3)], physicalClickActive: false)
        #expect(spy.gestures == [.click(zone: .left, count: 1), .holdBegan(zone: .left)])

        recognizer.cancelActiveHolds()
        #expect(spy.gestures == [.click(zone: .left, count: 1),
                                 .holdBegan(zone: .left),
                                 .holdEnded(zone: .left)])

        // State is cleared: a late `.ended` for the cancelled contact is inert.
        recognizer.ingest([SurfaceTouch(deviceID: device, id: 2, position: left,
            phase: .ended, timestamp: 0.60, size: 0.3)], physicalClickActive: false)
        #expect(spy.gestures.filter { $0 == .holdEnded(zone: .left) }.count == 1)
    }
}

// Phase 8 — the `pressAndHold` drag style (behind a settings toggle): a *single*
// contact held *still* past `holdThreshold`, with **no** leading tap, becomes a
// clean single-press drag. Gated by stillness (a finger *slide* is a scroll, not a
// drag) and single-contact (a two-finger gesture can't arm it). Normal taps and
// double clicks are unaffected (docs/03 §The v1 gesture set, docs/11 §Phase 8).
@Suite struct PressAndHoldDragTests {
    private let cfg = GestureConfig(dragStyle: .pressAndHold)
    private let left = CGPoint(x: 0.1, y: 0.5)

    /// A single contact at `p`: `.began` at `t0`, a `.stationary`/`.moved` sample
    /// every 20 ms until it has lived `hold`, then `.ended`. `drift` is the total
    /// on-shell travel spread across the samples (0 = perfectly still).
    private func held(
        at p: CGPoint, t0: TimeInterval = 0, hold: TimeInterval,
        drift: CGFloat = 0, id: Int32 = 1, others: [SurfaceTouch] = []
    ) -> [Frame] {
        func frame(_ x: CGFloat, _ phase: TouchPhase, _ t: TimeInterval) -> Frame {
            Frame(touches: [SurfaceTouch(deviceID: device, id: id,
                position: CGPoint(x: x, y: p.y), phase: phase, timestamp: t, size: 0.3)] + others,
                  physicalClickActive: false)
        }
        var frames = [frame(p.x, .began, t0)]
        var t = t0 + 0.02
        while t < t0 + hold {
            let f = min(1, (t - t0) / hold)
            frames.append(frame(p.x + drift * f, .moved, t))
            t += 0.02
        }
        frames.append(frame(p.x + drift, .ended, t0 + hold))
        return frames
    }

    @Test func stillSinglePressBecomesDragWithNoLeadingClick() {
        // No preceding tap: a held-still contact drags directly. No click(1) leaks —
        // that is the whole point (precise, no word pre-select).
        let out = run(held(at: left, hold: 0.30), config: cfg)
        #expect(out == [.holdBegan(zone: .left), .holdEnded(zone: .left)])
    }

    @Test func quickPressIsStillJustAClick() {
        // Released before holdThreshold → an ordinary tap → click, no drag. Clicks
        // keep their zero added latency in this mode.
        let out = run(held(at: left, hold: 0.10), config: cfg)
        #expect(out == [.click(zone: .left, count: 1)])
    }

    @Test func slidingFingerDoesNotDrag() {
        // A finger that slides past maxTravel (0.06) before the threshold is a scroll,
        // not a press — never promotes, and (too far to be a tap) emits nothing.
        let out = run(held(at: left, hold: 0.30, drift: 0.20), config: cfg)
        #expect(out.isEmpty)
    }

    @Test func twoFingerHoldDoesNotDrag() {
        // A second simultaneous contact means it isn't a single-finger press — no drag.
        let other = SurfaceTouch(deviceID: device, id: 9, position: CGPoint(x: 0.9, y: 0.5),
                                 phase: .moved, timestamp: 0, size: 0.3)
        let out = run(held(at: left, hold: 0.30, others: [other]), config: cfg)
        #expect(!out.contains(.holdBegan(zone: .left)))
    }

    @Test func doubleClickStillWorksInPressAndHold() {
        // Two quick taps in-gap → single then double, unaffected by the drag style.
        let out = run(tap(at: left, t0: 0) + tap(at: left, t0: 0.20), config: cfg)
        #expect(out == [.click(zone: .left, count: 1),
                        .click(zone: .left, count: 2)])
    }

    @Test func holdBeganFiresOnce() {
        let out = run(held(at: left, hold: 0.50), config: cfg)
        #expect(out.filter { $0 == .holdBegan(zone: .left) }.count == 1)
        #expect(out == [.holdBegan(zone: .left), .holdEnded(zone: .left)])
    }
}
