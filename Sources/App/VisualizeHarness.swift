import AppKit
import AppCore
import EventOutput
import Foundation
import GestureEngine
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

/// Posts nothing, ever. `visualize` is a viewer, not a driver — it must not click the
/// user's machine while they watch the picture. Deliberately *not* `LoggingEmitter`,
/// which forwards to a real `CGEventEmitter`.
final class SilentEmitter: ButtonEmitting {
    func click(_ zone: MouseZone, count: Int) {}
    func press(_ zone: MouseZone) {}
    func release(_ zone: MouseZone) {}
}

/// A `PhysicalClickSource` that never installs an event tap, so `visualize` still needs
/// no Accessibility grant. A viewer holding a live `.cghidEventTap` is the exact hazard
/// that once wedged clicking system-wide when the grant was revoked (docs/14
/// §Interceptor lifetime), and it buys nothing here: the only behaviour lost is
/// `requireNoPhysicalClick` rejection, which needs a real hardware click to matter.
final class InertClickSource: PhysicalClickSource {
    var onPhysicalClickChange: ((Bool) -> Void)?
    func start() throws {}
    func stop() {}
}

/// The app's own saved settings, read from *its* defaults domain.
///
/// `mb-dev` is a separate binary, so `UserDefaults.standard` here is a different domain
/// than `MagicButtons.app`'s — reading it would silently hand back stock defaults and
/// the harness would draw zone bands that disagree with what the app actually does.
/// That is precisely the divergence docs/06 exists to forbid, so the suite is named
/// explicitly. Falls back to defaults when the app has never run.
///
/// The identifier tracks `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml`; there is no
/// shared constant to hang it on, because the package cannot see the Xcode target.
private func loadAppSettings() -> (settings: AppSettings, foundSaved: Bool) {
    let appDomain = "com.gentleworks.MagicButtons"
    guard let defaults = UserDefaults(suiteName: appDomain) else {
        return (AppSettings(), false)
    }
    let store = SettingsStore(storage: UserDefaultsStorage(defaults))
    let settings = store.load()
    return (settings, settings != AppSettings())
}

@MainActor
func runVisualize(useSimulator: Bool) -> Int32 {
    // Same zone boundaries the app is using, so the bands are not a fiction.
    let (settings, foundSaved) = loadAppSettings()
    let model = VisualizerModel(layout: settings.zones)

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

    // Drive the picture through the **real** coordinator, on the app's own settings, so
    // the harness shows what the shipping recognizer would decide — travel rings, gesture
    // badges and the spoken readout included — rather than a contacts-only shadow of it.
    // Nothing is emitted (`SilentEmitter`) and no tap is installed (`InertClickSource`).
    let coordinator = AppCoordinator(
        source: source,
        clickSource: InertClickSource(),
        emitter: SilentEmitter(),
        settings: settings)

    coordinator.onFrame = { frame in
        // Read after the coordinator's own ingest, so these are this frame's measurements
        // from the recognizer that judges them — the same ordering `AppModel` relies on.
        model.update(frame,
                     budgets: VisualizerFeed.budgets(coordinator.liveContacts),
                     at: ProcessInfo.processInfo.systemUptime)
    }
    coordinator.onGesture = { gesture in
        model.register(VisualizerFeed.recognized(gesture))
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

    // The coordinator owns the source's lifecycle now, and reports a failed start as
    // status rather than throwing (docs/07) — so ask it afterwards instead of catching.
    coordinator.start()
    if let sourceError = coordinator.sourceError {
        print("source start failed: \(sourceError) (.noDevice = no Magic Mouse attached).")
        return 1
    }

    let delegate = VisualizeAppDelegate { coordinator.stop() }
    app.delegate = delegate
    print(foundSaved
          ? "Using your saved settings (zones + recognizer tunables) from MagicButtons.app."
          : "MagicButtons.app has no saved settings yet — showing stock defaults.")
    print("Visualizer window open. Move a finger on the mouse; close the window to quit.")
    print("Nothing is clicked: this posts no events and installs no event tap.")
    app.activate(ignoringOtherApps: true)
    app.run()
    return 0
}
