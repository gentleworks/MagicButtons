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
