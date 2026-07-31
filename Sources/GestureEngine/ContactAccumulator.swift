import Foundation
import CoreGraphics
import TouchKit

/// Why a contact would (or would not) be accepted as a tap. Lives here rather than
/// with the metrics recorder because it is now shared vocabulary: the recognizer's
/// decision, a logged sample, and the visualizer's live readout all come from the
/// one evaluation below.
public enum TapVerdict: String, Sendable, Equatable, Codable, CaseIterable {
    case tap
    case rejectedPhysicalClick
    case rejectedDuration
    case rejectedTravel
    case rejectedSize
}

/// The per-contact measurements the tap rules are judged on, accumulated over a
/// contact's life. **One implementation, deliberately shared**: `MouseGestureRecognizer`
/// (which decides) and `ContactMetricsRecorder` (which measures) each kept a parallel
/// copy of this arithmetic, and feeding the visualizer would have made a third — so
/// this exists to keep what is *drawn* the same as what *decides* (docs/10 §Visualizer).
///
/// Zone is captured once, at `.began`, so drift toward a boundary never reassigns the
/// button. Travel is Euclidean in **millimetres**, so the budget is a circle on the
/// physical surface — the same allowance whichever way the finger goes. It was
/// normalized-Euclidean through 1.1.2, which the portrait sensor made 1.76× more
/// permissive fore-aft (5.4 mm) than sideways (3.1 mm): an artifact of the coordinate
/// system rather than an ergonomic choice, and measurably wrong — a logged still press
/// drifted 1.60 mm × 1.45 mm, near-equal physically, and was scored ~2× on `x`
/// (docs/04 §Contact geometry).
public struct ContactAccumulator: Sendable, Equatable {
    public let origin: CGPoint
    public let startTime: TimeInterval
    public let zone: MouseZone

    public private(set) var last: CGPoint
    /// Timestamp of the newest frame seen. The recognizer is deliberately clock-free,
    /// so "now" is always this — never a wall clock.
    public private(set) var lastTime: TimeInterval
    /// Greatest distance from `origin` reached so far, in **millimetres**.
    public private(set) var maxTravelMM: CGFloat = 0
    public private(set) var maxSize: CGFloat
    public private(set) var sawPhysicalClick: Bool
    public private(set) var frameCount = 1

    public init(began touch: SurfaceTouch, zone: MouseZone, physicalClickActive: Bool) {
        self.origin = touch.position
        self.startTime = touch.timestamp
        self.zone = zone
        self.last = touch.position
        self.lastTime = touch.timestamp
        self.maxSize = touch.size
        self.sawPhysicalClick = physicalClickActive
    }

    public mutating func accumulate(_ touch: SurfaceTouch, physicalClickActive: Bool) {
        maxTravelMM = max(maxTravelMM, MouseSurface.millimetres(
            dx: touch.position.x - origin.x, dy: touch.position.y - origin.y))
        maxSize = max(maxSize, touch.size)
        if physicalClickActive { sawPhysicalClick = true }
        last = touch.position
        lastTime = touch.timestamp
        frameCount += 1
    }

    /// Elapsed as of the last observed frame.
    public var duration: TimeInterval { lastTime - startTime }

    /// How far the contact is from its origin **right now**, in millimetres — unlike
    /// `maxTravelMM`, this falls again when the finger comes back. Nothing is judged on
    /// it; it exists so a display can show where the finger is against the threshold,
    /// which a ratcheting high-water mark cannot. The two cross the budget at the same
    /// instant (the high-water is set *by* this value), and only diverge afterwards.
    public var displacementMM: CGFloat {
        MouseSurface.millimetres(dx: last.x - origin.x, dy: last.y - origin.y)
    }

    /// This contact's verdict as of `endTime`.
    public func verdict(at endTime: TimeInterval, against config: GestureConfig) -> TapVerdict {
        Self.verdict(duration: endTime - startTime, maxTravelMM: maxTravelMM, maxSize: maxSize,
                     sawPhysicalClick: sawPhysicalClick, config: config)
    }

    /// The single place the tap gates are evaluated, in the tap primitive's order
    /// (docs/03 §What counts as a tap): physical click → duration → travel → size.
    /// `MouseGestureRecognizer.isTap` and `ContactSample.verdict(against:)` both route
    /// here, so a live readout and the real decision cannot drift apart.
    public static func verdict(
        duration: TimeInterval, maxTravelMM: CGFloat, maxSize: CGFloat,
        sawPhysicalClick: Bool, config: GestureConfig
    ) -> TapVerdict {
        if config.requireNoPhysicalClick && sawPhysicalClick { return .rejectedPhysicalClick }
        if duration > config.maxDuration { return .rejectedDuration }
        if maxTravelMM > config.maxTravelMM { return .rejectedTravel }
        if maxSize > config.maxSize { return .rejectedSize }
        return .tap
    }
}
