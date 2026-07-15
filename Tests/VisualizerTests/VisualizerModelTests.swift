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

    @Test func registerClickTitlesByCount() {
        let model = VisualizerModel()
        model.register(.click(.left, count: 1))
        #expect(model.lastFlash?.title == "Tap")
        #expect(model.lastFlash?.zone == .left)

        model.register(.click(.middle, count: 2))
        #expect(model.lastFlash?.title == "Double-tap")
        #expect(model.lastFlash?.zone == .middle)
    }

    @Test func eachRegisterAdvancesTheFlashID() {
        let model = VisualizerModel()
        model.register(.click(.right, count: 1))
        let first = model.lastFlash?.id
        model.register(.click(.right, count: 1))   // same title, new event
        #expect(first != nil)
        #expect(model.lastFlash?.id != first)      // id advances so the view re-animates
    }

    @Test func holdBeganFlashesHoldAndHoldEndedClears() {
        let model = VisualizerModel()
        model.register(.holdBegan(.right))
        #expect(model.lastFlash?.title == "Hold")
        model.register(.holdEnded(.right))
        #expect(model.lastFlash == nil)
    }
}
