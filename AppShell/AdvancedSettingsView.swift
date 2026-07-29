import SwiftUI
import AppCore
import GestureEngine
import Visualizer

/// The **Advanced** region (docs/09 §Advanced): zone-boundary sliders over a live
/// mini-visualizer, the recognizer tunables from `GestureConfig`, reset-to-defaults,
/// and the cross-machine Export / Import. Every edit is bound through `AppModel`, so
/// it applies to the live recognizer (rebuilt for zone/timing changes) and persists.
/// Values are guesses until Phase 9 calibration; this pane exists because they'll
/// need per-user tuning.
struct AdvancedSettingsView: View {
    @Bindable var model: AppModel

    /// Keep a gap between the edges so the middle zone can't collapse or invert.
    private let edgeGap: CGFloat = 0.05

    var body: some View {
        Form {
            Section("Zones") {
                VisualizerView(model: model.visualizer)
                    .frame(height: 300)
                    .frame(maxWidth: .infinity)

                slider("Left edge", model.binding(\.zones.leftEdge),
                       in: 0.05...(model.settings.zones.rightEdge - edgeGap),
                       format: percent)
                slider("Right edge", model.binding(\.zones.rightEdge),
                       in: (model.settings.zones.leftEdge + edgeGap)...0.95,
                       format: percent)
            }

            Section("Timings & thresholds") {
                slider("Max tap duration", model.binding(\.gestures.maxDuration),
                       in: 0.05...0.5, format: seconds)
                slider("Max tap travel", model.binding(\.gestures.maxTravel),
                       in: 0.0...0.2, format: percent)
                slider("Max contact size", model.binding(\.gestures.maxSize),
                       in: 2...30, format: number)
                slider("Double-tap gap", model.binding(\.gestures.doubleTapGap),
                       in: 0.1...0.6, format: seconds)
                slider("Hold threshold", model.binding(\.gestures.holdThreshold),
                       in: 0.05...0.5, format: seconds)
                Toggle("Ignore taps during a physical click",
                       isOn: model.binding(\.gestures.requireNoPhysicalClick))
            }

            Section("Drag") {
                Picker("Drag style", selection: model.binding(\.gestures.dragStyle)) {
                    Text("Tap-and-a-half").tag(DragStyle.tapAndAHalf)
                    Text("Press and hold").tag(DragStyle.pressAndHold)
                }
                Text(dragStyleHelp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Settings file") {
                HStack {
                    Button("Export…") { model.exportSettings() }
                    Button("Import…") { model.importSettings() }
                    Spacer()
                    Button("Reset to Defaults", role: .destructive) { model.resetToDefaults() }
                }
                Text("Export a JSON file to copy your settings to another Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// One-line explainer that tracks the current pick, so the tradeoff is visible
    /// right where you choose (docs/03 §The v1 gesture set).
    private var dragStyleHelp: String {
        switch model.settings.gestures.dragStyle {
        case .tapAndAHalf:
            return String(localized: "Tap, then press and hold a second time and move the mouse to drag. Deliberate and familiar from the trackpad; a drag on text starts by selecting the word under the pointer. Fingers can rest on the shell.",
                          comment: "Explainer under the Drag style picker for the tap-and-a-half option.")
        case .pressAndHold:
            return String(localized: "Hold one finger still, then move the mouse to drag — no first tap, so text and small handles stay precise. Grip the mouse from the sides and keep the top surface clear except when tapping or dragging: a finger left resting on the shell starts a drag, and clicking the mouse won’t register until it lifts.",
                          comment: "Explainer under the Drag style picker for the press-and-hold option.")
        }
    }

    // MARK: Labeled slider

    private func slider<V: BinaryFloatingPoint>(
        _ title: LocalizedStringKey,
        _ value: Binding<V>,
        in range: ClosedRange<V>,
        format: @escaping (V) -> String
    ) -> some View where V.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            // Guard against an inverted range while the paired edge is mid-drag.
            Slider(value: value, in: range.lowerBound <= range.upperBound
                   ? range : range.upperBound...range.upperBound)
        }
    }

    // MARK: Value formatting

    // Locale-aware throughout: `String(format:)` and a hardcoded "%" would print an
    // English decimal point and symbol placement everywhere. `.asProvided` keeps
    // milliseconds from being auto-promoted to seconds.
    private func percent<V: BinaryFloatingPoint>(_ v: V) -> String {
        Double(v).formatted(.percent.precision(.fractionLength(0)))
    }
    private func seconds<V: BinaryFloatingPoint>(_ v: V) -> String {
        Measurement(value: (Double(v) * 1000).rounded(), unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }
    private func number<V: BinaryFloatingPoint>(_ v: V) -> String {
        Double(v).formatted(.number.precision(.fractionLength(1)))
    }
}
