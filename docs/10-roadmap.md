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

- **Diagnostics mode (in-app troubleshooting log)** — promoted 2026-07-16 right after
  Feature B, and for its sake: that work's findings existed only because the hardware was
  instrumented, and its decisive bug was found only by testing on it. **Built +
  HW-verified;** recorded in `14-post-v1.md` §Diagnostics mode. An opt-in Troubleshooting
  toggle in Settings → Status writes a four-stream, `hold_active`-tagged CSV to
  `~/Library/Logs/MagicButtons/`, capped and pruned, recording zones/gestures/timings only
  — never text or cursor positions — so it's safe to attach to a bug report.

  Two seam notes this roadmap got wrong, corrected there: teeing the *emitted* stream from
  `AppCoordinator.onGesture` would have been a bug (it fires **pre-policy**, so
  `hold_active` would claim holds the policy dropped — recording tees at the emitter
  boundary instead, and `onGesture` becomes its own pre-policy stream); and the physical
  tee needed no work, having already landed with Feature B as
  `EventInterceptor.onPhysicalButtonEvent`. **Still deferred:** Feature A (suppress physical
  clicks), which this pairs with — in v2 candidates below.

## v2 candidates

- **Sparkle beta channel** — a `beta` appcast channel for a tester track (deferred from the
  Sparkle work 2026-07-15; no testers yet). Cheap when needed: app-side
  `SPUUpdaterDelegate.allowedChannelsForUpdater:` → `["beta"]` behind an opt-in pref;
  release-side `generate_appcast --channel beta` (a `release.sh --beta` flag). Build-number
  increments per beta, clean version string (the earlier decision).
- **Homebrew cask** — a `brew install --cask magicbuttons` channel alongside the DMG.
  Researched end-to-end 2026-08-01 and **deferred on cost, not on feasibility**: the cask
  itself is written and passes `brew style`, `brew audit --cask --online` and
  `brew livecheck` against the live appcast (Homebrew 6.0.14). It is recorded in full below
  so none of this needs re-deriving when the blocker clears.

  **The blocker is notability, and it is measured, not judged.** `brew audit --new` — the
  submission gate for the official `homebrew/cask` repo — fails outright:

  ```
  Error: 1 problem in 1 cask detected.
   - Forgejo repository not notable enough (<30 forks, <30 watchers and <75 stars)
  ```

  Homebrew queries Codeberg/Forgejo natively, so **the host is not the problem** —
  `gram`, `librewolf` and `openrgb` all ship from `codeberg.org` URLs today. The repo is at
  1 star / 0 forks / 1 watcher. Note the audit's message understates the bar that actually
  applies: `Package-Acceptance-Policy.md` §Notability sets **30 forks / 30 watchers /
  75 stars** in general but **90 / 90 / 225 for a self-submission by the repository owner**,
  which is what a submission from here would be. Two documented routes in besides the
  metrics: a maintainer/prolific-contributor submission, or "substantial, independently
  verifiable public interest and multiple requests for inclusion" — i.e. **demand to point
  at is itself the qualification**, which is the argument for waiting rather than pushing.

  **Nothing in the release pipeline needs to change.** Homebrew's `:sparkle` livecheck
  strategy reads the existing appcast, takes `shortVersionString` + `version` and joins them
  as `1.1.2,5` (`bundle_version.rb#nice_version`) — which maps straight onto the
  `MagicButtons-1.1.2-5.dmg` / `v1.1.2-5` naming via `version.csv.first`/`.second`. Verified:
  `brew livecheck` resolves the published feed to exactly the declared version. The Codeberg
  Release asset is byte-identical to `updates/`, so the `sha256` can be taken from the local
  DMG at cut time without a re-download.

  **Why this needs a second repo, which is why it's deferred.** A tap is the *only*
  third-party mechanism — brew 6 rejects both a loose file and a URL:

  ```
  $ brew info --cask ./magicbuttons.rb
  Error: Homebrew requires casks to be in a tap, rejecting: ...
  $ brew info --cask http://localhost:8731/magicbuttons.rb
  Error: Cask 'magicbuttons' is unavailable: No Cask with this name exists.
  ```

  And a `Casks/` directory in *this* repo would make a poor tap. `brew tap` is a plain
  `git clone` with no `--depth` and no `--single-branch` (`tap.rb:708-719`), so everyone who
  taps clones **every branch** — `pages` included, which carries the published DMGs and
  deltas: **12.3 MB today against 0.9 MB for `main`**, growing by roughly one DMG (~3 MB) per
  release, permanently, since git keeps the blobs after a delete. The checkout itself would
  be fine — `main` is the default branch and would hold the `Casks/` — but the download would
  not. A separate `homebrew-magicbuttons` repo is a few KB that stays a few KB.

  **Decision (2026-08-01): hold.** The gain is discoverability and scriptable/dotfile
  installs; Sparkle already handles updating and the DMG is one click. That did not justify
  maintaining a second repo. Revisit when there is demand to point at — which, per the policy
  above, is also what would make the official repo reachable and the tap unnecessary.

  **When it is picked up**, the release-side work is one step: a `do_tap_release` after
  `do_codeberg_release` in `scripts/release.sh` that rewrites `version` + `sha256` from the
  DMG already on disk and pushes — the same shape as the existing `pages` worktree push, and
  the same "channels can't drift apart" rule as docs/07 §Distribution mechanics. `auto_updates
  true` is deliberate and gives the intended split: a plain `brew upgrade` leaves the app
  alone and lets Sparkle own updates, while `brew upgrade --greedy` picks it up.

  The cask as validated — `version`/`sha256` are a snapshot of 1.1.2 (5) and must be
  refreshed to the then-current build:

  ```ruby
  cask "magicbuttons" do
    version "1.1.2,5"
    sha256 "0288c64355ddae6cf04c7beb572c4eb18526713b6837c317dabc57f9be1cedbc"

    url "https://codeberg.org/anguiano/MagicButtons/releases/download/v#{version.csv.first}-#{version.csv.second}/MagicButtons-#{version.csv.first}-#{version.csv.second}.dmg"
    name "MagicButtons"
    desc "Middle button and tap-to-click for the Apple Magic Mouse"
    homepage "https://codeberg.org/anguiano/MagicButtons"

    livecheck do
      url "https://anguiano.codeberg.page/MagicButtons/appcast.xml"
      strategy :sparkle
    end

    auto_updates true
    depends_on macos: :sonoma

    app "MagicButtons.app"

    uninstall quit:       "com.gentleworks.MagicButtons",
              login_item: "MagicButtons"

    zap trash: [
      "~/Library/Caches/com.gentleworks.MagicButtons",
      "~/Library/HTTPStorages/com.gentleworks.MagicButtons",
      "~/Library/Logs/MagicButtons",
      "~/Library/Preferences/com.gentleworks.MagicButtons.plist",
    ]
  end
  ```

  Two details that cost a machine check rather than a guess: `depends_on macos: :sonoma`
  is the minimum-version form (`>= :sonoma` is a `brew style` offence, autocorrected to
  this), and the four `zap` paths are the ones the app is actually observed to create —
  `HTTPStorages` is Sparkle's, and there is no `Application Support` or
  `Saved Application State` directory to reclaim.

- **Suppress physical clicks (Feature A)** — optionally consume the hardware
  left/right click so tap-to-click *replaces* rather than *adds*. Mechanism already
  anticipated: the `EventInterceptor` active tap flips from pass-through to consuming.
  **Deferred, not scheduled** — real system-wide-wedge risk, no current need. Full
  design capture (measurement-first process, the inert-vs-re-emit fork, modifier/chord
  + device-scope hazards, two-tier safety story) lives in **`05-event-output.md`
  §Suppress physical clicks**. Its de-confliction prerequisite ships separately as
  **Feature B** — **`14-post-v1.md` §Click/drag de-confliction**, queued next.
- **Visualizer: non-visual + threshold visibility** — **all three strands DONE + HW-verified**
  (1–2 on 2026-07-30, PR #11; 3 on 2026-07-31, PR #12). Split out of the accessibility pass
  2026-07-30, which deliberately stopped at the UI's labels and left the visualizer's
  *picture* alone. The record of what was built and learned is `docs/14-post-v1.md` — two
  entries, "true-size contacts, the travel budget, and a circular gate" and "the spoken
  readout"; the design is `docs/06`. Kept here in full because the strands below are what
  the work was *estimated* as, and both estimates missed in instructive ways: strand 2 set
  out to draw the gate and ended up correcting it, and strand 3's named risk (announcement
  flooding) turned out less dangerous than the one nobody wrote down (announcement *scope*).
  1. **Feed the visualizer from the interpreting machinery. — DONE.** Per-contact accumulation
     (distance from the `.began` origin) is currently implemented **twice** —
     `MouseGestureRecognizer.swift:163` and `ContactMetrics.swift:219`, the latter
     "deliberately parallel" per its own header. **Decision: unify to one accumulator**
     rather than add a third copy in the visualizer, so what's drawn is what decides.
     `ContactMetrics` also needs live in-flight state exposed — today it only emits a
     `ContactSample` per *completed* contact — and it is currently dev-only (`mb-dev`,
     `Sources/App/main.swift:421`), so this puts it on the shipping per-frame path.
     Keep `Visualizer` on `TouchKit` alone: it declares its own value type and
     `AppShell/AppModel` translates, exactly as `ButtonGesture` →
     `VisualizerModel.RecognizedGesture` already does at `AppModel.swift:237-245`.
     Costs a mirror of `TapVerdict` on the visualizer side; that's the boundary's price.

     *As built:* the duplication above is **gone** — `ContactAccumulator` is the one
     accumulator, and the present tense in this paragraph describes the state before the
     work, not now. The boundary held as planned: `Visualizer` still depends on `TouchKit`
     alone, and the mirrored verdict was paid for.
  2. **Draw the tap-travel budget — DONE**, and it changed the gate. Around the contact origin, so you can see how close a
     tap came to being rejected as a drag, and *which* gate it tripped (`TapVerdict`
     already answers that). A separate "just landed" cue was considered and **dropped as
     redundant** with this (and `holdBegan` already flashes its own badge).

     **Aspect-ratio question: RESOLVED — the gate itself was corrected.** It shipped
     first as an ellipse, faithfully, because the gate *was* anisotropic (normalized
     Euclidean on a 1.76:1 portrait sensor). Drawing that shape is what made the problem
     legible: hands-on, drift proved not to favour fore-aft the way the gate assumed, and
     the logged still press had already shown near-equal physical drift being scored ~2×
     on `x`. Travel is now Euclidean in **millimetres** and the ring is a circle
     (docs/04 §Why travel is measured in millimetres).

     **Radius: settled at 4.1 mm**, hands-on 2026-07-30 — possibly a touch loose for a
     steady hand, and kept that way **deliberately**: the threshold should have room for
     someone whose hands shake, and it is a slider for anyone who wants it tighter.
     Revisit from use, not from theory.

  3. **The visualizer for users who can't see it — DONE** (docs/06 §The spoken readout,
     docs/14). The estimate held for the code and was wrong about which design problem
     bites. The predicted one — flooding `AccessibilityNotification.Announcement` — is
     real, but the "value changed AND ≥0.3 s since the last" gate proposed for it
     *causes* a worse bug: a landing finger changes the zone ~180 ms before the tap
     registers, so that gate speaks the zone and suppresses the **gesture**. Zone and
     gesture are separated by intent instead (gestures always; zone only after a 0.35 s
     dwell a tap can't reach), and the open question resolved as "both, but not equally".

     The cost that wasn't estimated: **scope**. The touch stream is live for as long as
     the app runs, so announcing from the model would have named a zone every time the
     user brushed the mouse, in every app, all day. Posting lives in the view, gated on
     VoiceOver running and the window being frontmost.

     **HW VoiceOver-verified 2026-07-31.** The dwell (0.35 s) and the wording are judged
     by ear rather than by test, and both stood up on the first pass; nothing turned.
     Forefront-only scoping confirmed as wanted, not merely as built.

  Note phase is **not** a travel signal and never was: raw state 3 → `.began` fires for a
  single frame (`PhaseMapping.swift`, pinned from bring-up as `3 → 4 … 4 → 5 → 6 → 7`),
  state 4 → `.moved` means "touching, moving *or still*", and `.stationary` is never
  emitted at all. So the green `.began` dot is invisible by construction, and any
  landing/lifting cue must be a **timed hold** (the badge's 900 ms `flashClearTask` is the
  idiom), not a colour.
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
| Diagnostics mode | *(shipped — see Graduated)* the `onFrame`/`onGesture` read-only tees and the injected `emitter` all became recording seams (nil = off, zero cost) |
| Per-app profiles | single policy layer that filters gestures by feature |
| Multi-finger | `fingerCount` on `ButtonGesture`; frame-level touch sets |
| More button kinds | `ButtonEmitting` protocol; policy chooses emitter |
| Drag/press variants | `press`/`release` already in `ButtonEmitting`; `dragStyle` selects the trigger |
| Deferred click timing | recognizer already routes single/double/drag through `WAIT_SECOND`/`SECOND_ACTIVE`; adds only withholding + a flush timer |
| Per-device settings | `deviceID` on `SurfaceTouch` |
| Cross-Mac sync | `Codable` config; export/import file |
