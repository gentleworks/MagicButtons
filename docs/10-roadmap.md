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

- **Diagnostics mode (in-app troubleshooting log)** — ⭐ **probable next feature**, after
  Feature B lands. An **opt-in** mode that records real interaction to a log the user can
  attach to a problem report.

  *Why it's near the front:* synthetic reproduction is **harder and less representative
  than everyday interaction**. The Feature B measurement session (`14-post-v1.md`
  §Measured findings) made the case: producing clean `tapAndAHalf` collision captures took
  deliberate effort, and the decisive finding — the straddle — is a timing artifact of
  *natural* use. When a user reports "drags sometimes drop," in-situ data is the only way
  to see what actually happened. It also pairs with **Feature A**: if suppression ever
  ships, in-situ logs are how a stuck-mouse report gets debugged.

  *Seams already in place (most of the work is done):*
  - `AppCoordinator.onFrame` and `onGesture` are already **optional read-only tees** (the
    Visualizer uses them). A recorder just sets them.
  - Physical clicks need one small addition — the coordinator monopolizes
    `clickSource.onPhysicalClickChange` in `wire()`; expose an optional `onPhysicalClick`
    tee composed there, same pattern as `onGesture` (~2 lines).
  - `ConflictLog` (added with `mb-dev log-conflicts`, docs/13) is the reusable basis: a
    three-stream, `hold_active`-tagged CSV writer. Promote it into `AppCore`.

  *Hard requirement — zero overhead when off:* nil closures, no allocation, no file
  handle; nothing is installed until the toggle flips. When **on**, buffer rows and flush
  on a background queue so file I/O can't perturb the very timing being recorded.

  *Privacy:* records event **types, zones, and timings** — no text, no cursor coordinates
  (position is consumed only to derive a zone), so a log is safe to attach to a bug report.
  Opt-in and clearly labeled regardless.

  *Still needs its own (small) design pass:* the UI affordance (toggle + "Reveal log" /
  "Export for bug report"), a log size cap / rotation, and the write location
  (Application Support).

- **Sparkle beta channel** — a `beta` appcast channel for a tester track (deferred from the
  Sparkle work 2026-07-15; no testers yet). Cheap when needed: app-side
  `SPUUpdaterDelegate.allowedChannelsForUpdater:` → `["beta"]` behind an opt-in pref;
  release-side `generate_appcast --channel beta` (a `release.sh --beta` flag). Build-number
  increments per beta, clean version string (the earlier decision).
- **Suppress physical clicks (Feature A)** — optionally consume the hardware
  left/right click so tap-to-click *replaces* rather than *adds*. Mechanism already
  anticipated: the `EventInterceptor` active tap flips from pass-through to consuming.
  **Deferred, not scheduled** — real system-wide-wedge risk, no current need. Full
  design capture (measurement-first process, the inert-vs-re-emit fork, modifier/chord
  + device-scope hazards, two-tier safety story) lives in **`05-event-output.md`
  §Suppress physical clicks**. Its de-confliction prerequisite ships separately as
  **Feature B** — **`14-post-v1.md` §Click/drag de-confliction**, queued next.
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
| Diagnostics mode | `AppCoordinator.onFrame`/`onGesture` read-only tees (nil = off, zero cost); `ConflictLog` in `mb-dev` as the recorder |
| Per-app profiles | single policy layer that filters gestures by feature |
| Multi-finger | `fingerCount` on `ButtonGesture`; frame-level touch sets |
| More button kinds | `ButtonEmitting` protocol; policy chooses emitter |
| Drag/press variants | `press`/`release` already in `ButtonEmitting`; `dragStyle` selects the trigger |
| Deferred click timing | recognizer already routes single/double/drag through `WAIT_SECOND`/`SECOND_ACTIVE`; adds only withholding + a flush timer |
| Per-device settings | `deviceID` on `SurfaceTouch` |
| Cross-Mac sync | `Codable` config; export/import file |
