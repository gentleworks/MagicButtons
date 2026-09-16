import TouchKit

/// A no-op `TouchSource` used only when the real `MultitouchSource` can't be
/// constructed at all — i.e. `MultitouchSource.init()` threw `.backendUnavailable`
/// (the private framework / struct layout didn't resolve on this macOS build). It
/// lets the `AppCoordinator` still be constructed so the app *launches* and degrades
/// visibly (docs/09 §Status: "unsupported macOS build" rather than silent breakage)
/// instead of failing to start. `start` reports the same error (synchronously —
/// there is nothing to wait for) so the coordinator records it as `sourceError`; it
/// never emits a frame.
/// `@unchecked Sendable`: like the simulated source, `onFrame` is set once before
/// `start` and the source carries no other mutable state.
final class IdleTouchSource: TouchSource, @unchecked Sendable {
    var onFrame: (([SurfaceTouch]) -> Void)?
    func start(completion: @escaping @Sendable (Result<Void, TouchSourceError>) -> Void) {
        completion(.failure(.backendUnavailable))
    }
    func stop(completion: @escaping @Sendable () -> Void) {
        completion()
    }
}
