import Foundation

/// The TCC permission MagicButtons needs (docs/07-permissions-distribution.md,
/// docs/08 §"Is Input Monitoring actually required?"). **Accessibility only.**
///
/// Input Monitoring was dropped after clean-machine testing (Phase 9): the private
/// `MultitouchSupport` contact stream that reads the Magic Mouse surface is **not**
/// gated by the Input Monitoring toggle — frames flow with the app absent from that
/// pane — and `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` reported it *granted*
/// spuriously, so checking it only produced a false positive and a dead-end "Fix"
/// that dropped the user on an empty pane. Accessibility remains the one real grant:
/// the public `CGEvent` tap (physical-click detection) and posting synthesized clicks.
/// It cannot be granted programmatically — the app checks it and deep-links the user
/// to the exact pane (docs/08 resolved).
public enum Permission: String, Sendable, CaseIterable {
    case accessibility
}

public extension Permission {
    /// Pane name as it reads in System Settings.
    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        }
    }

    /// One line: *why* the app needs it (docs/07 table).
    var rationale: String {
        switch self {
        case .accessibility: return "Post synthesized mouse-button clicks."
        }
    }

    /// One line: *what to do* once the deep link opens the pane.
    var fixInstruction: String {
        switch self {
        case .accessibility: return "Enable MagicButtons under Accessibility."
        }
    }

    /// Deep link straight to the exact System Settings pane (docs/07).
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// The check seam. Injected so the pure model is unit-tested without real TCC; the
/// system conformer (`SystemPermissionChecker`, in `App`) calls `AXIsProcessTrusted`
/// and is exercised on the machine (Phase 7.6/7.7), never in unit tests. Used on the
/// main thread (permission re-checks fire on app focus).
public protocol PermissionChecking {
    func isGranted(_ permission: Permission) -> Bool
}

/// An immutable read of the grant plus the derived capability the Status panel and
/// first-run flow need (docs/07, docs/09 §Status). The touch-read capability is *not*
/// represented here — it's ungated (docs/08), so the App derives it from real frame
/// arrival, not from a permission.
public struct PermissionsSnapshot: Sendable, Equatable {
    public let accessibility: Bool

    public init(accessibility: Bool) {
        self.accessibility = accessibility
    }

    /// Read the grant through a checker.
    public init(checker: any PermissionChecking) {
        self.init(accessibility: checker.isGranted(.accessibility))
    }

    public func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: return accessibility
        }
    }

    /// Accessibility granted → synthesized clicks actually post.
    public var canPostClicks: Bool { accessibility }
    /// The one required grant is present → every feature works.
    public var isFullyOperational: Bool { accessibility }

    /// Missing permissions in first-run prompt order.
    public var missing: [Permission] {
        Permission.allCases.filter { !isGranted($0) }
    }
}

/// Holds the current `PermissionsSnapshot` and re-reads it on demand — the App calls
/// `recheck()` when it regains focus (the user returning from System Settings,
/// docs/07 step 3). `onChange` fires only on an actual transition, so wiring it to a
/// focus notification is cheap. Main-thread use (not `Sendable`).
public final class PermissionsMonitor {
    private let checker: any PermissionChecking
    public private(set) var snapshot: PermissionsSnapshot
    /// Invoked on every change (never on a no-op recheck).
    public var onChange: ((PermissionsSnapshot) -> Void)?

    public init(checker: any PermissionChecking) {
        self.checker = checker
        self.snapshot = PermissionsSnapshot(checker: checker)
    }

    /// Re-read grants; update and notify only if the snapshot actually changed.
    @discardableResult
    public func recheck() -> PermissionsSnapshot {
        let new = PermissionsSnapshot(checker: checker)
        if new != snapshot {
            snapshot = new
            onChange?(new)
        }
        return snapshot
    }
}
