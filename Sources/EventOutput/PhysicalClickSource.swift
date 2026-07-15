/// The upstream physical-click signal the recognizer needs (docs/05 §Interceptor):
/// a source that reports when a *real* hardware click is held, so taps during it are
/// rejected (`requireNoPhysicalClick`). `EventInterceptor` is the production
/// conformer; the seam lets `AppCoordinator` be unit-tested with a fake that pulses
/// the signal without an event tap.
public protocol PhysicalClickSource: AnyObject {
    /// Called on real hardware-click transitions with the new active state.
    var onPhysicalClickChange: ((Bool) -> Void)? { get set }
    /// Install the tap on the current run loop. Throws if it can't (Accessibility).
    func start() throws
    func stop()
}

extension EventInterceptor: PhysicalClickSource {}

/// The interceptor is also the production `DragPromoting`: `CGEventEmitter.press`/
/// `release` arm/disarm its move→drag rewrite (docs/05 §Press/release). Same object
/// on both seams — one active tap does both jobs (physical-click state *and* drag
/// promotion) — but the emitter only sees the narrow capability.
extension EventInterceptor: DragPromoting {}
