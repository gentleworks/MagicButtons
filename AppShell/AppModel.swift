import AppKit
import SwiftUI
import Observation
import UniformTypeIdentifiers
import TouchKit
import AppCore
import GestureEngine
import Visualizer
import MultitouchAdapter
import EventOutput

/// The menu-bar app's runtime object (Phase 7.5): it owns the production `AppCoordinator`
/// wiring — real `MultitouchSource` → recognizer → `FeaturePolicy` → `CGEventEmitter`,
/// with physical-click state from an `EventInterceptor` and hot-plug re-enumeration from
/// a `DeviceMonitor` — plus the `PermissionsMonitor` and the `VisualizerModel`, and it
/// persists the master toggle. It mirrors the collaborators' state into `@Observable`
/// stored properties so the menu bar (icon + items) and the Settings window stay live.
///
/// This is the shipping counterpart of the dev harness's `verify-gesture` chain (docs/11
/// §Phase 7.4): same coordinator, now driven by an app shell instead of a bounded CLI run.
@MainActor
@Observable
final class AppModel {
    /// The single app-wide model. The App scene holds this as `@State` so SwiftUI tracks
    /// its `@Observable` changes — which is what makes the menu-bar icon follow health —
    /// while the `AppDelegate` drives lifecycle on the very same instance. Reaching the
    /// model through the delegate's property instead left it outside SwiftUI's observation
    /// graph, so the menu-bar label never re-rendered on a state change.
    static let shared = AppModel()

    let coordinator: AppCoordinator
    /// The visualizer's read-only feed, driven off the coordinator's frame tee so the
    /// picture and the recognized behavior read the exact same stream (docs/06).
    let visualizer: VisualizerModel

    @ObservationIgnored private let permissions: PermissionsMonitor
    /// The concrete system checker, kept so we can *request* (register + prompt) grants,
    /// not just read them.
    @ObservationIgnored private let systemPermissions = SystemPermissionChecker()
    /// The `SMAppService` login-item glue (docs/09 §Login item). Registration lives in
    /// the app target for the same reason as `systemPermissions`.
    @ObservationIgnored private let loginItem = LoginItemController()
    @ObservationIgnored private let deviceMonitor: DeviceMonitor
    @ObservationIgnored private let store: SettingsStore
    /// The event tap, retained so recording can claim its physical-click tee. The
    /// coordinator consumes `onPhysicalClickChange` (it feeds the recognizer);
    /// `onPhysicalButtonEvent` is separate and fires *after* the swallow decision, so the
    /// log can record whether de-confliction consumed each click (docs/14).
    @ObservationIgnored private let interceptor: EventInterceptor
    /// The emitter the pipeline posts through, retained so recording can claim its tee.
    @ObservationIgnored private let emitter: TeeingEmitter
    /// Recording lifecycle — file location, caps, pruning. **Session-only, by design:**
    /// this deliberately isn't in `AppSettings`, which persists to `UserDefaults` and is
    /// what Export/Import ships to another Mac. Recording therefore always starts off, and
    /// can neither be left on silently across relaunches nor follow the user to a second
    /// machine (docs/10 §Diagnostics mode).
    @ObservationIgnored private let diagnostics = DiagnosticsSession()
    /// Reads the Magic Mouse secondary-click side from the system so our left/right tap
    /// zones follow the user's mouse handedness. Consulted at start and on the poll.
    @ObservationIgnored private let secondaryClickReader = SecondaryClickReader()
    /// Re-reads permissions on a cadence while running: a menu-bar (`LSUIElement`) app
    /// doesn't reliably get `applicationDidBecomeActive`, so focus alone can't refresh the
    /// status after the user toggles a grant in System Settings.
    @ObservationIgnored private var pollTimer: Timer?
    /// Retained so the on-demand visualizer window survives close (`isReleasedWhenClosed
    /// = false`) and reopen just re-shows it.
    @ObservationIgnored private var visualizerWindow: NSWindow?
    /// Same pattern for Settings: managed imperatively (not a SwiftUI `Settings`
    /// scene) so an accessory app can raise it to the front on every reopen — the
    /// scene-based window can't be re-fronted once behind another app — and so it's
    /// resizable.
    @ObservationIgnored private var settingsWindow: NSWindow?
    /// Same retained-window pattern for the About card (docs/09): a small fixed-size
    /// panel an accessory app can re-front on every reopen.
    @ObservationIgnored private var aboutWindow: NSWindow?
    /// Monotonic timestamp of the last frame seen, used to derive `isReceivingTouches`
    /// on the status poll without churning observation on every 60–120 Hz frame.
    @ObservationIgnored private var lastFrameAt: TimeInterval = 0

    // MARK: Observable status mirror (drives the menu bar + Settings)

    /// Observable mirror of the live, persisted configuration (docs/09 §Persistence).
    /// The coordinator holds the authoritative copy; every edit flows through
    /// `update(_:)` (or `isEnabled`), which pushes to the coordinator, keeps the
    /// visualizer layout live, and persists. Stored — not computed off the plain
    /// (non-`@Observable`) coordinator — so the Features/Advanced panes actually
    /// re-render on an edit.
    private(set) var settings: AppSettings

    /// Master feature enable, bound to the menu-bar toggle and the Features pane.
    /// Routed through `coordinator.setEnabled` for its safety release of any held
    /// button (docs/05) — the general `apply` path deliberately doesn't release.
    var isEnabled: Bool {
        get { settings.features.masterEnabled }
        set {
            guard newValue != settings.features.masterEnabled else { return }
            settings.features.masterEnabled = newValue
            coordinator.setEnabled(newValue)
            persist()
        }
    }
    /// The login-item toggle (docs/09 §Login item, Phase 7.7). Reads the *actual*
    /// `SMAppService` status via the mirror, and on change registers/unregisters the
    /// main app while persisting the preference. Registration problems (e.g. the user
    /// switched it off in System Settings) surface in `launchAtLoginNote` instead of the
    /// checkbox silently flipping back. Kept separate from the pipeline `update(_:)` path
    /// since the login item touches neither the recognizer nor the visualizer.
    var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set {
            guard newValue != launchAtLoginEnabled else { return }
            setLaunchAtLogin(newValue)
        }
    }
    /// The Troubleshooting toggle (docs/10 §Diagnostics mode). Starting can fail (an
    /// unwritable log directory), so this reads the mirror of what actually happened
    /// rather than the requested value — a toggle that springs back is the honest
    /// outcome, with `diagnosticsNote` saying why.
    var isRecordingDiagnostics: Bool {
        get { diagnosticsIsRecording }
        set {
            guard newValue != diagnosticsIsRecording else { return }
            if newValue { startDiagnostics() } else { diagnostics.stop() }
        }
    }
    /// Observable mirror of `DiagnosticsSession.isRecording` (the session is a plain
    /// object). Stored, so the Status pane re-renders when a cap stops recording on its own.
    private var diagnosticsIsRecording = false
    /// The most recent session's log, live or finished — the Reveal target. `nil` until
    /// one has been recorded this launch.
    private(set) var diagnosticsLogURL: URL?
    /// Why recording stopped on its own, or why it couldn't start. `nil` when there's
    /// nothing to say — a user-initiated stop needs no explanation.
    private(set) var diagnosticsNote: String?
    /// The auto-stop cap, in minutes, read from the session rather than written into the
    /// UI copy — so what the Status pane promises can't drift from what's enforced.
    var diagnosticsAutoStopMinutes: Int { Int(diagnostics.limits.maxDuration / 60) }

    private(set) var permissionsSnapshot: PermissionsSnapshot
    /// Set when the user grants Accessibility while the app is already running. We retry
    /// the event tap in place (`coordinator.retryStream`); if that still can't install
    /// it, `needsRelaunch` uses this to offer a Quit & Reopen — the reliable fallback
    /// (docs/07 step 3). Never set for the touch stream: it needs no grant (docs/08).
    private(set) var grantedAccessibilityWhileRunning = false
    /// The private multitouch backend didn't resolve on this macOS build (docs/09).
    let backendUnavailable: Bool
    private(set) var isDeviceConnected = false
    private(set) var sourceError: TouchSourceError?
    private(set) var interceptorFailed = false
    /// Whether touch frames have arrived in the last couple of seconds — the live
    /// "backend is delivering frames" signal for the Status pane (docs/09 §Backend
    /// health). Recomputed on the 1.5 s status poll.
    private(set) var isReceivingTouches = false
    /// A Magic Mouse is connected but no frame has arrived since the stream started —
    /// the "connected but deaf" degraded state the coordinator latches (the framework
    /// enumerates the mouse without Input Monitoring, so no error is thrown; docs/08).
    /// Mirrored from `AppCoordinator.touchesNotArriving` on the status poll.
    private(set) var touchesNotArriving = false
    /// Observable mirror of the login item's real `SMAppService` status, reconciled at
    /// launch and after every toggle so the Advanced checkbox tracks System Settings →
    /// Login Items rather than only our stored preference.
    private(set) var launchAtLoginEnabled = false
    /// A hint shown under the login-item toggle when the system needs the user's
    /// approval, or when registering/unregistering failed — so the checkbox never
    /// silently disagrees with reality (docs/09). `nil` when there's nothing to say.
    private(set) var launchAtLoginNote: String?

    init() {
        let store = SettingsStore(storage: UserDefaultsStorage())
        let settings = store.load()
        self.store = store
        self.settings = settings

        // MultitouchSource.init throws only for a broken backend (unsupported OS); the
        // common "no mouse plugged in" case surfaces at start() and is recorded as
        // status. Fall back to an idle source so the app still launches and degrades.
        let source: any TouchSource
        do {
            source = try MultitouchSource()
            self.backendUnavailable = false
        } catch {
            source = IdleTouchSource()
            self.backendUnavailable = true
        }

        // One `EventInterceptor` serves both event-tap jobs: physical-click state
        // (as the coordinator's `clickSource`) and move→drag promotion during a hold
        // (armed by the emitter). Wire the emitter to it so `press`/`release` toggle
        // the rewrite (docs/05 §Press/release); the emitter holds it weakly.
        let interceptor = EventInterceptor()
        let cgEmitter = CGEventEmitter()
        cgEmitter.dragPromoter = interceptor
        // Wrapped so diagnostics can record what was *emitted* — after the policy filter
        // and the secondary-click swap. Both are retained (they'd otherwise be reachable
        // only from inside the coordinator) because their tees are what recording installs.
        let emitter = TeeingEmitter(cgEmitter)
        self.interceptor = interceptor
        self.emitter = emitter
        self.coordinator = AppCoordinator(
            source: source,
            clickSource: interceptor,
            emitter: emitter,
            settings: settings)
        self.visualizer = VisualizerModel(layout: settings.zones)

        // Stateless struct — a fresh value here is equivalent to `systemPermissions`
        // and sidesteps reading a stored property mid-init.
        let permissions = PermissionsMonitor(checker: SystemPermissionChecker())
        self.permissions = permissions
        self.permissionsSnapshot = permissions.snapshot
        self.deviceMonitor = DeviceMonitor()

        // Tee frames into the visualizer feed (already marshaled to main by the
        // coordinator) and stamp the last-frame time for the backend-health readout;
        // update the snapshot on any permission transition; re-enumerate mice on HID
        // attach/detach (delivered on the main run loop).
        coordinator.onFrame = { [weak self] frame in
            guard let self else { return }
            self.visualizer.update(frame)
            self.lastFrameAt = ProcessInfo.processInfo.systemUptime
            // Contact stream, when recording. Not recording ⇒ `log` is nil and this is one
            // check per frame — the other two streams aren't even installed.
            self.diagnostics.log?.contacts(frame)
        }
        // Flash recognized gestures in the visualizer (feedback while tuning tap /
        // double-tap thresholds, docs/09). Map the recognizer's `ButtonGesture` to the
        // visualizer's TouchKit-only vocabulary so that package stays decoupled.
        coordinator.onGesture = { [weak self] gesture in
            guard let self else { return }
            let recognized: VisualizerModel.RecognizedGesture
            switch gesture {
            case let .click(zone, count): recognized = .click(zone, count: count)
            case let .holdBegan(zone):    recognized = .holdBegan(zone)
            case let .holdEnded(zone):    recognized = .holdEnded(zone)
            }
            self.visualizer.register(recognized)
            // Gesture stream, when recording. Pre-policy on purpose — paired with the
            // emitter's `synth` rows, a gesture with no emission is one the policy dropped,
            // which is the "I tapped and nothing happened" report.
            self.diagnostics.log?.gesture(gesture)
        }
        // Every ending lands here — a user stop as much as a cap firing — so the tees are
        // torn down in exactly one place and can't be left installed by a path we forgot.
        diagnostics.onStop = { [weak self] reason in
            guard let self else { return }
            self.emitter.onEvent = nil
            self.interceptor.onPhysicalButtonEvent = nil
            self.diagnosticsIsRecording = false
            self.diagnosticsLogURL = self.diagnostics.lastFileURL
            self.diagnosticsNote = self.explanation(for: reason)
        }
        permissions.onChange = { [weak self] snapshot in self?.permissionsSnapshot = snapshot }
        deviceMonitor.onChange = { [weak self] in
            MainActor.assumeIsolated {
                self?.coordinator.refreshDevices()
                self?.mirrorStatus()
            }
        }
    }

    // MARK: Lifecycle

    /// Start the input streams and device watch. Called once the app finishes launching.
    func start() {
        coordinator.start()
        coordinator.setSecondaryClickSide(secondaryClickReader.currentSide())
        deviceMonitor.start()
        reconcileLoginItem()
        mirrorStatus()
        startPolling()
    }

    /// Stop everything, releasing any held button first (docs/05 §Press/release) — the
    /// safety stop on quit.
    func stop() {
        stopPolling()
        // Close the log on a clean quit so its tail is on disk. An *unclean* exit is
        // covered too — rows are written as they happen, not batched.
        diagnostics.stop()
        deviceMonitor.stop()
        coordinator.stop()
        mirrorStatus()
    }

    /// Re-read live external state — permissions **and** the login-item status — so a
    /// change made in System Settings (a granted permission, or the user removing the app
    /// under General → Login Items) is reflected without a relaunch. Wired to both the
    /// 1.5 s poll and app-focus (docs/07 step 3); the poll is the reliable path for an
    /// `LSUIElement` app that doesn't get `applicationDidBecomeActive` dependably.
    func recheckPermissions() {
        let hadAccessibility = permissionsSnapshot.canPostClicks
        permissions.recheck()
        refreshLoginItemMirror()
        // A mid-run Accessibility grant: re-arm the event tap in place so clicks start
        // posting without a relaunch. Remember the transition so `needsRelaunch` can
        // fall back to a Quit & Reopen prompt if the tap still won't install.
        if !hadAccessibility && permissionsSnapshot.canPostClicks {
            grantedAccessibilityWhileRunning = true
            coordinator.retryStream(for: .accessibility)
        }
        // A mid-run Accessibility *revocation*: pull the event tap out of the HID path at
        // once. An active `.cghidEventTap` left installed after the process loses trust
        // wedges every physical click system-wide (docs/05 §Interceptor lifetime).
        else if hadAccessibility && !permissionsSnapshot.canPostClicks {
            coordinator.suspendClickInterception()
        }
        // Self-heal a launch-time enumeration race (docs/08): a Bluetooth Magic Mouse
        // that wasn't ready when the source first started never fires the hot-plug
        // attach we watch, so it'd otherwise stay "not detected" until a relaunch.
        // Re-enumerate whenever we're running without a connected device.
        if !isDeviceConnected {
            coordinator.refreshDevices()
        }
        // Follow a mid-session change to the mouse's secondary-click side (System
        // Settings → Mouse). Idempotent, so this steady-state re-read is cheap.
        coordinator.setSecondaryClickSide(secondaryClickReader.currentSide())
        mirrorStatus()
    }

    private func startPolling() {
        pollTimer?.invalidate()
        // Fires on the main run loop; assumeIsolated is valid there.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPermissions() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func mirrorStatus() {
        isDeviceConnected = coordinator.isDeviceConnected
        sourceError = coordinator.sourceError
        interceptorFailed = coordinator.interceptorFailed
        isReceivingTouches = ProcessInfo.processInfo.systemUptime - lastFrameAt < 2.0
        touchesNotArriving = coordinator.touchesNotArriving
    }

    private func persist() {
        store.save(settings)
    }

    // MARK: Login item (docs/09 §Login item)

    /// Reconcile the login item with the persisted preference at launch: honor an
    /// imported/persisted `launchAtLogin` that was never registered on *this* Mac (so
    /// Export/Import actually transfers the behavior), then refresh the observable mirror
    /// from the real `SMAppService` status.
    private func reconcileLoginItem() {
        if settings.launchAtLogin && loginItem.status == .notRegistered {
            try? loginItem.enable()
        }
        refreshLoginItemMirror()
    }

    /// Sync the observable mirror + note to the live `SMAppService` status, and keep the
    /// persisted preference honest if it drifted (e.g. the user removed the app in System
    /// Settings → Login Items). Read-only — it never registers/unregisters, so the poll
    /// can't fight a user's external change; only `reconcileLoginItem()` (launch, and only
    /// for a never-registered app) ever re-registers.
    private func refreshLoginItemMirror() {
        let enabled = loginItem.isEnabled
        launchAtLoginEnabled = enabled
        launchAtLoginNote = loginItem.status == .requiresApproval
            ? "Turn MagicButtons on in System Settings → General → Login Items."
            : nil
        // Track external changes without churning the store when nothing moved.
        if settings.launchAtLogin != enabled {
            settings.launchAtLogin = enabled
            persist()
        }
    }

    /// Apply a login-item toggle: register/unregister the main app, persist the intent,
    /// and reconcile the mirror with reality. A failure is reported rather than swallowed.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try loginItem.enable() } else { try loginItem.disable() }
            launchAtLoginNote = nil
        } catch {
            launchAtLoginNote = "Couldn’t \(enabled ? "enable" : "disable") Open at Login: "
                + error.localizedDescription
        }
        // Persist intent even if the OS deferred it (e.g. requires approval); the mirror
        // then reflects the true post-call status.
        settings.launchAtLogin = enabled
        persist()
        refreshLoginItemMirror()
    }

    // MARK: Configuration edits (Features + Advanced)

    /// Apply an in-place edit to the live settings: updates the observable mirror
    /// (so the UI re-renders), pushes it to the coordinator (which rebuilds the
    /// recognizer only when zones/tunables changed), keeps the visualizer's zone
    /// overlay live, and persists. A no-op edit does nothing. Master enable goes
    /// through `isEnabled` instead, for its safety release.
    func update(_ mutate: (inout AppSettings) -> Void) {
        var edited = settings
        mutate(&edited)
        guard edited != settings else { return }
        sync(edited)
        persist()
    }

    /// A two-way binding to any field of the live settings, routed through `update`
    /// so edits from the Features/Advanced panes apply + persist immediately. Master
    /// enable is the exception (bind `$model.isEnabled` for its safety release).
    func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } })
    }

    /// Push a whole settings value through the live pipeline + visualizer (shared by
    /// `update`, Import, and Reset). Does not persist — callers decide (Import/Reset
    /// persist through the store; `update` persists explicitly).
    private func sync(_ new: AppSettings) {
        settings = new
        coordinator.apply(new)
        visualizer.layout = new.zones
    }

    // MARK: Diagnostics recording (docs/10 §Diagnostics mode)

    /// Open a log and point the three streams at it. Nothing is installed until here — the
    /// toggle being off costs a nil closure and nothing more.
    private func startDiagnostics() {
        guard let log = diagnostics.start(layout: settings.zones) else {
            diagnosticsNote = "Couldn’t create a log in "
                + DiagnosticsSession.defaultDirectory.path + "."
            return
        }
        // Captured weakly on purpose: the session owns the log and clears it on stop, so a
        // tee can never outlive its session even if teardown were somehow missed. Frames
        // come through the coordinator's existing tee (see `init`).
        emitter.onEvent = { [weak log] event in log?.synth(event) }
        interceptor.onPhysicalButtonEvent = { [weak log] type, button, swallowed in
            log?.physical(type: type, buttonNumber: button, wasSwallowed: swallowed)
        }
        diagnosticsIsRecording = true
        diagnosticsLogURL = log.fileURL
        diagnosticsNote = nil
    }

    /// Show the log in the Finder, ready to drag onto a bug report. A save panel would be
    /// the established idiom here (see `exportSettings`), but recording writes as it goes
    /// to a fixed location instead: the toggle has to start recording *now*, and a log on
    /// disk survives the force-quit that ends the very stuck-button session worth reading.
    func revealDiagnosticsLog() {
        guard let url = diagnosticsLogURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Plain-language reason a session ended on its own. A user-initiated stop says
    /// nothing — they know why it stopped.
    private func explanation(for reason: DiagnosticsStopReason) -> String? {
        switch reason {
        case .user:
            return nil
        case .timeLimit:
            let minutes = Int(diagnostics.limits.maxDuration / 60)
            return "Recording stopped automatically after \(minutes) minutes."
        case .sizeLimit:
            let mb = diagnostics.limits.maxBytes / 1_000_000
            return "Recording stopped automatically — the log reached \(mb) MB."
        }
    }

    // MARK: Settings transfer (docs/09 §Persistence & sync)

    /// Export the current settings to a user-chosen JSON file (account-free transfer
    /// between Macs). Uses the store's stable, pretty-printed encoding.
    func exportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export MagicButtons Settings"
        panel.nameFieldStringValue = "MagicButtons-Settings.json"
        panel.allowedContentTypes = [.json]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportJSON(settings).write(to: url)
        } catch {
            presentError("Couldn’t export settings", error)
        }
    }

    /// Import settings from a user-chosen JSON file and apply them live. A partial
    /// file decodes leniently (missing keys default); a file that isn't settings JSON
    /// surfaces an error rather than silently resetting (docs/09).
    func importSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import MagicButtons Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try store.importJSON(Data(contentsOf: url))  // also persists
            sync(imported)
        } catch {
            presentError("Couldn’t import settings", error)
        }
    }

    /// Restore and persist default settings (Advanced → Reset), applied live.
    func resetToDefaults() {
        sync(store.reset())
    }

    private func presentError(_ message: String, _ error: any Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Actions

    /// Open (or re-show) the live visualizer window. Managed imperatively with AppKit
    /// rather than a SwiftUI `Window` scene so an accessory (`LSUIElement`) app doesn't
    /// auto-open it at launch and so it works on the macOS 14 deployment floor.
    func showVisualizer() {
        if let window = visualizerWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MagicButtons — Visualizer"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VisualizerView(model: visualizer))
        window.center()
        visualizerWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open (or re-show + raise) the Settings window. Managed imperatively for the
    /// same reasons as the visualizer (docs/09): a menu-bar app must be able to bring
    /// it forward every time it's chosen from the menu, which the SwiftUI `Settings`
    /// scene doesn't allow once the window is behind another app. Reused across close.
    func showSettings() {
        if let window = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MagicButtons Settings"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(model: self))
        window.contentMinSize = NSSize(width: 460, height: 480)
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Open (or re-show + raise) the About card. Managed imperatively like the
    /// Settings/Visualizer windows so a menu-bar (`LSUIElement`) app can bring it
    /// forward on every reopen. Fixed-size (non-resizable) — it's a small info panel.
    func showAbout() {
        if let window = aboutWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "About MagicButtons"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.center()
        aboutWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The menu-bar "Fix …" action: **request** the permission — which shows the system
    /// prompt and, crucially, registers the app in the System Settings list so it can be
    /// toggled — then open the exact pane so the user can flip it on. An immediate recheck
    /// keeps the icon/menu honest even before the poll tick.
    func requestPermission(_ permission: Permission) {
        systemPermissions.request(permission)
        NSWorkspace.shared.open(permission.settingsURL)
        recheckPermissions()
    }

    /// Deep-link to the exact System Settings pane for a missing permission (docs/07),
    /// without prompting — used where the app is already registered.
    func openSystemSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// Quit and relaunch so an Accessibility grant made mid-session takes under a fresh
    /// process — the reliable fallback when the in-place tap retry couldn't install
    /// (see `needsRelaunch`). Opens a new instance of our own bundle, then terminates
    /// this one once the launch is under way.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    // MARK: Derived health (menu-bar icon + status line)

    enum Health {
        case operational   // both permissions granted, backend fine, enabled
        case disabled      // healthy but the master toggle is off
        case degraded      // missing a permission or the backend is unavailable
    }

    /// A menu-bar glyph source: either a system SF Symbol or a custom asset-catalog symbol,
    /// each loaded by name.
    enum MenuBarIcon: Equatable {
        case system(String)
        case custom(String)
    }

    /// Accessibility was granted while running but the in-place tap retry still hasn't
    /// installed the event tap — clicks won't post until a fresh launch. Cleared by
    /// relaunching (fresh process re-arms at launch) or the moment the tap installs.
    /// Gated on the mid-run-grant flag so a normal healthy launch never nags.
    var needsRelaunch: Bool {
        grantedAccessibilityWhileRunning && interceptorFailed
    }

    var health: Health {
        if backendUnavailable || !permissionsSnapshot.isFullyOperational { return .degraded }
        // A granted permission whose stream is still down is not "operational".
        if interceptorFailed || needsRelaunch { return .degraded }
        return isEnabled ? .operational : .disabled
    }

    /// Menu-bar glyph, reflecting health at a glance (docs/09). Mirrors the old fill/outline
    /// pairing with the app's own line-art mouse: a solid "magicbuttons.mouse.fill" when active,
    /// the hollow "magicbuttons.mouse" when switched off (fill vs. outline survives the menu
    /// bar's template rendering where opacity does not), and a system warning triangle for the
    /// degraded state.
    var menuBarIcon: MenuBarIcon {
        switch health {
        case .operational: return .custom("magicbuttons.mouse.fill")
        case .disabled:    return .custom("magicbuttons.mouse")
        case .degraded:    return .system("exclamationmark.triangle.fill")
        }
    }

    /// One-line status shown at the top of the menu.
    var statusSummary: String {
        if backendUnavailable { return "Unsupported macOS build — multitouch unavailable" }
        let missing = permissionsSnapshot.missing
        if !missing.isEmpty {
            return "Missing: \(missing.map(\.title).joined(separator: ", "))"
        }
        if needsRelaunch { return "Quit & Reopen to finish setup" }
        if interceptorFailed { return "Accessibility granted, but clicks aren’t posting" }
        if !isDeviceConnected { return "No Magic Mouse detected" }
        return isEnabled ? "Active" : "Disabled"
    }

    // MARK: Status-pane readouts (docs/09 §Status & Diagnostics)

    /// One-line device summary. v1 reports connected/active + touch flow; per-device
    /// names + v1/v2 generation are Phase 9 (multi-mouse polish, docs/11).
    var deviceStatus: String {
        if backendUnavailable { return "Unavailable on this macOS build" }
        if isDeviceConnected {
            return isReceivingTouches ? "Magic Mouse — connected, receiving touches"
                                      : "Magic Mouse — connected"
        }
        return "No Magic Mouse detected"
    }

    /// Plain-language capability line for the first-run / Features header, so a user
    /// who has granted only some permissions understands what works and what doesn't
    /// rather than seeing silent failure (docs/07 step 4 — graceful degradation).
    var capabilitySummary: String {
        permissionsSnapshot.canPostClicks
            ? "All features available."
            : "The visualizer works; grant Accessibility so clicks can post."
    }

    /// The most relevant recent problem for the Status pane's Errors row, in plain
    /// language with a suggested action, or `nil` when nothing's wrong (docs/09).
    var recentIssue: String? {
        if backendUnavailable {
            return "The multitouch backend didn’t load on this macOS build. An update to MagicButtons may be required."
        }
        // Accessibility granted mid-run but the tap still won't install → a fresh
        // launch applies it (docs/07 step 3). Supersedes the generic tap message below.
        if needsRelaunch {
            return "Accessibility was granted while MagicButtons was running — Quit & Reopen to finish enabling clicks."
        }
        if interceptorFailed {
            return "Couldn’t install the event tap — grant Accessibility so clicks can post."
        }
        // Connected yet no touches arrive: the silent-failure "deaf" case that would
        // otherwise show no error at all (docs/08).
        if touchesNotArriving {
            return "The Magic Mouse is connected but no touches are arriving. Try relaunching MagicButtons."
        }
        switch sourceError {
        case .noDevice:      return "No Magic Mouse was found. Connect one and it’ll be picked up automatically."
        case .backendUnavailable: return "The multitouch backend is unavailable on this macOS build."
        case .notAuthorized: return "The multitouch stream reported it isn’t authorized. Try relaunching MagicButtons."
        case nil:            return nil
        }
    }
}
