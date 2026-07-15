import Foundation
import CoreGraphics
import TouchKit
import EventOutput

// Shared fakes for the Phase 7.4 pipeline/coordinator tests — injected so the
// coordinator's wiring and lifecycle are verified with zero hardware and no real
// system events (docs/11 §Phase 7.4).

/// Records emitted buttons instead of posting them.
final class SpyEmitter: ButtonEmitting {
    private(set) var clicks: [(zone: MouseZone, count: Int)] = []
    private(set) var presses: [MouseZone] = []
    private(set) var releases: [MouseZone] = []
    func click(_ zone: MouseZone, count: Int) { clicks.append((zone, count)) }
    func press(_ zone: MouseZone) { presses.append(zone) }
    func release(_ zone: MouseZone) { releases.append(zone) }

    var clickedZones: [MouseZone] { clicks.map(\.zone) }
}

/// A `TouchSource` whose start can be made to fail (simulating no device) and whose
/// start/stop calls are counted.
final class ControllableSource: TouchSource {
    var onFrame: (([SurfaceTouch]) -> Void)?
    var startError: TouchSourceError?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }
    func stop() { stopCount += 1 }
}

/// A `PhysicalClickSource` whose start can be made to throw (simulating a failed tap
/// / missing Accessibility), with counted lifecycle.
final class FakeClickSource: PhysicalClickSource {
    var onPhysicalClickChange: ((Bool) -> Void)?
    var startShouldThrow = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() throws {
        startCount += 1
        if startShouldThrow { throw EventInterceptorError.tapCreationFailed }
    }
    func stop() { stopCount += 1 }
}

/// A completed left/middle/right tap as two frames (began → ended), within all tap
/// limits on the recalibrated size scale.
func tapFrames(x: CGFloat, t0: TimeInterval = 0) -> [[SurfaceTouch]] {
    let device = MouseDeviceID(raw: 1)
    return [
        [SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: x, y: 0.5),
                      phase: .began, timestamp: t0, size: 0.3)],
        [SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: x, y: 0.5),
                      phase: .ended, timestamp: t0 + 0.1, size: 0.3)],
    ]
}

/// A tap in `zone`'s x, then a second contact held past `holdThreshold` and left
/// **down** (no `.ended`), so the pipeline/coordinator is mid-drag — a synthetic
/// button pressed and not yet released. The scenario a device-loss/quit safety
/// release must clean up.
func holdInFlightFrames(x: CGFloat) -> [[SurfaceTouch]] {
    let device = MouseDeviceID(raw: 1)
    return tapFrames(x: x) + [
        [SurfaceTouch(deviceID: device, id: 2, position: CGPoint(x: x, y: 0.5),
                      phase: .began, timestamp: 0.20, size: 0.3)],
        [SurfaceTouch(deviceID: device, id: 2, position: CGPoint(x: x, y: 0.5),
                      phase: .stationary, timestamp: 0.45, size: 0.3)],
    ]
}
