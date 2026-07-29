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
            // it's stated plainly rather than left for the user to wonder about. One literal,
            // not a `+` join: a concatenation picks Text's verbatim overload and never
            // reaches the String Catalog at all.
            Text("The log records which zone your finger touches, the gestures recognized, and their timings. It never records text, cursor positions, or key presses.",
                 comment: "Troubleshooting section footer stating what the log does and doesn't capture.")
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
        guard model.isRecordingDiagnostics else {
            return String(localized: "Turn this on, reproduce the problem, then turn it off and attach the log to your bug report. Recording stops on its own after \(model.diagnosticsAutoStopMinutes) minutes.",
                          comment: "Troubleshooting help while not recording; %lld is a number of minutes.")
        }
        // Each state is one whole sentence pair rather than a stem plus an appended
        // fragment — a trailing clause can't be placed correctly in every language.
        guard let stopsAt = model.diagnosticsAutoStopAt else {
            return String(localized: "Recording — reproduce the problem, then turn this off and attach the log to your bug report.",
                          comment: "Troubleshooting help while recording, with no auto-stop time known.")
        }
        let time = stopsAt.formatted(date: .omitted, time: .shortened)
        return String(localized: "Recording — reproduce the problem, then turn this off and attach the log to your bug report. Stops on its own at \(time).",
                      comment: "Troubleshooting help while recording; %@ is a locale-formatted clock time.")
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
            return String(localized: "Multitouch backend unavailable — unsupported macOS build.",
                          comment: "Status pane, Backend row: the private backend didn't load.")
        }
        if !model.isDeviceConnected {
            return String(localized: "No Magic Mouse connected.",
                          comment: "Status pane, Backend row. 'Magic Mouse' is a product name — do not translate.")
        }
        return model.isReceivingTouches
            ? String(localized: "Multitouch stream healthy — frames flowing.",
                     comment: "Status pane, Backend row: touch frames are arriving.")
            : String(localized: "Backend ready — no frames yet (touch the mouse to confirm).",
                     comment: "Status pane, Backend row: connected but no frames seen yet.")
    }

    private var backendSymbol: String {
        backendOK ? "waveform.path.ecg" : "exclamationmark.triangle.fill"
    }
}
