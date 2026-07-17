# Post-v1 Build Log

The running build record **after v1 shipped** — the successor to
`11-build-plan.md`, which is now frozen as the v1 history. Same milestone-by-
milestone style, continued past the ship.

Where things live now:

- **v1 history** — `11-build-plan.md` (Phases 0–9, all complete + HW-verified).
  Frozen; not updated further.
- **Forward-looking candidates** — `10-roadmap.md`. A candidate **graduates** here
  when it is picked up for build; once done + HW-verified it stays here as the
  record (e.g. triple-click, below).
- **Feature detail** — the numbered design docs (`03`, `05`, `09`, …). This log
  records *what was built and verified*; the design docs carry the *why*.

Legend: **HW** = needs the attached Magic Mouse; **—** = hardware-free (CI-able).
Test counts are cumulative (`swift test`).

---

## Stuck-button hardening ✅ *(done; HW-verified 2026-07-14 — commits `2d5e6df`, `9b21626`)*

Trigger: revoking Accessibility **mid-hold** stranded a mouse button down system-
wide — the synthetic button-**down** had posted, but posting needs Accessibility, so
the compensating **up** could no longer be posted, and the still-live tap kept
promoting real moves into drags. Down and up both need the grant and it can vanish
between them, so recovery is impossible; the fixes therefore **prevent the held
state** rather than recover it (docs/05 §Stuck-button safeguards, docs/08 §Stuck-
button safeguards). *As built:*

- **Guard-on-trusted** — `CGEventEmitter.press` bails unless `AXIsProcessTrusted()`,
  so it never opens a drag it can't close. `init(isTrusted:)` injects it for tests;
  `click` is unaffected (atomic down+up).
- **Idempotent `release`** — lifts only a button actually held (guards on
  `heldZone`), so overlapping safety-release paths can't post a stray up.
- **Release on device loss** — `DeviceMonitor`(remove) → `refreshDevices` →
  `cancelActiveHolds` lifts a held button when the mouse disconnects mid-drag (no
  `.ended` frame arrives). Locked by
  `AppCoordinatorTests.deviceLossReleasesAnInFlightDrag`.
- **Frame-silence watchdog — measured & REJECTED.** Added `mb-dev probe-cadence`; the
  multitouch stream is delta-driven, so a motionless finger goes silent ~4 s while
  still fully in contact → silence ≠ lift, and any useful timeout would drop a paused
  drag. `.ended` stays the primary release signal; device-loss is the backstop.
- **HW-verified:** normal tap-and-a-half drag unchanged; powering the mouse off mid-
  drag drops the drag cleanly with no stuck button.

## Draggable own-sliders — live tunable edit preserves an in-flight hold ✅ *(done; HW-verified 2026-07-14 — commit `fb3c61d`)*

MagicButtons couldn't drag its **own** Advanced-pane sliders: each slider binds to a
live gesture/zone tunable, so every drag increment ran `AppModel.sync →
coordinator.apply → pipeline.reconfigure`, which called `cancelActiveHolds()` and
posted the synthetic mouse-**up** driving the drag — a self-cancelling loop (system
sliders like volume were immune; they don't touch our config). *As built:*

- **`GesturePipeline.reconfigure`** now calls the new
  `MouseGestureRecognizer.update(layout:config:)`, updating tunables **in place**
  (preserving `contacts` / `pendingClick`) instead of rebuilding the recognizer — the
  in-flight hold survives and still releases on lift (no strand, which is why the old
  rebuild released first). Also drops a ~60×/sec recognizer teardown per slider drag.
- The direct safety paths (disable / quit / device-loss) still call
  `cancelActiveHolds()`; the zone-line preview stays live off `visualizer.layout`, not
  the recognizer. See docs/05 §Live tunable edits keep an in-flight hold.

## Magic Mouse handedness — honor the secondary-click side ✅ *(done; HW-verified 2026-07-14 — commit `f694826`)*

Left/right tap zones were mapped 1:1 to buttons, ignoring System Settings → Mouse →
Secondary click. *As built:*

- Reads `com.apple.AppleMultitouchMouse` **`MouseButtonMode`** — `TwoButtonSwapped`
  (left-handed) swaps the left/right **zones at emission**; `TwoButton` / `OneButton`
  are right-handed. (`MouseButtonDivision` is only the split *position*, **not** the
  handedness — confirmed by toggling + diffing.) Middle is unaffected.
- New `SecondaryClickReader` (injectable raw read via `CFPreferencesCopyAppValue`; the
  app is unsandboxed so this is readable) + `AppCoordinator.setSecondaryClickSide`
  (idempotent). The swap lives in `GesturePipeline.effectiveZone` at emission so the
  emitter / held-zones / interceptor agree, while the recognizer + visualizer stay
  **spatial** (UI labels zones left/right, not primary/secondary).
- Read at launch and re-read on the existing 1.5 s poll → a mid-session change is
  auto-honored within ~1.5 s, no relaunch. docs/05 §Mouse handedness, docs/09.

## Triple-click ✅ *(graduated from `10-roadmap.md`; done; HW-verified 2026-07-14 — commit `a655f29`)*

Promoted because it earns regular use (selecting a whole **line**, not just a word).
It was the natural extension of the double-click run — no timer, no new recognizer,
unlike the still-deferred `.deferred` click timing — so it followed the Phase 6 "pure
parts, TDD" pattern. *As built:*

- **`MouseGestureRecognizer`** generalizes the per-zone WAIT_SECOND memory from a
  single end-time to a `PendingClick { endTime, count }`. Each in-gap contact now
  *continues* the run — `ContactState.followsCount` replaces the `isSecondTap` bool —
  emitting `click(Z, followsCount + 1)`: `click(1)→click(2)→click(3)`. The run arms
  the next step only while `count < config.maxClickCount`, so a triple does not arm a
  quadruple; past the cap or the gap it resets to a fresh single. The frame-starved
  hold guard and the double-tap-then-hold exclusion both key on `followsCount` now, so
  **only the immediate second contact (`followsCount == 1`) hold-promotes to a drag** —
  drag behavior is unchanged.
- **`GestureConfig.maxClickCount`** (default **3**) is the cap: `2` reverts to
  double-only, `1` disables multi-click. A pure tunable like the others (no per-field
  UI); lenient-decodes for older settings files.
- **Emitter + policy needed no change.** `CGEventEmitter.click(_, count:)` already sets
  `mouseEventClickState = count` (a genuine triple), and `FeaturePolicy.allows` gates by
  zone regardless of count — so triple-click inherits its zone's tap feature exactly like
  double-click, with no new toggle (docs/09 §Features).
- **Tests:** the Phase 6 `tripleTapIsDoubleThenSingle` became `three…SingleDoubleTriple`,
  plus cap-resets-to-single, past-gap, `maxClickCount = 2` disables, and different-zone
  cases. `swift test` green at **160** (+4). Spec updated in docs/03 §The unified state
  machine.
- **Exit ✅ (HW-verified 2026-07-14):** a real triple-tap in one zone triggers a genuine
  triple-click (line-select in a text view), confirmed across multiple apps in testing.

## App icon + custom menu-bar symbols ✅ *(done; verified 2026-07-15 — commit `3254f5c`)*

Replaced the stock SF Symbols menu-bar glyph (`computermouse[.fill]`) with the app's own
mouse line-art, and added a proper app icon. *As built:*

- **App icon** — an Icon Composer `.icon` (Liquid Glass) at `AppShell/magicbuttons.icon`,
  wired via `ASSETCATALOG_COMPILER_APPICON_NAME`; actool compiles it at build time.
- **Two custom symbols** in `AppShell/Assets.xcassets`: `magicbuttons.mouse.fill` (solid
  body + eye/ear cutouts, active) and `magicbuttons.mouse` (hollow line-art, disabled),
  plus the system triangle for degraded — `menuBarSymbol` became a `MenuBarIcon` enum
  (system vs custom). Editable sources: `magicbuttons-{fill,outline}.svg`.
- **Two gotchas (docs/09):** the SF Symbol renderer ignores `fill-rule="evenodd"`, so
  holes must be authored with **reversed-winding** subpaths (nonzero) or they collapse to
  a filled blob at compile time; and a `MenuBarExtra` label re-renders on state change
  only when the model is reached through SwiftUI's observation graph — the App now owns
  `AppModel.shared` as `@State`, not `delegate.model`. Menu-bar `.opacity()` doesn't
  survive template rendering, so states differ by glyph, not dimming.
- Also bumped `MARKETING_VERSION` to 1.1.0 / build 2.

## Interceptor lifetime — scope the tap to enabled + authorized ✅ *(done; HW-verified 2026-07-15 — commit `e1620e6`)*

Trigger: with the app **disabled**, revoking Accessibility lost all clicking system-wide.
Distinct from the stuck-button case (no synthetic hold was active) — the active
`.cghidEventTap` was installed for the whole session regardless of the master toggle, so a
disabled app held a system-wide tap with **no job**, and revoking Accessibility orphaned it
in the HID path, wedging every click. The old rationale ("keep streams running for the
visualizer") conflated the touch source (feeds the visualizer) with the event tap (feeds
synthesis only). *As built:*

- The tap is **scoped to running + master-enabled + Accessibility-granted**:
  `setEnabled(false)` tears it down (lifting any held button first), `setEnabled(true)`
  re-arms, `suspendClickInterception()` (from the permission poll's revoke transition)
  pulls it the moment trust is lost, and `start()` installs it only when already
  enabled+authorized. The touch source runs throughout — visualizer unaffected
  (docs/05 §Interceptor lifetime, docs/08 §D).
- **Tests (`swift test` green at 164, +4):** launched-disabled installs no tap;
  disable→re-enable tears down→reinstalls; suspend→re-grant removes→reinstalls; disabling
  mid-drag releases the held button first.
- Limitation: revoke-while-enabled teardown rides the 1.5 s poll (not instant).

---

## About card — version, copyright, homepage ✅ *(done — hardware-free)*

An **About MagicButtons** item in the menu-bar pull-down (directly under **Settings…**)
opens a small fixed-size card. Deliberately sparse for v1; a scaffold the homepage link
and (later) a Sparkle "Check for Updates…" hang off. *As built:*

- **`AppShell/AboutView.swift`** — app icon (`NSApp.applicationIconImage`, 96×96), app
  name, `Version 1.1.0 (2)`, the copyright line, and a **Homepage** link to
  `https://codeberg.org/anguiano/MagicButtons`. Version/build/copyright/name are read
  from the bundle (`CFBundleShortVersionString`, `CFBundleVersion`,
  `NSHumanReadableCopyright`, `CFBundleDisplayName`) — single source of truth, so a
  `project.yml` version bump flows through with no code edit.
- **`AppModel.showAbout()`** — retained, non-resizable (`[.titled, .closable]`) window,
  same imperative pattern as `showSettings()`/`showVisualizer()` so an accessory
  (`LSUIElement`) app can re-front it on every reopen (`isReleasedWhenClosed = false`).
- The **"Check for Updates…"** slot is marked in `AboutView` for when Sparkle lands
  (docs/10 §Sparkle).
- App-target only (SwiftUI/AppKit shell), so no `swift test` change; `xcodebuild` green.

---

## Sparkle auto-updater ✅ *(done; HW-verified 2026-07-15 — notarized build 1.1.0(3) live on Codeberg Pages, build 2→3 auto-update installed on hardware)*

Graduated from `10-roadmap.md`. MagicButtons ships a signed/notarized DMG **outside the
App Store** (docs/07 §Why not the Mac App Store), so there is no store to push fixes —
Sparkle with an **EdDSA-signed appcast** is the delivery path. Decisions (2026-07-15):
**hosting = Codeberg Pages**, **checks = automatic + manual**, **update format = the
existing DMG** (no separate ZIP; Sparkle mounts the DMG and copies the `.app` out).

**S1 — in-app integration ✅ (hardware-free; `xcodebuild` green):**
- Sparkle 2 (resolved **2.9.4**) is a package dependency **only on the Xcode app target**
  (`project.yml` top-level `packages:` + the target's `dependencies:`), never in
  `Package.swift` — the pure, CI-able SwiftPM library/test targets stay Sparkle-free.
  Xcode embeds + signs `Sparkle.framework` (with `Autoupdate`, `Updater.app`, and the
  Downloader/Installer XPC services) into `Contents/Frameworks`; verified in the Release
  build's nested-code `codesign --verify`.
- **`AppShell/UpdaterController.swift`** — `@MainActor @Observable` singleton wrapping
  `SPUStandardUpdaterController(startingUpdater: true)`. All policy is Info.plist-driven
  (below), not code. Bridges Sparkle's KVO `canCheckForUpdates` into a tracked property
  via a Combine sink so SwiftUI controls can disable while a check/install is in flight.
- **"Check for Updates…"** added to the menu-bar pull-down (`MenuBarContent`, under
  *About*) and to the About card (`AboutView`, replacing its placeholder slot). About
  window grew 300→340 pt for the extra control.
- **Info.plist** (`AppShell/Info.plist`): `SUFeedURL =
  https://anguiano.codeberg.page/MagicButtons/appcast.xml`, `SUPublicEDKey` (real key,
  below). `SUEnableAutomaticChecks` is **intentionally omitted** so Sparkle shows its
  standard one-time "check automatically?" consent prompt on the second launch and honors
  the user's choice.

**S2 — signing keys ✅:** `generate_keys` (from the Sparkle SPM artifacts) created the
EdDSA keypair; public key `P7c0kjIvG8mKtdfOtjbid2K49eJ9DXAqjzBaP18416o=` is in the
Info.plist, the **private key lives only in this developer's login Keychain** (never
committed — `.gitignore` already covered `*_priv.pem`). ⚠️ The private key is the only
thing that can sign updates — **back it up** (`generate_keys -x file`, store securely);
losing it means users on the current public key can't be updated without shipping a new
key out-of-band.

**S3 — release automation ✅ (built + verified via `release.sh --skip-notarize`):**
- **Build-number forcing function.** Sparkle compares `CFBundleVersion` to decide "is
  there an update"; nothing auto-bumped it before. `release.sh` now reads the built app's
  build number and **fails fast if it isn't strictly greater than the newest
  `sparkle:version` in `updates/appcast.xml`** — the missing forcing function, tied
  directly to Sparkle's own comparison rather than a tag convention. Bump
  `CURRENT_PROJECT_VERSION` in `project.yml` (never the generated `.xcodeproj`/Info.plist).
- **Appcast generation.** After notarize+staple, `release.sh` copies the DMG into
  `updates/` as `MagicButtons-<short>-<build>.dmg` (version-unique so past releases stay
  downloadable) and runs `generate_appcast --download-url-prefix <Pages URL>` over the
  dir. It **asserts `edSignature` is present** — a mismatched/absent `SUPublicEDKey`
  makes `generate_appcast` silently emit an *unsigned* entry (its per-update signature is
  gated on the app's embedded `SUPublicEDKey` matching the Keychain key,
  `Appcast.swift:199`), which Sparkle would then reject. Runs in the `--skip-notarize`
  dry run too (clearly labeled: that DMG isn't stapled — don't publish it).
- **Sparkle helper re-signing (notarization).** `xcodebuild build` re-signs the app and
  Sparkle.framework's shell but leaves Sparkle's nested executables — `Autoupdate`,
  `Updater.app`, and the `Downloader`/`Installer` XPC services — carrying Sparkle's own
  **ad-hoc** signature. That passes `codesign --deep --strict` (valid signatures) but
  **notarization rejects it**: "not signed with a valid Developer ID certificate" +
  "signature does not include a secure timestamp" for each nested Mach-O (first real
  `--publish`, submission `68af125c…`, status *Invalid*). Fix: `release.sh` now re-signs
  those helpers **inside-out** (`--options runtime --timestamp --sign <Developer ID>`) then
  re-seals the framework and the app, right after the build. Verified: the four helpers now
  carry `Authority=Developer ID Application` + runtime + timestamp, `--deep --strict` still
  passes. (Also hardened: `notarytool submit --wait` exits 0 even on *Invalid*, so the
  script now parses the returned `status`, auto-dumps Apple's issue log, and refuses to
  staple/publish anything that isn't `Accepted`.)
- `updates/` is gitignored — it's the **local mirror of the Codeberg Pages site**.
- **Publish (`--publish`).** Codeberg Pages serves the feed from a **`pages` orphan branch
  in this repo** → `https://anguiano.codeberg.page/MagicButtons/` (branch-name method: the
  repo name becomes the URL path; verified live, `curl -sI …/appcast.xml` → 200). The branch
  is checked out as a linked git **worktree** at `../MagicButtons-pages` (orphan → keeps the
  DMGs out of `main`'s history; created once with `git worktree add --orphan -b pages
  ../MagicButtons-pages`, overridable via `MB_PAGES_WORKTREE`). `./scripts/release.sh
  --publish` copies `updates/`'s appcast + versioned DMGs into that worktree, commits, and
  pushes. It **refuses to combine with `--skip-notarize`** (never publish an un-notarized
  DMG) and no-ops cleanly when nothing changed.
- **Codeberg Release mirror (`--publish`).** So the hand-download stays byte-identical to what
  Sparkle serves, `--publish` also cuts a **Codeberg Release** via the Forgejo REST API (Codeberg
  runs Forgejo; `gh` is GitHub-only). It tags the released source commit `v<short>-<build>` (e.g.
  `v1.1.0-4`), pushes the tag, creates the release (notes from `--notes FILE`, else a default
  body), and uploads the *same* notarized/stapled versioned DMG from `updates/` as the release
  asset — the identical bytes the appcast enclosure points at. Sparkle is untouched: it still
  reads only the Pages appcast/enclosure URLs. Needs a token with the `repository:write` scope in
  `MB_CODEBERG_TOKEN` (kept in `scripts/release.local.env`, gitignored); without it the step is
  skipped with a warning so Pages still publishes. Idempotent — if the tag's release already
  exists it's left untouched (safe to re-run). Repo defaults to `anguiano/MagicButtons`,
  overridable via `MB_CODEBERG_REPO`.
- The full release loop is now one command: bump `CURRENT_PROJECT_VERSION` →
  `./scripts/release.sh --publish` (optionally `--notes RELEASE_NOTES.md` for the Codeberg body).

**Shipped live:** build **1.1.0 (3)** was built, re-signed, **notarized** (submission
`78823f24…` Accepted), stapled, appcast-signed, and **published to Codeberg Pages** via
`./scripts/release.sh --publish` — `https://anguiano.codeberg.page/MagicButtons/appcast.xml`
serves version 3 (curl 200, valid `edSignature`, stapled DMG). The full pipeline ran
end-to-end in one command.

**S5 — HW verify N→N+1 ✅ (HW-verified 2026-07-15):** installed build 2, Check for Updates…,
and the running build discovered build 3, verified its EdDSA signature, downloaded, and
**installed it cleanly** on hardware. The Sparkle stable path is done, end to end.

**Remaining:**
- **S4 — beta channel: DEFERRED** back to `10-roadmap.md` (2026-07-15) — optional, no
  testers yet. Design is known and cheap when needed: app-side
  `SPUUpdaterDelegate.allowedChannelsForUpdater:` → `["beta"]` behind an opt-in pref;
  release-side `generate_appcast --channel beta` (a `release.sh --beta` flag). Matches the
  "separate channel, build-number per beta" decision.
- Known-benign: the 2→3 delta URL currently 404s (advertised but not published in the run
  before the `do_publish` `*.delta` fix, `b4bf905`); self-heals on the next release.

---

## Click/drag de-confliction ✅ *(done; HW-verified 2026-07-16 — commits `df1d17c`, `78094b7`, `b9cd131`, `d04fd86`, `36e530e`; 179 tests)*

A reliability/definition fix for the **currently shipping additive modes** — not a
new mode, no suppression toggle. When a synthetic gesture and a physical one collide,
neither should corrupt the other. Taken on because it has a tangible effect on the
reliability of drags people already use, and it's the prerequisite arbitration that
Feature A (suppress physical clicks, `10-roadmap.md` / `05` §Suppress physical clicks)
would build on.

**Shipped as two complementary halves:**

- **Recognizer** (`promoteToHoldIfNeeded`) — a contact that saw a physical click never
  promotes to a hold, the same rule the tap primitive already applied. Stops spurious
  holds from arming at all, and kills scenario #2 (competing drag start) at the source.
- **Interceptor** (`shouldSwallow`) — on the holds that legitimately do arm, a physical
  down is swallowed while the hold owns the pointer, and its up iff its down was
  swallowed (approach (c), balanced-swallow).

**HW verification (2026-07-16) confirmed:** mid-drag squeezes no longer interrupt a drag
(the headline fix) under **both** drag styles; physical single/double/triple-click all
work; a clean resting press still drags. The session also caught scenario #9 — a
regression the up-front reasoning missed — which is why the recognizer half exists.

**Also fixed here, pre-existing:** under `pressAndHold` the app was already synthesizing a
drag *on top of* the user's own physical click; the swallow merely made it visible.

**Known residual (inherent, mitigation declined):** in `pressAndHold`, resting a finger
past `holdThreshold` arms a drag, and physical clicks are then swallowed until it lifts —
so rest-then-double-click doesn't work. The two gestures physically overlap, since in that
mode *a resting finger is the drag trigger*. Surfaced in the drag-style picker's help text
rather than mitigated; `tapAndAHalf` is the mode for people who rest fingers (docs/03
§Drag styles).

**Scope both drag styles** — the collision windows differ:

- `tapAndAHalf` — the synthetic button is already down for the whole move, so the
  interceptor's `dragZone` is set across the entire drag.
- `pressAndHold` — a held contact may not have armed the synthetic button yet at the
  instant the shell is squeezed, so keying off `dragZone` alone leaves a gap at
  drag-onset; the guard must also see the recognizer's hold-arming state
  (`heldZones` in `GesturePipeline` / the arming window in `MouseGestureRecognizer`).

### Measurement first

Reproduce and log each collision on hardware before coding — with the purpose-built
**`mb-dev log-conflicts [seconds] [tap|hold] [path]`** (docs/13), which runs the real
pipeline (drag promotion wired) and writes a timestamped CSV interleaving physical
clicks, synthetic press/release/click, and contact changes, each tagged `hold_active`.
Run it under **both** styles: squeeze the shell mid-drag; race a physical press against
a `tapAndAHalf` onset; race a physical click against a same-zone tap click. The summary
counts physical events that hit during a synthetic drag; the CSV shows what the OS
actually did (drop / select / reorder) so the fix targets real behavior. *(Built
2026-07-16 as the first step of this feature; `verify-gesture` alone can't drag or log
the timeline.)*

### Measured findings (first HW session, 2026-07-16)

Two 30 s captures, one per style (`conflicts-*` CSVs). What they changed:

1. **Collisions are routine, both styles** — every deliberate click-to-drag put a
   synthetic hold concurrent with physical button events (`tapAndAHalf` flagged 6
   in-hold physical transitions; `pressAndHold` 13).
2. **`requireNoPhysicalClick` gates only *taps*, not holds.** A physical click already
   held when a contact promotes still lets the drag start, so the app gets **both** a
   real button-down and a synthetic one. Drag onset needs explicit arbitration.
3. **The *straddle* is the common case, and it breaks a naive "swallow while `dragZone`
   set" rule.** The dominant real pattern (both styles) is: physical **down** during
   *arming* (`hold_active=0`, contact present, pre-promotion) → synth **press** →
   physical **up** during the hold (`hold_active=1`) → synth **release**. Keying on the
   active hold alone swallows the *up* but not the *down* → **unbalanced physical
   state**. So balanced-swallow (scenario #4) is the *main* path, not an edge.
4. **Both styles have an arming window.** `tapAndAHalf`'s *second contact* has the same
   landing→promotion gap as `pressAndHold`'s pre-threshold window — a physical down
   lands there in both. The table's arming row applies to **both**, not just
   `pressAndHold`.
5. **Cross-zone confirmed** — a zone-less physical click (posts as left) collided with a
   synthetic **middle** hold. Arbitration must not assume same zone (scenario #6).
6. **Lone physical clicks self-resolve (scenario #3 → accept, don't swallow).** Physical
   clicks with a resting finger emitted **no** synthetic click — the coincident tap was
   rejected by `requireNoPhysicalClick` — so no double actuation to fix.

**The crux the data forces:** the physical down usually arrives *before* we know the
contact will become a drag, so swallowing can't be purely reactive. Three fix
directions, to decide before coding:

- **(a) Buffer/defer the physical down** briefly; drop on promotion, replay otherwise —
  needs the timer/`Scheduler` seam v1 avoided (same cost as deferred-click).
- **(b) Adopt the physical hold as the drag** — if a physical button is already held at
  promotion, arm move→drag promotion on *it* instead of synthesizing a second press.
- **(c) Accept the leaked down but guarantee balance** — track swallowed buttons so a
  down that leaked pre-hold lets its up leak too; never leave unbalanced state (accepts
  one concurrent real click, prevents the dangling-button corruption).

### Decision table — physical event × pointer state, per drag style

As implemented under (c) — `EventInterceptor.shouldSwallow`:

| Pointer state | physical down | physical up |
|---|---|---|
| idle (no synthetic gesture) | pass | pass |
| hold **arming** (contact landed, not yet promoted — either style) | **pass** (leaks; balanced by its up also passing) | swallow iff its down was swallowed |
| hold **active** (`dragZone` set, either style) | **swallow** | swallow iff its down was swallowed |

"Swallow" = `EventInterceptor.handle` returns `nil`. Outside a synthetic drag, physical
clicks always pass — this feature adds no Feature-A suppression. The balance rule
(swallow an *up* only if its *down* was swallowed) is what keeps the straddle safe
(finding #3), and it holds **across drag-end**, so the up of a swallowed down is
swallowed even after the drag is over (scenario #4).

**The arming row collapses under (c).** Because the rule keys on "is a hold active" plus
the balance invariant, the guard needs **no** knowledge of the arming window or the drag
*style* — an arming-window down simply passes, and its up passes with it. The
style-specific arming distinction (finding #4) only mattered for the rejected approaches
(a)/(b). So `shouldSwallow` takes no `dragStyle`, and the unit tests need no style axis;
both styles still get exercised at the **pipeline** level in the HW gate, where the
recognizer's timing differs.

**Known interaction — a stuck drag makes the mouse feel dead.** Swallowing is scoped to
`dragZone != nil`, so if a synthetic hold ever *stuck*, physical clicks would be
swallowed too and the shell would stop responding until the process quits. The
stuck-button safeguards (`05` §Stuck-button safeguards; guard-on-trusted, idempotent
release, release-on-device-loss) are what keep `dragZone` from sticking, and they now
carry this extra weight. The documented recovery still works unchanged — quitting kills
the tap, and *then* a physical click clears anything left (docs/13) — because the swallow
dies with the tap. Worth an explicit HW check.

### Chosen approach (decided 2026-07-16, from the measured findings)

- **(c) balanced-swallow is the baseline.** It fixes the two worst outcomes — the
  stuck/unbalanced button and the clean mid-drag squeeze (both physical events inside
  the hold → both swallowed, the common case) — with no timer and no new seam, keeping
  the recognizer clock-free. Residual: the straddle's leaked *down* completes as a
  *balanced* concurrent real click (a double-actuation, not a corruption).
- **(b) adopt-the-physical-hold, layered on only where the physical button matches the
  drag-zone button.** It can't handle cross-zone (physical is always left/right; a
  drag zone can be middle — finding #5) and does nothing for the pure mid-drag squeeze,
  so it rides on top of (c), not instead of it. Add it only if (c)'s residual
  double-actuation proves annoying in practice.
- **(a) buffer/defer — NOT now.** The only option that eliminates the leaked down, but
  it reintroduces the `Scheduler`/timer seam and added latency that got deferred-click
  parked. Shelved: fold into **deferred click** (`10-roadmap.md`) if that's ever built.
- **Plus a recognizer guard (added after HW testing).** (c) alone was not enough: it
  assumes a synthetic hold implies the user is dragging, which `pressAndHold` violates.
  `promoteToHoldIfNeeded` now refuses to promote a contact that saw a physical click
  (scenario #9). The two halves are complementary — the recognizer stops spurious holds
  from arming, and the interceptor swallows squeezes on the holds that legitimately do.

### Scenarios covered

1. **Errant click mid-drag** — the shell squeezed during a synthetic drag posts a
   physical down/up *inside* the held button, which the OS can read as a drop or a
   competing selection. Swallowing physical down/up while a drag is active fixes it.
2. **Competing drag start** — a physical press-drag races a `tapAndAHalf` onset →
   two `…MouseDragged` streams. One owner: if a synthetic hold is arming/active,
   physical drag is suppressed.
3. **Competing single click** — a physical click ~coincident with a tap-derived
   click → double actuation. Least severe; confirm from the measurement whether to
   swallow or accept.

### Further conflict scenarios (reasoned; **not** assumed exhaustive)

Harder to enumerate up front — capture what we can, fix what we can, and expect new
sources to surface once we're logging real collisions. Reasoned so far:

4. **Balanced swallow across drag-end (invariant, not just a scenario).** If we
   swallow a physical *down* during a drag, we must swallow its matching *up* **even
   if the drag ends in between** (finger lifts, `dragZone` clears). Track swallowed
   physical buttons explicitly and drain them on their own up — never leak an
   unbalanced physical up. This mirrors, inverted, the §Stuck-button "never drop a
   button-up we pressed" invariant.
5. **Multiple physical presses within one drag.** A user may squeeze the shell
   repeatedly mid-drag. The guard is a **count/set of swallowed buttons**, not a
   boolean — each down/up pair balanced independently (see #4).
6. **Physical clicks are zone-less; synthetic clicks aren't.** A physical click
   carries no zone (it's whole-shell / cursor-located), while a synthetic click is
   derived from finger position. So a collision can be **cross-zone** — physical left
   colliding with a synthetic *right* while a finger rests in the right zone. Any
   "coincident click" arbitration must not assume same-zone.
7. **Physical click during a multi-click run.** A physical click landing inside a
   `click(1→2→3)` run (within `doubleTapGap`) can inject a phantom actuation or skew
   the count the app perceives. Distinct from the single-click case (#3) because the
   run is mid-assembly.
8. **Scroll / momentum — explicitly out of scope.** Surface-scroll produces
   `scrollWheel` events, which the interceptor does **not** touch; they pass through
   untouched even during a synthetic hold. Recorded as a boundary so it isn't
   re-litigated: de-confliction covers button/drag events only.
9. **A synthetic hold armed by a *resting* finger swallows the user's own physical
   clicks** — ***found on hardware 2026-07-16; the one we did **not** reason out.***
   Physical double-click stopped selecting a word under `pressAndHold`. Chain: click 1
   lands before `holdThreshold` (so it passes — which is why *single* clicks still
   worked); the finger keeps resting; the still contact promotes to a synthetic drag,
   because promotion **never checked `sawPhysicalClick`** (finding #2); `dragZone` is now
   set, so click 2 is swallowed as a "mid-drag squeeze." Triple-click loses clicks 2
   *and* 3. Generalized: **in `pressAndHold`, any physical click after a finger rests past
   `holdThreshold` was swallowed** — double-click merely exposed it, because its second
   click necessarily arrives later.

   **Fix — extend `requireNoPhysicalClick` to holds** (`promoteToHoldIfNeeded`): a contact
   that saw a physical click never promotes, exactly as it can never be a tap, and for the
   same stated reason — *that click is the OS's to deliver, not ours to duplicate*. This
   also fixes a **pre-existing** bug the swallow merely made visible: under `pressAndHold`
   the app was already synthesizing a drag on top of the user's physical click. And it
   resolves scenario #2 (competing drag start) **at the source**, which in turn makes the
   straddle largely moot for drag *onset* — a down during arming now prevents the
   promotion outright, so there is no hold for its up to land inside.

   **Correction to this doc:** the earlier claim that "`dragZone != nil`" is a sufficient
   signal was wrong. It is a strong proxy for "the user is dragging" under `tapAndAHalf`
   (deliberate tap-then-hold) but a **weak** one under `pressAndHold`, where a merely
   resting finger arms it. The swallow rule still needs no `dragStyle`, but it depends on
   the recognizer not arming spurious holds — which is why the guard belongs there.

### Tests

- Unit: feed synthetic `CGEvent`s to `EventInterceptor.handle(...)` across the table
  above for **each** `dragStyle`; assert swallow vs pass, and that no button-up is
  ever dropped for a held button (mirrors §Stuck-button hardening, `05` §Press/release).
- HW exit gate: run each measured scenario on the Magic Mouse under **both** drag
  styles; confirm no corrupted drag and no double actuation.

## Diagnostics mode — opt-in troubleshooting log ✅ *(graduated from `10-roadmap.md`; done; HW-verified 2026-07-16 — commits `fde8cd9`, `e26f5e7`, `abb101b`, `ac24f82`, `90492ef`, `fbc1036`, `2f540b7`; 224 tests)*

Promoted straight after de-confliction, and for its sake: that section's measured
findings only existed because the hardware was instrumented, and scenario #9 was
found **only** by testing on it. When a user reports "my drag dropped", in-situ data
is the only way to see what happened — synthetic reproduction is both harder and less
representative than everyday use. *As built:*

- **The recorder is the one `log-conflicts` already used.** `ConflictLog` → 
  `AppCore.DiagnosticsLog`, `TappingEmitter` → `EventOutput.TeeingEmitter` (now generic
  over any `ButtonEmitting`). The streams needed to *build* de-confliction are the ones
  needed to *explain* it, so the harness and the app write the identical format from the
  same writer — which keeps `log-conflicts` a real hardware check on the shipping
  recorder rather than on a near-cousin (docs/13).
- **Four streams**, one row each, `hold_active`-tagged: `physical`, `gesture`, `synth`,
  `contacts`. **`gesture` and `synth` are a pair and the gap between them is the
  diagnosis:** `gesture` is what the recognizer produced (pre-policy, pre-swap — the
  *finger's* zone), `synth` is what was actually posted. A `gesture` row with no `synth`
  row is a gesture the policy dropped — "I tapped and nothing happened", a likelier field
  report than a collision. The two zones disagreeing is a left-handed arrangement.
- **The roadmap named the wrong seam, and it mattered.** It said to tee `synth` from
  `AppCoordinator.onGesture`; that fires *pre-policy*, so `hold_active` would have claimed
  a hold for a gesture the policy dropped — and that column is what the whole collision
  analysis above pivots on. Recording tees at the **emitter boundary** instead, which
  needed no coordinator change (`AppCoordinator.init` already takes an injected emitter).
  `onGesture` earns its place as the separate `gesture` stream, never touching
  `hold_active`. (The roadmap's other seam note was already stale: the physical tee landed
  with Feature B as `EventInterceptor.onPhysicalButtonEvent`.)
- **`AppCore.DiagnosticsSession`** owns the lifecycle — location, naming, caps, pruning —
  and deliberately knows nothing of the app's object graph: it returns a log and the caller
  wires the tees. That's what keeps it testable with no hardware and no writes to the real
  `~/Library/Logs` (inject `directory`, `now`, `pollInterval`).
- **`~/Library/Logs/MagicButtons/`**, not Application Support: the macOS convention for
  user-facing diagnostic logs, so Reveal lands somewhere recognizable and Console.app finds
  it. Writable directly because the app is unsandboxed by necessity (docs/07). Application
  Support is for data an app needs to function; these are disposable.
- **Caps stop, they don't truncate** (5 MB / 30 min / keep 5): a log that silently drops its
  middle is worse than a short one, since the reader can't tell which they hold. Polled, not
  checked per row, so an *idle* session still stops. The poll is a `Task`, not a `Timer` —
  a `Timer` is non-Sendable (Swift 6 forbids touching it from a nonisolated `deinit`, and
  `invalidate()` must run on the installing thread) and a default-mode timer is starved by
  menu tracking, which for a menu-bar app is exactly when it's in use.
- **Never in `AppSettings`.** That struct persists to `UserDefaults` and is what
  Export/Import ships to another Mac, so recording would have stayed on silently across
  relaunches and followed the user to a second machine. Session-only state on `AppModel`;
  always starts off.
- **Fixed location + Reveal, not an `NSSavePanel`** (the Export-settings idiom, docs/09):
  the toggle must start recording *now*, and a write-as-you-go file survives the force-quit
  that ends the very stuck-button session worth reading. For the same reason rows are handed
  to the writer queue **individually, not batched** — batching trades the log's tail for
  fewer dispatches, and the tail is the point. I/O still leaves the main thread, which is
  the actual requirement: recording must not perturb the timing it records.
- **Zero overhead when off:** the frame and gesture tees cost one nil check each (both were
  already claimed by the visualizer), the other two streams aren't installed at all, and no
  file, task, or allocation exists until the toggle flips.
- **UI** — a Troubleshooting section at the bottom of the tab already named *Status &
  Diagnostics* (docs/09 §Status), where first-run already sends anyone missing a grant, and
  last within it because recording is the escalation for when every readout looks fine. It
  reuses two existing idioms: switch + explainer-that-swaps-to-an-orange-note
  (`launchAtLoginNote`), and explainer-tracks-current-state (`dragStyleHelp`). While
  recording it names the auto-stop as a **clock time** — at that point the question is "have
  I got time to reproduce this?", which a deadline answers and a duration makes you compute;
  it's a fixed instant, so it needs no countdown ticking into the view. The cap figures are
  read from the session's real limits, so the copy can't drift from what's enforced.
- **Privacy** (why it's attachable to a public bug report, and stated plainly in the pane):
  zones, gestures, and timings only. Never text, cursor positions, or key presses — position
  is consumed only to derive a zone.
- **Two hazards the tests flushed out:** toggling off and back on inside one second reused
  the timestamped filename and **truncated the log just recorded** (names now uniquify); and
  pruning sorts by name, which only tracks chronology while the clock moves forward, so a
  **backwards jump (NTP) could delete the live file mid-session** (it's excluded explicitly).
- **Tests:** `DiagnosticsLogTests` (CSV contract — `hold_active`, `swallowed`, the
  gesture/synth split, flush-on-close), `DiagnosticsSessionTests` (caps against an injected
  clock, pruning, naming, the auto-stop deadline), `TeeingEmitterTests`, and
  `DiagnosticsWiringTests` — which pins the *pattern* `AppModel` follows, against the
  shipping pieces with fakes, including the regression test for the seam choice above
  (feature off ⇒ recognized but not posted ⇒ `gesture` row, no `synth` row). `swift test`
  green at **224** (+45). **`AppShell` has no test target**, so `AppModel`'s own wiring rests
  on `xcodebuild` + the hardware gate — the reason the wiring pattern is pinned in `AppCore`.
- **Exit ✅ (HW-verified 2026-07-16):** recording toggled on writes a live log to
  `~/Library/Logs/MagicButtons/`; Reveal selects it; all four streams land; the auto-stop
  time reads correctly. Layout confirmed in the real pane.

## In progress / next

Sparkle is **DONE (HW-verified 2026-07-15)**: in-app integration, EdDSA keys, and the full
release pipeline (build-number forcing function → re-signed helpers → notarize with
status-check → signed appcast → `--publish` to Codeberg Pages **+ a mirrored Codeberg
Release** for the hand-download) are built, a real notarized build 3 is **live**, and a build
2 → 3 auto-update **installed cleanly on hardware**. The
beta channel (S4) is deferred to `10-roadmap.md`.

**Click/drag de-confliction** and **diagnostics mode** are both DONE + HW-verified
2026-07-16 (sections above), and **1.1.1 (build 4) SHIPPED 2026-07-17** — notarized Accepted
on the first submission, live on Codeberg Pages + a mirrored Codeberg Release
(`v1.1.1-4`), auto-update offered to 1.1.0.

**Release notes in the Sparkle appcast — DONE + verified by the 1.1.1 cut.** The appcast
carried no notes through 1.1.0, so the update dialog showed an empty body — not a regression,
but 1.1.1 is the first release that *changes clicking behavior*, so silent notes cost
something. `release.sh` now defaults to the tracked `docs/release-notes/UNRELEASED.md`,
unwraps it, writes it to `updates/<DMG basename>.md` (the basename carries the build number,
so a hand-named file would go stale on every bump), passes `--embed-release-notes` to
`generate_appcast`, feeds the same text to the Codeberg Release body, and clears the file
after a successful publish. See docs/07 §Release notes for the rationale and the guards.

The cut confirmed the appcast path end to end: the live feed's newest item is build 4 with a
valid `edSignature` and a 2052-char `<description sparkle:format="markdown">`, no stub leak,
and **the update dialog renders it perfectly on hardware**.

**What the cut caught that no dry run could.** The *same text* rendered correctly in Sparkle
and badly on the Codeberg release page — ragged right edge, worst where bold and links made
the source line length diverge from the rendered one. Cause: a single newline inside a
paragraph is ambiguous markdown, and the two renderers resolve it oppositely (Sparkle soft,
Forgejo hard `<br>` — 15 of them in the page). So "one source feeds both, they cannot
disagree" was true of the *text* and false of the *rendering* — the property was weaker than
it read. Fixed by unwrapping at cut time (docs/07), which removes the ambiguity instead of
tuning for one renderer; the live 1.1.1 body was patched via the Forgejo API (no rebuild —
notes live in the feed and the release body, not the DMG).

Other candidates live in `10-roadmap.md` (e.g. deferred-click timing, `clickTiming =
.deferred`, specified in docs/03 §Click timing; and Feature A, suppress physical clicks,
deferred with a full design capture in `05` §Suppress physical clicks).
