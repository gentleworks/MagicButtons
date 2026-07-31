# Visualizer (`Visualizer`)

A small SwiftUI graphic showing live finger positions on the mouse surface and
which zone each finger occupies. Depends only on `TouchKit`. Read-only consumer
of the same frame stream and `ZoneLayout` the recognizer uses — so the picture
and the behavior can never disagree.

## What it shows

- An outline of the Magic Mouse shell (rounded top view).
- The three zones (left / middle / right) as tinted bands, boundaries driven by
  the live `ZoneLayout`.
- One **contact patch** per live contact, drawn as the ellipse the hardware fits to
  it — `size` (major axis) × `minorAxis`, rotated by `angle`, all in millimetres —
  at its true physical size. Tinted by phase (began/moved/ended). It was a
  fixed-point circle until 1.1.3, which drew the major axis in both directions and
  did not scale with the view: 58% of true size in the standalone window, 113% of it
  in the Advanced mini-map.
- The **tap-travel budget** around each contact's origin: a dashed circle at
  `maxTravelMM`, plus a live ring at the contact's current displacement, so you can
  see how close a tap is to being rejected as a drag. The budget latches solid red
  once the high-water passes it, and the inner ring disappears — that trip is what
  explains the dashed circle without a caption. See docs/10 §Visualizer for why the
  drawn ring is *displacement* while the *high-water* decides.
- The **active zone** highlighted when a finger is present (using `ZoneMapper`
  with hysteresis so it doesn't strobe at boundaries).
- A **gesture badge** naming the zone and gesture when one registers, auto-clearing
  after 900 ms (docs/09 §Advanced).
- Optional: fading trail, contact id label — useful during bring-up.

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

*As built:* `@Observable` rather than the `ObservableObject`/`@Published` sketched
above (macOS 14 + Swift 6), and `update(_:budgets:)` also carries a
`[ContactBudget]` — the travel rings. That is the visualizer's **own** value type,
not `GestureEngine.LiveContact`: the package still depends on `TouchKit` alone, and
`AppShell/AppModel` translates, exactly as it already does for `ButtonGesture` →
`RecognizedGesture`. The cost is a mirrored `TapVerdict`; that is the boundary's
price, paid deliberately.

`budgets` defaults empty, so a source with no recognizer behind it — SwiftUI
previews, the `mb-dev visualize` harness — still drives the picture, just without
rings.

`AppCoordinator` fans each frame here (marshaled to main) in parallel with the
recognizer, reading the budgets *after* `ingest` so they are the same frame's
measurements taken from the recognizer that judges them. The visualizer never drives
behavior; it's a pure sink.

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

- The **shell** is stylized — a rounded top-view outline is enough, and it is not a
  render of the real hardware. What sits *on* it is no longer stylized, though: the
  contact patch and the travel budget are drawn at true physical size, from
  `MouseSurface` in `TouchKit` (51.52 × 90.56 mm, measured — docs/04). That started
  as a fidelity fix for a dot that didn't scale, and turned out to be the thing that
  made the gate's own aspect bias visible enough to fix.
- No dependency on the recognizer or emitter — strictly a view over the stream. The
  travel rings do **not** breach this: the numbers arrive as the visualizer's own
  value type, translated at the composition layer.
- **Not yet non-visual.** Everything above is sight-only; the surface has no
  accessibility representation. Tracked as strand 3 in docs/10 §Visualizer, and it is
  the reason the picture is deliberately readable without colour alone (the badge
  names its zone, the tripped budget changes dash *and* weight, not just hue).