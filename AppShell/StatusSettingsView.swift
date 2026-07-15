import SwiftUI
import AppCore

/// The **Status & Diagnostics** region (docs/09 §Status): a live, plain-language
/// read of devices, permissions (each with a one-click fix), backend health, and the
/// most recent problem — so a user who granted nothing can still open Settings and
/// see exactly what's wrong and how to fix it. Re-checks happen in `AppModel` on the
/// status poll and on device attach/detach; this view just renders the mirror.
struct StatusSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            if model.needsRelaunch {
                Section {
                    Button("Quit & Reopen MagicButtons") { model.relaunch() }
                } header: {
                    Text("Finish setup")
                } footer: {
                    Text("Accessibility was granted while MagicButtons was running. Relaunch so clicks start posting.")
                }
            }

            Section("Device") {
                Label(model.deviceStatus, systemImage: deviceSymbol)
                    .foregroundStyle(model.isDeviceConnected ? .primary : .secondary)
            }

            Section("Permissions") {
                ForEach(Permission.allCases, id: \.self) { permission in
                    permissionRow(permission)
                }
            }

            Section("Backend") {
                Label(backendText, systemImage: backendSymbol)
                    .foregroundStyle(backendOK ? Color.primary : Color.orange)
            }

            if let issue = model.recentIssue {
                Section("Recent issue") {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Permission row

    @ViewBuilder
    private func permissionRow(_ permission: Permission) -> some View {
        let granted = model.permissionsSnapshot.isGranted(permission)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? Color.green : Color.red)
                Text(permission.title)
                Spacer()
                if granted {
                    Button("Open Settings…") { model.openSystemSettings(for: permission) }
                        .buttonStyle(.link)
                } else {
                    Button("Grant…") { model.requestPermission(permission) }
                }
            }
            Text(granted ? permission.rationale : permission.fixInstruction)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Derived presentation

    private var deviceSymbol: String {
        model.isDeviceConnected ? "computermouse.fill" : "computermouse"
    }

    private var backendOK: Bool {
        !model.backendUnavailable && !model.touchesNotArriving
    }

    private var backendText: String {
        if model.backendUnavailable {
            return "Multitouch backend unavailable — unsupported macOS build."
        }
        if !model.isDeviceConnected {
            return "No Magic Mouse connected."
        }
        return model.isReceivingTouches
            ? "Multitouch stream healthy — frames flowing."
            : "Backend ready — no frames yet (touch the mouse to confirm)."
    }

    private var backendSymbol: String {
        backendOK ? "waveform.path.ecg" : "exclamationmark.triangle.fill"
    }
}
