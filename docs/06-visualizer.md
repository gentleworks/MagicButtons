# Visualizer (`Visualizer`)

A small SwiftUI graphic showing live finger positions on the mouse surface and
which zone each finger occupies. Depends only on `TouchKit`. Read-only consumer
of the same frame stream and `ZoneLayout` the recognizer uses — so the picture
and the behavior can never disagree.

## What it shows

- An outline of the Magic Mouse shell (rounded top view).
- The three zones (left / middle / right) as tinted bands, boundaries driven by
  the live `ZoneLayout`.
- One dot per live contact, positioned from `SurfaceTouch.position`, sized from
  `SurfaceTouch.size`.
- The **active zone** highlighted when a finger is present (using `ZoneMapper`
  with hysteresis so it doesn't strobe at boundaries).
- Optional: fading trail, contact id label, phase tint (began/moved/ended) —
  useful during bring-up and threshold tuning.

## Data feed

```swift
@MainActor
public final class VisualizerModel: ObservableObject {
    @Published public private(set) var touches: [SurfaceTouch] = []
    public var layout: ZoneLayout

    public func update(_ frame: [SurfaceTouch]) {   // called on main
        touches = frame
    }
}
```

`AppCoordinator` fans each frame here (marshaled to main) in parallel with the
recognizer. The visualizer never drives behavior; it's a pure sink.

## Coordinate handling

`SurfaceTouch.position` is normalized `0...1`, origin **bottom-left**. SwiftUI is
top-left origin, so the view flips `y` once, at the drawing boundary:

```swift
func point(for t: SurfaceTouch, in size: CGSize) -> CGPoint {
    CGPoint(x: t.position.x * size.width,
            y: (1 - t.position.y) * size.height)   // flip y here only
}
```

Zone bands map `leftEdge` / `rightEdge` (normalized x) to view x directly.

## Uses

1. **User-facing:** a small always-available window / menu-bar popover so the
   user can see and trust where the zones are, and calibrate `ZoneLayout` by
   dragging the boundaries (a live editor writing back to settings).
2. **Developer-facing:** the fastest way to tune tap/zone thresholds and to
   verify the adapter's coordinates and phase mapping during bring-up.

## Calibration mode (stretch)

Overlay draggable boundary handles on the zone bands; dragging updates
`ZoneLayout.leftEdge/rightEdge`, persisted to settings, and both the visualizer
and recognizer pick it up immediately (shared config). This turns "where's the
middle button" from a guess into a direct-manipulation setting.

## Non-goals

- Not a hardware-accurate render; a stylized top-view outline is enough.
- No dependency on the recognizer or emitter — strictly a view over the stream.