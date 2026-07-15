import CoreGraphics

/// The three logical buttons a contact can fall into.
public enum MouseZone: Sendable, CaseIterable, Codable {
    case left, middle, right
}

/// Zone boundaries are **data, not code** — editable from settings without a
/// rebuild (docs/02-domain-model.md). Defaults are guesses until the visualizer
/// + hardware exist (calibrated in Phase 9).
public struct ZoneLayout: Sendable, Codable, Equatable {
    /// `x < leftEdge` → `.left`.
    public var leftEdge: CGFloat
    /// `x > rightEdge` → `.right`; otherwise `.middle`.
    public var rightEdge: CGFloat

    public init(leftEdge: CGFloat = 0.38, rightEdge: CGFloat = 0.62) {
        self.leftEdge = leftEdge
        self.rightEdge = rightEdge
    }

    private enum CodingKeys: String, CodingKey { case leftEdge, rightEdge }

    /// Lenient decode: a missing edge falls back to its default so partial/older
    /// settings JSON imports cleanly (docs/09 §Persistence). Encode still writes both.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ZoneLayout()
        self.init(
            leftEdge: try c.decodeIfPresent(CGFloat.self, forKey: .leftEdge) ?? d.leftEdge,
            rightEdge: try c.decodeIfPresent(CGFloat.self, forKey: .rightEdge) ?? d.rightEdge
        )
    }

    public func zone(for p: CGPoint) -> MouseZone {
        if p.x < leftEdge { return .left }
        if p.x > rightEdge { return .right }
        return .middle
    }
}
