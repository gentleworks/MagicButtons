import Testing
import Foundation
import CoreGraphics
@testable import AppCore
import TouchKit
import EventOutput

// The diagnostics recorder promoted out of `mb-dev log-conflicts` (docs/13, docs/14
// §Click/drag de-confliction). These pin the CSV contract the Feature B analysis reads —
// above all the `hold_active` and `swallowed` columns — plus the flush-on-close path the
// shipping diagnostics mode depends on.

@Suite struct DiagnosticsLogTests {

    /// A log writing to a throwaway file, with the file URL for reading it back.
    private func makeLog(
        layout: ZoneLayout = ZoneLayout()
    ) throws -> (log: DiagnosticsLog, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-\(UUID().uuidString).csv")
        return (try DiagnosticsLog(fileURL: url, layout: layout), url)
    }

    /// `close()` drains the writer queue, so rows are on disk by the time this returns.
    private func rows(of log: DiagnosticsLog, at url: URL) throws -> [String] {
        log.close()
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    private func touch(x: CGFloat, id: Int32 = 1) -> SurfaceTouch {
        SurfaceTouch(deviceID: MouseDeviceID(raw: 1), id: id,
                     position: CGPoint(x: x, y: 0.5), phase: .began,
                     timestamp: 0, size: 0.3)
    }

    // MARK: File contract

    @Test func writesTheHeaderOnCreation() throws {
        let (log, url) = try makeLog()
        #expect(try rows(of: log, at: url) == ["t_ms,stream,detail,hold_active,swallowed"])
    }

    /// The recorder's own record of where it's writing — the "Reveal in Finder" target.
    @Test func exposesItsFileURL() throws {
        let (log, url) = try makeLog()
        #expect(log.fileURL == url)
        _ = try rows(of: log, at: url)
    }

    @Test func openingAnUnwritablePathThrows() {
        let url = URL(fileURLWithPath: "/does/not/exist/nope.csv")
        #expect(throws: DiagnosticsLogError.self) {
            _ = try DiagnosticsLog(fileURL: url, layout: ZoneLayout())
        }
    }

    /// Rows are handed to a background queue; `close()` must drain it or a session's tail
    /// would vanish exactly when it matters most.
    @Test func closeFlushesEveryPendingRow() throws {
        let (log, url) = try makeLog()
        for _ in 0..<200 { log.synth(.click(.left, 1)) }

        let written = try rows(of: log, at: url)
        #expect(written.count == 201)   // header + 200
    }

    // MARK: hold_active — the column the whole analysis pivots on

    @Test func holdActiveIsSetFromPressUntilRelease() throws {
        let (log, url) = try makeLog()
        log.synth(.click(.left, 1))     // before any hold
        log.synth(.press(.middle))      // opens the hold
        log.synth(.click(.left, 1))     // inside the hold
        log.synth(.release(.middle))    // closes it
        log.synth(.click(.left, 1))     // after

        let holdColumn = try rows(of: log, at: url).dropFirst().map { $0.split(separator: ",", omittingEmptySubsequences: false)[3] }
        // The press row itself already reads as held; the release row already reads as free.
        #expect(holdColumn == ["0", "1", "1", "0", "0"])
    }

    // MARK: Physical stream

    @Test func countsPhysicalDownsAndUpsSeparately() throws {
        let (log, url) = try makeLog()
        log.physical(type: .leftMouseDown, buttonNumber: 0, wasSwallowed: false)
        log.physical(type: .leftMouseUp, buttonNumber: 0, wasSwallowed: false)
        log.physical(type: .leftMouseDown, buttonNumber: 0, wasSwallowed: false)

        #expect(log.physicalDowns == 2)
        #expect(log.physicalUps == 1)
        #expect(log.collisions == 0)
        _ = try rows(of: log, at: url)
    }

    /// A squeeze *inside* a synthetic drag that de-confliction consumed: a collision, and
    /// not a leak. This is the Feature B success case.
    @Test func aSwallowedClickDuringAHoldCountsAsACollisionButNotALeak() throws {
        let (log, url) = try makeLog()
        log.synth(.press(.left))
        log.physical(type: .leftMouseDown, buttonNumber: 0, wasSwallowed: true)
        log.synth(.release(.left))

        #expect(log.collisions == 1)
        #expect(log.swallowed == 1)
        #expect(log.leakedDuringHold == 0)

        let physicalRow = try rows(of: log, at: url)[2]
        #expect(physicalRow.hasSuffix(",1,1"))   // hold_active=1, swallowed=1
    }

    /// A physical event that reached the app mid-hold — the straddle's leaked pair.
    @Test func anUnswallowedClickDuringAHoldCountsAsALeak() throws {
        let (log, url) = try makeLog()
        log.synth(.press(.left))
        log.physical(type: .leftMouseUp, buttonNumber: 0, wasSwallowed: false)

        #expect(log.collisions == 1)
        #expect(log.swallowed == 0)
        #expect(log.leakedDuringHold == 1)
        _ = try rows(of: log, at: url)
    }

    @Test func clicksOutsideAHoldAreNotCollisions() throws {
        let (log, url) = try makeLog()
        log.physical(type: .leftMouseDown, buttonNumber: 0, wasSwallowed: false)
        log.synth(.press(.left))
        log.synth(.release(.left))
        log.physical(type: .leftMouseUp, buttonNumber: 0, wasSwallowed: false)

        #expect(log.collisions == 0)
        #expect(log.leakedDuringHold == 0)
        _ = try rows(of: log, at: url)
    }

    // MARK: Synth stream

    @Test func countsEachSynthKind() throws {
        let (log, url) = try makeLog()
        log.synth(.click(.left, 1))
        log.synth(.click(.right, 2))
        log.synth(.press(.middle))
        log.synth(.release(.middle))

        #expect(log.synthClicks == 2)
        #expect(log.synthPresses == 1)
        #expect(log.synthReleases == 1)

        // `;` separates the click's zone and count — a comma would break the column.
        #expect(try rows(of: log, at: url)[2].contains("click(right;2)"))
    }

    // MARK: Gesture stream (pre-policy)

    @Test func recordsEachRecognizedGestureInTheRecognizerVocabulary() throws {
        let (log, url) = try makeLog()
        log.gesture(.click(zone: .left, count: 2))
        log.gesture(.holdBegan(zone: .middle))
        log.gesture(.holdEnded(zone: .middle))

        let written = Array(try rows(of: log, at: url).dropFirst())
        #expect(written.count == 3)
        #expect(written[0].contains("gesture,click(left;2)"))
        #expect(written[1].contains("gesture,holdBegan(middle)"))
        #expect(written[2].contains("gesture,holdEnded(middle)"))
    }

    /// The load-bearing invariant: `hold_active` must track buttons that were really down.
    /// A `holdBegan` the policy goes on to drop pressed nothing, so recognizing one must
    /// not open a hold — only a `synth` press may.
    @Test func aRecognizedHoldDoesNotOpenTheHoldColumn() throws {
        let (log, url) = try makeLog()
        log.gesture(.holdBegan(zone: .left))
        log.physical(type: .leftMouseDown, buttonNumber: 0, wasSwallowed: false)

        #expect(log.collisions == 0)
        let physicalRow = try rows(of: log, at: url)[2]
        #expect(physicalRow.contains(",0,0"))   // hold_active=0
    }

    /// Recognized and posted are different facts; both belong in the timeline, and the
    /// gap between them is the diagnosis.
    @Test func theGestureAndSynthStreamsAreRecordedIndependently() throws {
        let (log, url) = try makeLog()
        log.gesture(.click(zone: .left, count: 1))   // recognized...
        log.synth(.click(.right, 1))    // ...and posted as the *other* button (left-handed)

        let written = Array(try rows(of: log, at: url).dropFirst())
        #expect(written[0].contains("gesture,click(left;1)"))
        #expect(written[1].contains("synth,click(right;1)"))
    }

    // MARK: Contacts stream

    @Test func logsAContactRowOnlyWhenTheContactSetChanges() throws {
        let (log, url) = try makeLog()
        log.contacts([touch(x: 0.1)])                    // n=1 [left]      → row
        log.contacts([touch(x: 0.2)])                    // same zone+count → no row
        log.contacts([touch(x: 0.9)])                    // n=1 [right]     → row
        log.contacts([touch(x: 0.9), touch(x: 0.1, id: 2)])  // n=2          → row
        log.contacts([])                                 // n=0             → row

        let written = Array(try rows(of: log, at: url).dropFirst())
        #expect(written.count == 4)
        #expect(written[0].contains("n=1 [left]"))
        #expect(written[1].contains("n=1 [right]"))
        #expect(written[2].contains("n=2 [left|right]"))   // sorted, `|`-joined
        #expect(written[3].contains("n=0 []"))
    }

    /// Contacts are recorded as *zones*, never coordinates — what makes a log safe to
    /// attach to a bug report.
    @Test func contactRowsCarryZonesNotCoordinates() throws {
        let (log, url) = try makeLog()
        log.contacts([touch(x: 0.123456)])

        let row = try rows(of: log, at: url)[1]
        #expect(row.contains("[left]"))
        #expect(!row.contains("0.12"))
    }

    // MARK: Console tee

    /// The shipping app leaves this nil (no console); the harness points it at `print`.
    @Test func consoleTeeIsSilentUntilInstalled() throws {
        let (log, url) = try makeLog()
        log.synth(.press(.left))   // must not trap on a nil tee

        var lines: [String] = []
        log.onConsoleLine = { lines.append($0) }
        log.synth(.release(.left))
        log.physical(type: .leftMouseDown, buttonNumber: 0, wasSwallowed: true)

        #expect(lines.count == 2)
        #expect(lines[0].contains("drag ends"))
        #expect(lines[1].contains("SWALLOWED"))
        _ = try rows(of: log, at: url)
    }

    @Test func consoleTeeMarksPhysicalEventsLandingInsideADrag() throws {
        let (log, url) = try makeLog()
        var lines: [String] = []
        log.onConsoleLine = { lines.append($0) }

        log.synth(.press(.left))
        log.physical(type: .leftMouseDown, buttonNumber: 0, wasSwallowed: false)

        #expect(lines.last?.contains("DURING synthetic drag") == true)
        _ = try rows(of: log, at: url)
    }
}
