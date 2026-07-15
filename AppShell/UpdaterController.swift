import SwiftUI
import Combine
import Sparkle

/// Owns the Sparkle updater for the menu-bar app (docs/07 §Distribution, docs/14 §Sparkle).
///
/// `SPUStandardUpdaterController` wires up the standard update UI, background scheduling,
/// and appcast handling; all policy is driven by the Info.plist keys (`SUFeedURL`,
/// `SUPublicEDKey`) rather than code. We keep a single shared instance for the app's
/// lifetime — Sparkle's scheduled checks and in-flight downloads must outlive any one view.
///
/// `@Observable` so the "Check for Updates…" menu/About controls can bind their disabled
/// state to `canCheckForUpdates` (false while a check or install is already running).
/// Sparkle exposes that as a KVO property on `SPUUpdater`, which Observation doesn't track
/// directly, so we bridge it through Combine into the tracked `canCheckForUpdates`.
@MainActor
@Observable
final class UpdaterController {
    static let shared = UpdaterController()

    /// True when a new update check may be started (no check/download/install in flight).
    /// Drives the enabled state of the menu + About "Check for Updates…" controls.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var cancellable: AnyCancellable?

    private init() {
        // startingUpdater: true begins scheduled background checks per the Info.plist
        // (and, on second launch, shows Sparkle's automatic-check consent prompt).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil)

        cancellable = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }

    /// Begin a user-initiated update check — the "Check for Updates…" action. Always shows
    /// UI (progress, "you're up to date", or the update prompt), unlike the silent
    /// scheduled checks.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
