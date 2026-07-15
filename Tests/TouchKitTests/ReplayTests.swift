import Testing
import Foundation
import CoreGraphics
import TouchKit
import TouchTestSupport

// Phase 1 exit criterion: script `[[SurfaceTouch]]` and replay it through a
// `TouchSource`, and round-trip the recording format.

private let device = MouseDeviceID(raw: 1)

private func touch(_ id: Int32, _ x: CGFloat, _ phase: TouchPhase, at t: TimeInterval) -> SurfaceTouch {
    SurfaceTouch(deviceID: device, id: id,
                 position: CGPoint(x: x, y: 0.5),
                 phase: phase, timestamp: t, size: 0.2)
}

/// A middle-zone tap: down, move, lift over 120 ms.
private func scriptedTap() -> [[SurfaceTouch]] {
    [
        [touch(1, 0.5, .began, at: 0.000)],
        [touch(1, 0.5, .moved, at: 0.060)],
        [touch(1, 0.5, .ended, at: 0.120)],
    ]
}

@Suite struct ReplayTests {
    @Test func replayDeliversEveryScriptedFrameInOrder() throws {
        let frames = scriptedTap()
        let source = SimulatedTouchSource()
        var received: [[SurfaceTouch]] = []
        source.onFrame = { received.append($0) }

        try source.start()
        source.emit(frames)

        #expect(received == frames)
    }

    @Test func emitIsInertBeforeStartAndAfterStop() throws {
        let source = SimulatedTouchSource()
        var frameCount = 0
        source.onFrame = { _ in frameCount += 1 }

        source.emit(scriptedTap())        // not started yet
        #expect(frameCount == 0)

        try source.start()
        source.emit(scriptedTap())
        #expect(frameCount == 3)

        source.stop()
        source.emit(scriptedTap())        // stopped
        #expect(frameCount == 3)
    }

    @Test func recordingRoundTripsAndReplaysIdentically() throws {
        let original = TouchRecording(interval: 0.06, frames: scriptedTap())

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TouchRecording.self, from: data)
        #expect(decoded == original)

        let source = SimulatedTouchSource()
        var received: [[SurfaceTouch]] = []
        source.onFrame = { received.append($0) }
        try source.start()
        source.emit(decoded)

        #expect(received == original.frames)
    }
}
