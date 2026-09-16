/// The swap seam between the backend and the pure core. Everything upstream
/// (the private-API adapter, or a simulated source) conforms to this; nothing
/// downstream knows which one it got (docs/02-domain-model.md).
///
/// Whole-frame delivery (`[SurfaceTouch]`), not per-touch callbacks: tap and
/// multi-finger logic needs the full set of simultaneous contacts each frame.
///
/// Lifecycle is **completion-based, not synchronous**: the real backend calls
/// into the private `MultitouchSupport` framework, whose `MTDeviceStop` has no
/// timeout contract and has been observed to spin forever on a device mid
/// sleep/wake re-registration (docs/14, 2026-09 incident). A `start()` that
/// returns would be a lie the caller can't verify, so the work reports back
/// through a completion that fires exactly once — possibly on another thread
/// (the real source runs the framework on its own queue; the completion must
/// be thread-safe). `Sendable` so a source can be handed across that boundary.
public protocol TouchSource: AnyObject, Sendable {
    var onFrame: (([SurfaceTouch]) -> Void)? { get set }
    /// (Re)start frame delivery. `completion` fires exactly once, on an
    /// unspecified thread, with the outcome of the (re)enumeration.
    func start(completion: @escaping @Sendable (Result<Void, TouchSourceError>) -> Void)
    /// Stop frame delivery and release any devices. `completion` fires exactly
    /// once, on an unspecified thread.
    func stop(completion: @escaping @Sendable () -> Void)
}

extension TouchSource {
    /// Stop, then start, as one atomic re-enumeration. The two hops land on the
    /// source's own serial queue in order, so the pair is all-or-nothing: a
    /// device change is always stop-then-start, and callers must never be able
    /// to interleave their own between the two.
    public func refresh(completion: @escaping @Sendable (Result<Void, TouchSourceError>) -> Void) {
        stop { self.start(completion: completion) }
    }
}

/// Domain-level errors so the App can present sensible UI without knowing the
/// backend (e.g. `.notAuthorized` → open the Input Monitoring pane).
public enum TouchSourceError: Error, Equatable {
    case noDevice
    case notAuthorized      // Input Monitoring not granted
    case backendUnavailable // framework/symbol missing on this OS
}
