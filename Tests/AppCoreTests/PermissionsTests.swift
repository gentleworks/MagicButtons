import Testing
import Foundation
@testable import AppCore

// Phase 7.3 / Phase 9 — the pure permissions model after Input Monitoring was dropped
// (docs/08 resolved): Accessibility is the only grant, so the model tracks just that.
// Descriptors, snapshot capability, and re-check/change behavior are driven by an
// injected checker (docs/07). The real TCC call lives in `App` and is verified on the
// machine, not here.

/// Mutable fake so a test can flip the grant between rechecks (a class, so the monitor
/// sees the new value through its stored reference).
private final class FakeChecker: PermissionChecking {
    var accessibility: Bool
    init(accessibility: Bool = false) {
        self.accessibility = accessibility
    }
    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: return accessibility
        }
    }
}

@Suite struct PermissionDescriptorTests {
    @Test func deepLinkTargetsTheAccessibilityPane() {
        #expect(Permission.accessibility.settingsURL.absoluteString
            == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @Test func everyPermissionHasCopyAndScheme() {
        for permission in Permission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.rationale.isEmpty)
            #expect(!permission.fixInstruction.isEmpty)
            #expect(permission.settingsURL.scheme == "x-apple.systempreferences")
        }
    }

    @Test func grantStateLabelsAreDistinctAndPresent() {
        // The Status pane's icon speaks these instead of an SF Symbol name, so an empty
        // or shared string would leave the grant state unsaid.
        let granted = Permission.grantStateLabel(granted: true)
        let notGranted = Permission.grantStateLabel(granted: false)
        #expect(!granted.isEmpty)
        #expect(!notGranted.isEmpty)
        #expect(granted != notGranted)
    }

    @Test func accessibilityIsTheOnlyPermission() {
        // Input Monitoring was dropped in Phase 9 — it doesn't gate the multitouch
        // stream and its check false-positived (docs/08).
        #expect(Permission.allCases == [.accessibility])
    }
}

@Suite struct PermissionsSnapshotTests {
    @Test func grantedIsFullyOperational() {
        let s = PermissionsSnapshot(accessibility: true)
        #expect(s.canPostClicks && s.isFullyOperational)
        #expect(s.missing.isEmpty)
    }

    @Test func notGrantedIsDegradedAndListsAccessibility() {
        // Graceful degradation (docs/07): touches read fine (ungated), clicks don't.
        let s = PermissionsSnapshot(accessibility: false)
        #expect(!s.canPostClicks)
        #expect(!s.isFullyOperational)
        #expect(s.missing == [.accessibility])
    }

    @Test func initFromCheckerReflectsGrant() {
        #expect(PermissionsSnapshot(checker: FakeChecker(accessibility: true)).accessibility)
        #expect(!PermissionsSnapshot(checker: FakeChecker(accessibility: false)).accessibility)
    }
}

@Suite struct PermissionsMonitorTests {
    @Test func startsWithCurrentSnapshot() {
        let monitor = PermissionsMonitor(checker: FakeChecker(accessibility: true))
        #expect(monitor.snapshot.isFullyOperational)
    }

    @Test func recheckNotifiesOnlyOnTransition() {
        let checker = FakeChecker(accessibility: false)
        let monitor = PermissionsMonitor(checker: checker)
        var changes: [PermissionsSnapshot] = []
        monitor.onChange = { changes.append($0) }

        // No change yet → no callback.
        monitor.recheck()
        #expect(changes.isEmpty)

        // Grant Accessibility → one callback, now fully operational.
        checker.accessibility = true
        let latest = monitor.recheck()
        #expect(changes.count == 1)
        #expect(latest.isFullyOperational)
        #expect(monitor.snapshot.isFullyOperational)

        // Recheck with no further change → still one callback.
        monitor.recheck()
        #expect(changes.count == 1)
    }
}
