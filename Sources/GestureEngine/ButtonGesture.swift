import TouchKit

/// Semantic button gestures the recognizer produces from the frame stream. A
/// thin policy in `App` maps each to `ButtonEmitting` calls; the recognizer
/// never touches `CGEvent` (docs/03-gesture-recognition.md).
///
/// The recognizer produces `click(_, 1)` (Phase 2), `click(_, 2)` (Phase 6, double
/// click), and `click(_, 3)` (triple click). The `hold*` cases (tap-and-a-half
/// drag) are produced in Phase 8.
public enum ButtonGesture: Sendable, Equatable {
    /// `count` 1 = single, 2 = double, 3 = triple (up to `GestureConfig.maxClickCount`);
    /// downstream sets `mouseEventClickState = count`. Zone is fixed at the touch's `.began`.
    case click(zone: MouseZone, count: Int)
    /// Drag start — button down (Phase 8).
    case holdBegan(zone: MouseZone)
    /// Drag end — button up (Phase 8).
    case holdEnded(zone: MouseZone)
}
