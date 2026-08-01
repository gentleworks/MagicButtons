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
  explains the dashed circle without a caption. The drawn ring is *displacement* while
  the *high-water* decides, because a ring that only ratchets can never show what the
  threshold feels like as you approach it; both cross the boundary at the same instant,
  since the high-water is set by that very value (docs/14 §What the drawing had to learn
  from being looked at).
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

`budgets` defaults empty, so a source with no recognizer behind it — a SwiftUI preview —
still drives the picture, just without rings.

The translation itself lives in **`AppCore.VisualizerFeed`**, in one copy, because there
are two consumers: `AppShell/AppModel` and the `mb-dev visualize` harness. It was private
to `AppModel` until 1.1.3, which is why the harness had no rings or badges at all — it had
no way to speak the recognizer's language. `AppCore` takes a `Visualizer` dependency for
that one file; the translation is pure and imports no UI.

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
- **Not a spoken transcript of the stream.** The picture has a non-visual form (below),
  but it speaks two things, not everything: which zone a settled finger is in,
  and which gesture registered. Position, contact size and the travel budget are drawn
  only. Reading a 90 Hz stream aloud is not an accessible interface, it is noise.

## The spoken readout

The picture has a non-visual form, built on the same feed (docs/10 §Visualizer, strand 3).

The whole view is **one accessibility element**, not a dozen. Left alone VoiceOver finds
the two caption strings and — for 900 ms at a time — the flash badge, so the picture reads
as fragments that appear and vanish under the cursor. Folded together with
`.accessibilityElement(children: .ignore)` it is what it looks like: one live readout,
labelled "Mouse surface", valued with the zone and the contact count.

That covers reading it *on demand*. But while calibrating, VoiceOver focus is on the
slider being dragged, not on the picture — so the value alone is inert, and the readout
also **announces**. Two signals compete for one voice, and the obvious gate ("the value
changed AND ≥0.3 s since the last", the WWDC pattern) gets them backwards: a finger
landing changes the zone immediately and the tap it becomes registers ~180 ms later, so
the zone speaks first and the *gesture* is the one suppressed. `AnnouncementGate`
separates them by intent instead of by rate:

- **Gestures always speak** — discrete, already rare, posted at `.high` priority so
  VoiceOver's queue can't drop them.
- **A zone speaks only once a finger has settled in it** for 0.35 s, comfortably past the
  180 ms defaults of both `maxDuration` and `holdThreshold`. A tap is long gone by then,
  so it never narrates its own landing; a finger resting or sliding does cross it, which
  is the exploring-the-surface case the picture exists for.
- **Lifting is silent** — the user knows they lifted — but it re-arms, so the next contact
  names its zone rather than being taken for a repeat.

The gate is pure and takes its clock as a parameter, so the dwell is tested without
waiting in real time (`VisualizerAnnouncementTests`).

**Deciding there is something to say lives in the model; deciding whether anyone is
listening lives in the view**, and the split is not cosmetic. The touch stream runs for as
long as the app does, so a model that announced on its own would name a zone every time
the user brushed their mouse — in every app, all day. `VisualizerView` posts only when
VoiceOver is running *and* its own window is frontmost (`controlActiveState`); a view
that isn't on screen never gets the chance at all.

This is also why the picture stays readable without colour alone (the badge names its
zone, the tripped budget changes dash *and* weight, not just hue): the spoken form covers
no sight at all, and the drawn form has to cover the far commoner case of colour vision
that differs.