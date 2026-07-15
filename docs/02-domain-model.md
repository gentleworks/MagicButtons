# Domain Model (`TouchKit`)

The stable vocabulary. No dependencies, no private API, no I/O. Everything
downstream of the backend speaks only these types.

## Coordinate convention

Positions are **normalized `0...1`** with origin at the **bottom-left** of the
mouse shell (matching the private framework's `normalized` readout, so the
adapter does no axis math beyond a straight copy). Downstream code that wants
top-left origin (SwiftUI) flips `y` at the view boundary only.

Normalization is deliberate: it decouples the whole system from physical device
dimensions. A different device, or a firmware change to surface size, is
absorbed in the adapter.

## Types

```swift
public struct SurfaceTouch: Sendable, Identifiable, Equatable, Codable {
    public let deviceID: MouseDeviceID  // which Magic Mouse produced this
    public let id: Int32            // stable per-contact id (unique within device)
    public let position: CGPoint    // normalized 0...1, origin bottom-left
    public let phase: TouchPhase
    public let timestamp: TimeInterval
    public let size: CGFloat        // contact area; used to reject palm/noise
}

public struct MouseDeviceID: Hashable, Sendable, Codable { public let raw: UInt64 }

public enum TouchPhase: Sendable, Equatable, Codable {
    case began, moved, stationary, ended
}
```

Conformance notes (as built):
- `SurfaceTouch` and `TouchPhase` are **`Equatable` + `Codable`**. `Codable` is
  what lets the frame-recording format (below) round-trip; `Equatable` makes
  replay/round-trip assertions clean. This matches the domain's existing choices
  (`MouseDeviceID`/`MouseZone`/`ZoneLayout` are already `Codable`).
- Every public type exposes a **public memberwise `init`** so downstream targets
  (`TouchTestSupport`, tests, previews) can construct them across module lines.

`id` is what lets the recognizer track a single contact across frames from
`.began` to `.ended`. The backend supplies richer raw states; the adapter
collapses them into these four (mapping table in `04-multitouch-backend.md`).

`deviceID` is carried from the start because multiple Magic Mice (and mixed v1/v2
generations) may be attached. Contact `id`s are only unique *within* a device, so
the recognizer keys tracking on `(deviceID, id)`. It also future-proofs per-device
settings (`10-roadmap.md`). v1 processes whichever device is active but never
conflates contacts across devices.

`size` is kept in the domain type because tap rejection (palm, accidental
brush) is a *policy* decision that belongs in `GestureEngine`, not the adapter —
so the adapter must pass the signal through rather than judge it.

## Zones

```swift
public enum MouseZone: Sendable, CaseIterable, Codable {
    case left, middle, right
}

/// Zone boundaries are DATA, not code — editable from settings without a rebuild.
public struct ZoneLayout: Sendable, Codable, Equatable {
    public var leftEdge: CGFloat  = 0.38   // x < leftEdge  → .left
    public var rightEdge: CGFloat = 0.62   // x > rightEdge → .right; else .middle

    public func zone(for p: CGPoint) -> MouseZone {
        if p.x < leftEdge { return .left }
        if p.x > rightEdge { return .right }
        return .middle
    }
}
```

Open question: do zones need a vertical component (e.g. ignore the very front lip
of the mouse)? Deferred — see `08-open-questions.md`. `ZoneLayout` can gain a
`yRange` without breaking callers.

## The swap seam

```swift
public protocol TouchSource: AnyObject {
    var onFrame: (([SurfaceTouch]) -> Void)? { get set }
    func start() throws
    func stop()
}

public enum TouchSourceError: Error {
    case noDevice
    case notAuthorized      // touch source refused access (retained; stream needs no TCC grant — 08 §C)
    case backendUnavailable // framework/symbol missing on this OS
}
```

Design notes:
- **Whole-frame delivery** (`[SurfaceTouch]`), not per-touch callbacks. Tap and
  multi-finger logic needs the full set of simultaneous contacts each frame.
- `AnyObject` + mutable `onFrame` closure keeps the seam trivial to implement for
  both the real adapter and `SimulatedTouchSource`. (If we later want
  back-pressure or async, this can become an `AsyncStream`; noted as a possible
  evolution, not v1.)
- Errors are domain-level, so the App can present sensible UI (e.g. `.noDevice` →
  "connect a Magic Mouse") without knowing the backend. The multitouch stream needs
  no TCC grant (`08 §C`), so the App derives touch-readiness from real frame arrival,
  not a permission.

## The output seam (lives in `EventOutput`, shown here for the whole picture)

```swift
public protocol ButtonEmitting {
    func click(_ zone: MouseZone, count: Int)   // count 1 = single, 2 = double
    func press(_ zone: MouseZone)               // button down, held (drag start)
    func release(_ zone: MouseZone)             // button up   (drag end)
}
```

Drag and double-click are v1 requirements, so `press`/`release` and a click
`count` are part of the seam from the start (not deferred). The recognizer's
`ButtonGesture` output type lives in `GestureEngine` (`03-gesture-recognition.md`);
a thin policy in `App` maps gestures to these calls.

## Test support (lives in `TouchTestSupport`)

The replay source plus its `Codable` record format (as built in Phase 1):

```swift
/// The Codable frame record/replay format. Not test-only — the App's debug
/// "record" feature and previews use it too.
public struct TouchRecording: Codable, Equatable, Sendable {
    public var interval: TimeInterval        // wall-clock spacing for real-time playback
    public var frames: [[SurfaceTouch]]
    public init(interval: TimeInterval = 0, frames: [[SurfaceTouch]])
}

public final class SimulatedTouchSource: TouchSource {
    public var onFrame: (([SurfaceTouch]) -> Void)?
    public init()
    public func start() throws            // begins running
    public func stop()                    // stops; emit() is a no-op while stopped
    public func emit(_ frames: [[SurfaceTouch]])   // deliver each frame in order
    public func emit(_ recording: TouchRecording)
}
```

Lets us script "finger down at (0.5, 0.5), lift 120 ms later" and assert a
middle-click was emitted — the core behavior, tested with no hardware.

**Replay is synchronous and deterministic:** frames are delivered in order on the
calling thread, and all timing the recognizer cares about lives in each
`SurfaceTouch.timestamp` (not wall-clock delivery), so a replay yields the
identical result every run. `TouchRecording.interval` is metadata for *real-time*
playback (e.g. driving the visualizer) and is intentionally ignored by `emit` —
which is why the emit signature drops the `interval:` parameter the earlier sketch
carried. `emit` is inert before `start()` and after `stop()`, mirroring a real
source that only delivers while running.
