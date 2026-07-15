import Testing
import Foundation
@testable import AppCore
import GestureEngine
import TouchKit

// Phase 7.1 — the feature-enable policy that filters the recognizer's
// `ButtonGesture` stream by the user's toggles before the emitter. Pure,
// hardware-free (docs/09-settings-and-status.md §Features, docs/11 §Phase 7.1).

@Suite struct FeaturePolicyTests {

    // MARK: Master enable

    @Test func masterDisabledBlocksEverything() {
        let policy = FeaturePolicy(masterEnabled: false)   // features individually on
        #expect(!policy.allows(.click(zone: .left, count: 1)))
        #expect(!policy.allows(.click(zone: .middle, count: 1)))
        #expect(!policy.allows(.click(zone: .right, count: 2)))
        #expect(!policy.allows(.holdBegan(zone: .left)))
    }

    @Test func allEnabledAllowsEveryZone() {
        let policy = FeaturePolicy()   // defaults: master + all three features on
        #expect(policy.allows(.click(zone: .left, count: 1)))
        #expect(policy.allows(.click(zone: .middle, count: 1)))
        #expect(policy.allows(.click(zone: .right, count: 1)))
    }

    // MARK: Tap-to-click (left / right)

    @Test func tapToClickOffBlocksLeftAndRightOnly() {
        let policy = FeaturePolicy(tapToClick: false, middleTapToClick: true)
        #expect(!policy.allows(.click(zone: .left, count: 1)))
        #expect(!policy.allows(.click(zone: .right, count: 1)))
        // Middle is a different feature — unaffected.
        #expect(policy.allows(.click(zone: .middle, count: 1)))
    }

    // MARK: Middle tap-to-click

    @Test func middleTapToClickOffBlocksMiddleOnly() {
        let policy = FeaturePolicy(tapToClick: true, middleTapToClick: false)
        #expect(!policy.allows(.click(zone: .middle, count: 1)))
        #expect(policy.allows(.click(zone: .left, count: 1)))
        #expect(policy.allows(.click(zone: .right, count: 1)))
    }

    // MARK: Double-click / drag inherit their zone's tap feature

    @Test func doubleClickInheritsZoneFeature() {
        // click(_, 2) gates exactly like click(_, 1) in the same zone.
        let leftOnly = FeaturePolicy(tapToClick: true, middleTapToClick: false)
        #expect(leftOnly.allows(.click(zone: .left, count: 2)))
        #expect(!leftOnly.allows(.click(zone: .middle, count: 2)))
    }

    @Test func holdsGateLikeTapsInSameZone() {
        let middleOnly = FeaturePolicy(tapToClick: false, middleTapToClick: true)
        // Middle holds pass (middle tap feature on); left holds blocked symmetrically.
        #expect(middleOnly.allows(.holdBegan(zone: .middle)))
        #expect(middleOnly.allows(.holdEnded(zone: .middle)))
        #expect(!middleOnly.allows(.holdBegan(zone: .left)))
        #expect(!middleOnly.allows(.holdEnded(zone: .left)))
    }

    // MARK: middleClick (physical) is NOT part of the ButtonGesture filter

    @Test func middleClickFlagDoesNotAffectGestureFilter() {
        // Physical middle-click is an interceptor rewrite (Phase 7.4), not a
        // tap-derived gesture — so it must not leak into `allows`. With both tap
        // features off, a middle *tap* gesture is blocked regardless of middleClick.
        let physicalOnly = FeaturePolicy(
            middleClick: true, tapToClick: false, middleTapToClick: false)
        #expect(!physicalOnly.allows(.click(zone: .middle, count: 1)))
        #expect(!physicalOnly.allows(.click(zone: .left, count: 1)))
    }

    // MARK: Persistence surface (feeds Phase 7.2)

    @Test func defaultsAreAllEnabled() {
        let policy = FeaturePolicy()
        #expect(policy.masterEnabled)
        #expect(policy.middleClick)
        #expect(policy.tapToClick)
        #expect(policy.middleTapToClick)
    }

    @Test func codableRoundTrips() throws {
        let policy = FeaturePolicy(
            masterEnabled: true, middleClick: false,
            tapToClick: true, middleTapToClick: false)
        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(FeaturePolicy.self, from: data)
        #expect(decoded == policy)
    }
}
