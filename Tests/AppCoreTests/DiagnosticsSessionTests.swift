import Testing
import Foundation
@testable import AppCore
import TouchKit

// The recording session's lifecycle: where it writes, what it's called, the caps that stop
// it on its own, and how many past sessions survive (docs/10 §Diagnostics mode). The clock
// and the directory are injected, so none of this waits out a 30-minute cap or touches the
// real `~/Library/Logs`.

@Suite @MainActor struct DiagnosticsSessionTests {

    /// A throwaway directory, plus a settable clock so the time cap is reachable instantly.
    @MainActor
    private final class Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-session-\(UUID().uuidString)")
        var clock = Date(timeIntervalSince1970: 1_784_000_000)   // a fixed 2026 instant

        func session(_ limits: DiagnosticsSession.Limits = .init()) -> DiagnosticsSession {
            DiagnosticsSession(
                directory: directory,
                limits: limits,
                // A long poll: these tests drive `checkLimits()` directly rather than
                // racing the session's own timer.
                now: { self.clock }, pollInterval: 3600)
        }

        /// Session files currently on disk, oldest name first.
        var files: [String] {
            let all = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return all.filter { $0.hasPrefix("diagnostics-") }.sorted()
        }

        func writeStaleSession(named name: String) {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: directory.appendingPathComponent(name).path, contents: Data("old".utf8))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: Location & naming

    /// `~/Library/Logs/MagicButtons` — the convention that makes "Reveal in Finder" land
    /// somewhere the user recognizes.
    @Test func defaultDirectoryIsTheUserLogsFolder() {
        let path = DiagnosticsSession.defaultDirectory.path
        #expect(path.hasSuffix("/Library/Logs/MagicButtons"))
    }

    @Test func startCreatesTheDirectoryAndAStampedFile() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session()

        #expect(session.start(layout: ZoneLayout()) != nil)
        defer { session.stop() }

        #expect(session.isRecording)
        #expect(h.files.count == 1)
        // yyyyMMdd-HHmmss, POSIX — stable regardless of the user's calendar.
        #expect(h.files[0].hasPrefix("diagnostics-2026"))
        #expect(h.files[0].hasSuffix(".csv"))
    }

    /// Toggling off and straight back on inside one second must not reuse the name and
    /// truncate the log just recorded.
    @Test func twoSessionsInTheSameSecondGetDistinctFiles() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session()

        session.start(layout: ZoneLayout())
        let first = session.lastFileURL
        session.stop()
        session.start(layout: ZoneLayout())   // same clock ⇒ same timestamp
        let second = session.lastFileURL
        session.stop()

        #expect(first != second)
        #expect(h.files.count == 2)
    }

    @Test func startReturnsNilWhenTheDirectoryCannotBeCreated() {
        let session = DiagnosticsSession(directory: URL(fileURLWithPath: "/dev/null/nope"))
        #expect(session.start(layout: ZoneLayout()) == nil)
        #expect(!session.isRecording)
    }

    // MARK: Start / stop

    @Test func startIsIdempotentAndKeepsTheSameLog() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session()

        let first = session.start(layout: ZoneLayout())
        let second = session.start(layout: ZoneLayout())
        defer { session.stop() }

        #expect(first === second)
        #expect(h.files.count == 1)
    }

    @Test func stopEndsTheSessionAndReportsTheUserAsTheReason() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session()
        var stops: [DiagnosticsStopReason] = []
        session.onStop = { stops.append($0) }

        session.start(layout: ZoneLayout())
        session.stop()

        #expect(!session.isRecording)
        #expect(session.log == nil)
        #expect(session.lastStopReason == .user)
        // Fires for a user stop too, so the caller has one teardown path for every ending.
        #expect(stops == [.user])
    }

    @Test func stopIsANoOpWhenNotRecording() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session()
        var stops: [DiagnosticsStopReason] = []
        session.onStop = { stops.append($0) }

        session.stop()

        #expect(stops.isEmpty)
        #expect(session.lastStopReason == nil)
    }

    /// The log has to stay reachable after recording ends — that's when it gets revealed.
    @Test func theFileURLSurvivesStopping() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session()

        session.start(layout: ZoneLayout())
        let live = session.lastFileURL
        session.stop()

        #expect(session.lastFileURL == live)
        #expect(FileManager.default.fileExists(atPath: live!.path))
    }

    /// A fresh session clears the previous ending, so the UI can't keep showing "stopped:
    /// size limit" over a live recording.
    @Test func startingAgainClearsThePreviousStopReason() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session()

        session.start(layout: ZoneLayout())
        session.stop()
        #expect(session.lastStopReason == .user)

        session.start(layout: ZoneLayout())
        defer { session.stop() }
        #expect(session.lastStopReason == nil)
    }

    // MARK: Caps

    @Test func hittingTheSizeCapStopsTheSession() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session(.init(maxBytes: 200))
        var stops: [DiagnosticsStopReason] = []
        session.onStop = { stops.append($0) }

        let log = session.start(layout: ZoneLayout())!
        session.checkLimits()
        #expect(session.isRecording)          // header alone is well under the cap

        while log.bytesWritten < 200 { log.synth(.click(.left, 1)) }
        session.checkLimits()

        #expect(!session.isRecording)
        #expect(session.lastStopReason == .sizeLimit)
        #expect(stops == [.sizeLimit])
    }

    /// The Status pane states this as a clock time, so it has to be the instant the cap
    /// actually fires — and it must not linger once recording ends.
    @Test func theAutoStopDeadlineIsTheStartPlusTheTimeCap() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session(.init(maxDuration: 60))
        #expect(session.autoStopAt == nil)

        session.start(layout: ZoneLayout())
        #expect(session.autoStopAt == h.clock.addingTimeInterval(60))

        // The cap fires exactly there, not a tick later.
        h.clock = session.autoStopAt!
        session.checkLimits()
        #expect(session.lastStopReason == .timeLimit)
        #expect(session.autoStopAt == nil)
    }

    @Test func hittingTheTimeCapStopsTheSession() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session(.init(maxDuration: 60))
        var stops: [DiagnosticsStopReason] = []
        session.onStop = { stops.append($0) }

        session.start(layout: ZoneLayout())

        h.clock.addTimeInterval(59)
        session.checkLimits()
        #expect(session.isRecording)

        h.clock.addTimeInterval(1)
        session.checkLimits()

        #expect(!session.isRecording)
        #expect(session.lastStopReason == .timeLimit)
        #expect(stops == [.timeLimit])
    }

    /// An idle session — no events at all — must still stop itself at the time cap. This is
    /// why the caps are polled rather than checked per row.
    @Test func anIdleSessionStillStopsAtTheTimeCap() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session(.init(maxDuration: 60))

        session.start(layout: ZoneLayout())   // nothing recorded at all
        h.clock.addTimeInterval(120)
        session.checkLimits()

        #expect(session.lastStopReason == .timeLimit)
    }

    /// An auto-stop must flush like any other: the tail is the interesting part.
    @Test func anAutoStoppedSessionIsFlushedToDisk() throws {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session(.init(maxDuration: 60))

        let log = session.start(layout: ZoneLayout())!
        for _ in 0..<50 { log.synth(.click(.right, 2)) }
        h.clock.addTimeInterval(60)
        session.checkLimits()

        let text = try String(contentsOf: session.lastFileURL!, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 51)   // header + 50
    }

    @Test func checkingLimitsWhenStoppedDoesNothing() {
        let h = Harness(); defer { h.cleanUp() }
        let session = h.session(.init(maxDuration: 0))

        session.checkLimits()   // a zero cap would fire instantly if it applied

        #expect(session.lastStopReason == nil)
    }

    // MARK: Pruning

    @Test func startingPrunesToTheNewestSessionsIncludingTheLiveOne() {
        let h = Harness(); defer { h.cleanUp() }
        for i in 1...5 { h.writeStaleSession(named: "diagnostics-20250101-00000\(i).csv") }
        let session = h.session(.init(keepSessions: 3))

        session.start(layout: ZoneLayout())
        defer { session.stop() }

        // The 2 newest stale files + the live one.
        #expect(h.files.count == 3)
        #expect(h.files.contains("diagnostics-20250101-000004.csv"))
        #expect(h.files.contains("diagnostics-20250101-000005.csv"))
        #expect(!h.files.contains("diagnostics-20250101-000001.csv"))
    }

    @Test func pruningLeavesFilesThatArentOurs() {
        let h = Harness(); defer { h.cleanUp() }
        h.writeStaleSession(named: "diagnostics-20250101-000001.csv")
        h.writeStaleSession(named: "notes.txt")
        h.writeStaleSession(named: "conflicts-20250101-000001.csv")
        let session = h.session(.init(keepSessions: 1))

        session.start(layout: ZoneLayout())
        defer { session.stop() }

        let all = try! FileManager.default.contentsOfDirectory(atPath: h.directory.path)
        #expect(all.contains("notes.txt"))
        #expect(all.contains("conflicts-20250101-000001.csv"))
        #expect(!all.contains("diagnostics-20250101-000001.csv"))   // ours, and over the cap
    }

    /// Names sort chronologically only while the clock moves forward. A backwards jump (an
    /// NTP correction) must not make the live file look oldest and delete it mid-session.
    @Test func pruningNeverDeletesTheFileBeingWritten() {
        let h = Harness(); defer { h.cleanUp() }
        for i in 1...4 { h.writeStaleSession(named: "diagnostics-20300101-00000\(i).csv") }
        let session = h.session(.init(keepSessions: 2))

        // The live file stamps 2026 — lexically older than every stale 2030 file.
        let log = session.start(layout: ZoneLayout())
        defer { session.stop() }

        #expect(log != nil)
        #expect(h.files.contains(session.lastFileURL!.lastPathComponent))
        #expect(FileManager.default.fileExists(atPath: session.lastFileURL!.path))
    }
}
