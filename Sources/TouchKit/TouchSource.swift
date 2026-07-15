/// The swap seam between the backend and the pure core. Everything upstream
/// (the private-API adapter, or a simulated source) conforms to this; nothing
/// downstream knows which one it got (docs/02-domain-model.md).
///
/// Whole-frame delivery (`[SurfaceTouch]`), not per-touch callbacks: tap and
/// multi-finger logic needs the full set of simultaneous contacts each frame.
public protocol TouchSource: AnyObject {
    var onFrame: (([SurfaceTouch]) -> Void)? { get set }
    func start() throws
    func stop()
}

/// Domain-level errors so the App can present sensible UI without knowing the
/// backend (e.g. `.notAuthorized` → open the Input Monitoring pane).
public enum TouchSourceError: Error, Equatable {
    case noDevice
    case notAuthorized      // Input Monitoring not granted
    case backendUnavailable // framework/symbol missing on this OS
}
