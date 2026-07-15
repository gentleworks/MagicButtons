import SwiftUI
import AppCore

/// The Settings window (docs/09): three tabbed regions — Features, Status &
/// Diagnostics, Advanced — all bound to `AppModel`. This is also where the first-run
/// flow lives (docs/07): when a grant is missing the window opens straight to Status,
/// which explains each permission and offers a one-click fix, and the Features header
/// spells out graceful degradation. Replaces the Phase 7.5 placeholder.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: Tab

    enum Tab: Hashable { case features, status, advanced }

    init(model: AppModel) {
        self.model = model
        // First-run: land on Status when something needs granting; otherwise Features.
        _selection = State(initialValue: model.permissionsSnapshot.isFullyOperational
                           ? .features : .status)
    }

    var body: some View {
        TabView(selection: $selection) {
            FeaturesSettingsView(model: model)
                .tabItem { Label("Features", systemImage: "cursorarrow.click") }
                .tag(Tab.features)

            StatusSettingsView(model: model)
                .tabItem { Label("Status", systemImage: "waveform.path.ecg") }
                .tag(Tab.status)

            AdvancedSettingsView(model: model)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(Tab.advanced)
        }
        // Fills its host window (managed by `AppModel.showSettings()`), which is
        // resizable and free to grow taller so the Advanced tab's sliders and
        // mini-visualizer can be seen together.
        .frame(minWidth: 460, maxWidth: 640, minHeight: 480, maxHeight: .infinity)
    }
}
