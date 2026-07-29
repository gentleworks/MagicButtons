import SwiftUI
import AppCore

/// The **Features** region of Settings (docs/09 §Features): a top app-lifecycle
/// cluster — the master enable and the `SMAppService` "Open at Login" toggle (Phase
/// 7.7), the two app-level on/persist concepts — followed by the three independent
/// button-capability toggles. Each is bound through `AppModel` so a change applies to
/// the live pipeline (or registers the login item) and persists immediately.
/// Double-click and drag (tap-and-a-half) inherit their zone's tap feature and are
/// deliberately not separate toggles (docs/03).
struct FeaturesSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            // App-lifecycle cluster: whether MagicButtons is on, and whether it stays on
            // across a reboot. Both are separate from *which* buttons do what (below).
            Section {
                Toggle("Enable MagicButtons", isOn: $model.isEnabled)
                    .toggleStyle(.switch)
                Text(model.capabilitySummary)
                    .font(.footnote)
                    .foregroundStyle(model.permissionsSnapshot.isFullyOperational ? Color.secondary : Color.orange)

                Toggle("Open at Login", isOn: $model.launchAtLogin)
                    .toggleStyle(.switch)
                // Shows the default explainer, and swaps to the orange approval/error note
                // when the login item needs attention — mirroring the capability line above.
                // The default must go through `String(localized:)`: `??` yields a String,
                // which binds Text's verbatim overload and would never be extracted.
                Text(model.launchAtLoginNote
                     ?? String(localized: "Keep MagicButtons running so it’s ready right after you restart.",
                               comment: "Explainer under the Open at Login toggle."))
                    .font(.footnote)
                    .foregroundStyle(model.launchAtLoginNote == nil ? Color.secondary : Color.orange)
            }

            Section("Buttons") {
                Toggle(isOn: model.binding(\.features.tapToClick)) {
                    Text("Tap to click")
                    Text("Tap the left or right zone to click that button.")
                }
                Toggle(isOn: model.binding(\.features.middleTapToClick)) {
                    Text("Middle tap to click")
                    Text("Tap the middle zone to emit a middle click.")
                }
                Toggle(isOn: model.binding(\.features.middleClick)) {
                    Text("Middle physical click")
                    Text("Physically click while your finger is in the middle zone to emit a middle click.")
                }
            }
            .disabled(!model.isEnabled)
        }
        .formStyle(.grouped)
    }
}
