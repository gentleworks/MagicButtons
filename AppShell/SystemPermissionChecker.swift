import AppCore
import ApplicationServices

/// The real TCC checks (docs/07), living in the app target rather than `AppCore`: the
/// `PermissionChecking` seam keeps the pure `PermissionsSnapshot`/`PermissionsMonitor`
/// model unit-tested while these system calls are exercised on the machine. A
/// conformer can only live in a target that depends on `AppCore`, so the two
/// app-layer consumers (this GUI app and the `App` dev harness) each carry this tiny
/// glue rather than sharing it through the untestable-by-design layer.
///
/// Accessibility only — Input Monitoring was dropped in Phase 9 (docs/08): it doesn't
/// gate the multitouch stream and its `IOHIDCheckAccess` reported a false positive.
struct SystemPermissionChecker: PermissionChecking {
    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }

    /// Trigger the OS authorization *request* — shows the system prompt and, for
    /// Accessibility, registers the app in the pane's list so it can be toggled.
    /// Idempotent (no prompt once already granted); safe to call from the main thread.
    func request(_ permission: Permission) {
        switch permission {
        case .accessibility:
            // The literal value of `kAXTrustedCheckOptionPrompt` — referenced directly to
            // avoid Swift 6 flagging that imported global `var` as non-Sendable shared state.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }
}
