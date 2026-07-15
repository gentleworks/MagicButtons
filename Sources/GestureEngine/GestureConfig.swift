import Foundation
import CoreGraphics

/// How a drag is initiated (docs/03 §The v1 gesture set). Two schemes that share the
/// same `holdBegan`/`holdEnded` output — only the *trigger* differs:
///
/// - **`tapAndAHalf`** *(default)* — a completed tap, then a **second** contact in the
///   same zone held past `holdThreshold`. Deliberate (a resting finger can't start it)
///   and matches the macOS trackpad idiom, at the cost of the leading tap reading as a
///   click, so on a text view the app sees a double-click-drag (word pre-select).
/// - **`pressAndHold`** — a **single** contact held **still** past `holdThreshold` →
///   drag, with no leading tap: a clean single-press drag (precise, no word pre-select,
///   no second-tap wiggle). The tradeoff is false positives from a genuinely resting
///   finger, gated by stillness + single-contact + duration. Novel to the mouse.
public enum DragStyle: String, Sendable, Codable, Equatable, CaseIterable {
    case tapAndAHalf
    case pressAndHold
}

/// Tunables for the recognizer. All values are **data**, surfaced under an
/// **Advanced** settings section (docs/03-gesture-recognition.md,
/// docs/09-settings-and-status.md); defaults are guesses until the visualizer +
/// hardware exist (calibrated in Phase 9).
///
/// Per-feature enable (middle click / tap-to-click / …) is applied by policy in
/// `App`, not here.
public struct GestureConfig: Sendable, Codable, Equatable {
    // MARK: Tap primitive
    /// Max `.began`→`.ended` duration for a contact to count as a tap.
    public var maxDuration: TimeInterval
    /// Max travel from the `.began` position, normalized `0...1`.
    public var maxTravel: CGFloat
    /// Max contact size at any point in the contact's life (rejects palm/heel).
    /// On the **major-axis scale** the real `MultitouchSource` delivers — a finger
    /// contact reads ~8–10, *not* normalized `0…1` like `position` (Phase 4;
    /// [[touch-size-scale]]). The default leaves headroom above a real tap;
    /// Phase 9 tunes it against logged data.
    public var maxSize: CGFloat
    /// A hardware click during the contact's life disqualifies the tap — the OS
    /// already delivered that click and we must not duplicate it.
    public var requireNoPhysicalClick: Bool

    // MARK: Multi-tap / drag timing (consumed in Phases 6 & 8)
    /// Max gap between the two taps of a double click.
    public var doubleTapGap: TimeInterval
    /// A contact held at least this long promotes to a drag (the held second contact
    /// in `tapAndAHalf`, or the held first contact in `pressAndHold`).
    public var holdThreshold: TimeInterval
    /// The highest multi-click the recognizer will build in one in-gap run: `2`
    /// stops at double, `3` (default) reaches triple (line-select in text views),
    /// and so on. Each in-gap tap continues the run — `click(1)`, `click(2)`,
    /// `click(3)` — until this cap, after which the run resets to a fresh single.
    /// `1` disables multi-click entirely. Double- and triple-click inherit their
    /// zone's tap feature; there is no separate toggle (docs/09 §Features).
    public var maxClickCount: Int

    // MARK: Drag
    /// Which drag-initiation scheme the recognizer uses (see `DragStyle`).
    public var dragStyle: DragStyle

    public init(
        maxDuration: TimeInterval = 0.18,
        maxTravel: CGFloat = 0.06,
        maxSize: CGFloat = 14,
        requireNoPhysicalClick: Bool = true,
        doubleTapGap: TimeInterval = 0.30,
        holdThreshold: TimeInterval = 0.18,
        dragStyle: DragStyle = .tapAndAHalf,
        maxClickCount: Int = 3
    ) {
        self.maxDuration = maxDuration
        self.maxTravel = maxTravel
        self.maxSize = maxSize
        self.requireNoPhysicalClick = requireNoPhysicalClick
        self.doubleTapGap = doubleTapGap
        self.holdThreshold = holdThreshold
        self.dragStyle = dragStyle
        self.maxClickCount = maxClickCount
    }

    private enum CodingKeys: String, CodingKey {
        case maxDuration, maxTravel, maxSize, requireNoPhysicalClick
        case doubleTapGap, holdThreshold, dragStyle, maxClickCount
    }

    /// Lenient decode: any **missing** key falls back to its default, so an older or
    /// partial settings file (e.g. exported before a new threshold was added) imports
    /// cleanly instead of throwing (docs/09 §Persistence, docs/11 §Phase 7.2). The
    /// synthesized `encode(to:)` still writes every key.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureConfig()
        self.init(
            maxDuration: try c.decodeIfPresent(TimeInterval.self, forKey: .maxDuration) ?? d.maxDuration,
            maxTravel: try c.decodeIfPresent(CGFloat.self, forKey: .maxTravel) ?? d.maxTravel,
            maxSize: try c.decodeIfPresent(CGFloat.self, forKey: .maxSize) ?? d.maxSize,
            requireNoPhysicalClick: try c.decodeIfPresent(Bool.self, forKey: .requireNoPhysicalClick) ?? d.requireNoPhysicalClick,
            doubleTapGap: try c.decodeIfPresent(TimeInterval.self, forKey: .doubleTapGap) ?? d.doubleTapGap,
            holdThreshold: try c.decodeIfPresent(TimeInterval.self, forKey: .holdThreshold) ?? d.holdThreshold,
            dragStyle: try c.decodeIfPresent(DragStyle.self, forKey: .dragStyle) ?? d.dragStyle,
            maxClickCount: try c.decodeIfPresent(Int.self, forKey: .maxClickCount) ?? d.maxClickCount
        )
    }
}
