import Testing
import Foundation
import CoreGraphics
@testable import AppCore
import GestureEngine
import TouchKit

// Phase 7.4 — the recognizer → policy → emitter core. Pure, hardware-free: scripted
// frames in, spy-emitter calls out (docs/11 §Phase 7.4).

@MainActor
@Suite struct GesturePipelineTests {

    private func makePipeline(policy: FeaturePolicy) -> (GesturePipeline, SpyEmitter) {
        let spy = SpyEmitter()
        let pipeline = GesturePipeline(
            layout: ZoneLayout(), config: GestureConfig(), emitter: spy, policy: policy)
        return (pipeline, spy)
    }

    private func feed(_ pipeline: GesturePipeline, _ frames: [[SurfaceTouch]]) {
        for frame in frames { pipeline.ingest(frame) }
    }

    /// A drag left in flight — see `holdInFlightFrames` (shared with the coordinator
    /// tests, which drive the same scenario through the device-loss path).
    private func holdInFlight(x: CGFloat) -> [[SurfaceTouch]] { holdInFlightFrames(x: x) }

    @Test func allowedTapEmitsClick() {
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        feed(pipeline, tapFrames(x: 0.1))   // left zone
        #expect(spy.clicks.count == 1)
        #expect(spy.clicks.first?.zone == .left)
        #expect(spy.clicks.first?.count == 1)
    }

    @Test func policyBlocksDisabledZoneButNotOthers() {
        // tap-to-click off (left/right blocked), middle tap-to-click on.
        let (pipeline, spy) = makePipeline(
            policy: FeaturePolicy(tapToClick: false, middleTapToClick: true))
        feed(pipeline, tapFrames(x: 0.1))   // left → blocked
        feed(pipeline, tapFrames(x: 0.5, t0: 1))   // middle → allowed
        #expect(spy.clickedZones == [.middle])
    }

    @Test func masterDisableBlocksEverything() {
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy(masterEnabled: false))
        feed(pipeline, tapFrames(x: 0.1))
        feed(pipeline, tapFrames(x: 0.5, t0: 1))
        #expect(spy.clicks.isEmpty)
    }

    @Test func policyChangesApplyLive() {
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        feed(pipeline, tapFrames(x: 0.1))          // allowed
        pipeline.policy.masterEnabled = false      // flip live
        feed(pipeline, tapFrames(x: 0.9, t0: 1))   // now blocked
        #expect(spy.clickedZones == [.left])
    }

    @Test func cancelActiveHoldsIsSafeWithNoHolds() {
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        pipeline.cancelActiveHolds()   // no active holds — must be a clean no-op
        #expect(spy.releases.isEmpty)
    }

    @Test func heldSecondContactPressesThenReleasesOnLift() {
        // tap → click; second contact held → press; lift → release. A completed drag
        // (docs/03 §state machine, docs/05 §Press/release).
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        let device = MouseDeviceID(raw: 1)
        feed(pipeline, holdInFlight(x: 0.1))   // left: tap + held (still down)
        pipeline.ingest([SurfaceTouch(deviceID: device, id: 2,
            position: CGPoint(x: 0.1, y: 0.5), phase: .ended, timestamp: 0.60, size: 0.3)])
        #expect(spy.clickedZones == [.left])
        #expect(spy.presses == [.left])
        #expect(spy.releases == [.left])
    }

    @Test func cancelActiveHoldsReleasesAnInFlightDrag() {
        // A drag left in flight (button pressed, finger still down) is released by the
        // coordinator's safety hook — no stuck button on disable/quit/device-loss.
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        feed(pipeline, holdInFlight(x: 0.5))   // middle: tap + held (still down)
        #expect(spy.presses == [.middle])
        #expect(spy.releases.isEmpty)          // not lifted yet

        pipeline.cancelActiveHolds()
        #expect(spy.releases == [.middle])
    }

    @Test func holdReleaseIsDeliveredEvenWhenFeatureDisabledMidHold() {
        // Feature toggled off while a middle drag is held: the button-up must still
        // fire so it can't stick — release exactly what was pressed (docs/05).
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        let device = MouseDeviceID(raw: 1)
        feed(pipeline, holdInFlight(x: 0.5))   // middle press
        #expect(spy.presses == [.middle])
        pipeline.policy.middleTapToClick = false   // disable mid-hold
        pipeline.ingest([SurfaceTouch(deviceID: device, id: 2,
            position: CGPoint(x: 0.5, y: 0.5), phase: .ended, timestamp: 0.60, size: 0.3)])
        #expect(spy.releases == [.middle])
    }

    @Test func reconfigureKeepsRecognizingUnderNewLayout() {
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        pipeline.reconfigure(layout: ZoneLayout(leftEdge: 0.2, rightEdge: 0.8),
                             config: GestureConfig())
        feed(pipeline, tapFrames(x: 0.5))   // middle under the new wider layout
        #expect(spy.clickedZones == [.middle])
        #expect(spy.releases.isEmpty)
    }

    @Test func reconfigurePreservesAnInFlightHold() {
        // Dragging a settings slider *with* a MagicButtons hold reconfigures the
        // recognizer on every increment — that must NOT cancel the hold driving it
        // (the self-cancelling loop that stopped the app's own sliders from dragging).
        // The hold survives the live edit and still releases on the eventual lift.
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        let device = MouseDeviceID(raw: 1)
        feed(pipeline, holdInFlight(x: 0.5))   // middle: tap + held (still down)
        #expect(spy.presses == [.middle])
        #expect(spy.releases.isEmpty)

        // A live tunable/zone edit mid-hold: no stray button-up.
        pipeline.reconfigure(layout: ZoneLayout(leftEdge: 0.2, rightEdge: 0.8),
                             config: GestureConfig())
        #expect(spy.releases.isEmpty)

        // Finger finally lifts → the preserved contact still fires its release.
        pipeline.ingest([SurfaceTouch(deviceID: device, id: 2,
            position: CGPoint(x: 0.5, y: 0.5), phase: .ended, timestamp: 0.60, size: 0.3)])
        #expect(spy.releases == [.middle])
    }

    @Test func leftHandedSideSwapsLeftAndRightClicksButNotMiddle() {
        // Secondary-click on the left (a left-handed mouse config): the left tap zone
        // emits the secondary (right) button and the right zone the primary (left);
        // middle is unaffected (docs/05 §Zone → button).
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        pipeline.secondaryClickSide = .left
        feed(pipeline, tapFrames(x: 0.1))          // left zone  → right click
        feed(pipeline, tapFrames(x: 0.9, t0: 1))   // right zone → left click
        feed(pipeline, tapFrames(x: 0.5, t0: 2))   // middle     → middle
        #expect(spy.clickedZones == [.right, .left, .middle])
    }

    @Test func leftHandedSideSwapsAHeldDrag() {
        // A drag begun in the left zone presses/releases the swapped (right) button, and
        // the swap round-trips so the same button that went down comes back up.
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        pipeline.secondaryClickSide = .left
        let device = MouseDeviceID(raw: 1)
        feed(pipeline, holdInFlight(x: 0.1))   // left zone, held → right button down
        #expect(spy.presses == [.right])
        #expect(spy.releases.isEmpty)
        pipeline.ingest([SurfaceTouch(deviceID: device, id: 2,
            position: CGPoint(x: 0.1, y: 0.5), phase: .ended, timestamp: 0.60, size: 0.3)])
        #expect(spy.releases == [.right])
    }

    @Test func defaultRightSideLeavesMappingUnswapped() {
        let (pipeline, spy) = makePipeline(policy: FeaturePolicy())
        #expect(pipeline.secondaryClickSide == .right)   // default
        feed(pipeline, tapFrames(x: 0.1))                // left zone → left click
        #expect(spy.clickedZones == [.left])
    }
}
