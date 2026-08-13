import Foundation
import CoreGraphics
import ApplicationServices
import TouchKit
import TouchTestSupport
import MultitouchAdapter
import GestureEngine
import EventOutput
import Visualizer
import AppCore

// App — the composition root (docs/01-architecture.md §Composition root).
//
// Phase 0/1 scaffold + Phase 3 manual-verification harness. The real menu-bar
// (LSUIElement) app shell — AppCoordinator wiring, settings, permission
// bootstrap — lands in Phase 7, hosted by a thin Xcode app target
// (docs/12-project-setup.md). Until then this executable doubles as the
// on-machine harness that closes the HW-manual exit gates (here: Phase 3).

// MARK: - Subcommands

func printUsage() {
    print("""
    mb-dev — MagicButtons dev harness
      (no args)              scaffold info (dependency-graph smoke check)
      verify-emit [zone] [count]
                            post a synthetic click and exit. zone ∈
                            left|middle|right (default middle), count 1|2
                            (default 1). Focus another app during the countdown.
      verify-tap [seconds]  run the EventInterceptor and log physical-click
                            state as you click the real mouse, for `seconds`
                            (default 20), then print a summary and exit.
      dump-frames [seconds] Phase 4 bring-up: enumerate multitouch devices, print
                            sizeof(MTTouch) + surface dimensions, then dump raw
                            contact fields as you touch the mouse (default 10s).
                            Just needs a Magic Mouse (see the note below).
      verify-source [seconds]
                            Phase 4 exit check: run the real MultitouchSource and
                            print SurfaceTouch began/ended events (deviceID, id,
                            zone, size) as you tap the mouse (default 10s).
      visualize [sim]       Phase 5: open a live SwiftUI window of finger dots +
                            zone bands + active zone, fed from the real mouse.
                            `visualize sim` drives a synthetic sweep so it runs
                            with no hardware. Close the window to quit.
      permissions           Phase 7.3: print the live TCC permission snapshot
                            (Accessibility — the sole grant), deep links to fix
                            it if missing, and the derived operational state.
                            Exit 0 iff fully operational.
      verify-gesture [seconds]
                            Phase 6 exit gate: run the whole pipeline live —
                            MultitouchSource → recognizer → CGEventEmitter, with
                            physical-click state fed from the interceptor. Tap and
                            double-tap the shell zones; each produces a real click
                            / double-click in the focused app (default 20s). Needs
                            Accessibility (and a Magic Mouse).
      verify-two-mouse [seconds]
                            Phase 9 gate: with TWO Magic Mice attached, prove
                            contacts stay attributed to the right deviceID —
                            especially both mice touched at once, and same contact
                            id live on both (default 20s). Needs two Magic Mice.
      log-gestures [seconds] [path]
                            Phase 9 calibration: measure every real contact
                            (duration, travel, size, zone, begin-y, physical-click,
                            tap verdict vs shipped defaults) and stream CSV rows to
                            `path` (default: timestamped file in the cwd), then print
                            a tuning summary. Filters/posts nothing — pure
                            measurement (default 30s). Accessibility optional
                            (fills the physical-click column).
      log-conflicts [seconds] [tap|hold] [path]
                            Feature B measurement (docs/14 §Click/drag de-
                            confliction): run the real pipeline with drag promotion
                            wired, and log a timestamped CSV of four streams —
                            physical clicks, recognized gestures, synthetic
                            press/release/click, and contact-set changes — each
                            tagged with whether a synthetic hold was active. The
                            same format the app's diagnostics mode writes.
                            Reproduce the collisions
                            (squeeze mid-drag, race press vs onset, click vs tap);
                            the summary counts physical events that hit during a
                            synthetic drag. `tap` = tapAndAHalf (default), `hold` =
                            pressAndHold — run both (default 30s). Posts real events;
                            needs Accessibility + a Magic Mouse.

      probe-cadence [seconds]
                            Stuck-button Tier 2: measure the Magic Mouse frame
                            cadence while a finger is held — especially resting
                            still — to size (or reject) the drag-release watchdog.
                            Prints the worst frame gap while in contact and a
                            timeout recommendation (default 20s). Needs a Magic
                            Mouse; no Accessibility required (reads only).

      log-events [seconds] [path]
                            Log the raw CGEvent stream as the TARGET APP receives
                            it — type, source (ours vs hardware), location,
                            clickState, pressure, eventNumber, button, deltas — to
                            a CSV. A listen-only tap tail-appended to the session
                            tap, so it observes events downstream of our own
                            rewrite; filters, posts and modifies nothing. Runs of
                            moves/drags collapse to first + count + last so the
                            transitions stay readable. This is the instrument for
                            "our synthetic input behaves differently from a real
                            mouse": reproduce the same gesture synthetically and
                            physically, then diff the field columns. The
                            gesture-level logs above do not carry these fields
                            (default 30s). Needs Accessibility; runs alongside the
                            app rather than replacing it.

    The commands that post clicks need Accessibility permission for the running
    binary (System Settings → Privacy & Security → Accessibility). See docs/05, docs/07.
    Input Monitoring is NOT required — the multitouch stream flows without it (Phase 9);
    grant it to the terminal only as a fallback if a command reports no frames.
    Full from-scratch reference to every subcommand: docs/13-dev-harness.md.
    """)
}

func parseZone(_ s: String?) -> MouseZone? {
    switch s?.lowercased() {
    case "left": return .left
    case "middle", nil: return .middle   // default
    case "right": return .right
    default: return nil
    }
}

/// Phase 3 exit gate (part 1): a synthesized click must land as a real click in
/// another app. Counts down so the operator can focus a target (e.g. TextEdit),
/// then posts one `CGEventEmitter.click`.
func runVerifyEmit(zoneArg: String?, countArg: String?) -> Int32 {
    guard let zone = parseZone(zoneArg) else {
        print("error: zone must be left|middle|right"); return 2
    }
    let count = Int(countArg ?? "1") ?? 1
    guard count == 1 || count == 2 else {
        print("error: count must be 1 or 2"); return 2
    }
    let emitter = CGEventEmitter()
    print("Posting click(\(zone), count: \(count)) in…")
    for n in stride(from: 3, through: 1, by: -1) {
        print("  \(n)  (focus your target app now)")
        Thread.sleep(forTimeInterval: 1)
    }
    emitter.click(zone, count: count)
    print("Posted. Expected: a real \(zone) click landed in the focused app.")
    print("If nothing happened, grant Accessibility to this binary and retry.")
    return 0
}

/// Phase 3 exit gate (part 2): real physical clicks must be *detected* (so the
/// recognizer can reject taps during them) and **not duplicated** — this tool
/// only reports; it never synthesizes on a physical click. Runs for a bounded
/// window then summarizes, so it never hangs (default 20s).
func runVerifyTap(secondsArg: String?) -> Int32 {
    let seconds = Double(secondsArg ?? "20") ?? 20
    let interceptor = EventInterceptor()
    var transitions = 0
    interceptor.onPhysicalClickChange = { active in
        transitions += 1
        print("physicalClickActive → \(active)")
    }
    do {
        try interceptor.start()
    } catch {
        print("error: could not install event tap (\(error)).")
        print("Grant Accessibility to the terminal hosting this, relaunch it, retry (docs/07).")
        return 1
    }
    print("EventInterceptor running for \(Int(seconds))s. Click the real mouse a few times.")
    print("Confirm: each physical click toggles true→false with NO extra click in other apps.")
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    interceptor.stop()
    print("Done. Observed \(transitions) physical-click transition(s).")
    if transitions == 0 {
        print("No transitions seen — if you did click, the tap isn't receiving events.")
    }
    return 0
}

/// Phase 4 exit check: drive the real `MultitouchSource` and print the
/// `SurfaceTouch` began/ended events it produces — verifying frames flow as
/// domain types, the layout guard passes, and each mouse carries a distinct
/// `deviceID` (two-mouse separation).
func runVerifySource(secondsArg: String?) -> Int32 {
    let seconds = TimeInterval(secondsArg ?? "10") ?? 10
    let source: MultitouchSource
    do {
        source = try MultitouchSource()
    } catch {
        print("MultitouchSource unavailable: \(error)")
        print("(.backendUnavailable = framework/sizeof mismatch; .noDevice = no Magic Mouse)")
        return 1
    }

    let layout = ZoneLayout()
    var seenDevices = Set<UInt64>()
    source.onFrame = { touches in
        for t in touches where t.phase == .began || t.phase == .ended {
            seenDevices.insert(t.deviceID.raw)
            print(String(format: "dev=0x%llx id=%d %@ pos=(%.3f,%.3f) zone=%@ size=%.2f",
                         t.deviceID.raw, t.id, "\(t.phase)",
                         t.position.x, t.position.y,
                         "\(layout.zone(for: t.position))", t.size))
        }
    }

    do {
        try source.start()
    } catch {
        print("start failed: \(error) (usually no Magic Mouse connected).")
        return 1
    }
    print("MultitouchSource running for \(Int(seconds))s — tap the mouse in different zones.")

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    source.stop()

    print("done. received frames: \(source.hasReceivedFrame); distinct devices: \(seenDevices.count)")
    if !source.hasReceivedFrame {
        print("no frames — grant Input Monitoring to the hosting terminal and relaunch it.")
    }
    return 0
}

/// Phase 9 two-mouse separation gate (docs/11 §Phase 9, docs/02): with two Magic Mice
/// attached, drive the real `MultitouchSource` into a `MultiDeviceContactTracker` and
/// prove contacts stay attributed to the right `deviceID` — especially when both mice
/// are touched at once, and when they hand out the **same** contact id simultaneously
/// (the case id-only keying would merge). Prints tagged began/ended events live and a
/// PASS/FAIL summary; exits non-zero unless two mice were concurrently separated.
@MainActor
func runVerifyTwoMouse(secondsArg: String?) -> Int32 {
    let seconds = TimeInterval(secondsArg ?? "20") ?? 20
    let source: MultitouchSource
    do {
        source = try MultitouchSource()
    } catch {
        print("MultitouchSource unavailable: \(error)")
        print("(.backendUnavailable = framework/sizeof mismatch; .noDevice = no Magic Mouse)")
        return 1
    }

    let tracker = MultiDeviceContactTracker()
    var announcedSeparation = false
    var announcedCollision = false

    source.onFrame = { touches in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for t in touches where t.phase == .began || t.phase == .ended {
                    print(String(format: "dev=0x%llx id=%d %@  (live devices: %d)",
                                 t.deviceID.raw, t.id, t.phase == .began ? "BEGAN" : "ended",
                                 tracker.concurrentDevices))
                }
                tracker.ingest(touches)
                if tracker.didSeparateTwoMice && !announcedSeparation {
                    announcedSeparation = true
                    print("  ✓ both mice live at once — contacts attributed to distinct deviceIDs")
                }
                if tracker.observedCrossDeviceIDCollision && !announcedCollision {
                    announcedCollision = true
                    print("  ✓✓ same contact id live on both mice — kept separate by (deviceID, id)")
                }
            }
        }
    }

    do {
        try source.start()
    } catch {
        print("start failed: \(error) (usually no Magic Mouse connected).")
        return 1
    }
    print("Two-mouse check for \(Int(seconds))s. Attach BOTH Magic Mice, then touch them")
    print("**at the same time** (and try tapping both together) to exercise separation.\n")

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    source.stop()

    print("\n── two-mouse summary ───────────────────────────────")
    print("distinct devices seen:      \(tracker.devicesSeen.count)")
    print("max concurrent devices:     \(tracker.maxConcurrentDevices)")
    print("cross-device id collision:  \(tracker.observedCrossDeviceIDCollision ? "observed + kept separate" : "not observed")")
    if !source.hasReceivedFrame {
        print("no frames — grant Input Monitoring to the hosting terminal and relaunch it.")
        return 1
    }
    if tracker.didSeparateTwoMice {
        print("RESULT: PASS — two mice were live simultaneously and stayed separated.")
        return 0
    }
    print("RESULT: INCOMPLETE — never saw two mice live at once. Attach both and touch")
    print("        them together during the run.")
    return 1
}

/// Logs each emitted button, then forwards to the real `CGEventEmitter`, so the live
/// harness prints what the pipeline decided while still posting real events.
final class LoggingEmitter: ButtonEmitting {
    private let inner = CGEventEmitter()
    func click(_ zone: MouseZone, count: Int) {
        print("→ click(\(zone), \(count))  \(count == 2 ? "[double]" : "")")
        inner.click(zone, count: count)
    }
    func press(_ zone: MouseZone)   { print("→ press(\(zone))");   inner.press(zone) }
    func release(_ zone: MouseZone) { print("→ release(\(zone))"); inner.release(zone) }
}

/// Phase 6 exit gate, now driven through the Phase 7 `AppCoordinator` — the same
/// object the shipping app uses. The coordinator owns the real `MultitouchSource` →
/// recognizer → `FeaturePolicy` → `CGEventEmitter` chain with `physicalClickActive`
/// from an `EventInterceptor`, plus device hot-plug re-enumeration via a
/// `DeviceMonitor`. A real tap makes a real click; a real double-tap in one zone
/// makes a genuine double-click. Runs on the shipped `GestureConfig` defaults (7.0
/// recalibrated `maxSize`).
@MainActor
func runVerifyGesture(secondsArg: String?) -> Int32 {
    let seconds = TimeInterval(secondsArg ?? "20") ?? 20

    let source: MultitouchSource
    do {
        source = try MultitouchSource()
    } catch {
        print("MultitouchSource unavailable: \(error)")
        print("(.backendUnavailable = framework/sizeof mismatch; .noDevice = no Magic Mouse)")
        return 1
    }

    let coordinator = AppCoordinator(
        source: source,
        clickSource: EventInterceptor(),
        emitter: LoggingEmitter())

    // Re-enumerate mice on any HID attach/detach (callback fires on the main run loop).
    let monitor = DeviceMonitor()
    monitor.onChange = { MainActor.assumeIsolated { coordinator.refreshDevices() } }
    monitor.start()

    coordinator.start()
    if coordinator.interceptorFailed {
        print("warning: event tap not installed (grant Accessibility + relaunch) — clicks won't post.")
    }
    if let sourceError = coordinator.sourceError {
        print("warning: touch source \(sourceError) (.noDevice = no Magic Mouse attached).")
    }

    print("Coordinator live for \(Int(seconds))s. Focus a target app (e.g. TextEdit).")
    print("Tap a zone → one click; double-tap a zone → a double-click (selects a word).")
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    // Capture status before stop() (which clears the connection flag).
    let connected = coordinator.isDeviceConnected
    coordinator.stop()
    monitor.stop()

    print("done. received frames: \(source.hasReceivedFrame); device connected: \(connected)")
    if !source.hasReceivedFrame {
        print("no frames — grant Input Monitoring to the hosting terminal and relaunch it.")
    }
    return 0
}

/// Streams logged contacts to a CSV file and accumulates the live summary. A
/// reference type so the recorder's `onSample` closure and the frame handler share
/// one accumulator on the main thread (frames are marshaled to main below).
final class CalibrationSink {
    private let handle: FileHandle
    private let config: GestureConfig
    private(set) var summary = ContactSummary()
    private(set) var count = 0

    init(handle: FileHandle, config: GestureConfig) {
        self.handle = handle
        self.config = config
        write(ContactSample.csvHeader)
    }

    func record(_ sample: ContactSample) {
        write(sample.csvRow(verdictAgainst: config))
        summary.add(sample, config: config)
        count += 1
        print(String(format: "  #%-3d %-6@ dur=%.3f travel=%.2fmm size=%.1f y=%.2f%@ → %@",
                     count, "\(sample.beganZone)", sample.duration, sample.maxTravelMM,
                     sample.maxSize, sample.origin.y,
                     sample.sawPhysicalClick ? " [click]" : "",
                     sample.verdict(against: config).rawValue))
    }

    private func write(_ line: String) { handle.write(Data((line + "\n").utf8)) }
}

/// Phase 9 calibration harness (docs/11 §Phase 9, docs/08 §"To determine
/// empirically"). Drives the real `MultitouchSource` through a
/// `ContactMetricsRecorder` and writes one CSV row per completed contact —
/// duration, travel, size, begin/end position, zone, physical-click, and the tap
/// verdict against the **shipped** `GestureConfig` defaults. Unlike `verify-gesture`
/// it filters nothing and posts nothing: it just measures, so the CSV's
/// distribution is the raw material for setting zone/threshold defaults and the
/// optional `y` rejection band. Prints a summary at the end.
///
/// CSV → file (arg or a timestamped default in the cwd); human progress + summary →
/// stdout, so the two never interleave. Reads touches with just a Magic Mouse;
/// Accessibility is optional (only fills the `sawPhysicalClick` column — without it
/// that column reads 0 and taps that coincide with a real click aren't flagged).
@MainActor
func runLogGestures(secondsArg: String?, pathArg: String?) -> Int32 {
    let seconds = TimeInterval(secondsArg ?? "30") ?? 30
    let config = GestureConfig()
    let layout = ZoneLayout()

    let source: MultitouchSource
    do {
        source = try MultitouchSource()
    } catch {
        print("MultitouchSource unavailable: \(error)")
        print("(.backendUnavailable = framework/sizeof mismatch; .noDevice = no Magic Mouse)")
        return 1
    }

    // CSV sink — timestamped default keeps repeated sessions from clobbering.
    let path: String = pathArg ?? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return "calibration-\(f.string(from: Date())).csv"
    }()
    FileManager.default.createFile(atPath: path, contents: nil)
    guard let handle = FileHandle(forWritingAtPath: path) else {
        print("error: could not open \(path) for writing."); return 1
    }
    defer { try? handle.close() }
    let sink = CalibrationSink(handle: handle, config: config)

    let recorder = ContactMetricsRecorder(layout: layout)
    recorder.onSample = { [sink] in sink.record($0) }

    // Physical-click state, updated on the main run loop by the interceptor and read
    // when frames are ingested on main. Optional: touches log without it.
    var physicalClickActive = false
    let interceptor = EventInterceptor()
    interceptor.onPhysicalClickChange = { physicalClickActive = $0 }
    let haveClicks: Bool
    do { try interceptor.start(); haveClicks = true }
    catch {
        haveClicks = false
        print("note: event tap not installed (grant Accessibility + relaunch to capture")
        print("      physical-click coincidence). Touch logging continues without it.")
    }

    // Frames arrive on the source's serial queue; marshal to main so the recorder,
    // sink, file, and `physicalClickActive` are all touched on one thread.
    source.onFrame = { touches in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                recorder.ingest(touches, physicalClickActive: physicalClickActive)
            }
        }
    }

    do {
        try source.start()
    } catch {
        print("start failed: \(error) (usually no Magic Mouse connected).")
        return 1
    }

    print("Logging contacts for \(Int(seconds))s → \(path)")
    print("Tap/drag the shell in every zone the way you normally would; palm-rest and")
    print("stray touches too — the point is to capture the real distribution.\n")

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    source.stop()
    if haveClicks { interceptor.stop() }
    recorder.reset()

    printCalibrationSummary(sink.summary, config: config, path: path,
                            receivedFrames: source.hasReceivedFrame)
    return 0
}

/// The at-a-glance tuning readout: contact counts by zone and by verdict, and the
/// min/mean/max of each measurement behind a threshold — enough to eyeball whether
/// a default has the right headroom before touching it.
func printCalibrationSummary(_ s: ContactSummary, config: GestureConfig,
                             path: String, receivedFrames: Bool) {
    print("\n── calibration summary ─────────────────────────────")
    print("contacts logged: \(s.count)   (full rows in \(path))")
    if !receivedFrames {
        print("no frames received — grant Input Monitoring to the hosting terminal and relaunch it.")
        return
    }
    guard s.count > 0 else {
        print("no completed contacts — did any finger land + lift on the shell?")
        return
    }

    func zone(_ z: MouseZone) -> Int { s.byZone[z] ?? 0 }
    print(String(format: "by zone:   left %d   middle %d   right %d",
                 zone(.left), zone(.middle), zone(.right)))

    let order: [TapVerdict] = [.tap, .rejectedPhysicalClick, .rejectedDuration,
                               .rejectedTravel, .rejectedSize]
    let verdicts = order.compactMap { v -> String? in
        guard let n = s.byVerdict[v], n > 0 else { return nil }
        return "\(v.rawValue) \(n)"
    }.joined(separator: "   ")
    print("verdict:   \(verdicts)   (vs shipped defaults)")

    func line(_ label: String, _ st: ContactSummary.Stat, _ limit: String) {
        print(String(format: "%-9@ min %.4f  mean %.4f  max %.4f    %@",
                     label, st.min, st.mean, st.max, limit))
    }
    print("")
    line("duration", s.duration, "maxDuration \(config.maxDuration)")
    line("travel/mm", s.travel,  "maxTravelMM \(config.maxTravelMM)")
    line("size",     s.size,     "maxSize \(config.maxSize)")
    line("beganY",   s.beganY,   "(y rejection band — off by default, docs/08 §A)")
    print("────────────────────────────────────────────────────")
}

// MARK: - log-conflicts (Feature B measurement — docs/14 §Click/drag de-confliction)

/// Feature B measurement instrument (docs/14 §Click/drag de-confliction). Runs the
/// **real** shipping pipeline — `MultitouchSource` → recognizer → `CGEventEmitter` with
/// drag promotion armed through the same `EventInterceptor` that feeds physical-click
/// state — and writes a unified, timestamped CSV of four streams (physical clicks,
/// recognized gestures, synthetic press/release/click, contact-set changes), each tagged
/// with whether a synthetic hold was active. Unlike `verify-gesture` it records the
/// interleaving to a file and wires the drag promoter (so moves genuinely drag); unlike
/// `log-gestures` it posts real events, so a real drag exists to collide with.
///
/// Writes through the same `DiagnosticsLog` as the app's diagnostics mode, wired the same
/// way — one format, one parser, and this harness stays the hardware check on the recorder
/// the app ships.
///
/// Pick the drag style to exercise both Feature B paths:
///   `log-conflicts [seconds] [tap|hold] [path]`  (tap = tapAndAHalf, default; hold = pressAndHold)
///
/// On hardware: squeeze the shell mid-drag; race a physical press against a drag onset;
/// race a physical click against a same-zone tap — then read the summary's collision
/// count. Needs Accessibility + a Magic Mouse.
@MainActor
func runLogConflicts(secondsArg: String?, styleArg: String?, pathArg: String?) -> Int32 {
    let seconds = TimeInterval(secondsArg ?? "30") ?? 30

    let style: DragStyle
    switch styleArg?.lowercased() {
    case "hold", "pressandhold", "press-and-hold": style = .pressAndHold
    case "tap", "taphalf", "tapandahalf", "tap-and-a-half", nil: style = .tapAndAHalf
    default:
        print("unknown drag style '\(styleArg ?? "")' — use 'tap' (tapAndAHalf) or 'hold' (pressAndHold).")
        return 2
    }

    let source: MultitouchSource
    do {
        source = try MultitouchSource()
    } catch {
        print("MultitouchSource unavailable: \(error)")
        print("(.backendUnavailable = framework/sizeof mismatch; .noDevice = no Magic Mouse)")
        return 1
    }

    // CSV sink — timestamped default so repeated sessions don't clobber.
    let path: String = pathArg ?? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return "conflicts-\(f.string(from: Date())).csv"
    }()

    var settings = AppSettings()
    settings.gestures.dragStyle = style

    let log: DiagnosticsLog
    do {
        log = try DiagnosticsLog(
            fileURL: URL(fileURLWithPath: path), layout: settings.zones)
    } catch {
        print("error: could not open \(path) for writing."); return 1
    }
    defer { log.close() }
    // The harness has a console; the shipping app leaves this nil.
    log.onConsoleLine = { print($0) }

    // One EventInterceptor does double duty (physical-click state *and* drag promotion),
    // exactly as the shipping app wires it — so moves actually drag and a real drag exists
    // to collide with. `verify-gesture` omits the drag-promoter link; here it's essential.
    // The coordinator claims `onPhysicalClickChange` (it feeds the recognizer), but
    // `onPhysicalButtonEvent` is ours: it fires *after* the swallow decision, so the log
    // can record whether de-confliction consumed each click.
    let clickSource = EventInterceptor()
    clickSource.onPhysicalButtonEvent = { [log] type, button, swallowed in
        log.physical(type: type, buttonNumber: button, wasSwallowed: swallowed)
    }

    let cgEmitter = CGEventEmitter()
    cgEmitter.dragPromoter = clickSource
    // Tee at the emitter boundary — post-policy, post secondary-click swap — so the
    // timeline's `hold_active` column tracks buttons that were really down.
    let emitter = TeeingEmitter(cgEmitter)
    emitter.onEvent = { [log] in log.synth($0) }

    let coordinator = AppCoordinator(
        source: source, clickSource: clickSource, emitter: emitter, settings: settings)
    coordinator.onFrame = { [log] in log.contacts($0) }
    coordinator.onGesture = { [log] in log.gesture($0) }

    // Re-enumerate mice on any HID attach/detach (callback fires on the main run loop).
    let monitor = DeviceMonitor()
    monitor.onChange = { MainActor.assumeIsolated { coordinator.refreshDevices() } }
    monitor.start()

    coordinator.start()
    if coordinator.interceptorFailed {
        print("warning: event tap not installed (grant Accessibility + relaunch) — no physical")
        print("         clicks will be logged and synthetic clicks won't post.")
    }
    if let sourceError = coordinator.sourceError {
        print("warning: touch source \(sourceError) (.noDevice = no Magic Mouse attached).")
    }

    print("Conflict logging for \(Int(seconds))s, drag style \(style) → \(path)")
    print("Focus a target app (e.g. TextEdit), then reproduce each collision:")
    print("  • start a drag, then squeeze the physical click mid-drag;")
    print("  • race a physical press against a drag onset;")
    print("  • race a physical click against a same-zone tap.")
    print("⚠︎ lines mark a physical event during a synthetic drag.\n")

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let connected = coordinator.isDeviceConnected
    coordinator.stop()
    monitor.stop()

    print("\n── conflict summary ────────────────────────────────")
    print("drag style: \(style)   (full timeline in \(path))")
    print("physical:   \(log.physicalDowns) down / \(log.physicalUps) up   (\(log.swallowed) swallowed)")
    print("synthetic:  \(log.synthPresses) press / \(log.synthReleases) release / \(log.synthClicks) click")
    print("collisions: \(log.collisions)   (physical transitions while a synthetic hold was active)")
    print("  ├ swallowed:  \(log.collisions - log.leakedDuringHold)   ← de-confliction consumed these")
    print("  └ passed:     \(log.leakedDuringHold)   ← expected: only a straddle's leaked pair")
    if !source.hasReceivedFrame {
        print("no frames received — grant Input Monitoring to the hosting terminal and relaunch it.")
    } else if !connected {
        print("note: device disconnected before the run ended.")
    }
    print("────────────────────────────────────────────────────")
    return 0
}

/// Watchdog feasibility probe (stuck-button Tier 2, docs/05 §Press/release). The
/// planned safeguard force-releases a synthetic hold when frames for the held contact
/// stop arriving — on the premise that a Magic Mouse streams frames continuously while
/// a finger is in contact and only falls silent when contact truly ends. This measures
/// that premise directly so we never pick a timeout that could fire *during* a real
/// drag (which would drop it — a worse bug than the one we're fixing).
///
/// The number that matters is the **worst gap while a finger was genuinely down**,
/// measured two ways: frame-to-frame (any contact present) and per-contact (the held
/// id momentarily dropping out of frames while still down — the subtle risk case).
/// Timing is sampled *after* the hop to main, matching where the real watchdog timer
/// would live. A safe timeout must sit comfortably above that worst gap.
@MainActor
func runProbeCadence(secondsArg: String?) -> Int32 {
    let seconds = TimeInterval(secondsArg ?? "20") ?? 20
    let source: MultitouchSource
    do {
        source = try MultitouchSource()
    } catch {
        print("MultitouchSource unavailable: \(error)")
        print("(.backendUnavailable = framework/sizeof mismatch; .noDevice = no Magic Mouse)")
        return 1
    }

    let clock = { ProcessInfo.processInfo.systemUptime }
    let sessionStart = clock()
    var lastContactFrameAt: TimeInterval?          // last frame carrying ≥1 live contact
    var lastSeenByContact: [String: TimeInterval] = [:]  // per live (device,id) → last seen
    var maxFrameGap = 0.0                           // worst frame-to-frame gap while in contact
    var maxContactGap = 0.0                         // worst per-contact reappearance gap
    var maxStationaryGap = 0.0                      // worst frame gap when prev frame was all-stationary
    var worstAt = 0.0                               // wall-time of the worst gap, for the log
    var prevAllStationary = false
    var totalFrames = 0, contactFrames = 0
    var begans = 0, endeds = 0
    var lastHeartbeat = clock()

    source.onFrame = { touches in
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let now = clock()
                totalFrames += 1
                let live = touches.filter { $0.phase != .ended }
                begans += touches.filter { $0.phase == .began }.count
                endeds += touches.filter { $0.phase == .ended }.count

                // Per-contact continuity: how long a still-live contact can vanish from
                // frames and come back — the exact gap the watchdog must not trip on.
                for t in live {
                    let key = "\(t.deviceID.raw):\(t.id)"
                    if let seen = lastSeenByContact[key], now - seen > maxContactGap {
                        maxContactGap = now - seen; worstAt = now
                    }
                    lastSeenByContact[key] = now
                }
                for t in touches where t.phase == .ended {
                    lastSeenByContact["\(t.deviceID.raw):\(t.id)"] = nil
                }

                if live.isEmpty {
                    lastContactFrameAt = nil        // contact chain broke (true release)
                    prevAllStationary = false
                } else {
                    contactFrames += 1
                    if let last = lastContactFrameAt {
                        let gap = now - last
                        if gap > maxFrameGap { maxFrameGap = gap }
                        if prevAllStationary { maxStationaryGap = max(maxStationaryGap, gap) }
                    }
                    lastContactFrameAt = now
                    prevAllStationary = live.allSatisfy { $0.phase == .stationary }
                }

                if now - lastHeartbeat >= 1.0 {
                    lastHeartbeat = now
                    print(String(format: "  … contacts=%d  worst-gap-while-down: frame=%.0fms contact=%.0fms",
                                 live.count, maxFrameGap * 1000, maxContactGap * 1000))
                }
            }
        }
    }

    do {
        try source.start()
    } catch {
        print("start failed: \(error) (if no frames arrive, grant Input Monitoring to the")
        print("hosting terminal and relaunch it — though Phase 9 found frames flow without it).")
        return 1
    }

    print("Cadence probe for \(Int(seconds))s. Do ALL of these so the worst case is captured:")
    print("  1) Rest ONE finger on the shell and hold PERFECTLY STILL for ~5s, then lift.")
    print("  2) Press and slowly DRAG, pausing motionless mid-drag for a couple seconds.")
    print("  3) A few normal taps and a tap-and-a-half drag.")
    print("The key question: does a still finger ever make frames go quiet?\n")

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    source.stop()

    let worst = max(maxFrameGap, maxContactGap)
    print("\n── cadence summary ─────────────────────────────────")
    print("frames: \(totalFrames) total, \(contactFrames) with a live contact")
    print("began/ended contacts: \(begans) / \(endeds)"
        + (begans == endeds ? "  (every contact ended cleanly)" : "  ⚠︎ mismatch — a lift went unreported!"))
    print(String(format: "worst frame-to-frame gap while down: %.1f ms", maxFrameGap * 1000))
    print(String(format: "worst all-stationary frame gap:      %.1f ms", maxStationaryGap * 1000))
    print(String(format: "worst per-contact reappearance gap:  %.1f ms  (at t≈%.1fs)",
                 maxContactGap * 1000, worstAt > 0 ? worstAt - sessionStart : 0))
    print("")

    if !source.hasReceivedFrame {
        print("RESULT: NO FRAMES — grant Input Monitoring to the terminal, relaunch, retry.")
        return 1
    }
    if contactFrames == 0 {
        print("RESULT: NO CONTACTS — did a finger actually land on the shell? Retry.")
        return 1
    }
    print(String(format: "WORST GAP WHILE A FINGER WAS DOWN: %.1f ms", worst * 1000))
    if endeds < begans {
        print("VERDICT: ⚠︎ A lift went unreported — the watchdog backstop is clearly WARRANTED,")
        print("         but pick the timeout from the worst gap above, with wide margin.")
    }
    if worst < 0.050 {
        print(String(format: "VERDICT: ✅ Tight, continuous stream. A ~%.0f ms watchdog (≈%.0f× worst gap)",
                     max(0.200, worst * 4) * 1000, max(0.200, worst * 4) / max(worst, 0.001)))
        print("         would never fire during real contact yet release promptly on lift.")
    } else if worst < 0.150 {
        print(String(format: "VERDICT: ✅ Feasible. Use ≥ %.0f ms (≈3× worst) for safe margin.",
                     max(0.400, worst * 3) * 1000))
    } else {
        print(String(format: "VERDICT: ⚠︎ Worst gap is %.0f ms — a frame-silence watchdog is RISKY;",
                     worst * 1000))
        print("         a timeout above this would be sluggish, below it could drop a real drag.")
        print("         Reconsider the trigger (e.g. key off an explicit .ended, not silence).")
    }
    print("────────────────────────────────────────────────────")
    return 0
}

// MARK: - Scaffold (default, no args)

func runScaffold() {
    let source: TouchSource = SimulatedTouchSource()
    let zones = MouseZone.allCases.map(String.init(describing:)).joined(separator: "/")
    let pendingModules = [
        MultitouchAdapter.moduleName,
        GestureEngine.moduleName,
        Visualizer.moduleName,
    ]
    print("MagicButtons scaffold — zones: \(zones); source: \(type(of: source)); "
        + "pending modules: \(pendingModules.joined(separator: ", "))")
}

// MARK: - log-events (raw CGEvent stream as the target app sees it)

/// Records the raw `CGEvent` field stream — the instrument that found the Pages/Numbers
/// drag-collapse bug (docs/14 §Synthetic drags read as clicks). Everything else in this
/// harness logs at the *gesture* level; none of it carries `clickState`, `pressure` or
/// `eventNumber`, which is where that whole class of defect lives.
///
/// The tap is **listen-only** and **tail-appended to the session tap**, two deliberate
/// choices. Listen-only means it cannot alter or drop anything, so it is safe to leave
/// running against the real app (unlike `log-conflicts`, this does not replace the app —
/// run both). Tail-appending to the *session* tap puts it downstream of the app's own
/// `.cghidEventTap` rewrite, so what it records is what the target application actually
/// receives, our move→drag promotion included. Reading a synthetic event and a hardware
/// one out of the same file is the entire point: diff the columns.
///
/// Runs of moves/drags are collapsed to first + count + last. A 30-second session is tens
/// of thousands of move events, and the interesting rows are always the transitions.
@MainActor
func runLogEvents(secondsArg: String?, pathArg: String?) -> Int32 {
    let seconds = TimeInterval(secondsArg ?? "30") ?? 30

    guard AXIsProcessTrusted() else {
        print("Accessibility not granted to this binary — a tap can't be created.")
        print("Grant it in System Settings → Privacy & Security → Accessibility, then rerun.")
        return 1
    }

    let path: String = pathArg ?? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        return "events-\(f.string(from: Date())).csv"
    }()

    let recorder = EventStreamRecorder()
    guard recorder.start() else {
        print("error: could not create the event tap.")
        return 1
    }
    defer { recorder.stop() }

    print("Logging the raw event stream for \(Int(seconds))s → \(path)")
    print("Reproduce the same gesture BOTH ways — synthetically and with a physical click —")
    print("then diff the clickState/pressure/eventNumber columns between the two.\n")

    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    let rows = recorder.finish()

    do {
        try rows.joined(separator: "\n").appending("\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
        print("error: could not write \(path): \(error)")
        return 1
    }

    print("\n── event stream ────────────────────────────────────")
    print("rows:      \(rows.count - 1)   (full stream in \(path))")
    print("synthetic: \(recorder.syntheticCount) button events from this app")
    print("physical:  \(recorder.physicalButtonCount) button events from hardware")
    print("────────────────────────────────────────────────────")
    return 0
}

/// Collects the stream for `log-events`. Kept out of the command body so the tap callback
/// has one stable object to write into, and so run-collapsing is testable by inspection.
@MainActor
final class EventStreamRecorder {
    private(set) var rows: [String] =
        ["ms,type,src,x,y,clickState,pressure,eventNumber,button,dx,dy"]
    private(set) var syntheticCount = 0
    private(set) var physicalButtonCount = 0

    private let startedAt = Date()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Collapsed run of consecutive same-kind stream events (moves/drags/scrolls).
    private var runKind: String?
    private var runCount = 0
    private var runFirst: String?
    private var runLast: String?

    private static let observed: [CGEventType] = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .mouseMoved, .scrollWheel,
    ]

    func start() -> Bool {
        let mask = Self.observed.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            // Tail-appended to the SESSION tap: downstream of our own HID-tap rewrite, so
            // a promoted move is already recorded as the drag the app will see.
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                if let refcon {
                    let recorder = Unmanaged<EventStreamRecorder>
                        .fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { recorder.record(type: type, event: event) }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        runLoopSource = nil
        tap = nil
    }

    /// Flush any open run and hand back the complete CSV.
    func finish() -> [String] {
        flushRun()
        return rows
    }

    private func record(type: CGEventType, event: CGEvent) {
        let synthetic =
            event.getIntegerValueField(.eventSourceUserData) == CGEventEmitter.syntheticMarker
        if Self.isButtonEvent(type) {
            if synthetic { syntheticCount += 1 } else { physicalButtonCount += 1 }
        }

        let location = event.location
        let row = [
            "\(Int(Date().timeIntervalSince(startedAt) * 1000))",
            Self.name(type),
            synthetic ? "SYNTH" : "phys",
            String(format: "%.1f", location.x),
            String(format: "%.1f", location.y),
            "\(event.getIntegerValueField(.mouseEventClickState))",
            String(format: "%.2f", event.getDoubleValueField(.mouseEventPressure)),
            "\(event.getIntegerValueField(.mouseEventNumber))",
            "\(event.getIntegerValueField(.mouseEventButtonNumber))",
            "\(event.getIntegerValueField(.mouseEventDeltaX))",
            "\(event.getIntegerValueField(.mouseEventDeltaY))",
        ].joined(separator: ",")

        // Only high-volume streams collapse; a button transition is always its own row.
        guard Self.isStreamEvent(type) else {
            flushRun()
            rows.append(row)
            return
        }
        let kind = Self.name(type) + (synthetic ? "/S" : "/p")
        if kind == runKind {
            runCount += 1
            runLast = row
            return
        }
        flushRun()
        runKind = kind
        runCount = 1
        runFirst = row
        runLast = row
    }

    private func flushRun() {
        guard let first = runFirst else { return }
        rows.append(first)
        if runCount > 2, let last = runLast {
            rows.append("# … \(runCount - 2) more \(runKind ?? "") …")
            rows.append(last)
        } else if runCount == 2, let last = runLast {
            rows.append(last)
        }
        runKind = nil
        runCount = 0
        runFirst = nil
        runLast = nil
    }

    private static func isButtonEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown,
             .rightMouseUp, .otherMouseDown, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    private static func isStreamEvent(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged, .scrollWheel:
            return true
        default:
            return false
        }
    }

    private static func name(_ type: CGEventType) -> String {
        switch type {
        case .leftMouseDown: return "leftDown"
        case .leftMouseUp: return "leftUp"
        case .leftMouseDragged: return "leftDrag"
        case .rightMouseDown: return "rightDown"
        case .rightMouseUp: return "rightUp"
        case .rightMouseDragged: return "rightDrag"
        case .otherMouseDown: return "otherDown"
        case .otherMouseUp: return "otherUp"
        case .otherMouseDragged: return "otherDrag"
        case .mouseMoved: return "moved"
        case .scrollWheel: return "scroll"
        default: return "type\(type.rawValue)"
        }
    }
}

// MARK: - Dispatch

// Unbuffered stdout so live logs and the countdown appear immediately even when
// the harness is run backgrounded/redirected to a file (block-buffered pipe).
setvbuf(stdout, nil, _IONBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "verify-emit":
    exit(runVerifyEmit(zoneArg: args.count > 1 ? args[1] : nil,
                       countArg: args.count > 2 ? args[2] : nil))
case "verify-tap":
    exit(runVerifyTap(secondsArg: args.count > 1 ? args[1] : nil))
case "dump-frames":
    let seconds = TimeInterval(args.count > 1 ? args[1] : "10") ?? 10
    MultitouchDump.run(seconds: seconds)
case "verify-source":
    exit(runVerifySource(secondsArg: args.count > 1 ? args[1] : nil))
case "visualize":
    exit(runVisualize(useSimulator: args.dropFirst().first == "sim"))
case "permissions":
    exit(runPermissions())
case "verify-gesture":
    exit(runVerifyGesture(secondsArg: args.count > 1 ? args[1] : nil))
case "verify-two-mouse":
    exit(runVerifyTwoMouse(secondsArg: args.count > 1 ? args[1] : nil))
case "log-gestures":
    exit(runLogGestures(secondsArg: args.count > 1 ? args[1] : nil,
                        pathArg: args.count > 2 ? args[2] : nil))
case "log-conflicts":
    exit(runLogConflicts(secondsArg: args.count > 1 ? args[1] : nil,
                         styleArg: args.count > 2 ? args[2] : nil,
                         pathArg: args.count > 3 ? args[3] : nil))
case "probe-cadence":
    exit(runProbeCadence(secondsArg: args.count > 1 ? args[1] : nil))
case "log-events":
    exit(runLogEvents(secondsArg: args.count > 1 ? args[1] : nil,
                      pathArg: args.count > 2 ? args[2] : nil))
case "-h", "--help", "help":
    printUsage()
case .none:
    runScaffold()
default:
    print("unknown command: \(args[0])\n")
    printUsage()
    exit(2)
}
