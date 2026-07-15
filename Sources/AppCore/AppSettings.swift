import TouchKit
import GestureEngine

/// The complete, persisted app configuration (docs/09-settings-and-status.md
/// §Persistence): zone boundaries, recognizer tunables, feature toggles, and the
/// login-item preference — one `Codable` value so it round-trips through
/// `UserDefaults` and the Export/Import JSON file with a single encode/decode.
///
/// Forward-compatible by construction: decoding is **lenient** at every level — a
/// missing top-level section, or a missing key *within* a section, falls back to
/// its default rather than throwing (see each type's `init(from:)`). So a file
/// exported by an older build, or hand-edited down to a few keys, still imports.
public struct AppSettings: Sendable, Equatable, Codable {
    /// Zone boundary layout (`leftEdge` / `rightEdge`), Advanced settings.
    public var zones: ZoneLayout
    /// Recognizer tunables (durations, travel, size, gaps), Advanced settings.
    public var gestures: GestureConfig
    /// Per-feature toggles + master enable (the Features section).
    public var features: FeaturePolicy
    /// Whether to register the `SMAppService` login item (applied in Phase 7.7 —
    /// this is just the persisted preference).
    public var launchAtLogin: Bool

    public init(
        zones: ZoneLayout = .init(),
        gestures: GestureConfig = .init(),
        features: FeaturePolicy = .init(),
        launchAtLogin: Bool = false
    ) {
        self.zones = zones
        self.gestures = gestures
        self.features = features
        self.launchAtLogin = launchAtLogin
    }

    private enum CodingKeys: String, CodingKey {
        case zones, gestures, features, launchAtLogin
    }

    /// Lenient decode: any missing section defaults (nested types are lenient too,
    /// so missing keys *within* a section default as well). Encode writes all.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        self.init(
            zones: try c.decodeIfPresent(ZoneLayout.self, forKey: .zones) ?? d.zones,
            gestures: try c.decodeIfPresent(GestureConfig.self, forKey: .gestures) ?? d.gestures,
            features: try c.decodeIfPresent(FeaturePolicy.self, forKey: .features) ?? d.features,
            launchAtLogin: try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        )
    }
}
