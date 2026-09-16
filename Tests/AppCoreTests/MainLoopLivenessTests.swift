import Testing
import Foundation
@testable import AppCore

// The main-loop liveness decision model (docs/14, layer 3 — the
// self-resurrection backstop): what counts as a dead main loop, and the
// latch that guarantees a process can never resurrect itself twice. The
// model is clock-free by design (the App feeds it a sleep-invariant clock),
// so these tests drive the clock directly.

@Suite struct MainLoopLivenessTests {

    @Test func aSilentMainLoopGoesStalePastTheThreshold() {
        let liveness = MainLoopLiveness(beatInterval: 0.5, staleAfter: 30)
        liveness.beat(at: 100)
        #expect(!liveness.isStale(at: 129.9))
        #expect(liveness.isStale(at: 130.1))
    }

    @Test func noBeatYetMeansNothingToMeasure() {
        // A launch-time hang before the first beat is the one case this
        // backstop cannot see (the checker hasn't started either) — it
        // must read "not stale", not "stale".
        let liveness = MainLoopLiveness()
        #expect(!liveness.isStale(at: 10_000))
    }

    @Test func steadyBeatsNeverReadStale() {
        let liveness = MainLoopLiveness(beatInterval: 0.5, staleAfter: 30)
        var now: TimeInterval = 0
        while now < 1000 {
            liveness.beat(at: now)
            now += liveness.beatInterval
            #expect(!liveness.isStale(at: now))
        }
    }

    @Test func aClockThatJumpsBackwardIsNotStale() {
        // `systemUptime` never actually moves backward, but any negative
        // "silence" (a clock hiccup) must not read as a dead loop.
        let liveness = MainLoopLiveness(beatInterval: 0.5, staleAfter: 30)
        liveness.beat(at: 100)
        #expect(!liveness.isStale(at: 99))
        #expect(!liveness.isStale(at: 100))
    }

    @Test func aGapShorterThanTheThresholdIsNotStale() {
        // The threshold is generous on purpose — ~60× the beat period — so
        // a busy (but alive) main thread that misses a few beats is fine.
        let liveness = MainLoopLiveness(beatInterval: 0.5, staleAfter: 30)
        liveness.beat(at: 0)
        #expect(!liveness.isStale(at: 29.9))   // ~60 missed beats
        #expect(liveness.isStale(at: 30.1))
    }

    @Test func fireLatchesSoThereIsNeverASecondResurrection() {
        let liveness = MainLoopLiveness(beatInterval: 0.5, staleAfter: 1)
        liveness.beat(at: 0)
        #expect(liveness.isStale(at: 2))
        #expect(liveness.fire())
        #expect(!liveness.fire())
    }
}
