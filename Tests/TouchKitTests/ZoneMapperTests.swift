import Testing
import Foundation
import CoreGraphics
import TouchKit

// Phase 5 — the visualizer's hysteresis active-zone readout. Pure, hardware-free.
// Default layout: leftEdge 0.38, rightEdge 0.62; hysteresis ±0.02.

@Suite struct ZoneMapperTests {
    @Test func firstSampleSnapsToRawZone() {
        var mapper = ZoneMapper()
        #expect(mapper.current == nil)
        #expect(mapper.update(x: 0.90) == .right)
        #expect(mapper.current == .right)
    }

    @Test func holdsZoneWithinDeadBand() {
        var mapper = ZoneMapper() // hysteresis 0.02
        _ = mapper.update(x: 0.10)                 // → left
        // Cross leftEdge (0.38) but stay inside the +0.02 band: still left.
        #expect(mapper.update(x: 0.39) == .left)
        #expect(mapper.update(x: 0.399) == .left)
    }

    @Test func switchesOncePastTheBand() {
        var mapper = ZoneMapper()
        _ = mapper.update(x: 0.10)                 // → left
        // Clear leftEdge + hysteresis (0.40): now middle.
        #expect(mapper.update(x: 0.41) == .middle)
        #expect(mapper.current == .middle)
    }

    @Test func doesNotStrobeWhenHoveringABoundary() {
        var mapper = ZoneMapper()
        _ = mapper.update(x: 0.30)                 // left
        // Jitter around leftEdge (0.38) inside the ±0.02 band stays put.
        for x in [0.37, 0.385, 0.39, 0.375, 0.395] as [CGFloat] {
            #expect(mapper.update(x: x) == .left)
        }
    }

    @Test func middleReleasesToEitherSideOnlyPastBand() {
        var mapper = ZoneMapper()
        _ = mapper.update(x: 0.50)                 // middle
        #expect(mapper.update(x: 0.37) == .middle) // inside left band, held
        #expect(mapper.update(x: 0.35) == .left)   // past leftEdge - 0.02
        _ = mapper.update(x: 0.50)                 // back to middle
        #expect(mapper.update(x: 0.63) == .middle) // inside right band, held
        #expect(mapper.update(x: 0.65) == .right)  // past rightEdge + 0.02
    }

    @Test func resetForgetsHeldZone() {
        var mapper = ZoneMapper()
        _ = mapper.update(x: 0.10)                 // left
        mapper.reset()
        #expect(mapper.current == nil)
        // After a lift, the next contact snaps fresh even mid-band.
        #expect(mapper.update(x: 0.39) == .middle)
    }

    @Test func honorsCustomLayoutAndHysteresis() {
        var mapper = ZoneMapper(layout: ZoneLayout(leftEdge: 0.25, rightEdge: 0.75),
                                hysteresis: 0.05)
        _ = mapper.update(x: 0.10)                 // left
        #expect(mapper.update(x: 0.28) == .left)   // within 0.05 band
        #expect(mapper.update(x: 0.31) == .middle) // past 0.25 + 0.05
    }
}
