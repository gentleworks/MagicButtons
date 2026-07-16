# Gesture Recognition (`GestureEngine`)

Pure logic. Depends only on `TouchKit`. No hardware, no `CGEvent`, no UI.
This is where requirement churn concentrates, so it is fully unit-tested.

## Responsibilities

1. **Zone mapping** — which zone a touch is in (thin wrapper over
   `ZoneLayout.zone(for:)`, plus hysteresis for the visualizer readout).
2. **Gesture recognition** — from the frame stream, produce semantic button
   gestures: **single click, double click, and drag (press-hold-release)** in a
   zone, with a finger count.

Deliberately *not* here: what a gesture *does* (that's policy in `App` +
`EventOutput`) and where touches come from (that's the adapter).

## The v1 gesture set (all required to ship)

Each of the three click features (see `09-settings-and-status.md`) must support:

- **single click** — one tap in a zone,
- **double click** — two taps in a zone within the double-tap gap,
- **drag** — a held contact that keeps the button pressed until the finger lifts.
  Actual dragging comes from moving the whole mouse (physical motion), promoted to
  drag events downstream (see `05-event-output.md`) — not from sliding the finger
  on the shell. v1 ships **two selectable drag styles** (`GestureConfig.dragStyle`):
  the default **tap-and-a-half** and the precision-oriented **press-and-hold** — see
  **Drag styles** below.

Why not a *plain* long-press as the only style: fingers frequently *rest* on the
Magic Mouse surface, so a bare long-press would fire accidentally. Tap-and-a-half
(a completed tap *then* a held second contact) makes drag deliberate and is the
default for that reason; press-and-hold is offered as a precision alternative that
accepts the resting-finger risk (both covered below). Since we are **not**
suppressing physical clicks in v1, ordinary click-and-drag by depressing the shell
still works too; the tap-derived drags are the no-press alternative.

## What counts as a tap (the primitive)

A single contact is a *tap* iff, from `.began` to `.ended`:

- **Duration** ≤ `maxDuration` (default 0.18 s),
- **Travel** ≤ `maxTravel` (default 0.06 normalized),
- **Contact size** stayed ≤ `maxSize` throughout (rejects palm/heel),
- **No physical click** during its lifetime (`requireNoPhysicalClick`) — a real
  hardware click is the OS's job; we must not duplicate it.

Zone is decided at `.began` (where the finger landed), so drift toward a
boundary never reassigns the button.

## Output type

```swift
public enum ButtonGesture: Sendable, Equatable {
    case click(zone: MouseZone, count: Int)   // count 1 = single, 2 = double
    case holdBegan(zone: MouseZone)           // drag start (button down)
    case holdEnded(zone: MouseZone)           // drag end   (button up)
}
```

The recognizer emits `ButtonGesture`; a thin policy in `App` maps each to
`ButtonEmitting` calls. Finger count travels for future multi-finger mapping.

## Config

```swift
public struct GestureConfig: Sendable, Codable, Equatable {
    // tap primitive
    public var maxDuration: TimeInterval = 0.18
    public var maxTravel: CGFloat        = 0.06
    public var maxSize: CGFloat          = 14      // major-axis scale, not 0…1 (see below)
    public var requireNoPhysicalClick    = true
    // multi-tap / drag timing
    public var doubleTapGap: TimeInterval = 0.30   // max gap between taps
    public var holdThreshold: TimeInterval = 0.18  // held this long → drag
    public var maxClickCount: Int = 3              // build up to triple; 2 = double only, 1 = off
    // drag
    public var dragStyle: DragStyle = .tapAndAHalf // .pressAndHold = precise, no leading tap
    // per-feature enable is applied by policy, not here (see Settings doc)
    //
    // post-v1: var clickTiming: ClickTiming = .immediate  — .deferred withholds the
    // first click until the second interaction resolves (see "Click timing" below).
}
```

> `maxSize` is on the **major-axis scale** the real backend delivers (a finger reads
> ~8–10, *not* the `0…1` range of `position`); recalibrated to `14` in Phase 7
> ([[touch-size-scale]]). Defaults are guesses until Phase 9 calibration.

All values are data, surfaced under an **Advanced** settings section.
`doubleTapGap` defaults near the system double-click interval; consider reading
`NSEvent.doubleClickInterval` as the default.

## The unified state machine (per zone)

One tap primitive feeds a per-zone state machine that resolves the next
interaction into a *further click* (double, triple, …) or a *drag*. This unifies
them without adding single-click latency:

```
IDLE
 └─ tap completes in zone Z ──▶ emit click(Z, 1) immediately
                               enter WAIT_NEXT(count 1)  (start doubleTapGap timer)

WAIT_NEXT(count N) (a click(Z, N) has already been emitted)
 ├─ new contact .began in Z within gap ──▶ NEXT_ACTIVE(N)
 └─ gap expires ──▶ IDLE   (nothing more; the run's clicks already delivered)

NEXT_ACTIVE(N)
 ├─ contact ends as a tap (within tap limits) ──▶ emit click(Z, N+1)
 │                                                 ├─ N+1 < maxClickCount ──▶ WAIT_NEXT(N+1)
 │                                                 └─ N+1 = maxClickCount ──▶ IDLE  (run ends)
 └─ contact still down past holdThreshold (N=1 only) ──▶ emit holdBegan(Z)
                                                   ├─ contact ends ──▶ emit holdEnded(Z) ──▶ IDLE
                                                   └─ (safety) forced release ──▶ holdEnded(Z)
```

So a run climbs `click(1) → click(2) → click(3)` as long as each next tap lands in
the same zone within `doubleTapGap`; it ends at `maxClickCount` (default 3, giving
**triple-click** — line-select in a text view) or when the gap expires. Only the
**second** contact (`N=1`) may hold-promote to a drag; a later tap in the run does
not (a double-tap-then-hold *drag* is a separate roadmap item, below).

Consequences (intentional):
- **No single-click latency.** Each click is emitted on its release; a following
  tap produces `click(Z, N+1)` which downstream sets `clickState = N+1`, so the OS
  sees a genuine double- or triple-click (each its own down/up pair). *This is the
  `.immediate` default; the post-v1 `.deferred` click timing trades it — see
  **Click timing**.*
- **Drag reads as click-then-press** (tap-and-a-half) — which the OS interprets as
  a **double-click-drag**; see the artifact note under **Drag styles**.
- A *direct* long-press (finger down and held without a preceding tap) does
  **nothing** in `tapAndAHalf` — prevents accidental drags from resting fingers.
  (The `pressAndHold` style deliberately makes this the drag trigger; see below.)

Future (v2): a double-tap-then-hold → double-click-drag (word select + drag) is a
natural extension of `SECOND_ACTIVE`; out of v1.

## Drag styles (both ship in v1)

Drag has two selectable initiation styles — `GestureConfig.dragStyle`, an
**Advanced** setting (`09-settings-and-status.md`). Both feed the **same**
`holdBegan`/`holdEnded` output and the same downstream press → move-promotion →
release path (`05-event-output.md`); only the **trigger** differs. Default is
`tapAndAHalf`.

- **`tapAndAHalf`** *(default)* — the machine above: a completed tap, then a
  **second** contact in the same zone **held** past `holdThreshold`. Deliberate (a
  resting finger can't start it) and the widely-expected mouse-utility idiom.
- **`pressAndHold`** — a **single** contact held **still** past `holdThreshold`,
  with **no** leading tap → drag. Three gates keep it from misfiring: it must be the
  **only** live contact (a two-finger gesture never arms it), it must have stayed
  **still** on the shell (on-shell travel ≤ `maxTravel` — a finger *slide* is a
  scroll, not a press), and it must have been held ≥ `holdThreshold`. A quick press
  is still an ordinary tap → click; a slow press with no mouse movement is a
  press+release at one spot = a click. No leading tap ⇒ a clean **single-press**
  drag.

Which to pick is a genuine trade, so both ship:

- `tapAndAHalf` — **no resting-finger false positives** and the familiar idiom; its
  cost is the *artifact* below.
- `pressAndHold` — **precision**: no leading click means dragging inside a word or
  on a small handle isn't preceded by a selection; its cost is that a genuinely
  resting finger, held still, then a mouse move, can start an unintended drag — the
  exact case `tapAndAHalf` guards. Novel to the mouse (no trackpad equivalent).
  Both verified working on hardware (Phase 8).

  **The resting-finger cost is sharper than "an unintended drag"** (HW-confirmed
  2026-07-16, once click/drag de-confliction landed — `14-post-v1.md` scenario #9). While
  that unintended drag is live, **de-confliction swallows physical clicks**, so clicking
  the shell does nothing until the finger lifts. Rest a finger and then physically
  double-click and the second click is eaten — the two gestures physically overlap, since
  in this mode *a resting finger is the drag trigger*. This is **inherent**, not a bug to
  fix: the mode's premise is that the top surface is free. So `pressAndHold` asks the user
  to **grip the mouse from the sides and keep the shell clear except when tapping or
  dragging**; `tapAndAHalf` is the mode for people who rest fingers. Surfaced in the
  drag-style picker's help text (`AdvancedSettingsView.dragStyleHelp`), which is where the
  choice is actually made.

  Two boundaries worth keeping straight: it needs **one** resting contact (promotion
  requires `singleContact`, so two resting fingers never arm it), and a contact that
  *saw* a physical click never promotes at all — so a double-click begun with the shell
  clear works normally.

**Known artifact of `tapAndAHalf` + `.immediate` clicks.** Because v1 emits the
first tap's click immediately and the drag's button-down then lands inside the
system double-click window, an app reads *click → press-and-move* as a
**double-click-drag**: on a text view the word under the pointer selects first, then
the drag extends by word — hurting precision, plus wiggle from the second physical
tap. This is a *consequence*, not a feature (the macOS trackpad avoids it by
**withholding** the first tap). `pressAndHold` sidesteps it entirely; the post-v1
`.deferred` click timing removes it for `tapAndAHalf` too — next.

## Click timing — immediate vs. deferred (post-v1)

**Status: specified here, deferred to post-v1 (`10-roadmap.md`). Orthogonal to
`dragStyle`.** A `GestureConfig.clickTiming` setting (default `.immediate`) surfaced
as an independent **Advanced** toggle ("Wait for a second tap before clicking").

### The two timings

- **`.immediate`** *(v1 default)* — the first tap's `click(Z,1)` fires the instant
  the tap releases. Zero click latency; double-click and the `tapAndAHalf` drag are
  *click-then-…*, which produces the artifact above.
- **`.deferred`** — the first tap's click is **withheld** until the second
  interaction resolves, so the recognizer can tell what the tap *was*:

```
WAIT_SECOND  (no click emitted yet — the only change)
 ├─ gap expires (timer)      ──▶ emit click(Z,1)                  (deferred single)
 ├─ 2nd contact ends as tap  ──▶ emit click(Z,1) then click(Z,2)  (double, both now)
 └─ 2nd contact held         ──▶ emit holdBegan(Z) …              (DRAG, no leading click)
```

The last branch is the point: withholding the tap makes a `tapAndAHalf` drag a
clean **single-press** drag — no double-click-drag artifact — matching how other
Magic Mouse utilities behave. That is the reason to add it: users who must use
`tapAndAHalf` (they rest a finger, so can't use `pressAndHold`) still get an
artifact-free drag.

### Costs & risks

- **Every single click gains ~`doubleTapGap` (300 ms default) of latency** — inherent,
  and the reason it is opt-in. Lowering `doubleTapGap` trades the double-click window
  for snappier clicks.
- A deferred **double** emits `click(1)`+`click(2)` back-to-back (~ms apart) rather
  than spread over the two real taps; `mouseEventClickState = 2` on the second pair
  should still register a genuine OS double-click — **verify on hardware**.

### Why it's non-trivial (the implementation seam)

The recognizer is today a **pure function of the frame stream — no clock**. A
double-click or a drag produce more frames, so they resolve on arrival; but a
**lone single click produces no follow-up frames**, so a withheld click must be
flushed by a **timer** firing ~`doubleTapGap` after the tap. Plan: inject a small
`Scheduler` seam (production = `DispatchQueue.main`; tests = a manual scheduler that
advances time) so the recognizer stays deterministic — the flush is scheduled when a
tap is withheld and cancelled when a second contact resolves it first. This timing
path is the bulk of the work; the state-machine change and the config/UI are small.

### Orthogonality

`clickTiming` (when the first click is emitted) and `dragStyle` (what triggers a
drag) are **independent**; all four combinations are coherent:

| | `tapAndAHalf` | `pressAndHold` |
|---|---|---|
| **`.immediate`** *(v1)* | default; drag has the artifact | precise drag, immediate clicks |
| **`.deferred`** *(post-v1)* | artifact-free drag; +click latency (the "compatibility" combo) | precise drag; +click latency, little added benefit |

## Recognizer shape

```swift
public final class MouseGestureRecognizer {
    public var onGesture: ((ButtonGesture) -> Void)?
    public init(layout: ZoneLayout, config: GestureConfig) { ... }

    /// One call per frame: ALL current contacts + current physical-click state.
    public func ingest(_ touches: [SurfaceTouch], physicalClickActive: Bool) { ... }

    /// Coordinator calls this if a feature is disabled or app is quitting, so any
    /// in-flight hold is safely released (prevents a stuck pressed button).
    public func cancelActiveHolds() { ... }
}
```

Internal state per live contact (keyed by `SurfaceTouch.id`): origin pos/time,
begin zone, running max-travel/size, disqualified flag. Plus a small per-zone
machine node holding its current state + timers. Pure function of the frame
stream + config → fully testable with scripted `SurfaceTouch` frames and a
`SpyEmitter` (see `05-event-output.md`).

## Physical-click input

`physicalClickActive` is passed *into* `ingest`, sourced from a public event tap
(see `05`), keeping the recognizer pure regardless of where the signal comes
from. Middle-click-while-hardware-click-held resolves to "no tap" by the
`requireNoPhysicalClick` rule (the accepted v1 behavior).

## Zone hysteresis

The recognizer uses the `began`-time zone (immune to edge flicker). The
*visualizer's* live "active zone" readout uses a separate `ZoneMapper` with a
small hysteresis band (±0.02) so it doesn't strobe at boundaries.

## Extensibility

- Multi-finger gestures already surface via finger count; mapping is policy, not
  a recognizer change.
- Multi-click builds in place: the same per-zone run that produces a double
  continues to a triple (and would to any `maxClickCount`) — no separate recognizer.
- Additional recognizers (swipe-in-zone, drag-lock) can sit beside
  `MouseGestureRecognizer` consuming the same frame stream. Explicit multi-touch
  gesture support is roadmap (`10-roadmap.md`); v1 only *rejects* problematic
  multi-finger cases if testing surfaces them.
