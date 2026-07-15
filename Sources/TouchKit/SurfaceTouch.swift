import Foundation
import CoreGraphics

/// Which Magic Mouse produced a contact. Carried from the start because several
/// mice (mixed v1/v2 generations) may be attached, and contact `id`s are only
/// unique *within* a device — the recognizer keys tracking on `(deviceID, id)`
/// (docs/02-domain-model.md).
public struct MouseDeviceID: Hashable, Sendable, Codable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }
}

/// The four phases the adapter collapses the backend's ~7 raw states into
/// (mapping table in docs/04-multitouch-backend.md).
public enum TouchPhase: Sendable, Equatable, Codable {
    case began, moved, stationary, ended
}

/// One finger contact on the mouse shell for a single frame. The stable
/// vocabulary everything downstream of `TouchSource` speaks — no private-API
/// types, no I/O (docs/02-domain-model.md).
///
/// Positions are normalized `0...1` with origin at the **bottom-left** of the
/// shell (matching the backend's `normalized` readout). Top-left-origin
/// consumers (SwiftUI) flip `y` at the view boundary only.
public struct SurfaceTouch: Sendable, Identifiable, Equatable, Codable {
    /// Which Magic Mouse produced this contact.
    public let deviceID: MouseDeviceID
    /// Stable per-contact id, unique within `deviceID`; tracks a contact from
    /// `.began` to `.ended`.
    public let id: Int32
    /// Normalized `0...1`, origin bottom-left.
    public let position: CGPoint
    public let phase: TouchPhase
    public let timestamp: TimeInterval
    /// Contact area; used downstream to reject palm/noise (a *policy* decision,
    /// so the adapter passes it through rather than judging it).
    public let size: CGFloat

    public init(
        deviceID: MouseDeviceID,
        id: Int32,
        position: CGPoint,
        phase: TouchPhase,
        timestamp: TimeInterval,
        size: CGFloat
    ) {
        self.deviceID = deviceID
        self.id = id
        self.position = position
        self.phase = phase
        self.timestamp = timestamp
        self.size = size
    }
}
