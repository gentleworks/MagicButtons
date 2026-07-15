import AppCore
import ApplicationServices

/// The real TCC check (docs/07). Kept out of `AppCore` on purpose: the whole point of
/// the `PermissionChecking` seam is that the pure model is unit-tested while these
/// system calls live in the untestable target and are verified on the machine (the
/// `permissions` harness below, then the Phase 7.6/7.7 flows).
///
/// Accessibility only — Input Monitoring was dropped in Phase 9 (docs/08): the private
/// multitouch contact stream isn't gated by it, and its check false-positived.
struct SystemPermissionChecker: PermissionChecking {
    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        }
    }
}

/// Phase 7.3 on-machine smoke check: print the live permission snapshot, the exact
/// deep link if it's missing, and the derived operational state — the same
/// `PermissionsSnapshot` the Status panel (7.6) renders. Exit 0 iff fully operational,
/// so it doubles as a scriptable gate.
func runPermissions() -> Int32 {
    let snapshot = PermissionsSnapshot(checker: SystemPermissionChecker())
    print("Permissions (live):")
    for permission in Permission.allCases {
        let ok = snapshot.isGranted(permission)
        print("  \(ok ? "✓" : "✗") \(permission.title) — \(permission.rationale)")
        if !ok {
            print("      fix:  \(permission.fixInstruction)")
            print("      open: \(permission.settingsURL.absoluteString)")
        }
    }
    if snapshot.isFullyOperational {
        print("Accessibility granted — fully operational.")
        print("(The multitouch/touch stream needs no grant — docs/08.)")
    } else {
        print("Degraded: touches read fine, but clicks can’t post until Accessibility is granted.")
    }
    return snapshot.isFullyOperational ? 0 : 1
}
