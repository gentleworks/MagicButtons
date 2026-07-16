import Testing
import Foundation
@testable import AppCore
import TouchKit
import GestureEngine
import EventOutput

// The composition the app shell uses to record: the coordinator's frame tee feeds the
// contacts stream, and a `TeeingEmitter` wrapped around the real emitter feeds the synth
// stream. `AppModel` itself lives in the (untestable) Xcode target, so these pin the
// *pattern* it follows — the pieces are the shipping ones, driven with fakes.
//
// The physical stream isn't exercised here: `onPhysicalButtonEvent` belongs to the concrete
// `EventInterceptor`, not the `PhysicalClickSource` protocol, so it needs the real event tap
// and hardware. `DiagnosticsLogTests` covers that stream's bookkeeping directly.

@MainActor
@Suite struct DiagnosticsWiringTests {

    private final class Rig {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-wiring-\(UUID().uuidString)")
        let source = ControllableSource()
        let spy = SpyEmitter()
        let emitter: TeeingEmitter
        let coordinator: AppCoordinator
        let session: DiagnosticsSession
        let settings: AppSettings

        @MainActor
        init(settings: AppSettings = .init()) {
            self.settings = settings
            self.emitter = TeeingEmitter(spy)
            self.coordinator = AppCoordinator(
                source: source, clickSource: FakeClickSource(),
                emitter: emitter, settings: settings)
            self.session = DiagnosticsSession(directory: directory, pollInterval: 3600)

            // Exactly `AppModel`'s wiring: frames tee unconditionally and cost a nil check
            // when off; the emitter tee is installed only while recording, and torn down on
            // every ending through `onStop`.
            coordinator.onFrame = { [session] frame in session.log?.contacts(frame) }
            coordinator.onGesture = { [session] gesture in session.log?.gesture(gesture) }
            session.onStop = { [emitter] _ in emitter.onEvent = nil }
            coordinator.start()
        }

        @MainActor
        func startRecording() {
            let log = session.start(layout: settings.zones)!
            emitter.onEvent = { [weak log] event in log?.synth(event) }
        }

        /// Frames hop to main inside the coordinator, so drain them before asserting.
        @MainActor
        func feed(_ frames: [[SurfaceTouch]]) async {
            for frame in frames { source.onFrame?(frame) }
            for _ in 0..<20 { await Task.yield() }
        }

        @MainActor
        func recordedRows() -> [String] {
            session.stop()   // flushes
            let text = (try? String(contentsOf: session.lastFileURL!, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").dropFirst().map(String.init)   // drop header
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func recordsSyntheticClicksWithoutDisturbingEmission() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.startRecording()

        await rig.feed(tapFrames(x: 0.5))

        // The button still posts — recording observes, it never intercepts.
        #expect(rig.spy.clickedZones == [.middle])
        #expect(rig.recordedRows().contains { $0.contains("synth,click(middle;1)") })
    }

    @Test func recordsContactChangesAsZones() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.startRecording()

        // `tapFrames` ends with the touch still present as `.ended`; the lift itself is the
        // next frame no longer carrying it, which is how the real stream reports it.
        await rig.feed(tapFrames(x: 0.1) + [[]])

        let contacts = rig.recordedRows().filter { $0.contains(",contacts,") }
        // One row per *change* — the two identical `n=1 [left]` frames collapse to one.
        #expect(contacts.count == 2)
        #expect(contacts[0].contains("n=1 [left]"))
        #expect(contacts[1].contains("n=0 []"))
    }

    /// A drag records `press` … `release`, and every row between them reads as held — the
    /// column the collision analysis pivots on.
    @Test func recordsAHoldAsAnOpenSpan() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.startRecording()

        await rig.feed(holdInFlightFrames(x: 0.5))

        let rows = rig.recordedRows()
        let press = rows.firstIndex { $0.contains("synth,press(middle)") }
        #expect(press != nil)
        // The release comes from the session's own teardown path releasing the held button.
        #expect(rows[press!].hasSuffix(",1,"))
    }

    /// Why the two streams are separate, and the case they exist to explain: with the
    /// feature off, the gesture is still *recognized* but no button is *posted*. The log
    /// must show a `gesture` row and no `synth` row — that pairing is the "I tapped and
    /// nothing happened" report. Recording only from the pre-policy tee would instead claim
    /// a hold that never happened, and `hold_active` is what the de-confliction analysis
    /// reads.
    @Test func aGestureThePolicyBlockedIsRecordedButNotAsAnEmission() async {
        var settings = AppSettings()
        settings.features.masterEnabled = false
        let rig = Rig(settings: settings); defer { rig.cleanUp() }
        rig.startRecording()

        await rig.feed(tapFrames(x: 0.5))

        let rows = rig.recordedRows()
        #expect(rig.spy.clicks.isEmpty)                                  // nothing posted
        #expect(rows.contains { $0.contains("gesture,click(middle;1)") })  // but recognized
        #expect(!rows.contains { $0.contains(",synth,") })
    }

    /// The pair agreeing is the ordinary case: recognized, then posted.
    @Test func anAllowedGestureIsRecordedOnBothStreams() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.startRecording()

        await rig.feed(tapFrames(x: 0.5))

        let rows = rig.recordedRows()
        let gesture = rows.firstIndex { $0.contains("gesture,click(middle;1)") }
        let synth = rows.firstIndex { $0.contains("synth,click(middle;1)") }
        #expect(gesture != nil)
        #expect(synth != nil)
        #expect(gesture! < synth!)   // recognized before posted — the tee order
    }

    /// Off is the steady state: after a stop, the streams must go quiet — no rows, no
    /// resurrection by a late frame.
    @Test func stoppingLeavesNothingRecording() async {
        let rig = Rig(); defer { rig.cleanUp() }
        rig.startRecording()
        await rig.feed(tapFrames(x: 0.5))

        let url = rig.session.lastFileURL!
        rig.session.stop()
        let afterStop = try! String(contentsOf: url, encoding: .utf8)

        await rig.feed(tapFrames(x: 0.9))   // more real activity, no session

        #expect(!rig.session.isRecording)
        #expect(try! String(contentsOf: url, encoding: .utf8) == afterStop)
        #expect(rig.spy.clickedZones == [.middle, .right])   // still emitting, just not logged
    }
}
