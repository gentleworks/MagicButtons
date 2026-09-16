import AppKit
import AppCore
import Darwin

/// The App-side main-loop watchdog (docs/14, layer 3 — the self-resurrection
/// backstop): a main run-loop timer records a beat every half second, and a
/// detached checker thread notices the beats going silent past ~30 s and
/// replaces this process with a fresh one.
///
/// Why a bare `Thread` and not a `Task` or a GCD timer: those run on
/// infrastructure that keeps moving while *the main run loop* is wedged —
/// which is exactly what this needs to outlive. A detached thread answers to
/// nothing but its own sleeps, so it keeps polling even when everything else
/// has stopped turning. Layers 1–2 (the source's lifecycle off main, the
/// re-enumeration timeout) make this essentially never fire; it exists so any
/// *future* main-thread hang costs ~30 s of downtime instead of days.
final class MainLoopWatchdog {
    /// ~60× the beat period (docs/14): no healthy main thread trips it, and a
    /// truly wedged one is replaced within a minute, not a morning.
    private let liveness = MainLoopLiveness(beatInterval: 0.5, staleAfter: 30)
    /// The beat timer. A main run-loop timer: it fires *because* the loop
    /// turns, so its silence is the symptom being watched.
    private var beatTimer: Timer?
    /// The checker thread; replaced on each start so a stop/start pair (quit
    /// and relaunch in one process — never expected, but free to be safe)
    /// never leaves two pollers running.
    private var checker: Thread?
    private let stopSignal = OneWayFlag()

    func start() {
        guard beatTimer == nil else { return }
        // Time t₀: the very first measurement, so the stale clock can't run
        // against a beat that hasn't happened yet.
        liveness.beat(at: ProcessInfo.processInfo.systemUptime)
        // Capture the (Sendable) model, not `self` — the timer block is
        // `@Sendable`, and this class is not.
        let liveness = self.liveness
        beatTimer = Timer.scheduledTimer(withTimeInterval: liveness.beatInterval, repeats: true) { _ in
            // Fires on the main run loop (the very thing being watched);
            // assumeIsolated is valid there and keeps the beat on main.
            MainActor.assumeIsolated {
                liveness.beat(at: ProcessInfo.processInfo.systemUptime)
            }
        }
        checker = Thread { [liveness, stopSignal] in
            while !stopSignal.isSet {
                // ~1 s granularity: detection lands at staleAfter + ≤1 s, and
                // a second of sleep per wake is nothing against a 30 s
                // threshold — the same sleep-invariant clock the beats use.
                usleep(1_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                if liveness.isStale(at: now), liveness.fire() {
                    resurrectStuckProcess()
                }
            }
        }
        checker?.start()
    }

    func stop() {
        beatTimer?.invalidate()
        beatTimer = nil
        stopSignal.set()
        // Not joined: the thread notices the flag within ~1 s and exits its
        // loop; by the time a quit gets here the process is leaving anyway.
        checker = nil
    }
}

/// The resurrection itself (docs/14): record this PID in a marker file,
/// launch a fresh instance of our own bundle, and exit this process. The
/// fresh instance reads the marker at launch (`WatchdogMarker`), kills the
/// recorded PID if it is still alive, and clears the file.
///
/// A free function on purpose: it runs on the bare checker thread, where
/// capturing a non-`Sendable` object would not compile — and it needs no
/// instance state, only the process and the bundle.
private func resurrectStuckProcess() {
    let pid = getpid()
    let marker = WatchdogMarker.url
    try? FileManager.default.createDirectory(
        at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? String(pid).write(to: marker, atomically: true, encoding: .utf8)

    // `/usr/bin/open -n` rather than `NSWorkspace`: this runs on a bare
    // thread where AppKit has no business being, and `open` hands the launch
    // to LaunchServices exactly as clicking the bundle in the Finder would.
    // `-n` forces a *new* instance — a plain `open` would merely "activate"
    // this running (wedged) one and launch nothing.
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-n", Bundle.main.bundleURL.path]
    do {
        try task.run()
    } catch {
        // The replacement can't be spawned: clear the marker so our PID
        // isn't attributed to some later, unrelated launch — and stay
        // wedged, visible to the user (and to a later manual relaunch),
        // rather than half-resurrected.
        try? FileManager.default.removeItem(at: marker)
        return
    }

    // `_exit`, not `exit`: the main thread may be parked in a kernel wait,
    // and `exit` would run atexit handlers and ObjC teardown that can block
    // or try to join threads. A fresh process is replacing us — there is
    // nothing in this one worth cleaning up.
    _exit(1)
}

/// The resurrection marker (docs/14): a machine-local file recording the PID
/// of a process that asked to be replaced. Lives in Application Support
/// (machinery, not the user-facing Logs directory) and is removed as soon as
/// a launch acts on it, so it never accumulates.
enum WatchdogMarker {
    static let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MagicButtons", isDirectory: true)
            .appendingPathComponent("watchdog-relaunch")
    }()

    /// Called by a fresh instance at launch (first thing in `AppModel.init`):
    /// kill the recorded PID if it is still alive **and** is our own
    /// executable — the PID-reuse guard — then clear the marker. No marker
    /// is the common case: a no-op.
    static func killPredecessorIfAny() {
        let me = getpid()
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return
        }
        guard let recorded = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              recorded != me else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Alive at all? (Usually not — `_exit` lands before the replacement
        // finishes launching; the kill is belt-and-braces.)
        guard kill(recorded, 0) == 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Alive is not enough: in the seconds between the marker and our
        // launch the OS may have recycled the PID to an unrelated process.
        // Confirm it is our own executable before touching it.
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(recorded, &path, UInt32(path.count))
        guard len > 0, String(cString: path) == Bundle.main.executablePath else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        kill(recorded, SIGKILL)
        try? FileManager.default.removeItem(at: url)
    }
}

/// A lock-guarded one-way on/off signal (set from the main actor, read from
/// the checker thread — a plain `Bool` there would be a data race).
private final class OneWayFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
