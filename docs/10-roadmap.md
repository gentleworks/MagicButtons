# Roadmap (post-v1)

Explicitly deferred features. Listed here so v1 can leave the right seams in
place without building them now.

## Graduated (promoted out of this roadmap)

- **Auto-updater (Sparkle)** — promoted 2026-07-15; **done + HW-verified**. In-app
  integration (Sparkle 2.9.4, app-target only) + EdDSA keys + the full release pipeline
  (build-number forcing function → re-signed helpers → notarize → signed appcast →
  `--publish` to Codeberg Pages) are built, a notarized **build 1.1.0 (3)** is **live** on
  `anguiano.codeberg.page/MagicButtons/`, and a build 2→3 auto-update **installed cleanly on
  hardware**. Decisions: hosting = Codeberg Pages, checks = automatic + manual, format = DMG.
  Recorded in `14-post-v1.md` §Sparkle. **Still deferred:** the **beta appcast channel**
  (in v2 candidates below).

- **Triple-click** — promoted because it has regular use (e.g. selecting a whole
  line, not just a word). It was the natural extension of the double-click run — the
  per-zone chain now climbs `click(1)→click(2)→click(3)`, capped by
  `GestureConfig.maxClickCount` (default 3) — so it needed no timer or new
  recognizer, unlike the still-deferred items below. **Built + HW-verified;** recorded
  in `14-post-v1.md`.

## v2 candidates

- **Sparkle beta channel** — a `beta` appcast channel for a tester track (deferred from the
  Sparkle work 2026-07-15; no testers yet). Cheap when needed: app-side
  `SPUUpdaterDelegate.allowedChannelsForUpdater:` → `["beta"]` behind an opt-in pref;
  release-side `generate_appcast --channel beta` (a `release.sh --beta` flag). Build-number
  increments per beta, clean version string (Paul's earlier decision).
- **Suppress physical clicks** — optionally consume the hardware left/right click
  so tap-to-click *replaces* rather than *adds*. Mechanism already anticipated:
  the `EventInterceptor` active tap flips from pass-through to consuming
  (`05-event-output.md`). Needs care around drag and modifier clicks.
- **Per-app profiles** — different feature sets / zones per frontmost app. The
  policy layer is designed to accept a frontmost-app signal (via
  `NSWorkspace.didActivateApplication`); v1 wires nothing but keeps feature
  filtering in one place so this slots in.
- **Explicit multi-finger gestures** — map two/three-finger taps or holds in a
  zone to actions (Mission Control, shortcuts). Finger count already travels on
  `ButtonGesture`; needs new recognizers + an action policy beyond buttons
  (`ShortcutEmitting` sibling of `ButtonEmitting`).
- **Vertical (`y`) zone component / active band** — see `08` open question; may
  arrive as an optional tap-rejection band before full 2D zones.
- **iCloud settings sync** — automatic cross-Mac sync if the file export/import
  in v1 proves insufficient.
- **Double-tap-then-hold → double-click-drag** (word-select + drag) — a natural
  extension of the `SECOND_ACTIVE` state in the recognizer.
- **Deferred click timing ("wait for a second tap")** — an **orthogonal**
  `GestureConfig.clickTiming = .deferred` option that **withholds** the first tap's
  click until the second interaction resolves, so a `tapAndAHalf` drag becomes a
  clean single-press drag (no double-click-before-drag) — the behavior other Magic
  Mouse utilities ship, and the only artifact-free drag available to users who rest
  a finger (and so can't use `pressAndHold`). **Fully specified in
  `03 §Click timing`.** Deferred because it adds ~`doubleTapGap` of single-click
  latency (opt-in) and needs a **timer / `Scheduler` seam** that v1's clock-free
  recognizer otherwise avoids — the main implementation cost. *(The `pressAndHold`
  drag style shipped in v1 and already gives an artifact-free precise drag for users
  who don't rest a finger; this covers the ones who do.)*
- **Drag lock** — tap-and-a-half that latches the drag until a subsequent tap,
  for long drags.

*(Auto-updater (Sparkle) graduated 2026-07-15 — see the Graduated section above.)*

## Carried forward from v1 (tuning & known limitations)

Not features — smaller items that surfaced during the v1 build (`11-build-plan.md`)
and were consciously left for later. Kept here so they aren't lost.

- **`pressAndHold` gate fine-tuning** — the still/single/duration gates were set from
  one logged HW session; revisit against more sessions. The data path already exists
  (`mb-dev log-gestures`, docs/13).
- **Palm size-reject path is real-world-untested** — a palm never registered as a
  *distinct* multitouch contact in testing, so `GestureConfig.maxSize`'s reject branch
  couldn't be exercised on hardware (9.1). A standing known-limitation, not an action
  item; would only matter if a palm ever does register as its own contact.
- **Stuck-button absolute max-hold cap** — considered and **declined for v1**: a coarse
  longstop that force-releases a synthetic hold after some maximum. Guard-on-trusted +
  release-on-device-loss (`14-post-v1.md` §Stuck-button hardening) cover the realistic
  strand paths, so this stays optional unless a new strand case appears.

## Seams v1 deliberately leaves for the above

| Future feature | v1 affordance already in place |
|----------------|-------------------------------|
| Suppress clicks | active `EventInterceptor` tap (pass-through now) |
| Per-app profiles | single policy layer that filters gestures by feature |
| Multi-finger | `fingerCount` on `ButtonGesture`; frame-level touch sets |
| More button kinds | `ButtonEmitting` protocol; policy chooses emitter |
| Drag/press variants | `press`/`release` already in `ButtonEmitting`; `dragStyle` selects the trigger |
| Deferred click timing | recognizer already routes single/double/drag through `WAIT_SECOND`/`SECOND_ACTIVE`; adds only withholding + a flush timer |
| Per-device settings | `deviceID` on `SurfaceTouch` |
| Cross-Mac sync | `Codable` config; export/import file |
