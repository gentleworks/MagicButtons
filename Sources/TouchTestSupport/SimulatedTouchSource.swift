import Foundation
import TouchKit

/// A `TouchSource` that replays scripted or recorded frames instead of reading
/// hardware. Lets us script "finger down at (0.5, 0.5), lift 120 ms later" and
/// assert the resulting gesture — the core behavior, tested with no hardware
/// (docs/02-domain-model.md, docs/01-architecture.md).
///
/// Replay is **synchronous and deterministic**: frames are delivered in order on
/// the calling thread. The recognizer derives all timing from
/// `SurfaceTouch.timestamp`, not from wall-clock delivery, so a replay produces
/// the same result every run. Real-time playback (honoring `interval`) belongs
/// to the visualizer/demo layer, not here.
public final class SimulatedTouchSource: TouchSource {
    public var onFrame: (([SurfaceTouch]) -> Void)?

    private var isRunning = false

    public init() {}

    public func start() throws { isRunning = true }

    public func stop() { isRunning = false }

    /// Deliver each frame in order via `onFrame`. No-op until `start()` and after
    /// `stop()`, mirroring a real source that only emits while running.
    public func emit(_ frames: [[SurfaceTouch]]) {
        guard isRunning else { return }
        for frame in frames { onFrame?(frame) }
    }

    /// Replay a recording's frames (its `interval` is metadata for real-time
    /// playback and is intentionally ignored here — see the type note).
    public func emit(_ recording: TouchRecording) {
        emit(recording.frames)
    }
}
