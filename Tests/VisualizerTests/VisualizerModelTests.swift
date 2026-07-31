import Testing
import Foundation
import CoreGraphics
import TouchKit
@testable import Visualizer

// Phase 5 — the visualizer's data feed. The view itself needs hardware to judge,
// but the model's frame→(touches, activeZone) logic is pure and testable.

@MainActor
@Suite struct VisualizerModelTests {
    private func touch(_ x: CGFloat, phase: TouchPhase = .moved, id: Int32 = 1) -> SurfaceTouch {
        SurfaceTouch(deviceID: MouseDeviceID(raw: 1), id: id,
                     position: CGPoint(x: x, y: 0.5), phase: phase, timestamp: 0, size: 9)
    }

    @Test func startsEmpty() {
        let model = VisualizerModel()
        #expect(model.touches.isEmpty)
        #expect(model.activeZone == nil)
    }

    @Test func updatePublishesTouchesAndActiveZone() {
        let model = VisualizerModel()
        model.update([touch(0.90)])
        #expect(model.touches.count == 1)
        #expect(model.activeZone == .right)
    }

    @Test func emptyFrameClearsActiveZone() {
        let model = VisualizerModel()
        model.update([touch(0.10)])
        #expect(model.activeZone == .left)
        model.update([])
        #expect(model.touches.isEmpty)
        #expect(model.activeZone == nil)
    }

    @Test func allEndedFrameCountsAsNoFinger() {
        let model = VisualizerModel()
        model.update([touch(0.10, phase: .ended)])
        #expect(model.touches.count == 1)   // still drawn as it lifts
        #expect(model.activeZone == nil)    // but not an active contact
    }

    @Test func activeZoneUsesFirstLiveContact() {
        let model = VisualizerModel()
        model.update([touch(0.10, phase: .ended, id: 1), touch(0.90, phase: .moved, id: 2)])
        #expect(model.activeZone == .right)
    }

    @Test func activeZoneCarriesHysteresisAcrossFrames() {
        let model = VisualizerModel()
        model.update([touch(0.10)])          // left
        model.update([touch(0.39)])          // inside +0.02 band → held left
        #expect(model.activeZone == .left)
        model.update([touch(0.41)])          // past band → middle
        #expect(model.activeZone == .middle)
    }

    @Test func layoutEditRepointsHysteresisMapper() {
        let model = VisualizerModel()
        model.update([touch(0.30)])          // left under default 0.38 edge
        #expect(model.activeZone == .left)
        model.layout = ZoneLayout(leftEdge: 0.20, rightEdge: 0.80)
        model.update([touch(0.30)])          // now inside the wider middle
        #expect(model.activeZone == .middle)
    }

    // MARK: Gesture flash (Phase 7.6 — tuning feedback)

    @Test func startsWithNoFlash() {
        #expect(VisualizerModel().lastFlash == nil)
    }

    @Test func registerClickCarriesTheTapCount() {
        let model = VisualizerModel()
        model.register(.click(.left, count: 1))
        #expect(model.lastFlash?.kind == .tap(count: 1))
        #expect(model.lastFlash?.zone == .left)

        model.register(.click(.middle, count: 2))
        #expect(model.lastFlash?.kind == .tap(count: 2))
        #expect(model.lastFlash?.zone == .middle)

        // Beyond a double the count passes through untouched — the view names it.
        model.register(.click(.right, count: 3))
        #expect(model.lastFlash?.kind == .tap(count: 3))
    }

    @Test func eachRegisterAdvancesTheFlashID() {
        let model = VisualizerModel()
        model.register(.click(.right, count: 1))
        let first = model.lastFlash?.id
        model.register(.click(.right, count: 1))   // same gesture, new event
        #expect(first != nil)
        #expect(model.lastFlash?.id != first)      // id advances so the view re-animates
    }

    @Test func holdBeganFlashesHoldAndHoldEndedClears() {
        let model = VisualizerModel()
        model.register(.holdBegan(.right))
        #expect(model.lastFlash?.kind == .hold)
        model.register(.holdEnded(.right))
        #expect(model.lastFlash == nil)
    }
}

// MARK: Spoken readout (strand 3 — the visualizer for users who can't see it)

/// The gate decides *when* to speak; `VisualizerView` decides the words and whether
/// anyone is listening. Driven through the model rather than the gate directly,
/// because the frame → active-zone → announcement path is the thing that has to hold.
@MainActor
@Suite struct VisualizerAnnouncementTests {
    private func touch(_ x: CGFloat, phase: TouchPhase = .moved) -> SurfaceTouch {
        SurfaceTouch(deviceID: MouseDeviceID(raw: 1), id: 1,
                     position: CGPoint(x: x, y: 0.5), phase: phase, timestamp: 0, size: 9)
    }

    /// Past the dwell with room to spare, so a test never sits on the threshold.
    private let settled = AnnouncementGate.dwell + 0.05

    @Test func startsWithNothingToSay() {
        #expect(VisualizerModel().zoneAnnouncement == nil)
    }

    /// The point of the dwell. A tap's contact is gone inside `maxDuration` (180 ms by
    /// default), well short of it, so the tap speaks only its gesture — landing never
    /// narrates itself.
    @Test func aTapIsTooBriefToSpeakItsZone() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        model.update([touch(0.10)], at: 0.18)
        model.update([], at: 0.19)
        #expect(model.zoneAnnouncement == nil)
    }

    /// The other half: a finger that stays put is someone feeling for the boundaries,
    /// which is exactly what the picture is for.
    @Test func aRestingFingerSpeaksItsZoneOnceSettled() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        #expect(model.zoneAnnouncement == nil)      // still dwelling
        model.update([touch(0.10)], at: settled)
        #expect(model.zoneAnnouncement?.zone == .left)
    }

    @Test func aSettledZoneIsNotRepeatedFrameAfterFrame() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        model.update([touch(0.10)], at: settled)
        let spoken = model.zoneAnnouncement?.id
        model.update([touch(0.10)], at: settled + 1)
        model.update([touch(0.10)], at: settled + 2)
        #expect(model.zoneAnnouncement?.id == spoken)
    }

    /// Crossing a boundary restarts the clock, so sliding across the middle band
    /// doesn't announce it in passing — only settling in it does.
    @Test func crossingIntoANewZoneRestartsTheDwell() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        model.update([touch(0.10)], at: settled)
        #expect(model.zoneAnnouncement?.zone == .left)

        model.update([touch(0.50)], at: settled + 0.1)         // into the middle
        model.update([touch(0.50)], at: settled + 0.2)         // still short of the dwell
        #expect(model.zoneAnnouncement?.zone == .left)
        model.update([touch(0.50)], at: settled + 0.1 + settled)
        #expect(model.zoneAnnouncement?.zone == .middle)
    }

    /// Lifting says nothing — the user knows they lifted — but it does re-arm, so the
    /// next contact names its zone instead of being taken for a repeat of the last.
    @Test func liftingIsSilentAndRearmsTheNextContact() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        model.update([touch(0.10)], at: settled)
        let first = model.zoneAnnouncement?.id
        #expect(first != nil)

        model.update([], at: settled + 0.1)
        #expect(model.zoneAnnouncement?.id == first)            // silence, not a new event

        model.update([touch(0.10)], at: settled + 1)            // same zone, new contact
        model.update([touch(0.10)], at: settled + 1 + settled)
        #expect(model.zoneAnnouncement?.zone == .left)
        #expect(model.zoneAnnouncement?.id != first)            // and it does speak again
    }

    /// A press-and-hold registers at `holdThreshold` (180 ms), before the dwell. The
    /// badge names its own zone and the view speaks it, so the dwell must not follow up
    /// with a bare "left" a fraction of a second later.
    @Test func aGestureSuppressesTheZoneItAlreadyNamed() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        model.register(.holdBegan(.left), at: 0.18)
        model.update([touch(0.10)], at: settled)
        model.update([touch(0.10)], at: settled + 1)
        #expect(model.zoneAnnouncement == nil)
    }

    /// …but only for the zone it named. Move on from it while still holding and that
    /// new zone is news again.
    @Test func aGestureDoesNotSilenceALaterZone() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        model.register(.holdBegan(.left), at: 0.18)
        model.update([touch(0.90)], at: 0.5)
        model.update([touch(0.90)], at: 0.5 + settled)
        #expect(model.zoneAnnouncement?.zone == .right)
    }

    /// The one case `minimumGap` actually catches, and the reason it isn't dead code:
    /// two *zone* announcements can never crowd each other, since changing zone restarts
    /// the dwell. A zone crowding a **gesture** takes two fingers — one resting in the
    /// middle while another taps left. The resting finger's zone is deferred, not
    /// dropped, so it still arrives once the gap is clear.
    @Test func aZoneWaitsItsTurnBehindAGestureInAnotherZone() {
        let model = VisualizerModel()
        model.update([touch(0.50)], at: 0)                  // a finger resting in the middle
        model.register(.click(.left, count: 1), at: 0.10)   // another one taps left

        model.update([touch(0.50)], at: settled)            // dwell is up, but the gap isn't
        #expect(model.zoneAnnouncement == nil)
        model.update([touch(0.50)], at: 0.10 + AnnouncementGate.minimumGap + 0.01)
        #expect(model.zoneAnnouncement?.zone == .middle)
    }

    /// `holdEnded` clears the badge and speaks nothing, so it has nothing to report to
    /// the gate — and must not be mistaken for a gesture that named a zone.
    @Test func holdEndedDoesNotCountAsSomethingSpoken() {
        let model = VisualizerModel()
        model.update([touch(0.10)], at: 0)
        model.register(.holdEnded(.left), at: 0.18)
        model.update([touch(0.10)], at: settled)
        #expect(model.zoneAnnouncement?.zone == .left)
    }
}

@MainActor
@Suite struct VisualizerBudgetTests {
    private func budget(
        id: Int32 = 1, maxTravelMM: CGFloat = 1.0, displacementMM: CGFloat? = nil,
        verdict: VisualizerModel.ContactBudget.Verdict = .wouldTap
    ) -> VisualizerModel.ContactBudget {
        VisualizerModel.ContactBudget(id: id, origin: CGPoint(x: 0.5, y: 0.5),
                                      maxTravelMM: maxTravelMM,
                                      displacementMM: displacementMM ?? maxTravelMM,
                                      budgetMM: 4.1, verdict: verdict)
    }

    private func touch(_ x: CGFloat) -> SurfaceTouch {
        SurfaceTouch(deviceID: MouseDeviceID(raw: 1), id: 1,
                     position: CGPoint(x: x, y: 0.5), phase: .moved, timestamp: 0, size: 9)
    }

    @Test func startsWithNoBudgets() {
        #expect(VisualizerModel().budgets.isEmpty)
    }

    /// The harness and previews drive the picture with no recognizer behind them, so
    /// the budget argument defaults away rather than forcing every caller to have one.
    @Test func updateWithoutBudgetsLeavesThemEmpty() {
        let model = VisualizerModel()
        model.update([touch(0.5)])
        #expect(model.touches.count == 1)
        #expect(model.budgets.isEmpty)
    }

    @Test func updatePublishesBudgets() {
        let model = VisualizerModel()
        model.update([touch(0.5)], budgets: [budget(maxTravelMM: 2.0)])
        #expect(model.budgets.count == 1)
        #expect(model.budgets.first?.maxTravelMM == 2.0)
        #expect(model.budgets.first?.verdict == .wouldTap)
    }

    /// Budgets belong to the frame they arrived with — a later frame with none must
    /// clear them, or a ring would outlive the contact that owned it.
    @Test func aFrameWithoutBudgetsClearsThePreviousOnes() {
        let model = VisualizerModel()
        model.update([touch(0.5)], budgets: [budget()])
        model.update([])
        #expect(model.budgets.isEmpty)
    }

    /// The two are equal until the finger retreats; after that the drawing needs both,
    /// so the model must not collapse them.
    @Test func carriesDisplacementApartFromTheHighWaterMark() {
        let model = VisualizerModel()
        model.update([touch(0.5)], budgets: [budget(maxTravelMM: 3.5, displacementMM: 1.0)])
        #expect(model.budgets.first?.maxTravelMM == 3.5)
        #expect(model.budgets.first?.displacementMM == 1.0)
    }

    @Test func carriesTheVerdictThatTripped() {
        let model = VisualizerModel()
        model.update([touch(0.5)], budgets: [budget(maxTravelMM: 6.0, verdict: .rejectedTravel)])
        #expect(model.budgets.first?.verdict == .rejectedTravel)
    }
}
