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
    /// Normalized `0...1`, origin bottom-left. This is the contact patch's
    /// **centroid**, so it shifts when the patch grows asymmetrically — a finger
    /// rolling onto its side registers as movement while the finger itself is
    /// still (measured on hardware 2026-07-30: ~half the axis growth, and it
    /// reverses as the patch shrinks).
    public let position: CGPoint
    public let phase: TouchPhase
    public let timestamp: TimeInterval
    /// **Major axis** of the ellipse the hardware fits to the contact patch, in
    /// millimetres (~9–12 for a fingertip). Not an area and not a pressure — it
    /// grows as the patch elongates under press. Used downstream to reject
    /// palm/noise (a *policy* decision, so the adapter passes it through rather
    /// than judging it).
    public let size: CGFloat
    /// **Minor axis** of the same fitted ellipse, in millimetres (always ≤ `size`).
    /// `0` means "not reported" — the drawing boundary falls back to a circle.
    public let minorAxis: CGFloat
    /// Orientation of the major axis, in radians in the sensor's **y-up** frame
    /// (hardware-quantized to π/64 steps; ≈π/2 when the finger lies along the
    /// mouse's long axis). Consumers drawing in y-down space negate it.
    public let angle: CGFloat

    public init(
        deviceID: MouseDeviceID,
        id: Int32,
        position: CGPoint,
        phase: TouchPhase,
        timestamp: TimeInterval,
        size: CGFloat,
        minorAxis: CGFloat = 0,
        angle: CGFloat = 0
    ) {
        self.deviceID = deviceID
        self.id = id
        self.position = position
        self.phase = phase
        self.timestamp = timestamp
        self.size = size
        self.minorAxis = minorAxis
        self.angle = angle
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID, id, position, phase, timestamp, size, minorAxis, angle
    }

    /// Lenient decode for the two fields added after v1, so a `TouchRecording` made
    /// before they existed still replays — the ellipse just falls back to a circle.
    /// Same rule `ZoneLayout` / `GestureConfig` already follow (docs/09 §Persistence).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            deviceID: try c.decode(MouseDeviceID.self, forKey: .deviceID),
            id: try c.decode(Int32.self, forKey: .id),
            position: try c.decode(CGPoint.self, forKey: .position),
            phase: try c.decode(TouchPhase.self, forKey: .phase),
            timestamp: try c.decode(TimeInterval.self, forKey: .timestamp),
            size: try c.decode(CGFloat.self, forKey: .size),
            minorAxis: try c.decodeIfPresent(CGFloat.self, forKey: .minorAxis) ?? 0,
            angle: try c.decodeIfPresent(CGFloat.self, forKey: .angle) ?? 0)
    }
}
