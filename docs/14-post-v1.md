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

## In progress / next

Sparkle is **DONE (HW-verified 2026-07-15)**: in-app integration, EdDSA keys, and the full
release pipeline (build-number forcing function → re-signed helpers → notarize with
status-check → signed appcast → `--publish` to Codeberg Pages **+ a mirrored Codeberg
Release** for the hand-download) are built, a real notarized build 3 is **live**, and a build
2 → 3 auto-update **installed cleanly on hardware**. The
beta channel (S4) is deferred to `10-roadmap.md`. Nothing else committed to build right now;
candidate features live in `10-roadmap.md` (nearest: deferred-click timing,
`clickTiming = .deferred`, specified in docs/03 §Click timing).
