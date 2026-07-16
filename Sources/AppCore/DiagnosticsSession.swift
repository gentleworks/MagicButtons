import Foundation
import TouchKit

/// Why a recording session ended — surfaced verbatim in the Status pane, because "it
/// stopped on its own" with no reason is exactly the sort of thing that makes a user
/// distrust a troubleshooting tool.
public enum DiagnosticsStopReason: Sendable, Equatable {
    /// The user toggled recording off.
    case user
    /// The session hit `Limits.maxBytes`.
    case sizeLimit
    /// The session hit `Limits.maxDuration`.
    case timeLimit
}

/// Owns the *lifecycle* of a diagnostics recording: where it's written, what it's called,
/// when it must stop on its own, and how many past sessions survive. Deliberately knows
/// nothing about the app's object graph — it hands back a `DiagnosticsLog` and the caller
/// wires the tees to it, so this stays testable with no hardware, no event tap, and no
/// writing to the real `~/Library/Logs`.
///
/// **Nothing exists until `start`.** No file handle, no timer, no allocation — the toggle
/// being off has to cost nothing at all (docs/10 §Diagnostics mode).
///
/// The counterpart guarantee is that a session can't be left running by accident: it is
/// never persisted (a relaunch starts off), and it stops itself on either cap. That pairs
/// with keeping the toggle out of `AppSettings`, which would both persist it and export it
/// to another Mac.
@MainActor
public final class DiagnosticsSession {

    /// The bounds a session runs under. Both caps **stop** the session rather than
    /// truncating it: a log that silently drops its middle is worse than a short one,
    /// because the reader can't tell which they're holding.
    public struct Limits: Sendable {
        /// Runaway guard. Rows are ~40–60 bytes, so this is ~100k rows — in practice
        /// `maxDuration` binds first, and this only catches pathological event rates.
        public var maxBytes: Int
        /// Wall-clock ceiling on one session.
        public var maxDuration: TimeInterval
        /// How many session files survive in `directory`, newest first (including the one
        /// just started). Files persist deliberately — a force-quit must not lose the log —
        /// so something has to clean up.
        public var keepSessions: Int

        public init(
            maxBytes: Int = 5_000_000,
            maxDuration: TimeInterval = 30 * 60,
            keepSessions: Int = 5
        ) {
            self.maxBytes = maxBytes
            self.maxDuration = maxDuration
            self.keepSessions = keepSessions
        }
    }

    /// `~/Library/Logs/MagicButtons` — the macOS convention for user-facing diagnostic
    /// logs, which is what makes "Reveal in Finder" land somewhere a user recognizes and
    /// a bug report easy to attach. (Application Support is for data an app needs to
    /// function; these are disposable.) Writable directly because MagicButtons is
    /// unsandboxed by necessity — the sandbox is incompatible with the multitouch stream
    /// and global event posting (docs/07 §Distribution).
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MagicButtons", isDirectory: true)
    }

    private static let filePrefix = "diagnostics-"
    private static let fileExtension = "csv"

    private let directory: URL
    /// Public so the UI can state the caps it's actually running under rather than
    /// hardcoding numbers that drift out of sync with them.
    public let limits: Limits
    private let now: () -> Date
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var startedAt: Date?

    /// The live recorder — non-nil exactly while recording. The caller points its tees here.
    public private(set) var log: DiagnosticsLog?

    public var isRecording: Bool { log != nil }

    /// The most recent session's file, live or finished — the "Reveal in Finder" target.
    /// Survives `stop` so the log stays reachable after recording ends.
    public private(set) var lastFileURL: URL?

    /// Why the most recent session ended; `nil` while recording or before the first one.
    public private(set) var lastStopReason: DiagnosticsStopReason?

    /// Fires whenever a session actually ends — including a user-initiated `stop()`, so the
    /// caller has **one** teardown path and can't leak a tee by forgetting the auto-stop
    /// case. Not called when `start` fails (nothing was ever wired).
    public var onStop: ((DiagnosticsStopReason) -> Void)?

    /// - Parameters:
    ///   - directory: where sessions are written. Defaults to `defaultDirectory`; tests
    ///     pass a temporary one.
    ///   - now: injected clock, so the time cap is testable without waiting it out.
    ///   - pollInterval: how often the caps are checked while recording.
    public init(
        directory: URL = DiagnosticsSession.defaultDirectory,
        limits: Limits = .init(),
        now: @escaping () -> Date = Date.init,
        pollInterval: TimeInterval = 1
    ) {
        self.directory = directory
        self.limits = limits
        self.now = now
        self.pollInterval = pollInterval
    }

    deinit { pollTask?.cancel() }

    // MARK: Lifecycle

    /// Begins recording. Idempotent — a no-op while already recording.
    ///
    /// Returns `nil` if the log couldn't be opened (the directory is unwritable), leaving
    /// the session stopped; the caller surfaces that rather than silently pretending to
    /// record. Otherwise returns the recorder to wire tees to.
    @discardableResult
    public func start(layout: ZoneLayout) -> DiagnosticsLog? {
        if let log { return log }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let url = availableFileURL()
            let newLog = try DiagnosticsLog(fileURL: url, layout: layout)
            log = newLog
            lastFileURL = url
            lastStopReason = nil
            startedAt = now()
            prune()
            startPolling()
            return newLog
        } catch {
            return nil
        }
    }

    /// Ends the session the user asked for. Idempotent — a no-op when not recording.
    public func stop() { finish(.user) }

    private func finish(_ reason: DiagnosticsStopReason) {
        guard let log else { return }
        pollTask?.cancel()
        pollTask = nil
        startedAt = nil
        log.close()
        self.log = nil
        lastStopReason = reason
        onStop?(reason)
    }

    // MARK: Caps

    /// A `Task` rather than a `Timer`: it keeps ticking regardless of run-loop mode (a
    /// menu-bar app spends its interesting moments in menu tracking, which starves a
    /// default-mode timer), and it's `Sendable`, so `deinit` can cancel it — `Timer`
    /// is neither, and `invalidate()` must run on the thread that installed it, which a
    /// nonisolated `deinit` can't promise.
    private func startPolling() {
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(pollInterval))
                guard let self else { return }
                self.checkLimits()
            }
        }
    }

    /// One check for both caps, driven by the session's poll. Polling rather than checking
    /// on each row so an *idle* session still stops itself at the time cap — with no rows
    /// arriving, a row-driven check would never fire.
    ///
    /// Internal rather than private so tests can drive it against the injected clock instead
    /// of waiting out a 30-minute cap.
    func checkLimits() {
        guard let log, let startedAt else { return }
        if log.bytesWritten >= limits.maxBytes { return finish(.sizeLimit) }
        if now().timeIntervalSince(startedAt) >= limits.maxDuration { return finish(.timeLimit) }
    }

    // MARK: Files

    /// `diagnostics-20260716-041530.csv`. POSIX locale so the name is stable regardless of
    /// the user's calendar, and lexical order matches chronological order — which is what
    /// lets `prune` sort by name.
    private func availableFileURL() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: now())

        // Toggling off and straight back on inside one second would otherwise reuse the
        // name and truncate the log just recorded.
        var url = fileURL(stamp)
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = fileURL("\(stamp)-\(suffix)")
            suffix += 1
        }
        return url
    }

    private func fileURL(_ stamp: String) -> URL {
        directory.appendingPathComponent("\(Self.filePrefix)\(stamp).\(Self.fileExtension)")
    }

    /// Keeps the `keepSessions` newest session files and deletes the rest. Only ever touches
    /// files this session type named — a user's own files in the directory are not ours to
    /// remove.
    private func prune() {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }

        // Never the file being written to. Names sort chronologically only while the clock
        // moves forward; a backwards jump (an NTP correction) would otherwise make the live
        // file look like the oldest and delete it mid-session.
        let live = log?.fileURL.lastPathComponent
        let ours = all.filter {
            $0.lastPathComponent.hasPrefix(Self.filePrefix)
                && $0.pathExtension == Self.fileExtension
                && $0.lastPathComponent != live
        }
        // Timestamped names sort lexically in chronological order.
        let oldestFirst = ours.sorted { $0.lastPathComponent < $1.lastPathComponent }
        // The live file counts toward `keepSessions`, so it's one fewer of the rest.
        let keepOthers = max(0, limits.keepSessions - 1)
        guard oldestFirst.count > keepOthers else { return }
        for url in oldestFirst.dropLast(keepOthers) {
            try? fm.removeItem(at: url)
        }
    }
}
