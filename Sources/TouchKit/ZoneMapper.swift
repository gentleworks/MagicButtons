import CoreGraphics

/// Stateful active-zone readout with hysteresis, for the **visualizer's** live
/// picture (docs/03 §Zone hysteresis, docs/06). The recognizer judges taps by the
/// `began`-time zone and never uses this; but a *live* readout of "which zone is
/// the finger in right now" would strobe when a contact hovers on a boundary. So
/// this holds the current zone until the contact crosses that boundary by more
/// than `hysteresis` (±0.02 by default).
///
/// It lives in `TouchKit` — the shared vocabulary everything agrees on — rather
/// than `GestureEngine` where the architecture sketch first grouped it, because
/// `Visualizer` depends only on `TouchKit` (docs/06 non-goals: no dependency on
/// the recognizer) and so cannot reach `GestureEngine`. Keeping it here lets both
/// consume one implementation, so the picture and the behavior can't drift.
public struct ZoneMapper: Sendable {
    /// Boundaries to map against; keep in sync with the recognizer's layout so
    /// the picture and the behavior agree.
    public var layout: ZoneLayout
    /// Half-width of the dead-band around each boundary, in normalized x.
    public var hysteresis: CGFloat

    /// The zone the active contact is currently held in; `nil` before the first
    /// sample and after `reset()` (no finger present).
    public private(set) var current: MouseZone?

    public init(layout: ZoneLayout = ZoneLayout(), hysteresis: CGFloat = 0.02) {
        self.layout = layout
        self.hysteresis = hysteresis
    }

    /// Feed the active contact's normalized x and get the (possibly held) zone.
    /// The first sample snaps to the raw zone; subsequent samples only switch
    /// once x clears the relevant boundary by `hysteresis`.
    @discardableResult
    public mutating func update(x: CGFloat) -> MouseZone {
        let raw = layout.zone(for: CGPoint(x: x, y: 0))
        guard let held = current else {
            current = raw
            return raw
        }
        switch held {
        case .left:
            if x > layout.leftEdge + hysteresis { current = raw }
        case .right:
            if x < layout.rightEdge - hysteresis { current = raw }
        case .middle:
            if x < layout.leftEdge - hysteresis || x > layout.rightEdge + hysteresis {
                current = raw
            }
        }
        return current ?? raw
    }

    /// Contact lifted — forget the held zone so the next touch snaps fresh.
    public mutating func reset() {
        current = nil
    }
}
