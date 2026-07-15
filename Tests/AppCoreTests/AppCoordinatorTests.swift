import Testing
import Foundation
@testable import AppCore
import TouchKit
import GestureEngine

// Phase 7.4 — the coordinator's lifecycle, degradation handling, master enable, and
// device re-enumeration, driven with injected fakes (docs/11 §Phase 7.4). The live
// frame path is verified on hardware via `verify-gesture`.

@MainActor
@Suite struct AppCoordinatorTests {

    private func makeCoordinator(
        settings: AppSettings = .init()
    ) -> (AppCoordinator, ControllableSource, FakeClickSource, SpyEmitter) {
        let source = ControllableSource()
        let click = FakeClickSource()
        let emitter = SpyEmitter()
        let coordinator = AppCoordinator(
            source: source, clickSource: click, emitter: emitter, settings: settings)
        return (coordinator, source, click, emitter)
    }

    // MARK: Lifecycle

    @Test func startStartsBothStreams() {
        let (coordinator, source, click, _) = makeCoordinator()
        coordinator.start()
        #expect(coordinator.isRunning)
        #expect(coordinator.isDeviceConnected)
        #expect(coordinator.sourceError == nil)
        #expect(!coordinator.interceptorFailed)
        #expect(source.startCount == 1)
        #expect(click.startCount == 1)
    }

    @Test func startIsIdempotent() {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.start()
        coordinator.start()
        #expect(source.startCount == 1)
    }

    @Test func stopStopsBothStreams() {
        let (coordinator, source, click, _) = makeCoordinator()
        coordinator.start()
        coordinator.stop()
        #expect(!coordinator.isRunning)
        #expect(!coordinator.isDeviceConnected)
        #expect(source.stopCount == 1)
        #expect(click.stopCount == 1)
    }

    @Test func stopIsIdempotentWhenNotRunning() {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.stop()
        #expect(source.stopCount == 0)
    }

    // MARK: Degradation (recorded, not thrown)

    @Test func missingDeviceIsRecordedAndStillRuns() {
        let source = ControllableSource()
        source.startError = .noDevice        // no Magic Mouse
        let click = FakeClickSource()
        let coordinator = AppCoordinator(source: source, clickSource: click, emitter: SpyEmitter())
        coordinator.start()
        #expect(coordinator.isRunning)               // app stays up
        #expect(!coordinator.isDeviceConnected)
        #expect(coordinator.sourceError == .noDevice)
        #expect(click.startCount == 1)               // click source still started (degraded)
    }

    @Test func interceptorFailureIsRecordedAndStillRuns() {
        let source = ControllableSource()
        let click = FakeClickSource()
        click.startShouldThrow = true        // e.g. Accessibility missing
        let coordinator = AppCoordinator(source: source, clickSource: click, emitter: SpyEmitter())
        coordinator.start()
        #expect(coordinator.isRunning)
        #expect(coordinator.interceptorFailed)
        #expect(source.startCount == 1)      // touch source still started
    }

    // MARK: Mid-run Accessibility grant (Phase 9 first-run flow)

    @Test func retryStreamReArmsTapAfterAccessibilityGranted() {
        let source = ControllableSource()
        let click = FakeClickSource()
        click.startShouldThrow = true            // Accessibility missing at launch
        let coordinator = AppCoordinator(source: source, clickSource: click, emitter: SpyEmitter())
        coordinator.start()
        #expect(coordinator.interceptorFailed)
        #expect(click.startCount == 1)

        // User grants Accessibility → the tap now installs in place, no relaunch.
        click.startShouldThrow = false
        coordinator.retryStream(for: .accessibility)
        #expect(!coordinator.interceptorFailed)
        #expect(click.startCount == 2)           // retried exactly once
    }

    @Test func retryStreamIsNoOpWhenTapAlreadyInstalled() {
        let (coordinator, _, click, _) = makeCoordinator()
        coordinator.start()
        #expect(!coordinator.interceptorFailed)
        coordinator.retryStream(for: .accessibility)
        #expect(click.startCount == 1)           // not restarted when already healthy
    }

    @Test func retryStreamIsNoOpWhenStopped() {
        let (coordinator, _, click, _) = makeCoordinator()
        coordinator.retryStream(for: .accessibility)
        #expect(click.startCount == 0)
    }

    @Test func retryStreamStillFailingLeavesInterceptorFailed() {
        let source = ControllableSource()
        let click = FakeClickSource()
        click.startShouldThrow = true
        let coordinator = AppCoordinator(source: source, clickSource: click, emitter: SpyEmitter())
        coordinator.start()
        coordinator.retryStream(for: .accessibility)  // tap still can't install
        #expect(coordinator.interceptorFailed)        // → the App falls back to a relaunch prompt
    }

    // MARK: Click-interceptor lifetime (scoped to master-enabled + Accessibility)

    @Test func launchingDisabledInstallsNoTap() {
        // The tap has no job when the master toggle is off — only the touch source needs to
        // run (it drives the visualizer). So a disabled launch must hold no HID tap at all.
        var settings = AppSettings()
        settings.features.masterEnabled = false
        let (coordinator, source, click, _) = makeCoordinator(settings: settings)
        coordinator.start()
        #expect(coordinator.isRunning)
        #expect(source.startCount == 1)          // touch source (visualizer) still runs
        #expect(click.startCount == 0)           // but no event tap
        #expect(!coordinator.interceptorFailed)  // absence-by-design isn't a failure
    }

    @Test func disablingTearsDownTheTapAndReenablingReinstalls() {
        let (coordinator, _, click, _) = makeCoordinator()   // enabled by default
        coordinator.start()
        #expect(click.startCount == 1)

        coordinator.setEnabled(false)
        #expect(click.stopCount == 1)            // tap removed the moment we're switched off

        coordinator.setEnabled(true)
        #expect(click.startCount == 2)           // and reinstalled when switched back on
    }

    @Test func suspendClickInterceptionRemovesTheTapAndReGrantReinstalls() {
        // Revoking Accessibility mid-run must pull the tap out of the HID path at once, or
        // every physical click routes into a tap the process is no longer trusted to service
        // and clicking wedges system-wide (docs/05 §Interceptor lifetime).
        let (coordinator, _, click, _) = makeCoordinator()
        coordinator.start()
        #expect(click.startCount == 1)

        coordinator.suspendClickInterception()   // Accessibility revoked
        #expect(click.stopCount == 1)

        coordinator.retryStream(for: .accessibility)  // re-granted → reinstalled in place
        #expect(click.startCount == 2)
    }

    @Test func disablingReleasesAnInFlightHoldBeforeRemovingTheTap() async {
        // Tearing the tap down mid-drag must lift the synthetic button first, or it stays
        // stuck (docs/05 §Stuck-button safeguards) — the same guarantee `refreshDevices` makes.
        let (coordinator, source, _, emitter) = makeCoordinator()
        coordinator.start()

        for frame in holdInFlightFrames(x: 0.5) { source.onFrame?(frame) }
        for _ in 0..<20 where emitter.presses.isEmpty { await Task.yield() }
        #expect(emitter.presses == [.middle])
        #expect(emitter.releases.isEmpty)        // still held — finger never lifted

        coordinator.setEnabled(false)            // switch off mid-drag
        #expect(emitter.releases == [.middle])   // button lifted, not stranded
    }

    // MARK: Device re-enumeration

    @Test func refreshDevicesReenumerates() {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.start()                  // startCount 1
        coordinator.refreshDevices()         // stop + start again
        #expect(source.stopCount == 1)
        #expect(source.startCount == 2)
        #expect(coordinator.isDeviceConnected)
    }

    @Test func refreshDevicesTracksDetachThenReattach() {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.start()

        source.startError = .noDevice        // unplug
        coordinator.refreshDevices()
        #expect(!coordinator.isDeviceConnected)
        #expect(coordinator.sourceError == .noDevice)

        source.startError = nil              // replug
        coordinator.refreshDevices()
        #expect(coordinator.isDeviceConnected)
        #expect(coordinator.sourceError == nil)
    }

    @Test func refreshDevicesIsNoOpWhenStopped() {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.refreshDevices()
        #expect(source.startCount == 0)
    }

    @Test func deviceLossReleasesAnInFlightDrag() async {
        // Stuck-button Tier 2 (docs/05 §Stuck-button safeguards): a Magic Mouse that
        // disconnects mid-drag never sends the `.ended` frame that lifts the synthetic
        // button, so the device-loss hook (DeviceMonitor → refreshDevices) must lift it.
        // This is the *coordinator-level* guarantee — that `refreshDevices` releases —
        // so a future change to it can't silently strand a button.
        let (coordinator, source, _, emitter) = makeCoordinator()
        coordinator.start()

        // Drive a drag into flight. Frames marshal onto the main actor
        // (Task { @MainActor }), so drain the hops before asserting.
        for frame in holdInFlightFrames(x: 0.5) { source.onFrame?(frame) }
        for _ in 0..<20 where emitter.presses.isEmpty { await Task.yield() }
        #expect(emitter.presses == [.middle])
        #expect(emitter.releases.isEmpty)          // still held — finger never lifted

        coordinator.refreshDevices()               // the mouse vanished mid-drag
        #expect(emitter.releases == [.middle])     // button lifted, not left stuck
    }

    // MARK: Touch liveness (error-state observability, Phase 9.2)

    @Test func touchesNotArrivingUntilFirstFrame() async {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.start()
        // Device enumerated but no frame yet — the "connected but deaf" state
        // (e.g. Input Monitoring missing): sourceError stays nil, yet it's degraded.
        #expect(coordinator.isDeviceConnected)
        #expect(coordinator.sourceError == nil)
        #expect(!coordinator.hasReceivedFrameSinceStart)
        #expect(coordinator.touchesNotArriving)

        for frame in tapFrames(x: 0.5) { source.onFrame?(frame) }
        for _ in 0..<20 where !coordinator.hasReceivedFrameSinceStart { await Task.yield() }

        #expect(coordinator.hasReceivedFrameSinceStart)
        #expect(!coordinator.touchesNotArriving)   // stream is live
    }

    @Test func stopClearsTouchLiveness() async {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.start()
        for frame in tapFrames(x: 0.5) { source.onFrame?(frame) }
        for _ in 0..<20 where !coordinator.hasReceivedFrameSinceStart { await Task.yield() }
        #expect(coordinator.hasReceivedFrameSinceStart)

        coordinator.stop()
        #expect(!coordinator.hasReceivedFrameSinceStart)
        #expect(!coordinator.touchesNotArriving)   // not running → not a degraded state
    }

    @Test func refreshDevicesClearsLivenessUntilNextFrame() async {
        let (coordinator, source, _, _) = makeCoordinator()
        coordinator.start()
        for frame in tapFrames(x: 0.5) { source.onFrame?(frame) }
        for _ in 0..<20 where !coordinator.hasReceivedFrameSinceStart { await Task.yield() }
        #expect(coordinator.hasReceivedFrameSinceStart)

        coordinator.refreshDevices()               // re-enumerate: liveness resets
        #expect(!coordinator.hasReceivedFrameSinceStart)
        #expect(coordinator.touchesNotArriving)    // device back, but silent again

        for frame in tapFrames(x: 0.5) { source.onFrame?(frame) }
        for _ in 0..<20 where !coordinator.hasReceivedFrameSinceStart { await Task.yield() }
        #expect(coordinator.hasReceivedFrameSinceStart)    // new device delivering
    }

    @Test func noDeviceIsNotTouchesNotArriving() {
        let source = ControllableSource()
        source.startError = .noDevice
        let coordinator = AppCoordinator(source: source, clickSource: FakeClickSource(), emitter: SpyEmitter())
        coordinator.start()
        // No device is its own error state (sourceError == .noDevice), distinct from
        // "connected but deaf" — touchesNotArriving must not fire here.
        #expect(!coordinator.isDeviceConnected)
        #expect(!coordinator.touchesNotArriving)
    }

    // MARK: Master enable & settings

    @Test func setEnabledTogglesMaster() {
        let (coordinator, _, _, _) = makeCoordinator()
        #expect(coordinator.isMasterEnabled)     // default on
        coordinator.setEnabled(false)
        #expect(!coordinator.isMasterEnabled)
        #expect(!coordinator.settings.features.masterEnabled)
        coordinator.setEnabled(true)
        #expect(coordinator.isMasterEnabled)
    }

    // MARK: Visualizer frame tee

    @Test func onFrameTeeReceivesFramesInParallelWithRecognizer() async {
        let (coordinator, source, _, emitter) = makeCoordinator()
        var teed: [[SurfaceTouch]] = []
        coordinator.onFrame = { teed.append($0) }
        coordinator.start()

        // A complete tap: both frames flow to the recognizer AND the tee.
        for frame in tapFrames(x: 0.5) { source.onFrame?(frame) }

        // The coordinator marshals frames onto the main actor (Task { @MainActor });
        // drain those hops before asserting.
        for _ in 0..<20 where teed.count < 2 { await Task.yield() }

        #expect(teed.count == 2)                    // tee saw every frame
        #expect(emitter.clicks.count == 1)          // recognizer still produced the click
    }

    // MARK: Visualizer gesture tee (Phase 7.6)

    @Test func onGestureTeeReceivesRecognizedGestures() async {
        let (coordinator, source, _, emitter) = makeCoordinator()
        var gestures: [ButtonGesture] = []
        coordinator.onGesture = { gestures.append($0) }
        coordinator.start()

        for frame in tapFrames(x: 0.5) { source.onFrame?(frame) }  // middle-zone tap
        for _ in 0..<20 where gestures.isEmpty { await Task.yield() }

        #expect(gestures == [.click(zone: .middle, count: 1)])     // tee saw the gesture
        #expect(emitter.clicks.count == 1)                         // and it still routed
    }

    @Test func onGestureTeeFiresEvenWhenPolicyBlocks() async {
        let (coordinator, source, _, emitter) = makeCoordinator()
        coordinator.setEnabled(false)                              // master off → nothing routes
        var gestures: [ButtonGesture] = []
        coordinator.onGesture = { gestures.append($0) }
        coordinator.start()

        for frame in tapFrames(x: 0.5) { source.onFrame?(frame) }
        for _ in 0..<20 where gestures.isEmpty { await Task.yield() }

        #expect(gestures == [.click(zone: .middle, count: 1)])     // diagnostic tee is pre-policy
        #expect(emitter.clicks.isEmpty)                            // but the click was blocked
    }

    @Test func applyUpdatesSettings() {
        let (coordinator, _, _, _) = makeCoordinator()
        var next = AppSettings()
        next.zones = ZoneLayout(leftEdge: 0.2, rightEdge: 0.8)
        next.features.tapToClick = false
        coordinator.apply(next)
        #expect(coordinator.settings.zones == next.zones)
        #expect(!coordinator.settings.features.tapToClick)
    }
}
