# Build Plan (v1 — HISTORICAL)

> **Frozen v1 record.** Phases 0–9 are complete and HW-verified; v1 has shipped
> (notarized DMG, clean-machine validated). This document is **no longer updated** —
> it stands as the v1 build history. Post-v1 work is logged in `14-post-v1.md`;
> forward-looking candidates live in `10-roadmap.md`. Everything below is either
> **done + tested**, or **measured & rejected** (noted inline), or **moved to future
> consideration** and carried forward in those two docs.

Milestone-by-milestone, ordered so a **shippable click/double-click core exists
early** and **drag lands last on a confirmed functional base** (drag is the
riskiest piece — active tap + move→drag promotion, verified across real apps).

Legend: **HW** = needs the attached Magic Mouse; **—** = hardware-free (CI-able).

| Phase | Focus | HW? | Depends on |
|-------|-------|-----|-----------|
| 0 | Scaffolding | — | — |
| 1 | Domain core + simulated source | — | 0 |
| 2 | Gesture engine: single click | — | 1 |
| 3 | Event output: click + interceptor skeleton | HW (manual verify) | 1,2 |
| 4 | Private adapter bring-up | HW | 1 |
| 5 | Visualizer | HW (best) | 1,4 |
| 6 | Double-click | — (unit) / HW (verify) | 2,3 |
| 7 | App shell: settings, status, permissions | HW | 3,4,6 |
| 8 | **Drag** | HW (heavy iteration) | 7 |
| 9 | Hardening & distribution | HW | 8 |

Phases 1–2 and 6 are pure logic and fully unit-tested. Phases 3–5, 7–9 need the
mouse; the dev machine (Magic Mouse on target OS) is the bring-up/verification
target.

---

## Phase 0 — Scaffolding ✅ *(done)*
- SwiftPM package with all targets: `TouchKit`, `MTPrivate` (C shim),
  `MultitouchAdapter`, `GestureEngine`, `EventOutput`, `Visualizer`, `App`, plus
  `GestureEngineTests`, `EventOutputTests`.
- Dependency graph enforced (only `MultitouchAdapter` sees `MTPrivate`).
- **Exit:** empty project compiles; CI runs the (empty) test targets.
- *As built:* `App` is an **executable target in the package** (a console stub)
  for now — the thin Xcode app target/workspace is deferred to Phase 7 (see
  `12-project-setup.md`). `swift build` + `swift test` green.

## Phase 1 — Domain core + simulated source ✅ *(done, hardware-free)*
- `TouchKit`: `SurfaceTouch` (+`deviceID`), `TouchPhase`, `MouseZone`,
  `ZoneLayout`, `TouchSource`, `TouchSourceError`, `MouseDeviceID`.
- `SimulatedTouchSource` + a `Codable` frame-recording format for replay.
- **Exit:** can script `[[SurfaceTouch]]` and replay it through `TouchSource`.
- *As built:* `SurfaceTouch`/`TouchPhase` gained `Equatable` + `Codable` (needed
  by the `TouchRecording` format); replay is synchronous/deterministic. Verified
  by a new `TouchKitTests` target (`02-domain-model.md`, `01-architecture.md`).

## Phase 2 — Gesture engine: single click ✅ *(done, hardware-free, TDD)*
- `MouseGestureRecognizer` with the **tap primitive** and **single click only**
  (`click(zone, 1)`); `GestureConfig`.
- `SpyEmitter` in tests. Cover: valid tap, too-long, too-far, too-big,
  physical-click-active rejection, zone-at-began.
- **Exit:** scripted frames → correct `ButtonGesture.click(_,1)`; green tests.
- *As built:* `ButtonGesture` (incl. the deferred `count: 2` / `hold*` cases) and
  `GestureConfig` added; recognizer tracks per-contact state keyed by
  `(deviceID, id)`, captures zone at `.began`, and judges duration/travel/size
  over the whole contact life. `cancelActiveHolds()` is a documented no-op until
  Phase 8. Nine `TapPrimitiveTests` (incl. a mid-contact size spike and a
  no-`.began` contact) via a `GestureSpy` + per-frame `physicalClickActive`
  scripting. `swift test` green (18 tests).

## Phase 3 — Event output: click mechanism + interceptor skeleton ✅ *(done; HW manual verify passed)*
- `ButtonEmitting`/`CGEventEmitter.click(count:)` (public CoreGraphics).
- `EventInterceptor` active tap: **physical-click detection only** (pass-through;
  no drag promotion yet). Feed `physicalClickActive` into the recognizer.
- **Exit (met):** with permissions granted, a tap in a hard-coded zone produces a
  real click in another app. Physical clicks are detected and not duplicated.
- *As built (code):* `ButtonEmitting` protocol (`click`/`press`/`release`);
  `CGEventEmitter` posts to `.cghidEventTap`, sets `mouseEventClickState` for
  double, and stamps `.eventSourceUserData` with a synthetic marker so the
  interceptor ignores our own posts. `press`/`release` emit the button down/up
  now (the move→drag promotion that makes them *drag* is Phase 8).
  `EventInterceptor` is an active `.defaultTap` (pass-through in v1) that feeds a
  pure `PhysicalClickTracker` and fires `onPhysicalClickChange` on real
  transitions; re-enables itself on `tapDisabled*`; throws
  `EventInterceptorError.tapCreationFailed` (→ Accessibility permission flow).
  Testable seams extracted: `ButtonMapping` (zone→button/type table) and
  `PhysicalClickTracker` — 8 hardware-free tests, `swift test` green (24 total).
- *Manual verify (passed, on the Magic Mouse):* harness lives in the `App`
  executable (`verify-emit`, `verify-tap`; `setvbuf` unbuffered, bounded run so it
  can't hang). With Accessibility granted to the hosting terminal:
  `verify-tap` logged 8 clean `physicalClickActive true→false` transitions with no
  duplicated clicks; `verify-emit right` popped a context menu in the focused app;
  `verify-emit left 2` selected a word (confirms `mouseEventClickState = 2`).
  Middle uses the same proven `.otherMouse*` path. Harness needs the terminal's
  Accessibility grant; the shipping app's own first-run prompt is Phase 7.

## Phase 4 — Private adapter bring-up ✅ *(done; 2nd-mouse HW test since PASSED in 9.4)*
- `MTPrivate` shim; **debug dump mode** (raw frames + `sizeof`) to **verify
  struct layout / `state` values / surface dimensions** on the target OS.
- `MultitouchSource` via `dlopen`/`dlsym` (scoped to the touch stream); device
  enumeration; Magic Mouse identification; **multi-device tagging** with
  `deviceID`; startup sanity checks; hot plug/unplug.
- **Exit:** real finger frames flow as `SurfaceTouch`; layout guard passes;
  two-mouse case keeps contacts separate.
- *As built + verified on hardware (via `dump-frames` then `verify-source`):*
  - **`MTBackend`** resolves the private symbols with `dlopen`/`dlsym` (no
    link-time private linkage), throwing `.backendUnavailable` if any is missing.
    Learned the hard way that **`MTDeviceCreateList` returns an autoreleased (+0)
    array** — `.takeRetainedValue()` over-releases → CFRelease `SIGTRAP`; fixed to
    `.takeUnretainedValue()` + keep the list alive + never `MTDeviceRelease` list
    devices.
  - **Struct layout confirmed:** `sizeof(MTTouch) == 96`; normalized coords come
    out sane (`0…1`, tracking the finger). Pinned `96` as the startup guard.
  - **Phase mapping pinned empirically** (`PhaseMapping`): raw `state` `3→began`,
    `4→moved`, `5/6/7→ended` (a contact lives `3→4…→5→6→7`, `major`→0 at 7). The
    repeated `.ended` frames are deduped by the recognizer (finalize on first,
    ignore the rest). `.stationary` is not emitted (state 4 → `.moved`).
  - **Magic Mouse identification:** sensor is **portrait** (`w < h`); trackpads
    are landscape. Confirmed mouse `5152×9056` (family `0x70`) vs trackpad
    `15780×9780` (family `0x69`). Trackpad correctly excluded — no leaked contacts.
  - **`MultitouchSource`** conforms to `TouchSource`, tags each `SurfaceTouch`
    with its device's `MouseDeviceID`, hops frames onto a serial queue, guards
    `sizeof`, and errors `.noDevice` / `.backendUnavailable`. `verify-source`
    showed correct began/ended + zone for left/middle/right taps, single device.
- *Deferred at Phase 4 — all since resolved (pointers below):*
  - **Two-mouse separation** was handled by construction (per-device `deviceID`
    keying + registry) but not yet demonstrated on hardware — needed a second
    Magic Mouse. ✅ **Resolved in 9.4:** `verify-two-mouse` HW gate PASSED (two mice,
    concurrent separation + id-collision exercised). See [[phase-completion-gates]].
  - **Hot plug/unplug** re-enumeration was deferred to Phase 7 (coordinator/status own
    the device-change signal). ✅ **Resolved in 7.4** (device-change re-enumeration +
    safety release, covered by `AppCoordinatorTests`; see "Track 2 done") and hardened
    in **9.6** (launch-time enumeration race for an already-connected BT mouse).
  - **`size` scale:** `major` runs ~8–10, not `0…1`, so `GestureConfig.maxSize` had to
    be recalibrated before the recognizer met the real source. ✅ **Resolved:** default
    is now **14** (Phase 7), and **9.1** validated it against a logged HW session
    (all contacts ≤ 11.05). ([[touch-size-scale]])

## Phase 5 — Visualizer ✅ *(done; HW manual verify passed)*
- SwiftUI finger dots + zone bands + live active-zone (hysteresis); `y`-flip at
  the view boundary; fed from the real stream.
- Doubles as the **tuning instrument** for zone/threshold defaults.
- **Exit:** live, accurate finger/zone picture on real hardware.
- *As built (code, hardware-free parts tested):*
  - **`ZoneMapper`** (hysteresis active-zone readout, ±0.02) lives in **`TouchKit`**,
    not `GestureEngine` where `01-architecture` first grouped it: `Visualizer`
    depends only on `TouchKit` (docs/06 non-goal: no recognizer dependency) so
    can't reach `GestureEngine`. Putting it in the shared vocabulary lets both
    consume one implementation, so the picture and behavior can't drift. The
    recognizer still judges by the `began`-time zone and doesn't use it. 7 tests.
  - **`VisualizerModel`** is modeled with Apple's current **`@Observable`** rather
    than docs/06's illustrative `ObservableObject`/`@Published` (macOS 14 + Swift 6);
    same public surface plus an `activeZone` readout. First live (non-`.ended`)
    contact is the "primary" that drives the highlight. 7 `@MainActor` tests.
  - **`VisualizerView`** — aspect-locked portrait shell (5152×9056), three tinted
    zone bands (HStack, widths from the live `ZoneLayout`) clipped to a rounded
    outline, dashed boundary lines, a phase-colored dot per contact with the `y`
    flipped once at the drawing boundary, and a caption showing active zone +
    contact count. `size` (~8–10, not `0…1`) is scaled into the dot diameter. A
    hardware-free `#Preview` renders a scripted frame.
  - **Harness:** `MagicButtons visualize` opens a live `NSHostingView` window fed
    from the real `MultitouchSource` (frames marshaled to main); `visualize sim`
    drives a synthetic `SweepSource` so the view runs with no hardware. Sits beside
    the other `verify-*` tools in the `App` executable until the Phase 7 app shell.
  - `swift build` + `swift test` green (38 tests, +14).
- *Manual verify (passed, on the Magic Mouse):* `MagicButtons visualize` put a
  live window on screen; finger dots and the active-zone highlight tracked a real
  finger accurately — right-side-up (`y`-flip correct) and in the correct zone.
  First real look at the zone/threshold defaults, carried into the Phase 9 tuning
  pass.

## Phase 6 — Double-click ✅ *(done; HW manual verify passed)*
- Extend the state machine `WAIT_SECOND`→`click(zone, 2)`; emitter sets
  `mouseEventClickState`.
- **Exit:** scripted double-tap → `click(_,2)`; a real double-tap triggers a
  genuine double-click (e.g. selects a word) across a couple of apps.
- *As built (code, hardware-free parts tested):*
  - `MouseGestureRecognizer` now runs the **WAIT_SECOND** half of the per-zone
    machine, implemented **lazily** (no timer): a completed tap emits
    `click(Z,1)` immediately **and** arms `pendingClickEnd[Z] = endTime`. When the
    next contact `.begins`, that zone's entry is consumed — claimed as the second
    tap iff `began − firstEnd ≤ doubleTapGap`, otherwise dropped as expired
    (WAIT_SECOND→IDLE). A second tap in the **same zone within the gap** finalizes
    as `click(Z,2)` and returns to IDLE (in Phase 6; the post-v1 triple-click change
    below instead continues the run to `click(Z,3)`);
    a second tap in a **different zone**, or past the gap, is just another single.
    A second contact that begins in-gap but **isn't a valid tap** consumes the
    pending and leaves the first single standing (the held-second→drag branch is
    Phase 8). **No single-click latency** — the first click is never deferred.
  - Emitter side needed **no change**: `CGEventEmitter.click(_, count:)` already
    sets `mouseEventClickState = count` (Phase 3), so `click(_,2)` posts a genuine
    double-click.
  - 5 new `DoubleClickTests` (double-in-gap, two-singles-past-gap, different-zone,
    non-tap second, triple-tap) via the existing frame/spy harness. `swift test`
    green (43 tests, +5).
  - **Harness:** `MagicButtons verify-gesture [seconds]` runs the **whole live
    pipeline** — `MultitouchSource → GesturePipeline(recognizer) → CGEventEmitter`,
    with `physicalClickActive` fed from an `EventInterceptor` (a preview of the
    Phase 7 `AppCoordinator` chain, main-actor-confined). Everything touching the
    recognizer is marshaled to main. It overrides **only** `GestureConfig.maxSize`
    (→100) so real taps pass despite the `majorAxis ≈ 8–10` scale
    ([[touch-size-scale]]); the shipped default recalibration stays Phase 9.
- *Manual verify (passed, on the Magic Mouse):* `verify-gesture` with Input
  Monitoring + Accessibility granted — a real tap produced a single click and a
  real double-tap in one zone produced a genuine double-click (word-select) across
  a couple of apps, as expected.

## Phase 7 — App shell: settings, status, permissions ✅ *(7.0–7.7 done + HW-verified)*
- Menu-bar (`LSUIElement`) app; `AppCoordinator` wiring source→recognizer→policy
  →emitter and interceptor→`physicalClickActive`.
- **Feature policy**: three independent toggles (middle click / tap-to-click /
  middle tap-to-click) filtering `ButtonGesture`s; global master enable.
- First-run permission flow **and** the Status/Diagnostics panel (devices,
  permissions + fix links, backend health, errors).
- Persistence: `UserDefaults` + **Export/Import JSON**; `SMAppService` login item;
  Advanced settings (zones, timings, thresholds).
- **Exit:** a real, usable app — all click & double-click features, per-feature
  toggles, diagnostics, and settings that persist and transfer. **This is the
  confirmed functional base drag builds on.**

### Plan (as scoped)

Ordered so the **hardware-free, TDD-able pieces land first** (like Phases 2/6) and
the app is only assembled once its parts are proven. `7.1–7.3` need no mouse and
are unit-tested; `7.4–7.7` are the on-machine assembly. Full specs live in
`07-permissions-distribution.md`, `09-settings-and-status.md`, and the Xcode-target
migration in `12-project-setup.md` — this is the execution sequence that ties them
together.

- **7.0 — `maxSize` recalibration checkpoint** ✅ *(—, code)*. Before the real
  source is wired to the recognizer, bump `GestureConfig.maxSize` off its `0.60`
  (`0…1`-position assumption) onto the **major-axis scale** (`major` reads ~8–10 on
  a real contact; start ~12–15, tune in Phase 9). Without this **every real tap is
  rejected** and nothing clicks — the one change that must precede `7.4`. Verified
  live in `7.7`. See [[touch-size-scale]]. (Phase 6's `verify-gesture` only patched
  this locally; here it becomes the shipped default.)
  *As built:* shipped default set to **14**; the two size-rejection unit tests moved
  onto the major-axis scale (sizes `20`); `verify-gesture` dropped its local
  `maxSize = 100` override so it now exercises the shipped default.
- **7.1 — Feature policy layer** ✅ *(—, TDD)*. A `FeaturePolicy` filtering
  `ButtonGesture`s by the three independent toggles (middle click / tap-to-click /
  middle tap-to-click) **and** the global master enable, *before* the emitter — the
  recognizer stays feature-agnostic (`09 §Features`). Double-click/drag inherit per
  feature, not as separate toggles.
  *As built:* lives in a new **`AppCore`** package library (pure App-layer logic the
  thin Xcode app + the harness both consume — keeps it CI-testable; also the home
  for 7.2 persistence), depending on `TouchKit` + `GestureEngine`. `allows(_:)` is a
  pure predicate: master-off blocks all; `.left/.right` gated by `tapToClick`,
  `.middle` by `middleTapToClick`; `click(_,2)` and `holdBegan/Ended` gate like
  `click(_,1)` in the same zone. **Reconciliation of a docs tension:** `09` says the
  policy "filters ButtonGestures" for *all three* toggles, but `03 §Physical-click
  input` treats a physical click as "no tap" and `05`'s interceptor is pass-through —
  so **middleClick (physical)** is *not* a tap-derived gesture and `allows(_:)`
  deliberately never consults it; that feature is a CoreGraphics rewrite deferred to
  `7.4`. The flag is still stored on `FeaturePolicy` so the feature set is one
  `Codable` value. 9 `FeaturePolicyTests`; `swift test` green (52 total, +9).
- **7.2 — Persistence** ✅ *(—, TDD)*. One `Codable` settings struct bundling
  `ZoneLayout`, `GestureConfig`, feature flags, and the login-item preference;
  `UserDefaults` load/save; **Export/Import JSON**; reset-to-defaults (`09
  §Persistence`). Bundle ID `com.gentleworks.MagicButtons` is fixed — TCC grants are
  keyed to it, so it must not change (`12 §Identity`).
  *As built (in `AppCore`):* `AppSettings` (zones/gestures/features/`launchAtLogin`)
  + `SettingsStore` over a small `SettingsStorage` seam (`UserDefaultsStorage` in
  prod; an in-memory fake in tests, so persistence is CI-tested without touching the
  real defaults DB). `load()` returns defaults on **missing or corrupt** data (never
  bricks launch); `importJSON` instead **throws** on a non-settings file so the UI
  can report a failed import; `exportJSON` is pretty-printed + sorted-keys for clean
  cross-machine diffs; `reset()` persists defaults. **Forward-compat by lenient
  decode at every level** — a custom `init(from:)` on `AppSettings`, `GestureConfig`,
  `ZoneLayout`, and `FeaturePolicy` fills any missing key (whole section *or*
  sub-key) from defaults, so older/partial JSON imports cleanly; encode still writes
  everything. `launchAtLogin` is the persisted preference only (registration is 7.7).
  14 tests (`SettingsStoreTests`, `AppSettingsTests`); `swift test` green (66, +14).
- **7.3 — Permissions model** ✅ *(—/env, TDD via injected checkers)*. Over Input
  Monitoring (`IOHIDCheckAccess(...ListenEvent)`) and Accessibility
  (`AXIsProcessTrusted`), each → granted/missing + the exact
  `x-apple.systempreferences:` deep-link and one-line fix; missing Input Monitoring
  maps to `TouchSourceError.notAuthorized` (`07`). Re-check on app focus.
  *As built (in `AppCore`):* `Permission` (enum in first-run prompt order, carrying
  title/rationale/fixInstruction/`settingsURL` — `Privacy_ListenEvent` /
  `Privacy_Accessibility`); a pure `PermissionsSnapshot` with the derived
  capability/degradation readout (`canReadTouches` / `canPostClicks` /
  `isFullyOperational`, ordered `missing`, and the `.notAuthorized` mapping); and
  `PermissionsMonitor` (holds the snapshot, `recheck()` fires `onChange` only on an
  actual transition — the App wires it to app-focus in 7.6). The system calls sit
  behind an injected `PermissionChecking` seam, with the real conformer
  (`SystemPermissionChecker`) in `App`, so the model is fully unit-tested without
  TCC. `TouchSourceError` gained `Equatable`. 10 tests. **Live smoke:** the new
  `MagicButtons permissions` harness printed both grants ✓ and exited 0 on the dev
  machine — the full first-run/degradation UI is 7.6. `swift test` green (76, +10).
- **7.4 — `AppCoordinator`** ✅ *(HW manual verify passed)*. Promote Phase 6's `verify-gesture` preview
  chain into the real app object (`@MainActor`): `MultitouchSource →
  GesturePipeline(recognizer) → FeaturePolicy → CGEventEmitter`, with
  `EventInterceptor → physicalClickActive`. Owns lifecycle — start/stop, master
  enable, **safety stop on quit**, and **device attach/detach re-enumeration**
  (carried over from the Phase 4 deferral, lines 119–120).
  *As built:* two new `AppCore` types — `GesturePipeline` (the recognizer→policy→
  emitter core, injectable `ButtonEmitting`, with a symmetric hold/`cancelActiveHolds`
  safety path that never drops a button-up) and `AppCoordinator` (owns source +
  click-source + pipeline; `start`/`stop`, `setEnabled` as a **live policy flag** so
  the streams keep feeding the visualizer while gestures are gated, `apply` for
  settings edits, and `refreshDevices` re-enumeration). Collaborators are injected as
  protocols — added `PhysicalClickSource` in `EventOutput` (`EventInterceptor`
  conforms) — so lifecycle/degradation/master/re-enumeration are all unit-tested with
  a simulated source + fake click-source + spy emitter (**no HW, no real events**).
  Degradation is *recorded, not thrown*: missing device → `sourceError`/`isDevice
  Connected`, failed tap → `interceptorFailed`, app stays up. Hot-plug trigger is a
  new IOKit `DeviceMonitor` in `MultitouchAdapter` (matches all `IOHIDDevice`
  add/remove → `refreshDevices`). `verify-gesture` now runs **through the
  coordinator** (+ `DeviceMonitor`, + a `LoggingEmitter`). 17 tests
  (`GesturePipelineTests`, `AppCoordinatorTests`); `swift test` green (93, +17).
  **Manual verify (passed, on the Magic Mouse):** `verify-gesture` through the
  coordinator — a real single tap produced a single click and a real double-tap
  produced a genuine double-click (word-select) in TextEdit, as expected.
- **7.5 — Menu-bar shell + Xcode-target migration** ✅ *(done; HW manual verify passed)*.
  Migrate `App` from the SPM executable stub to the **thin Xcode app
  target + workspace** (`12 §Packaging`): `Info.plist` (`LSUIElement`, TCC usage strings),
  entitlements + Hardened Runtime, code-signing settings. Menu-bar item: master
  enable/disable, open Settings, open Visualizer, quit; icon reflects permission/health
  state (`09 §Menu-bar`). Keep the `verify-*` / `visualize` dev harnesses reachable where
  practical.
  *As built (code + build):*
  - **Structure — SwiftPM package kept intact; a new thin Xcode *app target* layered on
    top** (not a migration *out* of SPM). The package is unchanged except the dev-harness
    executable product was renamed **`MagicButtons` → `mb-dev`**: when the app project
    embeds the package, Xcode surfaces the package's executable as a scheme, so a shared
    name produced a **duplicate `MagicButtons` scheme** — `mb-dev` disambiguates and also
    reads as "dev harness, not the shipping app." The GUI lives in a top-level **`AppShell/`**
    (outside `Sources/` so SPM never compiles it); `swift run mb-dev …` harnesses still work.
  - **Project generation — XcodeGen.** A committed **`project.yml`** is the source of truth;
    the generated **`MagicButtons.xcodeproj` is gitignored** and rebuilt with `xcodegen
    generate` (README "Building from source", alongside the betterleaks hook — reproducible/reviewable, no drift, contributors bootstrap once). The app target
    embeds the local package (`packages: { path: . }`) and links `AppCore` / `Visualizer` /
    `MultitouchAdapter` / `EventOutput` / `TouchKit`.
  - **Menu-bar shell — SwiftUI `MenuBarExtra`** (`.menu` style): a live status line, the
    master-enable `Toggle`, one **"Fix …"** action per missing permission (first-run order),
    **Open Visualizer**, a native **`SettingsLink`**, and **Quit**. The icon is a
    health-derived SF Symbol (operational / disabled / degraded from permissions + backend +
    master). A **`Settings` scene placeholder** confirms the window opens and shows a live
    permission read — its three real regions are 7.6.
  - **Permission UX corrections (found in HW testing):** "Fix …" must **request** the grant
    (`IOHIDRequestAccess(ListenEvent)` / `AXIsProcessTrustedWithOptions(prompt)`), not just
    deep-link — an app that has only ever *checked* Input Monitoring **never appears in that
    Settings pane**, so there's nothing to toggle. And because an `LSUIElement` app doesn't
    get reliable `applicationDidBecomeActive`, status is refreshed by a **1.5 s poll** while
    running (not focus alone), so the icon/menu clear once a grant is flipped. (Input
    Monitoring still typically needs an app **relaunch** to actually start reading the
    stream even after the toggle — the status clears, but touch reading resumes on relaunch.)
  - **`AppModel` (`@MainActor @Observable`)** owns the production `AppCoordinator` (real
    `MultitouchSource` → recognizer → `FeaturePolicy` → `CGEventEmitter`, physical-click from
    `EventInterceptor`, hot-plug from `DeviceMonitor`), the `PermissionsMonitor`
    (`SystemPermissionChecker`, re-checked on app focus), and the `VisualizerModel`. It
    mirrors the plain collaborators' status into observable properties so the icon/menu stay
    live, persists the master toggle, and drives lifecycle from an `NSApplicationDelegate`
    (start after launch; **safety stop on quit**). Backend-unavailable (a broken private
    layer) degrades to an `IdleTouchSource` so the app still launches and says so, rather than
    failing to start; the common "no mouse" case is already recorded by the coordinator.
  - The **visualizer window is managed imperatively** (AppKit `NSWindow` + `NSHostingView`,
    reused across close) rather than a SwiftUI `Window` scene — an accessory (`LSUIElement`)
    app would otherwise auto-open a `Window` at launch, and the imperative path holds the
    macOS 14 floor. Fed by a **new tested `AppCoordinator.onFrame` tee** so the picture and
    the recognized behavior read the exact same stream (`docs/06`). +1 unit test → **94**.
  - **Bundle/signing config:** `Info.plist` (`LSUIElement`, versioning; deliberately **no**
    `NS*UsageDescription` — Input-Monitoring/Accessibility prompts are system-provided and the
    in-app deep-links do the user-facing work), `.entitlements` (`app-sandbox = false`;
    Hardened Runtime via `ENABLE_HARDENED_RUNTIME`, **no exceptions** — `dlopen` of the
    Apple-signed private framework passes library validation). Swift 6 + complete concurrency,
    macOS 14 (Developer ID + notarize is Phase 9). **All signing lives in an xcconfig
    chain, not `project.yml`** (project settings would override xcconfig): a committed
    `AppShell/Signing.xcconfig` defaults to **ad-hoc "Sign to Run Locally"** (a fresh
    clone builds/runs with no account or cert) and `#include?`s a **gitignored
    `Signing.local.xcconfig`** (template committed as `.example`) that survives `xcodegen
    generate`. **Signing gotcha learned the hard way:** setting `DEVELOPMENT_TEAM` flips
    Automatic signing into demanding a provisioning profile, which fails ("No signing
    certificate 'Mac Development' found …") when no Apple ID account is added to Xcode —
    even though a valid *Apple Development* cert is in the keychain. The local override
    therefore signs **Manually against the cert's SHA-1 hash with no team**, which needs
    no account/profile and yields a stable identity + Hardened Runtime (so TCC grants
    persist across rebuilds). `swift test` green (94); `xcodebuild` builds & signs
    `MagicButtons.app`, which **launches clean** (menu-bar process up, no crash).
  - **HW gate PASSED (2026-07-13, on the Magic Mouse):** all three buttons via tap
    (middle opened a link in a new browser tab), double-tap word-select, master toggle
    gates clicks off/on, **Open Visualizer** shows the live finger/zone window, **Settings**
    opens, and **Quit** leaves no stuck button. **Surprise, logged as an open question
    (`docs/08`):** the app read touches and every tap worked while MagicButtons **never
    appeared in the Input Monitoring list** — Input Monitoring may not be required for the
    private `MultitouchSupport` frame path (only Accessibility is, for the CGEvent tap).
    ✅ **Resolved in 9.6 (`08 §C`):** confirmed on a clean machine — Input Monitoring is
    **not** required and was **removed entirely**; Accessibility is the only grant. See
    [[phase-completion-gates]].
- **7.6 — Settings window** ✅ *(done; HW manual verify passed)*.
  SwiftUI window with the three regions (`09`):
  **Features** (toggles → `7.1` policy), **Status & Diagnostics** (attached
  device(s) + active, permissions with per-pane **Open Settings** links, backend
  health + struct-layout guard result, recent `TouchSourceError`/tap failures;
  re-check on focus + device notifications), **Advanced** (zone-boundary sliders
  with a live mini-visualizer, `GestureConfig` timings/thresholds, reset). Plus the
  **first-run permission flow** (`07`): explainer + deep-link per missing grant,
  **graceful degradation** — Input-Monitoring-only makes the visualizer work while
  clicks don't, surfaced clearly rather than failing silently.
  *As built:*
  - **A tabbed settings window** (`AppShell/SettingsView.swift`) with three panes —
    `FeaturesSettingsView`, `StatusSettingsView`, `AdvancedSettingsView` — replacing
    the 7.5 placeholder. All three are `.formStyle(.grouped)` and bound to **`AppModel`**
    (the `@Observable` façade), never to `AppCoordinator` directly. First-run: it
    **opens to Status** whenever a grant is missing (`isFullyOperational`), otherwise
    Features.
  - **Window managed imperatively, not via the SwiftUI `Settings` scene** (HW-driven
    correction, mirrors `showVisualizer`): `AppModel.showSettings()` owns a reused
    `NSWindow` (`.resizable`, `contentMinSize 460×480`) and the menu item is a plain
    **Button**, not `SettingsLink`. This was necessary because a menu-bar
    (`LSUIElement`) app can't re-front the scene-based Settings window once it's behind
    another app, and that window wasn't resizable — the imperative window activates +
    `makeKeyAndOrderFront` on every open, so it always comes forward and can grow taller.
  - **`AppModel` widened to own the editable config.** A stored, observable
    `settings: AppSettings` mirror is now the UI's source of truth; edits flow through
    `update(_:)` → `coordinator.apply` (rebuilds the recognizer only on zone/tunable
    change) → `visualizer.layout` (keeps the Advanced mini-map live) → persist. A
    generic `binding(_:)` (`WritableKeyPath<AppSettings, Value>`) backs every
    Feature/Advanced control. **Master enable stays special** — `isEnabled` routes
    through `coordinator.setEnabled` for its safety release, which `apply` deliberately
    skips. Added status readouts: `isReceivingTouches` (frames-in-last-2s, recomputed on
    the existing 1.5 s poll via a `@ObservationIgnored` last-frame stamp on the `onFrame`
    tee), `deviceStatus`, `capabilitySummary` (graceful-degradation line), `recentIssue`.
  - **Features pane:** master switch + the three `FeaturePolicy` toggles (tap-to-click /
    middle-tap-to-click / middle physical-click); the button toggles disable when the
    master is off. Double-click/drag inherit their zone (no separate toggles, `03`).
  - **Status pane:** device line, both permissions each with a **Grant…** (calls the
    7.5 `requestPermission` — register+prompt+deep-link) or **Open Settings…** link plus
    rationale/fix text, a backend-health row (backend-unavailable / waiting-on-Input-
    Monitoring / frames-flowing), and a plain-language recent-issue row. Re-checks ride
    the existing focus + `DeviceMonitor` + poll machinery.
  - **Advanced pane:** live `VisualizerView` mini-map above `leftEdge`/`rightEdge`
    sliders (ranges keep a 0.05 gap so the middle zone can't invert), the five
    `GestureConfig` timings/thresholds + the no-physical-click toggle, **Reset to
    Defaults**, and **Export…/Import…** JSON (`SettingsStore.exportJSON`/`importJSON`
    via `NSSavePanel`/`NSOpenPanel`, applied live).
  - **Gesture-flash feedback** (HW-driven addition — there was no on-screen indicator
    that a tap registered while tuning the tap/double-tap tunables): a read-only tee
    `GesturePipeline.onGesture` → `AppCoordinator.onGesture` → `AppModel` fires *before*
    the policy filter, so the visualizer flashes a zone-tinted **"Tap" / "Double-tap" /
    "Hold"** badge even when a feature is off (the honest tuning signal). The Visualizer
    package stays decoupled from `GestureEngine`: it defines its own TouchKit-only
    `VisualizerModel.RecognizedGesture`/`GestureFlash` (auto-clears ~0.9 s), and the
    `ButtonGesture`→flash mapping lives in `AppModel` (the app target gained a direct
    `GestureEngine` dependency for it). A double-tap reads "Tap" then "Double-tap"
    (recognizer emits `click(1)` then `click(2)`).
  - **Scope reduction (→ Phase 9):** the Status device line is a single connected/active
    summary; per-device **names + v1/v2 generation + multi-mouse listing** need a device
    API the private backend doesn't surface yet and land with Phase 9's multi-mouse
    polish. `swift test` green (**100**, +6: gesture-flash mapping + coordinator tee);
    `xcodebuild -scheme MagicButtons` builds clean (no warnings). **HW gate PASSED
    (2026-07-13, on the Magic Mouse):** all Feature toggles gate live, Status reads
    truthfully with working Grant/Open-Settings, Advanced zone sliders move the live
    mini-map + change behavior, timing sliders take effect with the gesture-flash
    confirming recognition, Reset works, and Export→Import round-trips across relaunch.
- **7.7 — Login item + manual-verify exit** ✅ *(HW)*. `SMAppService` login-item toggle
  (`09 §Login item`). Then the **exit gate**: a real, usable app — every click &
  double-click feature works on the Magic Mouse, per-feature toggles gate correctly,
  diagnostics read accurately, settings **persist and transfer** via Export/Import,
  and the login item registers. Stays **🚧 until this on-machine pass** — code +
  unit tests are not the gate for a HW phase. See [[phase-completion-gates]].
  *As built:* `AppShell/LoginItemController.swift` — a thin `SMAppService.mainApp`
  wrapper (`status`/`isEnabled`/`enable()`/`disable()`), app-side like
  `SystemPermissionChecker` so `AppCore` stays pure (no entitlement or helper bundle;
  `SMAppService` is macOS 13+, needs no guard under the 14.0 floor). `AppModel` gained
  `var launchAtLogin` (register/unregister + persist intent + reflect the real
  `.status`), an observable `launchAtLoginEnabled` mirror, and a `launchAtLoginNote`
  (shown on `.requiresApproval` or a register/unregister failure — the checkbox never
  silently disagrees). **Two reconciliation paths keep it honest:**
  `reconcileLoginItem()` at `start()` honors an imported/persisted `launchAtLogin` only
  when the app is `.notRegistered` (so Export/Import *transfers* the behavior without
  ever fighting a user's manual removal); `refreshLoginItemMirror()` — folded into the
  existing 1.5 s permissions poll + app-focus — reflects **external** changes read-only
  (user removes it in System Settings → status goes `.requiresApproval`, toggle flips
  off within ~1.5 s, preference synced), never re-registering. The login item stays off
  the `update(_:)`/`sync` pipeline (touches neither recognizer nor visualizer).
  **UI decision (HW review):** the toggle lives in the **Features** pane's top section,
  clustered with the master **Enable** switch — the two app-lifecycle concepts (*on* /
  *stays on across reboot*), distinct from the button-behavior toggles below; its
  footnote shows a default explainer and swaps to the orange note when attention's
  needed (mirrors the capability line). `swift test` green (**100**, unchanged — the
  seam is app-side/untestable by design, like `SystemPermissionChecker`); `xcodebuild
  -scheme MagicButtons` builds clean. **HW EXIT GATE PASSED (2026-07-13, on the Magic
  Mouse):** all three features **and double-click** work and gate correctly via their
  toggles; login item registers, tracks external add/remove, and unregisters cleanly;
  Status/diagnostics read truthfully; settings **persist across app restarts** and
  transfer via Export/Import. **Phase 7 done — the confirmed functional base Phase 8
  (drag) builds on.**

**Dependency shape:** `7.1` + `7.2` + `7.3` feed both `7.4` (coordinator) and `7.6`
(settings UI); `7.0` gates `7.4`; `7.5` (Xcode migration) is the structural pivot
everything visual sits on. Each sub-step carries its own inline *As built* note
(matching Phases 3–6); **Phase 7 is complete and HW-verified.**

## Phase 8 — Drag ✅ *(done; HW-verified — heavy iteration, last on purpose)*
- Recognizer: `SECOND_ACTIVE` held past `holdThreshold` → `holdBegan`/`holdEnded`
  (tap-and-a-half).
- `EventInterceptor`: **`mouseMoved`→`…MouseDragged` promotion** while a synthetic
  hold is active; `press`/`release` in the emitter; **safety release** on
  disable/quit/device-loss.
- Verify across real drags: Finder icon drag, text selection, window/title-bar
  drag, slider drags — for all three buttons.
- **Exit:** tap-and-a-half dragging works reliably app-to-app; no stuck buttons.

**As built (2026-07-13) — code complete + unit-verified; verified in hardware.**
`swift test` green at **120 tests** (100 baseline + 14 drag + 6 press-and-hold);
`xcodebuild -scheme MagicButtons` builds. The core drag (below) plus the drag-style
addition and the deferred-click spec (both after the note further down). What landed:
- `MouseGestureRecognizer`: the `SECOND_ACTIVE` branch of the per-zone machine now
  promotes to a drag. `ContactState.didBeginHold` latches; `promoteToHoldIfNeeded`
  fires `holdBegan` on the first live `.moved`/`.stationary` frame past
  `holdThreshold` (button goes down *while the finger is still on the shell*);
  `.ended` on a promoted contact emits `holdEnded`. A **frame-starved** second
  contact (only `.began`+`.ended`, held ≥ `holdThreshold`) is guarded in `finalize`
  to emit nothing rather than a phantom press/release or a spurious double-click —
  the first single stands. `cancelActiveHolds()` now emits `holdEnded` for every
  in-flight drag and clears all tracking state (so a late `.ended` for a cancelled
  contact is inert). *(`.moved` covers stationary — adapter never emits `.stationary`
  (docs/04 PhaseMapping) — and the private frame callback streams continuously while
  a contact exists, so a resting second finger reliably produces a frame past the
  threshold.)*
- `EventInterceptor`: added `.mouseMoved` to the observed set; `dragZone` +
  `beginDragPromotion(zone:)`/`endDragPromotion()`; `applyDragPromotion(type:event:)`
  rewrites a physical `mouseMoved` **in place** to the held button's `…MouseDragged`
  (retyped + button-number set) via `ButtonMapping`. Pass-through otherwise — v1 still
  never suppresses physical clicks.
- `CGEventEmitter`: `press`/`release` arm/disarm promotion through a new
  `DragPromoting` seam (`ButtonEmitting.swift`); holds it **weakly** (`dragPromoter`)
  — the coordinator owns both objects, a strong link would retain the tap. Spy-driven
  tests need no promoter.
- Wiring (`AppShell/AppModel`): one `EventInterceptor` instance serves both event-tap
  jobs — coordinator `clickSource` (physical-click state) **and** the emitter's
  `dragPromoter` — realizing docs/05's "one facade owns both" without a wrapper.
- Tests: `DragTests` (recognizer, 6), `DragPromotionTests` (interceptor rewrite, 5),
  + 3 pipeline holds (press→release, safety cancel, release-despite-disable-mid-hold).

**Drag-style addition (2026-07-13, HW-verified).** After
HW trial, tap-and-a-half's leading click was found to read as a **double-click-drag**
(word pre-select on text, precision loss). Decision: keep `tapAndAHalf` as default,
**add a second shipping drag style `pressAndHold`** behind a global toggle (both
wanted, for different users), and **specify but defer** a `.deferred` click-timing
option that would make `tapAndAHalf` artifact-free. What landed (branch
`phase-8-drag`): `DragStyle` enum in `GestureConfig` (Codable, lenient-decode,
persists/transfers); recognizer branches promotion on it — `pressAndHold` promotes a
**single, still** (`≤ maxTravel`) contact held past `holdThreshold` with **no leading
tap** (clean single-press drag); Advanced-pane picker with a tradeoff-aware
explainer. Only the recognizer changed — the whole drag output path is shared.
`PressAndHoldDragTests` (6) → **120 tests** green. Full spec: `03 §Drag styles`.

**Deferred to post-v1 (specified, not built): `clickTiming = .deferred`.** Withholds
the first tap's click until the second interaction resolves, removing the
double-click-before-drag for `tapAndAHalf` (matches other Magic Mouse utilities;
serves finger-resters who can't use `pressAndHold`). Orthogonal to `dragStyle`. Costs
~`doubleTapGap` of single-click latency and needs a **flush timer / `Scheduler`
seam** (v1's recognizer is clock-free) — the real work. Full spec: `03 §Click timing`;
roadmap entry in `10`. This feature may need more refinement before implementing.

- **HW tested and verified** ([[phase-completion-gates]]): real drags — Finder icon, text
  selection, window/title-bar, slider — for **all three buttons**, in **both** drag
  styles, plus no stuck button on disable/quit/device-loss mid-drag.

## Phase 9 — Hardening & distribution ✅ *(COMPLETE — v1 ships; clean-machine validated)*

> **Progress:** Phase 9 ✅ **COMPLETE — v1 ships; clean-machine validated 2026-07-14.**
> 9.1 calibration (defaults validated), 9.2 error-state observability, 9.3 struct-layout
> table, 9.4 two-mouse separation (HW-verified), 9.5 distribution (notarized + stapled DMG),
> 9.6 clean-machine validation + first-run overhaul. **Track 4 resolved (`08 §C`): Input
> Monitoring is NOT required and was removed entirely** — Accessibility is the only grant.
> The full feature sweep passed on the notarized build on a fresh Mac.
- Calibrate default zone boundaries + thresholds from real data; decide on the
  optional `y` rejection band (`08 §A`). **Includes recalibrating
  `GestureConfig.maxSize`** — `major`/`size` runs ~8–10, not `0…1` (Phase 4).
- Multi-mouse / hot-plug / error-state polish; compatibility struct-layout guard
  finalized with the per-OS table. **Carry-over from Phase 4: demonstrate
  two-mouse contact separation on a second physical Magic Mouse** (structurally
  verified only so far).
- Developer-ID sign + Hardened Runtime + **notarize + staple**; DMG.
- **Exit:** signed, notarized build; docs/readme updated; v1 ships.

### 9.1 — Calibration instrument ✅ *(tool landed + unit-tested; HW session captured → defaults validated)*
The tuning pass needs **data, not guesses**, so the first Phase 9 piece is a
hardware-free, TDD-able measurement tool (same "pure parts first" order as Phases
2/6). *As built:*
  - **`GestureEngine/ContactMetrics.swift`** — pure calibration types, deliberately
    parallel to the recognizer (never part of it) so it measures **every** contact
    without filtering, yet mirrors the recognizer's accounting exactly:
    - `ContactMetricsRecorder` — frame stream → one `ContactSample` per completed
      contact; began-time zone capture, Euclidean max-travel, max-size, physical-
      click latch, frame count, keyed on `(deviceID, id)` like the recognizer.
    - `ContactSample.verdict(against:)` — reproduces `isTap`'s gate order but reports
      **which** gate a contact tripped (`tap` / `rejectedPhysicalClick` /
      `…Duration` / `…Travel` / `…Size`), so a session shows not just how many real
      taps are rejected but by what → which default to loosen. `csvHeader`/`csvRow`.
    - `ContactSummary` — aggregate: counts by zone + verdict, and min/mean/max of
      duration, travel, size, and **begin-`y`** (the input to the optional `y`
      rejection-band decision, `08 §A`).
  - **Harness `mb-dev log-gestures [seconds] [path]`** — drives the real
    `MultitouchSource` → recorder, streams CSV rows to a file (timestamped default),
    physical-click from an `EventInterceptor` (optional; touches log without it),
    frames marshaled to main. Filters/posts **nothing** — pure measurement. Prints a
    tuning summary vs the shipped defaults at the end.
  - **14 new tests** (`ContactMetricsTests`), incl. a check that the recorder's
    verdict agrees with the recognizer's real output. `swift test` green at **134**.
  - **HW-manual gate PASSED (2026-07-13):** ran a 60 s session on the Magic Mouse
    (`log-gestures 60 session.csv`) — **35 contacts: 24 taps, 10 holds/drags, 1
    physical-click reject.** Read the distributions; they **validate every shipped
    default** (decision: change nothing — one session is too little to justify
    over-fitting, which docs' own sequencing note warns against):
    - **maxDuration 0.18** — real taps span 0.017–**0.165** s (mean 0.088); shortest
      non-tap 0.555 s → a clean tap/hold gap straddling the threshold.
    - **maxTravel 0.06** — taps peak at **0.032** (mean 0.008). Ample headroom.
    - **maxSize 14** — every contact ≤ **11.05** (taps ≤ 10.57). No palm outliers seen
      (palm never registered as a distinct contact, so the size-reject path stays
      real-world-untested — the one open caveat).
    - **`ZoneLayout` 0.38 / 0.62** — L ≤0.294 · M 0.411–0.559 · R ≥0.885; every tap
      correctly zoned. (Data faintly favors `leftEdge`→0.35 for symmetry; left within
      noise, so left at 0.38.)
    - **`y` rejection band** — all touches cluster y **0.746–0.850**, no front-lip/
      palm-rear cluster → stays **off** (confirms `08 §A`).
    - **requireNoPhysicalClick** — the one click-coincident contact was correctly
      rejected. The `size ≈ 8–10` scale ([[touch-size-scale]]) is confirmed in the
      wild (contacts 7.7–11.05).

### 9.2 — Error-state observability ✅ *(code + unit-tested; UI-message verify SUPERSEDED by 9.6)*
Closes the silent-failure hole: a Magic Mouse enumerates **without** Input
Monitoring, so the framework yields the device but no frames — `sourceError` stays
`nil` and nothing works, with nothing surfaced (the docs/08 scenario; also `04
§Sanity check #3`). *As built:*
  - **`AppCoordinator`** gains a clock-free liveness latch `hasReceivedFrameSinceStart`
    (set on the first frame, reset on stop / re-enumeration) and the derived
    `touchesNotArriving` (`isRunning && isDeviceConnected && never-received`). The
    degraded-state *decision* now lives in tested `AppCore`, not untested AppShell.
  - **`AppModel`** mirrors `touchesNotArriving` on the 1.5 s status poll and adds a
    `recentIssue` branch — when connected + IM-granted yet deaf, the Errors row shows
    an actionable "relaunch / re-toggle Input Monitoring" message instead of nothing.
    (The existing time-windowed `isReceivingTouches` still drives the live "receiving
    touches" readout — a distinct concern: *live now* vs *ever started*.)
  - **4 new tests** (`AppCoordinatorTests`): deaf-until-first-frame, stop clears,
    re-enumerate clears until next frame, `.noDevice` is *not* the deaf state.
    `swift test` green at **138**; app target builds (`xcodebuild`).
  - **Manual verify — SUPERSEDED by 9.6:** Input Monitoring was removed entirely
    (`08 §C`), so the deaf-state message no longer references it; the connected-but-deaf
    readout now reads purely off `touchesNotArriving`. Clean-machine feature sweep passed.

### 9.3 — Struct-layout guard + per-OS table ✅ *(finalized)*
Finalizes the compatibility guard (docs/11 Track 2, `04 §Sanity checks`). Clarified
that the `sizeof(MTTouch) == 96` guard checks the **shim's own** struct (catches an
accidental edit), *not* the framework's runtime layout — so cross-OS correctness
rests on the empirical coordinate check. Added a **per-OS verification table** to
`04` (first row: macOS 26.5.2 / Darwin 25.5.0 / build 25F84 → 96 bytes, coordinates
sane) and pointed the code comment at it. No behavior change; a speculative runtime
coordinate-validator was deliberately **not** added (over-investment; `08`/sequencing
caution). Add a table row when verified on a new macOS.

### 9.4 — Two-mouse contact separation ✅ *(checker + harness + unit-tested; HW gate PASSED)*
Turns the Phase 4 *structural* two-mouse claim into a real, exercisable gate
(docs/02 — contact ids are unique only within a device, so keying is `(deviceID,id)`).
*As built:*
  - **`TouchKit/MultiDeviceContactTracker.swift`** — pure, hardware-free: consumes the
    frame stream and reports `devicesSeen`, `maxConcurrentDevices`, `didSeparateTwoMice`
    (two mice live **at once**, not merely both seen), and
    `observedCrossDeviceIDCollision` — the same contact `id` live on both mice
    simultaneously, kept apart by the `(device,id)` key (the case id-only keying would
    merge). **5 tests** (`MultiDeviceContactTrackerTests`), incl. sequential-≠-concurrent
    and the id-collision separation. `swift test` green at **143**.
  - **Harness `mb-dev verify-two-mouse [seconds]`** — drives the real source into the
    tracker, prints tagged began/ended + live-device count, highlights the first
    concurrent-separation and id-collision moments, and prints a PASS/INCOMPLETE
    summary (exit 0 only on real concurrent separation). Smoke-tested (enumerates,
    summarizes, correctly reports INCOMPLETE with one mouse / no frames).
  - **HW gate PASSED (2026-07-14):** `verify-two-mouse 20` with two Magic Mice
    (`0x4000000311dba66`, `0x400000070db836a`) → **2 distinct devices,
    maxConcurrentDevices == 2, and a cross-device id collision (both mice had contact
    `id=6` live at once) observed + kept separate → RESULT: PASS.** The subtle failure
    mode was actually exercised, not just the happy path. (Aside: the real stream emits
    many repeated `.ended` frames per lifted contact; the tracker — like the recognizer
    — is idempotent on a removed key, so this is harmless.)

### Track 2 done
- Hot-plug re-enumeration + master-enable safety release: Phase 7.4, covered by
  `AppCoordinatorTests`. 9.2 error-state observability + 9.3 struct-layout table above.

### 9.5 — Distribution pipeline ✅ *(notarized + stapled; v1 ships)*
Track 3. **`scripts/release.sh`** — one command: Release `.app` signed with the
**Developer ID Application** identity + Hardened Runtime + secure timestamp → signed DMG →
notarize → staple (DMG + `.app`). Overrides signing on the `xcodebuild` command line so
the committed local-dev ad-hoc default (`AppShell/Signing.xcconfig`) is untouched.
`--skip-notarize` runs everything bar the Apple round-trip. *As built / verified:*
  - Developer ID identity + certs loaded into Xcode (2026-07-14). Release build signs
    clean: full Developer ID chain, `flags=0x10000(runtime)`, secure timestamp, the
    Developer ID team; `codesign --verify --deep --strict` passes with **no entitlement
    exceptions** (confirms `07 §Signing` — library validation permits the Apple-signed
    private-framework `dlopen`; no `disable-library-validation`).
  - Full local dry run (`--skip-notarize`) produces `dist/MagicButtons.app` + a signed
    `dist/MagicButtons.dmg` (864 KB). Fixed a `set -o pipefail`+`grep -q` SIGPIPE
    false-failure in the verify step (capture then grep).
  - **Notarized + stapled (2026-07-14):** notary profile `MagicButtons-Notary` stored;
    `scripts/release.sh` → submission **Accepted**, ticket stapled to both DMG and .app,
    and `spctl` reports **`source=Notarized Developer ID`** for each. `dist/MagicButtons.dmg`
    launches with no Gatekeeper warning on any Mac. **Phase 9 exit met — v1 ships.**
  - **One fix along the way:** the first submission was **Invalid** —
    `com.apple.security.get-task-allow` (the debug "attach a debugger" entitlement) was
    auto-injected by a plain `build`. Added `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` to
    the release build (our explicit `app-sandbox=false` entitlement still applies); the
    re-submission was Accepted.

### 9.6 — Clean-machine validation + first-run overhaul ✅ *(feature sweep PASSED on the notarized build)*
The notarized `dist/MagicButtons.dmg` was run on a **fresh Mac** (never built the app;
clean TCC). Opened with no Gatekeeper warning; the full feature sweep — single/double/
middle clicks, tap-to-click, both drag styles, per-feature toggles, master enable, login
item — passed. First-run testing there exposed a bug cluster (all fixed):
  - **★ Track 4 / `08 §C` RESOLVED — Input Monitoring is NOT required; removed entirely.**
    With the app absent from the Input Monitoring pane, touching the mouse showed live
    contacts in the Visualizer → the private `MultitouchSupport` frame path isn't gated by
    the IM toggle. The check was also *harmful*: `IOHIDCheckAccess(ListenEvent)` reported a
    **false-positive** grant, and `IOHIDRequestAccess` never registered the app in the pane,
    so "Fix Input Monitoring" dropped the user on an empty pane. `Permission` is now
    **`.accessibility`-only**; `inputMonitoring` / `canReadTouches` / `touchSourceError`
    deleted from the model + both `SystemPermissionChecker`s.
  - **Launch-time enumeration race** — a Bluetooth Magic Mouse not yet enumerated when
    `MultitouchSource.start()` first ran read as "No Magic Mouse" until a relaunch (no
    hot-plug attach fires for an already-connected mouse). `AppModel.recheckPermissions`
    now re-enumerates on the 1.5 s poll whenever running without a connected device.
  - **Mid-run grant not re-deriving** — tap + messaging were bound at launch, so a
    just-granted Accessibility read green while stale "grant Accessibility"/"No Magic Mouse"
    text persisted. New `AppCoordinator.retryStream(for:)` re-arms the tap in place;
    `AppModel.needsRelaunch` + `relaunch()` drive a "Quit & Reopen to Finish Setup" fallback
    (menu + Status) when the in-place retry can't install it. `health` / `statusSummary` /
    `deviceStatus` / `capabilitySummary` / `recentIssue` reworked to derive from real stream
    state, not the (removed) IM check. `swift test` green at **145**; app target builds.
  - This **supersedes** the 9.2 "deaf-message manual verify on an IM-revocable machine"
    remnant: IM is gone, and the deaf-state message no longer references it.

> **Post-v1 work continues in `14-post-v1.md`** — triple-click, stuck-button
> hardening, draggable own-sliders, and Magic Mouse handedness were all built and
> HW-verified after this document was frozen. See that log and `10-roadmap.md`.

---

## Sequencing notes
- **Two parallel tracks after Phase 1:** the pure-logic track (2 → 6) and the
  hardware track (3, 4, 5). They converge at Phase 7. If working solo, do
  4 before 5 (visualizer wants real data) and interleave 2/6 whenever blocked on
  hardware.
- **Drag deferred deliberately** — every other gesture is proven and the app is
  usable before we take on the active-tap complexity, so drag can be iterated
  against a known-good base (your call, and it's the right one).
- **Tuning is a Phase 5+ activity** — thresholds and zone defaults are guesses
  until the visualizer + hardware exist; don't over-invest in defaults earlier.
