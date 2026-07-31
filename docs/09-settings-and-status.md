# Settings & Status View

A single Settings window (opened from the menu-bar item) with three regions:
**Features**, **Status & Diagnostics**, and **Advanced**. Plus the always-listed
menu-bar controls and the separate visualizer window (`06-visualizer.md`).

## Features (per-feature enable/disable)

Independent toggles, each a distinct capability the user can turn on/off:

| Toggle | Trigger | Effect |
|--------|---------|--------|
| **Middle click** | *physical click* while finger is in the middle zone | emits middle button (`.otherMouse*`) |
| **Tap-to-click** | *tap* in the left / right zone | emits left / right button |
| **Middle tap-to-click** | *tap* in the middle zone | emits middle button |

All three inherit **double-click** and **drag** automatically
(`03-gesture-recognition.md`); they are not separate toggles in v1. The drag
*style* (**tap-and-a-half** default / **press-and-hold**) is a single global
**Advanced** setting, not per-feature.

Global **master enable** (also in the menu bar) gates everything. Per-app
profiles are roadmap (`10-roadmap.md`); the policy layer is structured to accept
a frontmost-app signal later, but v1 exposes only global state.

Feature enablement is applied by the **policy** layer (`FeaturePolicy` in
`AppCore`), which filters `ButtonGesture`s by zone/kind before calling the emitter
— the recognizer itself stays feature-agnostic. Exception: **Middle click** is a
*physical* click, which `03 §Physical-click input` treats as "no tap" (not a
`ButtonGesture`); it is realized as a CoreGraphics rewrite in the interceptor
(Phase 7.4), so `FeaturePolicy.allows(_:)` gates only the two tap features. The
`middleClick` flag still lives on `FeaturePolicy` so the feature set persists as
one value.

## Status & Diagnostics

Live panel so the user can see the system is healthy and fix it when it isn't.
Requested explicitly; complements (does not replace) the first-run flow
(`07-permissions-distribution.md`).

Shows:

- **Attached device(s):** each detected Magic Mouse — name, generation (v1/v2 if
  determinable), and which is **active**. "No Magic Mouse detected" state when
  none. Multiple mice are listed (see backend doc); v1 supports several present.
- **Permissions:** Accessibility — the only required grant (Input Monitoring was
  dropped in Phase 9, `08 §C`) — with a status (✓ granted / ✗ missing) and, when
  missing, a **Grant** button that registers the app and deep-links to the exact
  pane plus one line of what to do.
- **Backend health:** whether the multitouch stream is delivering frames; a
  visible warning if the private-framework layout check failed on this OS
  ("unsupported macOS build") instead of silent breakage.
- **Errors:** most recent `TouchSourceError` / interceptor tap failures, in plain
  language with a suggested action.

Design intent: a user who grants nothing should still open Settings and
immediately understand *what* is wrong and *how* to fix it, one click from each
fix. Re-checks on window focus and on device attach/detach notifications.

## Advanced

Collapsed by default. Power-user tuning, all persisted:

- **Zone boundaries** — `leftEdge` / `rightEdge` sliders, ideally with a live
  mini-visualizer and draggable handles (`06-visualizer.md` calibration).
- **Timings & thresholds** — `maxDuration`, `maxTravelMM` (shown in mm), `maxSize`,
  `doubleTapGap`, `holdThreshold` (`GestureConfig`).
- **Drag style** — `tapAndAHalf` (default) / `pressAndHold` picker
  (`GestureConfig.dragStyle`; `03 §Drag styles`). Global, not per-feature. In
  `pressAndHold`, `maxTravelMM` doubles as the press *stillness* budget and
  `holdThreshold` as the press duration.
- **Wait for a second tap before clicking** *(post-v1 — `10-roadmap.md`)* — the
  `.deferred` click timing (`03 §Click timing`), an **orthogonal** toggle. Removes
  the double-click-before-drag from `tapAndAHalf` at the cost of ~`doubleTapGap` of
  single-click latency. Specified but not built in v1.
- Reset-to-defaults.

Starting values (from `03`) are as good as any; this section exists because they
*will* need per-user tuning after real-world testing.

**Applied live, no rebuild.** Every Advanced edit takes effect immediately; the
recognizer is updated in place so an in-flight synthetic hold survives — you can even
drag these sliders *with* MagicButtons itself, and the zone-edge preview tracks as you
drag (`05 §Live tunable edits keep an in-flight hold`).

**Mouse handedness is inherited, not configured here.** If a Magic Mouse user moves the
secondary click to the left side (System Settings → Mouse), MagicButtons swaps its
left/right zones to match, automatically and within ~1.5 s — there is no separate
control (`05 §Mouse handedness`).

## Persistence & sync

- v1 persistence: `Codable` config structs (`ZoneLayout`, `GestureConfig`,
  feature flags) in `UserDefaults`.
- **Settings transfer across machines** — **v1: Export / Import JSON file**
  (one file the user copies between Macs; account-free, user-controlled). iCloud
  key-value sync (`NSUbiquitousKeyValueStore`) is roadmap (`10`), avoided in v1
  because it adds an iCloud entitlement/container we otherwise don't need.

## Menu-bar item

- Master enable/disable, open Settings, open Visualizer, quit.
- Reflects health at a glance via the glyph (`AppModel.menuBarIcon`): the app's own
  **filled** mouse when active, the **hollow** line-art mouse when disabled, a system
  warning **triangle** when degraded (missing permission / backend down). The two custom
  symbols (`magicbuttons.mouse{,.fill}`, sourced from `magicbuttons-{fill,outline}.svg`)
  are authored with **winding-based holes** — the SF Symbol renderer ignores
  `fill-rule="evenodd"`, so even-odd holes vanish at compile time. The label only
  re-renders on state change when it reads an `@State`-owned model (`AppModel.shared`),
  not `delegate.model`; menu-bar `.opacity()` doesn't survive template rendering, so
  states differ by glyph (fill vs outline), not dimming. App icon: an Icon Composer
  `.icon` (`AppShell/magicbuttons.icon`). See docs/14 §App icon + custom menu-bar symbols.

## Login item

Ship as a **Login Item** via `SMAppService` so the utility is present after
restart (expected for a background input utility). Toggle in Settings.
