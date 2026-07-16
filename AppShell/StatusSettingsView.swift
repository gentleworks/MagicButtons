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

            troubleshooting
        }
        .formStyle(.grouped)
    }

    // MARK: Troubleshooting

    /// Opt-in recording (docs/10 §Diagnostics mode), last because it's the escalation for
    /// when the readouts above all look fine and it still misbehaves. The note line follows
    /// the Features pane's idiom: the explainer swaps to an orange note when there's
    /// something to say — recording stopped on its own, or couldn't start at all.
    @ViewBuilder
    private var troubleshooting: some View {
        Section {
            Toggle("Record a troubleshooting log", isOn: $model.isRecordingDiagnostics)
                .toggleStyle(.switch)
            Text(model.diagnosticsNote ?? recordingHelp)
                .font(.footnote)
                .foregroundStyle(model.diagnosticsNote == nil ? Color.secondary : Color.orange)
            HStack {
                // Always shown, disabled until there's something to reveal — a button that
                // appears and disappears is harder to find than one that's simply dimmed.
                Button("Reveal in Finder…") { model.revealDiagnosticsLog() }
                    .disabled(model.diagnosticsLogURL == nil)
                Spacer()
            }
        } header: {
            Text("Troubleshooting")
        } footer: {
            // The privacy claim is the reason this is attachable to a public bug report, so
            // it's stated plainly rather than left for the user to wonder about.
            Text("The log records which zone your finger touches, the gestures recognized, "
                 + "and their timings. It never records text, cursor positions, or key presses.")
        }
    }

    /// Tracks the toggle, so the instruction is always the *next* step rather than telling
    /// someone to turn on what they already turned on (the `dragStyleHelp` idiom).
    ///
    /// Both states name the auto-stop, and *while recording* it becomes a clock time: at
    /// that point the useful question is "have I got time to reproduce this?", which a
    /// deadline answers and a duration makes you compute. It's a fixed instant, so stating
    /// it needs no countdown ticking into the view.
    private var recordingHelp: String {
        if model.isRecordingDiagnostics {
            let stops = model.diagnosticsAutoStopAt.map {
                " Stops on its own at \($0.formatted(date: .omitted, time: .shortened))."
            } ?? ""
            return "Recording — reproduce the problem, then turn this off and attach the log "
                + "to your bug report." + stops
        }
        return "Turn this on, reproduce the problem, then turn it off and attach the log to "
            + "your bug report. Recording stops on its own after "
            + "\(model.diagnosticsAutoStopMinutes) minutes."
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
