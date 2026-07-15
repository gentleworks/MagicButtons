import Foundation
import TouchKit
import MTPrivate

/// Debug bring-up tool (docs/04 §The C shim — "the first thing built in this
/// target"). Enumerates devices, prints `sizeof(MTTouch)` and per-device surface
/// dimensions, then dumps raw contact fields as you touch the mouse — so struct
/// layout, `state` values, and Magic-Mouse-vs-trackpad dimensions are verified
/// empirically on the running OS BEFORE any coordinate is trusted downstream.
///
/// Intentionally standalone: it does NOT build `SurfaceTouch`. The real
/// `MultitouchSource` is written against whatever this reveals.
public enum MultitouchDump {

    /// Enumerate + print device table, then stream raw frames for `seconds`.
    public static func run(seconds: TimeInterval) {
        let backend: MTBackend
        do {
            backend = try MTBackend.resolve()
        } catch {
            print("backend unavailable: \(error) — MultitouchSupport did not resolve.")
            return
        }

        print("sizeof(MTTouch) = \(MTPrivate_touchStructSize()) bytes")

        guard let (list, devices) = backend.devices(), !devices.isEmpty else {
            print("no multitouch devices enumerated (.noDevice).")
            return
        }

        print("devices (\(devices.count)):")
        let state = DumpState()
        for (index, device) in devices.enumerated() {
            let dims = backend.surfaceSize(of: device)
            let id = backend.stableID(of: device)
            let dimStr = dims.map { "\($0.width)×\($0.height) (¹⁄₁₀₀ mm)" } ?? "unknown"
            print("  [\(index)] id=0x\(String(id, radix: 16)) surface=\(dimStr)")
            state.label[device] = index
        }

        print("""
        \nstreaming raw contacts for \(Int(seconds))s — touch/tap/lift on the mouse.
        columns: dev  frame  id  state  x      y      major  ts
        """)

        activeDump = state
        for (index, device) in devices.enumerated() {
            backend.registerCallback(device, dumpFrameCallback)
            let rc = backend.start(device, 0)
            print("  started [\(index)] rc=\(rc)")
        }

        // Keep the process alive for the full window AND keep pumping the run
        // loop in slices (run(until:) can early-return with no sources attached;
        // the framework delivers on its own thread regardless). A per-second
        // heartbeat shows live whether frames are arriving.
        let deadline = Date().addingTimeInterval(seconds)
        var nextBeat = Date().addingTimeInterval(1)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if Date() >= nextBeat {
                print("  … callbacks=\(state.callbacks) contacts=\(state.contactsSeen)")
                nextBeat = Date().addingTimeInterval(1)
            }
        }

        // Stop only — the list/framework owns the device elements; do NOT
        // MTDeviceRelease them here (that double-frees → CFRelease SIGTRAP).
        for device in devices { _ = backend.stop(device) }
        activeDump = nil

        print("""
        \ndone. callbacks=\(state.callbacks) contacts=\(state.contactsSeen) \
        printed=\(state.printed) lines; observed states: \
        \(state.seenStates.sorted().map(String.init).joined(separator: ", "))
        """)
        if state.callbacks == 0 {
            print("callback never fired — registration/start path is the issue, not "
                + "permissions or the wait loop. I'll try MTDeviceCreateDefault / the "
                + "run-loop callback variant next.")
        }
        withExtendedLifetime(list) {} // hold the device list until cleanup is done
    }

    /// Per-run scratch shared with the C callback. Diagnostic-only.
    final class DumpState {
        var label: [MTBackend.DeviceRef: Int] = [:]
        var printed = 0
        var callbacks = 0
        var contactsSeen = 0
        var seenStates: Set<Int32> = []
        let maxLines = 400
    }
}

/// The active dump's state, read by the C callback (framework thread). A debug
/// tool runs one dump at a time, so a single global is adequate.
nonisolated(unsafe) private var activeDump: MultitouchDump.DumpState?

/// Non-capturing C callback the framework invokes with each contact frame.
private let dumpFrameCallback: MTContactFrameCallback = { device, touches, numTouches, timestamp, _ in
    guard let dump = activeDump else { return 0 }
    dump.callbacks += 1
    guard let touches, let device else { return 0 }
    let dev = dump.label[device] ?? -1
    // Clamp against a bad struct layout handing us a garbage count.
    let count = max(0, min(Int(numTouches), 32))
    dump.contactsSeen += count
    for i in 0..<count {
        let t = touches[i]
        dump.seenStates.insert(t.state)
        guard dump.printed < dump.maxLines else { continue }
        dump.printed += 1
        let line = String(
            format: "%3d %6d %3d %5d  %.3f  %.3f  %.3f  %.3f",
            dev, t.frame, t.identifier, t.state,
            t.normalized.position.x, t.normalized.position.y,
            t.majorAxis, timestamp)
        print(line)
    }
    return 0
}
