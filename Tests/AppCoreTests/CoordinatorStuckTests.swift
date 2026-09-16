import Testing
import Foundation
@testable import AppCore
import TouchKit
import GestureEngine

// The 2026-09 incident's behavior, locked in (docs/14): a (re)enumeration
// whose completion never arrives is marked `stuck` after `reenumerationTimeout`
// (instead of sitting silently "re-enumerating" for days); a *late* completion
// clears the flag and honors its outcome; superseded completions and timeouts
// can't clobber state; and no second pass is ever issued into a wedged source.
// `StuckSource` goes silent where the private framework call did.

@MainActor
@Suite struct CoordinatorStuckTests {

    /// A short timeout so the whole suite runs in fractions of a second; the
    /// production value is asserted separately.
    private func makeCoordinator(
        source: any TouchSource,
        timeout: TimeInterval = 0.2
    ) -> AppCoordinator {
        AppCoordinator(
            source: source,
            clickSource: FakeClickSource(),
            emitter: SpyEmitter(),
            reenumerationTimeout: timeout)
    }

    // MARK: The wedge is detected

    @Test func startThatNeverCompletesIsMarkedStuck() async {
        let source = StuckSource()
        let coordinator = makeCoordinator(source: source)
        coordinator.start()
        #expect(coordinator.sourceState == .reEnumerating)
        try? await Task.sleep(for: .seconds(0.5))
        #expect(coordinator.sourceState == .stuck)
    }

    @Test func aRefreshThatNeverCompletesIsMarkedStuck() async {
        // The incident's exact shape: the source is live, then a stop-then-start
        // re-enumeration goes into the private framework and the stop never
        // returns. Start completes so the coordinator reaches `.live` first.
        let source = StuckSource()
        source.hangsOnStart = false
        let coordinator = makeCoordinator(source: source)
        coordinator.start()
        #expect(coordinator.sourceState == .live)
        coordinator.refreshDevices()
        #expect(source.stopCount == 1)   // the pair began; its start never was asked
        #expect(coordinator.sourceState == .reEnumerating)
        try? await Task.sleep(for: .seconds(0.5))
        #expect(coordinator.sourceState == .stuck)
    }

    // MARK: A late arrival is good news

    @Test func aLateSuccessfulCompletionClearsStuck() async {
        let source = StuckSource()
        let coordinator = makeCoordinator(source: source)
        coordinator.start()
        try? await Task.sleep(for: .seconds(0.5))
        #expect(coordinator.sourceState == .stuck)
        source.releaseStart(with: .success(()))
        #expect(coordinator.sourceState == .live)
        #expect(coordinator.isDeviceConnected)
        #expect(coordinator.sourceError == nil)
    }

    @Test func aLateFailedCompletionClearsStuckAndRecordsTheError() async {
        let source = StuckSource()
        let coordinator = makeCoordinator(source: source)
        coordinator.start()
        try? await Task.sleep(for: .seconds(0.5))
        #expect(coordinator.sourceState == .stuck)
        source.releaseStart(with: .failure(.noDevice))
        #expect(coordinator.sourceState == .live)
        #expect(!coordinator.isDeviceConnected)
        #expect(coordinator.sourceError == .noDevice)
    }

    // MARK: Stale work can't clobber state

    @Test func stopInvalidatesTheInFlightCompletion() async {
        let source = StuckSource()
        let coordinator = makeCoordinator(source: source)
        coordinator.start()
        try? await Task.sleep(for: .seconds(0.1))
        #expect(coordinator.sourceState == .reEnumerating)
        coordinator.stop()
        #expect(coordinator.sourceState == .idle)
        // The superseded completion arrives after the stop: a stale
        // generation, so it must not resuscitate anything.
        source.releaseStart(with: .success(()))
        #expect(coordinator.sourceState == .idle)
        #expect(!coordinator.isDeviceConnected)
        // …and the (cancelled) timeout must not mark a stopped coordinator
        // stuck.
        try? await Task.sleep(for: .seconds(0.5))
        #expect(coordinator.sourceState == .idle)
    }

    // MARK: Nothing is re-sent into a wedged source

    @Test func refreshIsNoOpWhileAReenumerationIsInFlight() async {
        let source = StuckSource()
        let coordinator = makeCoordinator(source: source)
        coordinator.start()
        try? await Task.sleep(for: .seconds(0.1))
        #expect(coordinator.sourceState == .reEnumerating)
        coordinator.refreshDevices()
        #expect(source.startCount == 1)
        #expect(source.stopCount == 0)
        try? await Task.sleep(for: .seconds(0.5))
        #expect(coordinator.sourceState == .stuck)
        #expect(source.startCount == 1)   // still no second pass
    }

    @Test func refreshIsNoOpWhileStuck() async {
        let source = StuckSource()
        let coordinator = makeCoordinator(source: source)
        coordinator.start()
        try? await Task.sleep(for: .seconds(0.5))
        #expect(coordinator.sourceState == .stuck)
        coordinator.refreshDevices()
        #expect(source.startCount == 1)
        #expect(source.stopCount == 0)
    }

    // MARK: The production threshold

    @Test func theReenumerationTimeoutDefaultsToThirtySeconds() {
        let coordinator = AppCoordinator(
            source: StuckSource(),
            clickSource: FakeClickSource(),
            emitter: SpyEmitter())
        #expect(coordinator.reenumerationTimeout == 30)
    }
}
