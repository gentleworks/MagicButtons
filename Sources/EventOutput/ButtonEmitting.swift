import TouchKit

/// *Mechanism*: posts synthesized mouse buttons for a zone. The App's policy
/// maps each `ButtonGesture` to one of these calls; behind a protocol so tests
/// use a spy and never post real system events (docs/05-event-output.md).
///
/// - `click`   ← `ButtonGesture.click`
/// - `press`   ← `ButtonGesture.holdBegan` (drag start; button down, held)
/// - `release` ← `ButtonGesture.holdEnded` (drag end;   button up)
public protocol ButtonEmitting {
    /// `count` 1 = single, 2 = double (sets `mouseEventClickState`).
    func click(_ zone: MouseZone, count: Int)
    func press(_ zone: MouseZone)
    func release(_ zone: MouseZone)
}

/// The move→drag rewrite the emitter arms during a hold so a synthetic button-down
/// makes physical mouse motion register as a *drag* (docs/05 §Why drag needs the
/// interceptor). `EventInterceptor` is the production conformer; behind a protocol so
/// `CGEventEmitter` couples to the capability, not the concrete tap — and tests can
/// drive `press`/`release` with a spy that records promotion arm/disarm.
public protocol DragPromoting: AnyObject {
    /// Rewrite physical `mouseMoved` into `zone`'s `…MouseDragged` until disarmed.
    func beginDragPromotion(zone: MouseZone)
    /// Stop rewriting moves (drag ended).
    func endDragPromotion()
}
