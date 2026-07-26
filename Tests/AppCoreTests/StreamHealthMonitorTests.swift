import Testing
import Foundation
@testable import AppCore

// The enumerated-but-deaf recovery rule (docs/08). These lock in *why* the trigger is a
// physical-click cross-check and not a silence watchdog: silence is normal, a click
// without contacts is not.
//
// Results are bound to locals before asserting because `#expect` decomposes a call
// expression and can't invoke a `mutating` member through it.

@Suite struct StreamHealthMonitorTests {

    // MARK: The cross-check

    @Test func clickWithNoFramesEverProvesDeafness() {
        var monitor = StreamHealthMonitor()
        // Enumeration succeeded but not one frame has ever arrived, and the user just
        // physically clicked — which is impossible without touching the surface.
        let recovered = monitor.shouldRecover(physicalClickAt: 100, hasActiveHolds: false)
        #expect(recovered)
        #expect(monitor.isProvenDeaf)
    }

    @Test func clickAlongsideFramesIsHealthy() {
        var monitor = StreamHealthMonitor()
        monitor.noteFrame(at: 99.95)
        // Contacts for the clicking finger land milliseconds before the click.
        let recovered = monitor.shouldRecover(physicalClickAt: 100, hasActiveHolds: false)
        #expect(!recovered)
        #expect(!monitor.isProvenDeaf)
    }

    @Test func clickAfterStaleFramesProvesDeafness() {
        var monitor = StreamHealthMonitor()
        monitor.noteFrame(at: 40)              // last contact seen a minute ago
        let recovered = monitor.shouldRecover(physicalClickAt: 100, hasActiveHolds: false)
        #expect(recovered)
        #expect(monitor.isProvenDeaf)
    }

    @Test func silenceAloneNeverTriggersRecovery() {
        // The whole reason this isn't a watchdog: an untouched mouse is silent forever,
        // and re-enumerating on that would loop all night (docs/08).
        var monitor = StreamHealthMonitor()
        monitor.noteFrame(at: 10)
        #expect(!monitor.isReceivingFrames(at: 10_000))   // long since quiet
        #expect(!monitor.isProvenDeaf)                    // …but not deaf, just idle
    }

    // MARK: Guards

    @Test func anInFlightHoldVetoesRecovery() {
        // A motionless finger mid-drag produces no frames, so it looks exactly like a
        // dead stream — and re-enumeration lifts holds (docs/05), which would drop the
        // drag. The veto must also leave no false proof behind.
        var monitor = StreamHealthMonitor()
        monitor.noteFrame(at: 40)
        let recovered = monitor.shouldRecover(physicalClickAt: 100, hasActiveHolds: true)
        #expect(!recovered)
        #expect(!monitor.isProvenDeaf)
    }

    @Test func recoveryIsRateLimitedButProofPersists() {
        var monitor = StreamHealthMonitor(minimumRetryInterval: 5)
        let first = monitor.shouldRecover(physicalClickAt: 100, hasActiveHolds: false)
        #expect(first)
        // A burst of clicks against a stream that stays dead must not thrash…
        let tooSoon = monitor.shouldRecover(physicalClickAt: 101, hasActiveHolds: false)
        let stillTooSoon = monitor.shouldRecover(physicalClickAt: 104, hasActiveHolds: false)
        #expect(!tooSoon)
        #expect(!stillTooSoon)
        #expect(monitor.isProvenDeaf)                     // …yet it's still deaf
        // …and once the floor passes, it tries again.
        let retried = monitor.shouldRecover(physicalClickAt: 106, hasActiveHolds: false)
        #expect(retried)
    }

    @Test func aFrameClearsTheProof() {
        var monitor = StreamHealthMonitor()
        let recovered = monitor.shouldRecover(physicalClickAt: 100, hasActiveHolds: false)
        #expect(recovered)
        #expect(monitor.isProvenDeaf)
        monitor.noteFrame(at: 101)          // the re-subscription worked
        #expect(!monitor.isProvenDeaf)
    }

    @Test func resubscribeDoesNotClearTheProof() {
        // Trying a fix isn't evidence the fix worked — only a frame is. This is what
        // keeps the Status pane honest when re-enumeration doesn't help.
        var monitor = StreamHealthMonitor()
        let recovered = monitor.shouldRecover(physicalClickAt: 100, hasActiveHolds: false)
        #expect(recovered)
        monitor.noteResubscribe()
        #expect(monitor.isProvenDeaf)
    }

    @Test func resubscribeForgetsTheStaleFrameClock() {
        // Pre-wake frames must not make a stream that died over sleep read as live.
        var monitor = StreamHealthMonitor()
        monitor.noteFrame(at: 100)
        #expect(monitor.isReceivingFrames(at: 100.5))
        monitor.noteResubscribe()
        #expect(!monitor.isReceivingFrames(at: 100.5))
    }

    // MARK: Liveness readout

    @Test func framesReadLiveOnlyInsideTheWindow() {
        var monitor = StreamHealthMonitor(liveWindow: 2)
        #expect(!monitor.isReceivingFrames(at: 100))     // nothing seen yet
        monitor.noteFrame(at: 100)
        #expect(monitor.isReceivingFrames(at: 101.9))
        #expect(!monitor.isReceivingFrames(at: 102.1))
    }
}
