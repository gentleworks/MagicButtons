# Event Output (`EventOutput`)

Turns recognized gestures into synthesized mouse buttons — **including drag and
double-click** — using the **public** `CoreGraphics` event API. Depends only on
`TouchKit`. Behind protocols so policy is swappable and tests never post real
system events.

## Two collaborating pieces

Drag support forces more than a one-shot emitter. This target has two parts:

1. **`ButtonEmitting`** — *mechanism*: posts button events (down/up, click-count,
   press/release).
2. **`EventInterceptor`** — an **active `CGEventTap`** that does two jobs:
   - reports **physical-click state** upstream (feeds `physicalClickActive` into
     the recognizer — the public signal we chose over the private frame bit), and
   - **promotes `mouseMoved` → `…MouseDragged`** while a synthetic hold is active,
     which is what makes tap-and-a-half dragging actually drag (see finding below).

A small `MouseOutput` facade owns both and hides the coupling from the App.

## Why drag needs the interceptor (key finding)

Posting a synthetic `otherMouseDown` does **not** make the driver's subsequent
*physical* mouse-move events register as *drags*. HID move events carry their own
button mask; a synthetic button-down is a separate event and doesn't change it.
So the OS keeps sending `mouseMoved` (no drag), and apps won't drag.

Fix: while a synthetic button is held, an **active** tap rewrites each
`mouseMoved` into the matching `…MouseDragged` (with the held button number/flag)
and passes it through. The initial `otherMouseDown`, the stream of rewritten
`…MouseDragged`, and the final `…MouseUp` together form a real drag.

This is also exactly the machinery v2's "suppress physical clicks" will need, so
building it now is not throwaway.

## Seams

```swift
public protocol ButtonEmitting {
    func click(_ zone: MouseZone, count: Int)   // count 1 = single, 2 = double
    func press(_ zone: MouseZone)               // button down, held (drag start)
    func release(_ zone: MouseZone)             // button up   (drag end)
}
```

Policy mapping (in `App`):
- `ButtonGesture.click(z, n)`  → `emitter.click(z, count: n)`
- `ButtonGesture.holdBegan(z)` → `emitter.press(z)`   (also arms move→drag promotion)
- `ButtonGesture.holdEnded(z)` → `emitter.release(z)` (disarms promotion)

## Zone → button mapping

| Zone | `CGMouseButton` | Down / Up / Dragged types |
|------|-----------------|---------------------------|
| `.left`   | `.left`   | `.leftMouseDown` / `.leftMouseUp` / `.leftMouseDragged` |
| `.right`  | `.right`  | `.rightMouseDown` / `.rightMouseUp` / `.rightMouseDragged` |
| `.middle` | `.center` | `.otherMouseDown` / `.otherMouseUp` / `.otherMouseDragged` |

`.center` + `.otherMouse*` (button number 2) is what apps read as a middle click.

### Mouse handedness (secondary-click side)

The table above is the **right-handed** default. macOS lets a Magic Mouse user move the
*secondary* click to the left side (System Settings → Mouse → Secondary click), for
left-handed use. MagicButtons follows that choice: when the system reports the
left-handed arrangement, the `.left`/`.right` **zones are swapped at emission**
(`.middle` unaffected), so a left tap fires the secondary button and a right tap the
primary — matching the physical mouse.

The side comes from `com.apple.AppleMultitouchMouse`'s **`MouseButtonMode`** key
(`TwoButtonSwapped` = left-handed; `TwoButton` / `OneButton` = right-handed) — confirmed
by toggling the setting and diffing the domain. `MouseButtonDivision` is only the split
*position* and is **not** consulted. It's read at launch and re-read on the App's steady
1.5 s poll, so a mid-session change is honored without relaunch. The swap lives in
`GesturePipeline` at the point of emission: the recognizer and the visualizer stay
**spatial** (they show where the finger is, not which button fires — and the UI labels
the zones "left/right", not "primary/secondary", so the spatial reading is the correct
one), while the emitter and the drag-promotion interceptor both see the one
already-swapped zone. `SecondaryClickReader` / `AppCoordinator.setSecondaryClickSide`.

## Click / double-click

```swift
func click(_ zone: MouseZone, count: Int) {
    let loc = CGEvent(source: nil)?.location ?? .zero
    let src = CGEventSource(stateID: .hidSystemState)
    let down = CGEvent(mouseEventSource: src, mouseType: downType, mouseCursorPosition: loc, mouseButton: btn)
    let up   = CGEvent(mouseEventSource: src, mouseType: upType,   mouseCursorPosition: loc, mouseButton: btn)
    down?.setIntegerValueField(.mouseEventClickState, value: Int64(count))  // 2 → double
    up?.setIntegerValueField(.mouseEventClickState,   value: Int64(count))
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
}
```

The recognizer emits `click(1)` then `click(2)` for a double-tap; the second pair
carrying `clickState = 2` (within the system double-click interval) is what makes
the OS treat it as a genuine double-click.

## Press / release (drag)

```swift
func press(_ zone: MouseZone) {
    guard isTrusted() else { return }                  // don't open a hold we can't close
    heldButton = btn                                   // remember for the tap
    post(downType, at: currentLocation, button: btn)
    interceptor.beginDragPromotion(button: btn)        // moves → dragged from now on
}
func release(_ zone: MouseZone) {
    guard let btn = heldButton else { return }         // idempotent: only lift what's held
    post(upType, at: currentLocation, button: btn)
    interceptor.endDragPromotion()
    heldButton = nil
}
```

## Live tunable edits keep an in-flight hold

Editing a threshold or zone edge in **Advanced** applies live by updating the recognizer
**in place** (`MouseGestureRecognizer.update`, via `GesturePipeline.reconfigure`) rather
than rebuilding it. Preserving contact state matters for one concrete case: dragging an
Advanced **slider with a MagicButtons hold**. Each drag increment changes a tunable, so a
rebuild-and-release would post the synthetic button-up that *is* driving the slider — a
self-cancelling loop that made the app's own sliders undraggable. In-place update keeps
the hold's contact, so the eventual finger-lift still fires `holdEnded` → `release` (no
stranded button — the reason the old rebuild released first). A live hold's button is
fixed at `.began`, so only *future* contacts see the new config; the direct safety paths
(feature-disable, quit, device-loss) still `cancelActiveHolds()` outright. Bonus: it also
drops a ~60×/sec recognizer teardown during any slider drag.

## Stuck-button safeguards (key finding)

A synthetic **hold** is the one place output can wedge the whole machine: `press`
posts a button-down and arms drag-promotion, and only the matching `release`'s
button-up (plus `endDragPromotion`) undoes it. If the up never lands, the OS is
left in a permanent drag — cursor stuck, every click read as drag-end. This was
observed live when Accessibility was revoked *mid-hold*: posting needs
Accessibility, so once it's gone the down had already landed but the up could no
longer post — and the still-live tap kept rewriting the user's real moves into
drags, actively sustaining the lockup until the process was killed.

The asymmetry is the crux: **the down and the up both need Accessibility, and the
grant can vanish between them.** Once it's gone you cannot post the up, so
"detect revocation, then release" does not work — the release can't post. The
defenses therefore *prevent the held state* rather than trying to recover it:

- **Guard-on-trusted** — `press` bails (opens no hold, arms no promotion) unless
  `AXIsProcessTrusted()`. We never open a drag we might not be able to close.
  `click` needs no guard: its down/up post atomically and can't be split.
- **Idempotent `release`** — lifts only a button actually held. Multiple safety
  paths (recognizer lift, `cancelActiveHolds`, quit, device loss) can overlap
  without posting a stray up; a `release` after a bailed `press` is a clean no-op.
- **Release on device loss** — a Magic Mouse that disconnects mid-drag never sends
  the `.ended` frame that lifts the button, so `DeviceMonitor → refreshDevices →
  cancelActiveHolds` lifts it (this posts fine — a disconnect doesn't touch the
  grant). See `AppCoordinatorTests.deviceLossReleasesAnInFlightDrag`.

Still covered by the existing hook: on feature-disable and app quit the
coordinator calls `cancelActiveHolds()` → `release`, and `holdEnded`/release is
**never** gated by the feature policy (release exactly what was pressed).

**Rejected: a frame-silence watchdog.** The tempting Tier-2 idea — force-release
when frames for the held contact stop arriving — was measured and rejected. The
multitouch stream is *delta-driven*: a motionless finger produces essentially no
frames (measured gaps of ~4 s while a finger rested in full contact; `mb-dev
probe-cadence`). Silence ≠ lift, so any timeout short enough to be useful would
drop a legitimate paused drag — a worse bug than the one it fixes. `.ended` is
delivered reliably on a real lift and stays the primary release signal; device
loss (above) is the backstop for the case `.ended` never comes (docs/08).

## Interceptor lifetime

The tap is **scoped to when it has a job**: installed only while the app is running,
the master toggle is on, **and** Accessibility is granted; torn down otherwise. Its
only consumers are physical-click state and drag promotion — both feeding *synthesis*
(recognizer/emitter). The **visualizer** is driven by the touch `source`, not the tap,
so nothing on-screen needs it when the feature is off.

Holding an active `.cghidEventTap` with no job is not free: it sits in the HID path
for every physical click, and if the process loses trust while it's installed (the
user revokes Accessibility) the tap is **orphaned** — events route into a tap the
system won't service and **all clicking wedges system-wide** until the process exits.
This is distinct from §Stuck-button safeguards (no synthetic hold need be active): it
bites even when the app is merely *disabled*.

So the lifetime is reconciled at every edge (`AppCoordinator`):

- `setEnabled(false)` tears the tap down (lifting any held button first);
  `setEnabled(true)` re-arms it.
- `suspendClickInterception()` — called from `AppModel.recheckPermissions` on the
  Accessibility-**revoke** transition — pulls it the moment trust is lost; the existing
  `retryStream` re-arms on re-grant.
- `start()` installs it only when already enabled+authorized (a disabled launch runs
  the touch source alone).

Revoke-while-enabled teardown rides the 1.5 s permission poll, so it isn't instant; a
`com.apple.accessibility.api` change notification would make it immediate if ever
needed. `AppCoordinatorTests` locks in: launched-disabled installs no tap;
disable→re-enable tears down→reinstalls; suspend→re-grant removes→reinstalls; disabling
mid-drag releases the held button first.

## Interceptor sketch

```swift
final class EventInterceptor {
    var onPhysicalClickChange: ((Bool) -> Void)?       // → recognizer
    private var dragButton: CGMouseButton?

    // .defaultTap so we can MODIFY; headInsertEventTap; listens for
    // left/right/other mouse down/up + mouseMoved.
    private let callback = { type, event in
        // 1) maintain physicalClickActive from real left/right down/up
        // 2) if dragButton != nil and type == .mouseMoved:
        //      rewrite to matching …MouseDragged with dragButton, pass through
        // else pass through unchanged (we do NOT suppress physical clicks in v1)
    }
    func beginDragPromotion(button: CGMouseButton) { dragButton = button }
    func endDragPromotion() { dragButton = nil }
}
```

Notes:
- **Location** for synthesized events is the *current cursor* position, not the
  finger's shell position (finger ≠ cursor).
- The tap is **pass-through except in two narrow cases**: the move→drag rewrite
  above, and the **de-confliction swallow** — a physical button-down consumed while
  a synthetic hold owns the pointer, plus its matching up (`shouldSwallow`; docs/14
  §Click/drag de-confliction). Outside a synthetic drag every physical click still
  passes untouched. That is **not** Feature A: blanket suppression stays deferred
  (§Suppress physical clicks), and would additionally swallow clicks with no drag in
  flight.
- `CGEvent.post` and tap callbacks run on the serial output/recognition queue.

## Suppress physical clicks (Feature A — deferred; design capture)

**Status: not scheduled.** Captured so the cost is legible if it's ever requested.
The risk below is real and there is no current need, so this stays a future item;
what follows is everything we know about *how* to tackle it — not a build plan.

**Goal.** Optionally **consume** the hardware left/right click so tap-to-click
*replaces* rather than *adds*. The machinery already exists: the active
`EventInterceptor` (`handle(type:event:)`) sees every physical down/up and today
passes them through. Suppression returns `nil` for those events behind an opt-in
flag, gated on tap being enabled.

### Measurement first (gates the mechanism)

Course-correcting on data is expected, but one unknown gates the whole design, so
measure it before speccing the mechanism — with the dev harness (`mb-dev
log-gestures`, docs/13):

- Log touch frames **and** physical click events with timestamps under Mode-1
  conditions: rest a finger then click; click *cold* with no resting finger; fast
  clicks; ⌘/⇧/⌃-clicks.
- Characterize: (a) does **every** shell click coincide with a touch contact;
  (b) the lead time between contact-resume and shell actuation on a *cold* click;
  (c) the frame rate.

Why it matters: the click is a dome switch under a capacitive shell, so a finger in
contact necessarily precedes/accompanies actuation — a click with **zero** frames
should be near-impossible, and "no frames for N s" should reliably mean *hand is off
the mouse*, not *a click is imminent*. The open number is the cold-engage timing
(b), which decides whether the frame-idle disengage (below) is viable and whether
the first click after re-engage leaks through as physical.

### The inert-vs-re-emit fork (decide before building)

A shell click is disqualified from being a tap (`requireNoPhysicalClick`). So if we
suppress the physical click and it can't become a tap, **pressing the shell produces
nothing** — inert shell, tap the only click path. Coherent, but a habitual presser
gets silence. Two readings:

1. **Inert shell** — suppress and emit nothing. Simplest; surprising for pressers.
2. **Re-emit (recommended)** — suppress the physical event but synthesize a zone
   click in its place, **carrying the live `CGEventFlags`** so ⌘/⇧/⌃/⌥-click keep
   working. More faithful; more machinery — and it's where the modifier work lives.

### Correctness hazards (all live only in this mode)

- **Modifier / chord clicks.** ⌘-/⇧-/⌥-click must keep their modifiers. Under
  re-emit, flags are copied onto the synthetic click at emit time; under inert, the
  modified press is simply lost. **Biggest correctness risk.**
- **⌃-click is a secondary click** on macOS. Suppressing physical left and
  re-emitting left silently changes ⌃-click's meaning — preserve or re-derive it.
- **Device scoping.** Suppress only clicks originating from the Magic Mouse. A
  trackpad or a second plain mouse must pass through untouched — we can't replace
  *their* clicks with taps (multiple mice is already supported, docs/00).

### Safety — two tiers

Consuming every click is far riskier than the v1 promotion tap: an orphaned or
wedged consuming tap means **all clicking wedges system-wide** (§Interceptor
lifetime). Split the story:

- **Load-bearing (must-have; touch-independent).**
  - Reconcile suppression on the exact edges the tap already uses — disable /
    Accessibility-revoke / device-loss each **restore passthrough** (same seams as
    §Interceptor lifetime).
  - A **keyboard panic shortcut** that force-restores passthrough — works even when
    the mouse appears dead.
  - A **watchdog on the output/recognition queue** so a hung callback can't hold
    every click hostage.
- **Optional (measure-first).** **Frame-idle disengage:** restore passthrough after
  N s with no touch frames; re-arm on next contact. Convenience only — its viability
  and the first-click-leak-on-re-engage question both depend on the measurement
  above. Do **not** make correctness depend on it.

### Prerequisite

Feature B (§ click/drag de-confliction, `14-post-v1.md`) is effectively a
prerequisite: this mode must never let a stray physical event corrupt an in-flight
synthetic drag, and B defines that arbitration — for both drag styles — first, in
the shipping additive product.

## Testability

- `SpyEmitter: ButtonEmitting` records calls → the recognizer→policy→emitter
  chain is verified with zero OS events.
- The `EventInterceptor`'s move→drag rewrite is unit-tested by feeding it
  synthetic `CGEvent`s and asserting the transformed type/button.
- Real end-to-end drag/double-click gets a manual/integration pass on the
  attached Magic Mouse (this machine — see `04-multitouch-backend.md`).
