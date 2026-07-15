import TouchKit

/// A no-op `TouchSource` used only when the real `MultitouchSource` can't be
/// constructed at all — i.e. `MultitouchSource.init()` threw `.backendUnavailable`
/// (the private framework / struct layout didn't resolve on this macOS build). It
/// lets the `AppCoordinator` still be constructed so the app *launches* and degrades
/// visibly (docs/09 §Status: "unsupported macOS build" rather than silent breakage)
/// instead of failing to start. `start()` re-throws the same error so the coordinator
/// records it as `sourceError`; it never emits a frame.
final class IdleTouchSource: TouchSource {
    var onFrame: (([SurfaceTouch]) -> Void)?
    func start() throws { throw TouchSourceError.backendUnavailable }
    func stop() {}
}
