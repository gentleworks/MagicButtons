import TouchKit

/// One synthetic emission, teed before it is posted.
///
/// Deliberately mirrors `ButtonEmitting`, not `ButtonGesture`: this is what the app
/// *actually did*, after the feature policy and the secondary-click swap have had their
/// say (docs/05 §Zone → button). The zone here is the **emitted** button, not the finger's
/// spatial zone.
public enum SynthEvent: Sendable {
    case press(MouseZone)
    case release(MouseZone)
    case click(MouseZone, Int)
}

/// Wraps any `ButtonEmitting` and tees each emission to `onEvent` before forwarding it.
///
/// This is the honest seam for recording what the app emitted. `GesturePipeline.onGesture`
/// fires *earlier* — before the policy filter and before `effectiveZone` applies the
/// secondary-click swap — so it reports gestures that were recognized, which is not the
/// same set as the buttons that were posted (a gesture whose feature is toggled off is
/// recognized and then dropped). Anything reasoning about what the system actually saw —
/// above all "was a synthetic button held just then?" — has to observe it here.
///
/// Main-confined by convention, exactly like the pipeline that drives it: every call
/// arrives via `GesturePipeline.route`, which runs on main. Not `@MainActor` because
/// `ButtonEmitting` is a nonisolated protocol.
public final class TeeingEmitter: ButtonEmitting {
    private let inner: any ButtonEmitting
    /// `nil` ⇒ no recording, one nil-check per emission and nothing else.
    public var onEvent: ((SynthEvent) -> Void)?

    public init(_ inner: any ButtonEmitting) { self.inner = inner }

    public func click(_ zone: MouseZone, count: Int) {
        onEvent?(.click(zone, count))
        inner.click(zone, count: count)
    }

    public func press(_ zone: MouseZone) {
        onEvent?(.press(zone))
        inner.press(zone)
    }

    public func release(_ zone: MouseZone) {
        onEvent?(.release(zone))
        inner.release(zone)
    }
}
