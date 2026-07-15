import SwiftUI
import AppCore

/// The menu-bar pull-down (docs/09 §Menu-bar item): a live status line, the master
/// enable toggle, one-tap fixes for any missing permission, and the Visualizer /
/// Settings / Quit controls. Reads the `@Observable` `AppModel`, so it and the
/// menu-bar icon update as health changes.
struct MenuBarContent: View {
    @Bindable var model: AppModel
    var updater = UpdaterController.shared

    var body: some View {
        Text(model.statusSummary)   // disabled (non-interactive) status line

        Divider()

        // State-change action item (macOS HIG): the label names the action the
        // click performs, not the current state — so it never contradicts the
        // status line above it.
        Button(model.isEnabled ? "Disable MagicButtons" : "Enable MagicButtons") {
            model.isEnabled.toggle()
        }

        // One "Fix …" item per missing permission (Accessibility is the only one).
        let missing = model.permissionsSnapshot.missing
        if !missing.isEmpty {
            Divider()
            ForEach(missing, id: \.self) { permission in
                Button("Fix \(permission.title)…") {
                    model.requestPermission(permission)
                }
            }
        }

        // A grant applied mid-run needs a fresh launch to fully take (docs/07 step 3).
        if model.needsRelaunch {
            Divider()
            Button("Quit & Reopen to Finish Setup") { model.relaunch() }
        }

        Divider()

        Button("Open Visualizer") { model.showVisualizer() }
        Button("Settings…") { model.showSettings() }   // imperative window (raises on reopen)
        Button("About MagicButtons") { model.showAbout() }

        // Sparkle: disabled while a check/download/install is already in flight (docs/14).
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)

        Divider()

        Button("Quit MagicButtons") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}
