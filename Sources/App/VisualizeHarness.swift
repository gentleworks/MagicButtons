import AppKit
import Foundation
import SwiftUI
import TouchKit
import Visualizer
import MultitouchAdapter

// Phase 5 exit gate: put a live, accurate finger/zone picture on screen from the
// real stream. Like the other verify-* tools this lives in the App executable
// (no app bundle until Phase 7); it bootstraps a minimal NSApplication window
// hosting `VisualizerView` and fans frames into `VisualizerModel` on main.
//
// `visualize`      — drive from the real MultitouchSource (needs a Magic Mouse +
//                    Input Monitoring for the hosting terminal).
// `visualize sim`  — drive from a synthetic sweep, so the view can be seen with
//                    no hardware (docs/06: "runs on simulated too").

/// A hardware-free `TouchSource`: one contact sweeping left↔right across the
/// zones on a main-thread timer, so `visualize sim` shows a moving dot and the
/// active-zone highlight tracking it. Real-time (unlike `SimulatedTouchSource`,
/// which replays synchronously), which is exactly what a live demo wants.
@MainActor
final class SweepSource: @MainActor TouchSource {
    var onFrame: (([SurfaceTouch]) -> Void)?
    private var timer: Timer?
    private var t: CGFloat = 0
    private var dir: CGFloat = 1
    private let device = MouseDeviceID(raw: 0x5124)

    func start() throws {
        var first = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.t += self.dir * 0.006
                if self.t >= 1 { self.t = 1; self.dir = -1 }
                if self.t <= 0 { self.t = 0; self.dir = 1 }
                let phase: TouchPhase = first ? .began : .moved
                first = false
                let touch = SurfaceTouch(
                    deviceID: self.device, id: 1,
                    position: CGPoint(x: self.t, y: 0.6 + 0.15 * sin(self.t * .pi * 2)),
                    phase: phase, timestamp: Date().timeIntervalSinceReferenceDate, size: 9)
                self.onFrame?([touch])
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Terminates the process when the visualizer window closes, and stops the source
/// on the way out so a hardware tap stream isn't left running.
final class VisualizeAppDelegate: NSObject, NSApplicationDelegate {
    private let onQuit: () -> Void
    init(onQuit: @escaping () -> Void) { self.onQuit = onQuit }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { onQuit() }
}

@MainActor
func runVisualize(useSimulator: Bool) -> Int32 {
    let model = VisualizerModel()

    let source: TouchSource
    if useSimulator {
        source = SweepSource()
    } else {
        do {
            source = try MultitouchSource()
        } catch {
            print("MultitouchSource unavailable: \(error)")
            print("(no Magic Mouse or framework/sizeof mismatch). Try: mb-dev visualize sim")
            return 1
        }
    }

    // Frames arrive off-main (real source hops to a serial queue); marshal to the
    // main actor before touching the model.
    source.onFrame = { frame in
        Task { @MainActor in model.update(frame) }
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered, defer: false)
    window.title = useSimulator ? "MagicButtons — Visualizer (sim)" : "MagicButtons — Visualizer"
    window.contentView = NSHostingView(rootView: VisualizerView(model: model))
    window.center()
    window.makeKeyAndOrderFront(nil)

    do {
        try source.start()
    } catch {
        print("source start failed: \(error) (often Input Monitoring not granted; docs/07)")
        return 1
    }

    let delegate = VisualizeAppDelegate { source.stop() }
    app.delegate = delegate
    print("Visualizer window open. Move a finger on the mouse; close the window to quit.")
    app.activate(ignoringOtherApps: true)
    app.run()
    return 0
}
