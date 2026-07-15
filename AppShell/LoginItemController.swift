import ServiceManagement

/// App-side wrapper over `SMAppService.mainApp` (docs/09 §Login item, Phase 7.7) — the
/// actual login-item registration lives in the app target rather than `AppCore`, exactly
/// like `SystemPermissionChecker`: `AppCore` keeps the pure, unit-tested preference
/// (`AppSettings.launchAtLogin`) while this thin glue makes the system call on the
/// machine. Registering makes MagicButtons launch at login so this background input
/// utility is present after a restart (expected for the category).
///
/// `SMAppService.mainApp` needs no helper bundle or extra entitlement — it registers the
/// app itself. Available since macOS 13, below the macOS 14 deployment floor, so no
/// availability guard is required.
struct LoginItemController {
    /// The raw service status, so the model can distinguish "the user switched it off in
    /// System Settings → Login Items" (`.requiresApproval`) from "never registered".
    var status: SMAppService.Status { SMAppService.mainApp.status }

    /// Whether the login item is currently registered *and* enabled by the user.
    var isEnabled: Bool { status == .enabled }

    /// Register (enable) the login item. Throws if the system rejects it.
    func enable() throws { try SMAppService.mainApp.register() }

    /// Unregister (disable) the login item. Throws if the system rejects it.
    func disable() throws { try SMAppService.mainApp.unregister() }
}
