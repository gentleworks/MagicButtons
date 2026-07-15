import TouchKit
import GestureEngine

/// Per-feature enable policy (docs/09-settings-and-status.md §Features). Lives on
/// the App side of the recognizer: the recognizer stays feature-agnostic and
/// always produces the full `ButtonGesture` stream; this filters that stream by
/// which capabilities the user has turned on, immediately before the emitter
/// (docs/01-architecture.md §Composition root).
///
/// Three independent toggles plus a global master enable:
///
/// - **tapToClick** — a *tap* in the **left/right** zone emits that button.
/// - **middleTapToClick** — a *tap* in the **middle** zone emits the middle button.
/// - **middleClick** — a *physical* click while the finger is in the middle zone
///   emits the middle button. This is **not** a tap-derived `ButtonGesture`
///   (docs/03 §Physical-click input treats a physical click as "no tap"; docs/05's
///   interceptor is pass-through in v1), so it can't be realized by filtering this
///   gesture stream — it is a CoreGraphics-level rewrite the interceptor/coordinator
///   applies (Phase 7.4). The flag is stored here so the whole feature set is one
///   `Codable` value (docs/09 §Persistence), but `allows(_:)` — which only sees the
///   tap/drag gestures — deliberately never consults it. (This is the reconciliation
///   of docs/09's "filters ButtonGestures by zone/kind" against docs/03/05; see
///   `11-build-plan.md` §Phase 7.1.)
///
/// Double-click and drag are **not** separate toggles: they inherit their zone's
/// tap feature automatically (docs/09), so `click(_, 2)` and `holdBegan/Ended` gate
/// exactly like `click(_, 1)` in the same zone.
public struct FeaturePolicy: Sendable, Equatable, Codable {
    /// Global master enable — off gates every feature (also surfaced in the menu bar).
    public var masterEnabled: Bool
    /// Physical click in the middle zone → middle button (interceptor rewrite; see above).
    public var middleClick: Bool
    /// Tap in the left/right zone → left/right button.
    public var tapToClick: Bool
    /// Tap in the middle zone → middle button.
    public var middleTapToClick: Bool

    public init(
        masterEnabled: Bool = true,
        middleClick: Bool = true,
        tapToClick: Bool = true,
        middleTapToClick: Bool = true
    ) {
        self.masterEnabled = masterEnabled
        self.middleClick = middleClick
        self.tapToClick = tapToClick
        self.middleTapToClick = middleTapToClick
    }

    private enum CodingKeys: String, CodingKey {
        case masterEnabled, middleClick, tapToClick, middleTapToClick
    }

    /// Lenient decode: a missing toggle falls back to its default, so a settings file
    /// written before a feature existed imports cleanly (docs/09 §Persistence). Encode
    /// still writes every flag.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FeaturePolicy()
        self.init(
            masterEnabled: try c.decodeIfPresent(Bool.self, forKey: .masterEnabled) ?? d.masterEnabled,
            middleClick: try c.decodeIfPresent(Bool.self, forKey: .middleClick) ?? d.middleClick,
            tapToClick: try c.decodeIfPresent(Bool.self, forKey: .tapToClick) ?? d.tapToClick,
            middleTapToClick: try c.decodeIfPresent(Bool.self, forKey: .middleTapToClick) ?? d.middleTapToClick
        )
    }

    /// Whether a recognizer-produced (tap-derived) gesture should reach the emitter.
    /// `false` whenever the master is off or the gesture's zone-feature is off.
    ///
    /// Symmetric across `.click` / `.holdBegan` / `.holdEnded`: a hold gates like a
    /// tap in the same zone. Releasing a hold whose feature is switched off
    /// *mid-hold* is the coordinator's safety job — `cancelActiveHolds()` bypasses
    /// this filter (docs/05 §Press/release) — so this stays a pure function of the
    /// flags and the gesture, with no lifecycle state of its own.
    public func allows(_ gesture: ButtonGesture) -> Bool {
        guard masterEnabled else { return false }
        switch zone(of: gesture) {
        case .left, .right: return tapToClick
        case .middle:       return middleTapToClick
        }
    }

    private func zone(of gesture: ButtonGesture) -> MouseZone {
        switch gesture {
        case let .click(zone, _): return zone
        case let .holdBegan(zone): return zone
        case let .holdEnded(zone): return zone
        }
    }
}
