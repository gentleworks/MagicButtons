import Foundation

/// Decides whether the **main run loop** is still alive (docs/14) — the pure
/// half of the App's layer-3 self-resurrection backstop.
///
/// The 2026-09 incident showed the failure this guards: the main thread hung
/// forever in a private framework call, and because a login item launches at
/// login but never *resurrects* a hung process, the app sat dead for days.
/// Layers 1–2 (the source's lifecycle off the main thread, the re-enumeration
/// timeout) should prevent a hang from ever happening again; this is the
/// backstop that turns any *future* main-thread hang from "dead until you
/// notice" into "restarted in ~30 s".
///
/// The App owns the clock and both sides of the check — a main run-loop timer
/// records beats, a detached thread polls `isStale` — mirroring how
/// `StreamHealthMonitor` keeps the decision logic pure while the App holds
/// the clock. The clock must be **sleep-invariant**
/// (`ProcessInfo.systemUptime`, which stops while the machine sleeps):
/// against a wall clock, one whole nap would read as silence and "resurrect"
/// a perfectly healthy app.
public final class MainLoopLiveness: @unchecked Sendable {
    /// How often the main thread records a beat (the App's timer interval).
    public let beatInterval: TimeInterval
    /// How long the main loop may go silent before it is judged dead.
    /// Generous on purpose: ~60× the beat period — even a busy main thread
    /// (a settings import, a relayout storm) interrupts a timer for
    /// milliseconds, not tens of seconds.
    public let staleAfter: TimeInterval

    private let lock = NSLock()
    /// The last beat, in the App's (sleep-invariant) clock. `nil` until the
    /// first tick.
    private var lastBeat: TimeInterval?
    /// A fired watchdog never fires again in this process.
    private var fired = false

    public init(beatInterval: TimeInterval = 0.5, staleAfter: TimeInterval = 30) {
        self.beatInterval = beatInterval
        self.staleAfter = staleAfter
    }

    /// Record a main-loop heartbeat, in the App's clock.
    public func beat(at now: TimeInterval) {
        lock.lock()
        lastBeat = now
        lock.unlock()
    }

    /// Whether the main loop has been silent longer than `staleAfter`.
    /// Requires at least one beat first: before the first tick there is
    /// nothing to measure — a hang *before* the first beat is the one case
    /// this backstop cannot see, because the checker thread hasn't started
    /// either, and the next login's launch of the login item is the recovery
    /// there.
    public func isStale(at now: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastBeat else { return false }
        return now - lastBeat > staleAfter
    }

    /// Latch a firing so a checker thread can never resurrect twice, even if
    /// something goes wrong with the exit that follows. Returns `true`
    /// exactly once.
    @discardableResult
    public func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}
