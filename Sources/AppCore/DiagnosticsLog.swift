import Foundation
import CoreGraphics
import TouchKit
import EventOutput

/// Owns the log file and performs every write on one serial background queue, so the
/// recording path never blocks on the file system — the whole point of recording in situ
/// is to observe real timing, and a synchronous `write(2)` on main would perturb the very
/// thing under measurement.
///
/// Rows are handed off **individually, not batched**. Batching would buy fewer dispatches
/// at the cost of losing the tail of the log on a force-quit — and the stuck-button class
/// of bug this exists to diagnose is precisely the one where the user force-quits. Rows are
/// rare (a few per second at most; contact rows only on *change*), so the dispatch is noise.
///
/// `@unchecked Sendable`: `handle` is touched only from `queue`.
private final class LogFileWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.magicbuttons.diagnostics.write", qos: .utility)

    init(handle: FileHandle) { self.handle = handle }

    /// Formats on the calling thread (cheap) and writes on `queue` (not).
    func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { self.write(data) }
    }

    private func write(_ data: Data) { try? handle.write(contentsOf: data) }

    /// Drains the queue before closing — serial, so every already-appended row lands first.
    func close() { queue.sync { try? handle.close() } }
}

public enum DiagnosticsLogError: Error {
    /// The file couldn't be created or opened for writing (missing parent directory,
    /// permissions). Carries the URL so the caller can surface *which* path failed.
    case couldNotOpen(URL)
}

/// Shared timeline accumulator: one CSV row per event across three streams (physical
/// clicks, synthetic press/release/click, contact-set changes), each stamped with
/// ms-since-start, whether a synthetic hold was active, and — for physical rows —
/// whether de-confliction **consumed** the event. So a mid-drag squeeze is a one-column
/// filter (`hold_active = 1`) and the fix's effect is the next column over
/// (`swallowed = 1`).
///
/// Promoted out of the `mb-dev log-conflicts` harness (docs/13, docs/14 §Click/drag
/// de-confliction), which measured Feature B, into the recorder behind the shipping
/// diagnostics mode — the streams a developer needed to *build* de-confliction are the
/// same ones needed to explain a user's "my drag dropped" report.
///
/// Feed `synth` from a `TeeingEmitter`, **not** from `AppCoordinator.onGesture`: the
/// `hold_active` column has to mean "a synthetic button was really down", and `onGesture`
/// fires pre-policy, so it would claim a hold for a gesture the policy dropped.
///
/// A reference type, main-confined by convention rather than `@MainActor`: every stream's
/// closure already marshals to main, so all mutation lands on one thread, and staying
/// nonisolated lets the tees stay plain closures. File I/O is the one thing that leaves
/// main (see `LogFileWriter`).
public final class DiagnosticsLog {
    private let writer: LogFileWriter
    private let start = Date()
    private let layout: ZoneLayout
    private var holdActive = false
    private var lastContactKey = ""

    /// Where this session is being written — the "Reveal in Finder" target.
    public let fileURL: URL

    /// Optional tee of the human-readable running commentary. `mb-dev log-conflicts` points
    /// this at `print` for live console feedback; the shipping app leaves it `nil` — the app
    /// has no console, and a menu-bar agent writing to stdout helps nobody.
    public var onConsoleLine: ((String) -> Void)?

    public private(set) var physicalDowns = 0
    public private(set) var physicalUps = 0
    public private(set) var synthPresses = 0
    public private(set) var synthReleases = 0
    public private(set) var synthClicks = 0
    /// Physical transitions that landed while a synthetic hold was active — the collisions.
    public private(set) var collisions = 0
    /// Physical events de-confliction consumed (docs/14 §Click/drag de-confliction).
    public private(set) var swallowed = 0
    /// Physical events that reached the app while a hold was active — i.e. collisions we
    /// did **not** swallow. Expected to be the straddle's leaked pair, never a squeeze
    /// that began inside the drag.
    public private(set) var leakedDuringHold = 0

    /// Creates (truncating) the file at `fileURL` and writes the CSV header. The parent
    /// directory must already exist.
    public init(fileURL: URL, layout: ZoneLayout) throws {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
            throw DiagnosticsLogError.couldNotOpen(fileURL)
        }
        self.writer = LogFileWriter(handle: handle)
        self.fileURL = fileURL
        self.layout = layout
        write("t_ms,stream,detail,hold_active,swallowed")
    }

    /// Flushes and closes the file. The log is unusable afterward.
    public func close() { writer.close() }

    private func ms() -> Int { Int((Date().timeIntervalSince(start) * 1000).rounded()) }
    private func write(_ line: String) { writer.append(line) }
    // detail fields never contain a comma (they'd break the column) — separators are `;`/`|`.
    // `swallowed` is blank on rows where consuming isn't a concept (synth/contacts).
    private func row(_ stream: String, _ detail: String, swallowed: Bool? = nil) {
        let s = swallowed.map { $0 ? "1" : "0" } ?? ""
        write("\(ms()),\(stream),\(detail),\(holdActive ? 1 : 0),\(s)")
    }

    public func physical(type: CGEventType, buttonNumber: Int64, wasSwallowed: Bool) {
        let isDown = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
        if isDown { physicalDowns += 1 } else { physicalUps += 1 }
        if wasSwallowed { swallowed += 1 }
        if holdActive {
            collisions += 1
            if !wasSwallowed { leakedDuringHold += 1 }
        }
        row("physical", "\(isDown ? "down" : "up")(btn\(buttonNumber))", swallowed: wasSwallowed)
        let during = holdActive ? "  ⚠︎ DURING synthetic drag" : ""
        let verdict = wasSwallowed ? "  → SWALLOWED" : ""
        onConsoleLine?("  [\(ms())ms] physical \(isDown ? "down" : "up") btn\(buttonNumber)\(during)\(verdict)")
    }

    public func synth(_ e: SynthEvent) {
        switch e {
        case let .press(z):
            holdActive = true; synthPresses += 1
            row("synth", "press(\(z))"); onConsoleLine?("  [\(ms())ms] synth press(\(z))  → drag begins")
        case let .release(z):
            holdActive = false; synthReleases += 1
            row("synth", "release(\(z))"); onConsoleLine?("  [\(ms())ms] synth release(\(z))  → drag ends")
        case let .click(z, n):
            synthClicks += 1
            row("synth", "click(\(z);\(n))"); onConsoleLine?("  [\(ms())ms] synth click(\(z), \(n))")
        }
    }

    public func contacts(_ touches: [SurfaceTouch]) {
        let zones = touches.map { "\(layout.zone(for: $0.position))" }.sorted().joined(separator: "|")
        let key = "\(touches.count):\(zones)"
        guard key != lastContactKey else { return }   // log only when the contact set changes
        lastContactKey = key
        row("contacts", "n=\(touches.count) [\(zones)]")
    }
}
