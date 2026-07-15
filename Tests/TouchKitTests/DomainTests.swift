import Testing
import Foundation
import CoreGraphics
import TouchKit

// Phase 1 — domain vocabulary. Pure, hardware-free.

@Suite struct ZoneLayoutTests {
    @Test func defaultBoundariesMapThreeZones() {
        let layout = ZoneLayout()
        #expect(layout.zone(for: CGPoint(x: 0.10, y: 0.5)) == .left)
        #expect(layout.zone(for: CGPoint(x: 0.50, y: 0.5)) == .middle)
        #expect(layout.zone(for: CGPoint(x: 0.90, y: 0.5)) == .right)
    }

    @Test func boundariesAreExclusiveEdges() {
        let layout = ZoneLayout() // leftEdge 0.38, rightEdge 0.62
        // Exactly on an edge is NOT past it → middle on both sides.
        #expect(layout.zone(for: CGPoint(x: 0.38, y: 0.5)) == .middle)
        #expect(layout.zone(for: CGPoint(x: 0.62, y: 0.5)) == .middle)
        // Just past each edge flips.
        #expect(layout.zone(for: CGPoint(x: 0.379, y: 0.5)) == .left)
        #expect(layout.zone(for: CGPoint(x: 0.621, y: 0.5)) == .right)
    }

    @Test func customBoundariesAreHonored() {
        let layout = ZoneLayout(leftEdge: 0.25, rightEdge: 0.75)
        #expect(layout.zone(for: CGPoint(x: 0.30, y: 0.5)) == .middle)
        #expect(layout.zone(for: CGPoint(x: 0.20, y: 0.5)) == .left)
    }
}

@Suite struct CodableTests {
    @Test func surfaceTouchRoundTrips() throws {
        let touch = SurfaceTouch(
            deviceID: MouseDeviceID(raw: 42),
            id: 7,
            position: CGPoint(x: 0.5, y: 0.25),
            phase: .began,
            timestamp: 123.456,
            size: 0.3
        )
        let data = try JSONEncoder().encode(touch)
        let decoded = try JSONDecoder().decode(SurfaceTouch.self, from: data)
        #expect(decoded == touch)
    }

    @Test func zoneLayoutRoundTrips() throws {
        let layout = ZoneLayout(leftEdge: 0.4, rightEdge: 0.6)
        let decoded = try JSONDecoder().decode(
            ZoneLayout.self, from: JSONEncoder().encode(layout))
        #expect(decoded == layout)
    }
}
