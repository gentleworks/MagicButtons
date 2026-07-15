import Testing
import Foundation
@testable import AppCore
import GestureEngine
import TouchKit

// Phase 7.2 — the AppSettings bundle and its lenient, forward-compatible decoding
// (docs/09 §Persistence, docs/11 §Phase 7.2).

@Suite struct AppSettingsTests {

    @Test func defaultsMatchComponentDefaults() {
        let s = AppSettings()
        #expect(s.zones == ZoneLayout())
        #expect(s.gestures == GestureConfig())
        #expect(s.features == FeaturePolicy())
        #expect(s.launchAtLogin == false)   // login item is opt-in
    }

    @Test func fullBundleRoundTrips() throws {
        let s = AppSettings(
            zones: ZoneLayout(leftEdge: 0.25, rightEdge: 0.75),
            gestures: GestureConfig(maxDuration: 0.2),
            features: FeaturePolicy(masterEnabled: false),
            launchAtLogin: true)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == s)
    }

    // MARK: Lenient decode — missing whole sections

    @Test func missingSectionsDefault() throws {
        // Only one scalar present; every section absent → each defaults.
        let json = Data(#"{ "launchAtLogin": true }"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.zones == ZoneLayout())
        #expect(s.gestures == GestureConfig())
        #expect(s.features == FeaturePolicy())
        #expect(s.launchAtLogin == true)
    }

    @Test func emptyObjectDecodesToDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(s == AppSettings())
    }

    // MARK: Lenient decode — missing keys *within* a section

    @Test func partialGestureConfigKeepsOtherDefaults() throws {
        // A future/older file that only carries maxSize must not drop the rest.
        let json = Data(#"{ "gestures": { "maxSize": 22 } }"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.gestures.maxSize == 22)
        #expect(s.gestures.maxDuration == GestureConfig().maxDuration)
        #expect(s.gestures.doubleTapGap == GestureConfig().doubleTapGap)
    }

    @Test func partialFeaturePolicyKeepsOtherDefaults() throws {
        let json = Data(#"{ "features": { "tapToClick": false } }"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.features.tapToClick == false)
        #expect(s.features.masterEnabled == FeaturePolicy().masterEnabled)
        #expect(s.features.middleTapToClick == FeaturePolicy().middleTapToClick)
    }

    @Test func partialZoneLayoutKeepsOtherEdgeDefault() throws {
        let json = Data(#"{ "zones": { "leftEdge": 0.2 } }"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        #expect(s.zones.leftEdge == 0.2)
        #expect(s.zones.rightEdge == ZoneLayout().rightEdge)
    }
}
