import SwiftUI
import AppKit

/// The thin menu-bar (`LSUIElement`) app shell (Phase 7.5, docs/12 §Packaging). All
/// runtime wiring lives in `AppModel`; this only declares the two scenes — the
/// `MenuBarExtra` pull-down and the `Settings` window — and drives lifecycle through an
/// `NSApplicationDelegate` so the input streams start after launch and stop (safely
/// releasing any held button) on quit.
@main
struct MagicButtonsApp: App {
    // Held as `@State` (not read off `delegate.model`) so SwiftUI observes the model's
    // `@Observable` changes and re-renders the menu-bar label when health flips. Same
    // instance the delegate drives — `AppModel.shared`.
    @State private var model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
        // No SwiftUI `Settings` scene: the Settings window is managed imperatively by
        // `AppModel.showSettings()` so a menu-bar (accessory) app can raise it to the
        // front on every reopen and make it resizable (docs/09).
    }
}

/// The health-derived menu-bar glyph. A dedicated `View` so reading `model.menuBarIcon`
/// happens inside a view body, letting Observation re-render it on state changes.
@MainActor
private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        switch model.menuBarIcon {
        case .system(let name):
            Image(systemName: name)
        case .custom(let name):
            Image(name)
        }
    }
}

/// Owns the `AppModel` and bridges NSApplication lifecycle to it. Constructed by the
/// `@NSApplicationDelegateAdaptor`; the model is built here (no streams start until
/// `applicationDidFinishLaunching`).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Returning from System Settings re-activates the app — re-read grants so a
    /// just-granted permission is reflected without a relaunch (docs/07 step 3).
    func applicationDidBecomeActive(_ notification: Notification) {
        model.recheckPermissions()
    }

    /// Safety stop on quit — never leave a synthesized button held (docs/05).
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}
