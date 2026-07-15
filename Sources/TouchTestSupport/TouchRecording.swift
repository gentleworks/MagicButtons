import Foundation
import TouchKit

/// A recorded sequence of touch frames for deterministic replay.
///
/// Not test-only: the App's debug "record" feature and previews replay through
/// the same format (docs/01-architecture.md). Timing that matters to the
/// recognizer lives in each `SurfaceTouch.timestamp`; `interval` is the
/// wall-clock spacing used only for real-time playback (e.g. driving the
/// visualizer), so replay into the recognizer stays fully deterministic.
public struct TouchRecording: Codable, Equatable, Sendable {
    /// Wall-clock spacing between frames for real-time playback. `0` = as fast
    /// as delivered.
    public var interval: TimeInterval
    /// Ordered frames; each frame is the full set of simultaneous contacts.
    public var frames: [[SurfaceTouch]]

    public init(interval: TimeInterval = 0, frames: [[SurfaceTouch]]) {
        self.interval = interval
        self.frames = frames
    }
}
