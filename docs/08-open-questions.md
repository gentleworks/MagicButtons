# Decisions & Open Questions

## Resolved (recorded for the build)

| # | Question | Decision |
|---|----------|----------|
| 1 | Link-time vs runtime symbol resolution | **Runtime `dlsym`, scoped to the multitouch contact stream only.** Everything else public/link-time. (`04`) |
| 2 | Physical-click detection source | **Public event tap** (`EventInterceptor`), not the private frame bit — it's the signal that matters downstream and is less fragile. (`03`,`05`) |
| 3 | Suppress hardware clicks? | **No in v1** — additive only, avoid duplication. Suppression → v2 (`10`). |
| 4 | Middle-click while hardware click held | **Gated off** via `requireNoPhysicalClick` (accepted default). (`03`) |
| 5 | Drag support | **Required for v1**, all three features. Tap-and-a-half; needs active tap to promote moves→drags (`05`). May be built after clicks/double-clicks (see build plan). |
| 6 | Double-click | **Required for v1**, all three features. `click(count:)` + state machine (`03`,`05`). |
| 7 | Multiple mice / v1+v2 generations | **Supported in v1.** Subscribe to all Magic Mice, tag touches with `deviceID` (`04`). |
| 8 | Explicit multi-finger gestures | **Roadmap.** v1 only rejects problematic multi-finger cases if testing shows them. |
| 9 | Global vs per-app | **Global in v1**; policy layer kept single so per-app slots in later (`10`). |
| 10 | Login item | **Yes**, `SMAppService` (`07`,`09`). |
| 11 | Per-feature enable in Settings | **Yes** — middle click / tap-to-click / middle tap-to-click independent (`09`). |
| 12 | Status/diagnostics in Settings | **Yes** — devices, permissions + fix assistance, backend health, errors (`09`). |

## Resolved with background

### A. Vertical (`y`) zone component — **Decided: `x`-only zones + optional `y` rejection band**

**Decision:** button zones stay **`x`-only**; add an optional **`y` active-band
for tap *rejection* only**, off by default, in Advanced settings, calibrated from
real data post-bring-up. Rationale below.

**What `y` represents:** front (fingertip / click end) → back (palm end) of the
shell. The whole top is touch-sensitive *and* clickable.

**Apple's own behavior:** left/right click discrimination is **purely x-based**
(which half the finger is on). There is **no y component** to standard clicking,
so the user's mental model of "where to click" is x-only.

**Two possible uses of `y`, very different in value:**

1. **Rejection / active-band (low risk, real benefit).** Ignore taps whose
   begin-`y` falls outside a comfortable band — e.g. the extreme front lip or the
   rear where the palm rests. This reduces *accidental* taps (tap-to-click is a
   light trigger) **without** changing the button model. Defensible.
2. **Extra buttons via front/back split (high risk).** Subdividing zones in `y`
   to add more buttons. Problems: the Magic Mouse is shallow front-to-back, so
   targets get cramped and error-prone; fingers naturally travel in `y` during
   normal use (reaching to click, resting back), making `y` a noisier intent axis
   than `x`.

**The decisive interaction — scrolling.** Vertical finger motion on the shell
*is* the scroll gesture. `y`-based zones risk confusing a scroll start with a
zone selection. **`x`-based zones are orthogonal to vertical scroll; `y`-based
zones are not.** This alone argues for keeping button zones `x`-only.

**Why (the reasoning behind the decision):**
- **Button zones `x`-only** matches the hardware's own left/right logic and stays
  orthogonal to vertical scroll (a `y`-split would collide with scroll-gesture
  detection).
- The optional **`y` active-band** captures the reliability win (fewer accidental
  taps from the front lip / palm-rest rear) without the cost of cramped 2D targets
  or the scroll conflict.
- `ZoneLayout` gains a `yRange` without breaking callers, so the band is added
  **post-bring-up**, calibrated from **real false-tap data** — not part of the
  initial build.

### B. Settings transfer across machines — **Decided: export/import JSON for v1**

**Decision:** **Export/Import JSON file** in v1 (simplest, account-free,
user-controlled). **iCloud key-value sync → roadmap** (`10`), since it adds an
iCloud entitlement/container we otherwise avoid.

## To determine empirically during bring-up (not design decisions)

- **`MTTouch` struct layout, `state` values, surface dimensions** on the target
  OS — verify on this machine's attached Magic Mouse first (`04`).
- **Default zone boundaries** (`0.38 / 0.62`) — calibrate from real contact data.
- **Tap/drag thresholds** (`maxDuration`, `maxTravel`, `maxSize`, `doubleTapGap`,
  `holdThreshold`) — tune on hardware; all exposed in Advanced settings.
- **Multi-finger false positives** — whether v1 must actively reject any patterns.
- **Magic Mouse v1 vs v2 property differences** — only needed for the Status
  view's generation label, not correctness.

### C. Is Input Monitoring actually required? — **RESOLVED (Phase 9): No. Dropped.**

**Decision:** Input Monitoring is **not** required and has been **removed** from the
permission model, menu, Status pane, and first-run flow. **Accessibility is the sole
TCC grant** (for the CGEvent tap: physical-click detection + posting clicks).

**How it was settled.** Clean-machine testing (a fresh Mac, never granted Input
Monitoring, app absent from the pane) confirmed the 7.5 hypothesis: touching the
Magic Mouse produced live finger contacts in the Visualizer, so the private
`MultitouchSupport` contact-frame path is **not** gated by the Input Monitoring TCC
toggle. Worse, the check was actively harmful:
- `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)` reported **granted spuriously**
  (a false positive) even though nothing was granted and the app wasn't listed.
- `IOHIDRequestAccess(...)` (the "Fix Input Monitoring" action) **did not register
  the app** in the Input Monitoring pane, so the user landed on an empty pane with
  nothing to toggle — a dead end.

**Also fixed alongside (same clean-machine session):**
- **Launch-time enumeration race** — a Bluetooth Magic Mouse not yet enumerated when
  `MultitouchSource.start()` first ran left "No Magic Mouse detected" until a
  relaunch (no hot-plug attach fires for an already-connected mouse). The app now
  re-enumerates on the status poll whenever it's running without a connected device.
- **Mid-run Accessibility grant** — the event tap and menu/Status messaging were
  bound at launch and never re-derived, so a just-granted permission read as green
  while stale "grant Accessibility" / "No Magic Mouse" text persisted. The tap is now
  retried in place (`AppCoordinator.retryStream`), with a "Quit & Reopen" fallback
  (`AppModel.needsRelaunch` + `relaunch()`) when the in-place retry can't install it.

### D. Can a stranded synthetic hold wedge the mouse? — **RESOLVED (post-v1): prevented, not recovered.**

**Trigger observed.** Revoking Accessibility *during* a synthetic hold left a button
stuck down system-wide (cursor stuck, clicks read as drag-end). Posting needs
Accessibility, so the button-down had landed but the compensating up could no longer
post; the still-live tap kept promoting the user's real moves into drags, sustaining
the lockup until the process was killed.

**Decision.** Since the down and up both need Accessibility and the grant can vanish
between them, once it's gone the up cannot post — so recovery is impossible and the
safeguards *prevent the held state* instead (docs/05 §Stuck-button safeguards):
`press` guards on `AXIsProcessTrusted()` (never open a hold we can't close), `release`
is idempotent, and **device loss releases an in-flight hold** (`refreshDevices →
cancelActiveHolds`), covering the disconnect-mid-drag case where no `.ended` arrives.

**Frame-silence watchdog — measured and rejected.** A watchdog that force-releases
when frames for the held contact stop was considered, then killed by measurement
(`mb-dev probe-cadence`): the multitouch stream is delta-driven, so a **motionless
finger legitimately goes silent for seconds** (worst gap ~4 s with a finger resting in
full contact). Silence ≠ lift; any useful timeout would drop a paused drag. `.ended`
is reliable on real lifts and remains the primary release signal.

**Further hardening (post-v1).** A residual variant — the tap wedging clicks with **no
hold active**, e.g. revoking Accessibility while the app is merely *disabled* — is closed
by scoping the tap's lifetime: it's installed only while running + master-enabled +
Accessibility-granted, and pulled on the revoke transition, so a disabled or unauthorized
app holds no tap to orphan (docs/05 §Interceptor lifetime, docs/14).

**HW-verified (2026-07-14):** on the Magic Mouse — a normal tap-and-a-half drag works
unchanged (guard-on-trusted is invisible with Accessibility granted), and powering the
mouse off mid-drag drops the drag cleanly with no stuck button (device-loss release).

### E. Can a *successfully enumerated* stream go deaf? — **RESOLVED (post-v1): yes; recovered on wake + a click cross-check.**

**Trigger observed (2026-07-25).** A 1.1.1 instance up for two days across many
sleep/wake cycles stopped showing contacts in the visualizer and stopped synthesizing
clicks, while the menu still read Active. The process was healthy (`sample` showed
`mt_ThreadedMTEntry` parked in its runloop, main thread idle), the Magic Mouse was
connected, and a **fresh process** driven from `mb-dev dump-frames` enumerated the
mouse (`5152×9056`) and received contacts *at that moment*. So the system-wide stream
was fine and only the running instance's subscription was dead.

**Why nothing recovered it.** `AppCoordinator.isDeviceConnected` latches true on a
*successful enumeration* — `MTDeviceCreateList` returned a portrait surface and
`MTDeviceStart` was called — not on frames arriving. The App's self-heal is gated on
`!isDeviceConnected`, so once the flag latched against a handle that later went stale
it never fired again. `DeviceMonitor` didn't help either: a Bluetooth Magic Mouse can
re-register without the IOHIDDevice add/remove pair it watches. And the menu-bar toggle
can't help *by design* — `setEnabled` scopes the event tap, never the touch source — so
the one thing a user naturally tries is guaranteed not to work.

**Decision: two precise triggers, still no silence watchdog.** §D's measurement stands
— the stream is delta-driven and a motionless finger goes silent for seconds, and an
*untouched* mouse is silent indefinitely, so silence can neither stand in for a lift nor
for a dead stream. A plain watchdog would also re-enumerate on a loop all night and,
because re-enumeration resets `hasReceivedFrameSinceStart`, would leave the Status pane
permanently alarming. Instead:

1. **Wake hook.** `NSWorkspace.didWakeNotification → AppCoordinator.refreshDevices()`.
   Sleep is the moment the handle actually goes stale, so this is a hook at the cause
   rather than an inference from the symptom.
2. **Physical-click cross-check** (`StreamHealthMonitor`). A Magic Mouse cannot be
   physically clicked without a finger on its touch surface, so a click that arrives
   with no contact frame near it is *proof* the stream is dead — and it is only
   observable while the user is actually using the mouse, never while idle. Recovery is
   rate-limited, and vetoed while a hold is in flight (re-enumeration lifts holds per
   §D, which would drop a paused drag — the same motionless-finger case that killed the
   watchdog).

**Status-pane consequence.** `touchesNotArriving` alone only ever meant "no frame since
(re)start", which an untouched mouse satisfies too; with re-enumeration now happening on
every wake it would have alarmed after each sleep. The App therefore requires the cross-
check's proof before surfacing it, which also makes the existing message honest — by the
time it shows, a re-subscription has already been tried and failed.
