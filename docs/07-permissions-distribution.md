# Permissions & Distribution

## TCC permissions required

| Permission | Why | API to check | Pane |
|-----------|-----|--------------|------|
| **Accessibility** | Post synthesized mouse buttons (`CGEvent.post`) + install the event tap for physical-click detection | `AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions` | Privacy & Security → Accessibility |

**Accessibility is the only required grant.** Input Monitoring was **dropped in
Phase 9** after clean-machine testing proved it doesn't gate the private
`MultitouchSupport` contact stream (frames flow with the app absent from that pane)
and that `IOHIDCheckAccess(ListenEvent)` false-positived — see docs/08 §C.

It cannot be granted programmatically. First-run flow:
1. Check Accessibility on launch.
2. If missing, show an explainer and a button that deep-links to the exact pane
   (`x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`)
   — the `request` call also registers the app in that pane so it can be toggled.
3. Re-check on the status poll and when the app regains focus (user returns from
   System Settings). On a mid-run grant, re-arm the event tap in place
   (`AppCoordinator.retryStream`); if it still can't install, offer **Quit & Reopen**
   (`AppModel.needsRelaunch` → `relaunch()`).
4. Degrade gracefully: without Accessibility the visualizer still works (touches are
   ungated) but clicks don't post — surface that clearly rather than failing silently.

The touch stream needs no grant, so a "can't read touches" state maps to device
presence + real frame arrival (`isDeviceConnected`, `touchesNotArriving`), not to a
permission.

## App shape

- **Menu-bar (LSUIElement) app**, no Dock icon. Menu for enable/disable, open
  settings, open visualizer, quit.
- Runs continuously; **Login Item** via `SMAppService` (confirmed for v1;
  toggle in Settings) so it's present after restart.
- Settings window: per-feature enable, status/diagnostics, and an Advanced
  section (zones, timings, thresholds). Full spec in `09-settings-and-status.md`.

## Signing & notarization

- **Developer ID** signing (not App Store). Hardened Runtime **on**.
- Notarization: private-framework usage is permitted for Developer-ID/notarized
  apps (unlike the App Store). **Decided:** resolve private symbols at runtime
  via `dlopen`/`dlsym`, **scoped to the multitouch contact stream only**
  (`04-multitouch-backend.md`) — avoids embedding a link reference to a private
  framework and keeps the private surface minimal. Everything else is public,
  link-time API.
- Entitlements: Hardened Runtime with no special exceptions expected for
  `dlsym`-based access; verify during first notarization dry-run. Do **not** need
  `com.apple.security.cs.disable-library-validation` unless we end up linking the
  private framework directly.

## Why not the Mac App Store

The App Store was never viable, and for **two independent reasons** — either one
is disqualifying on its own:

1. **Private frameworks.** The core contact stream comes from Apple's private
   `MultitouchSupport` framework. The App Store forbids non-public API; Developer
   ID / notarization permits it (see above).
2. **The sandbox.** The Mac App Store *mandates* the App Sandbox
   (`com.apple.security.app-sandbox`) — it has been non-negotiable for all new
   apps and updates since 2012. There is no "opt out and get reviewed anyway."

These are stacked hard requirements, not one problem counted twice. Even a
hypothetical rewrite using only public APIs would still fail on #2, because the
sandbox specifically forbids what this app *does*, not just which APIs it calls:

- **Global input interception** — a session/HID-level `CGEventTap` to watch all
  mouse/trackpad input system-wide. Sandboxed apps can't create system-wide taps.
- **Synthesizing events into other apps** — posting `CGEvent`s to drive
  clicks/drags in the frontmost app. The sandbox's whole model is that a process
  may not reach out and control other processes.
- **Accessibility "trusted process" control** (`AXIsProcessTrusted`) — granting
  this is fundamentally at odds with sandbox isolation.

The sandbox is deny-by-default: a process gets an isolated container and punches
specific, Apple-blessed holes via entitlements. No entitlement grants "tap all
system input and puppet other applications" — that would defeat the sandbox's
purpose. (The old `com.apple.security.temporary-exception.*` entitlements are
deprecated and not accepted for new App Store submissions regardless.)

So **the sandbox is the deeper blocker**: the private-framework issue could in
principle be engineered around; the sandbox one cannot, because the app must run
*outside* the sandbox to function. Notarization is a malware scan + signature
check — it requires neither the sandbox nor public-only API, which is exactly why
the unsandboxed, notarized DMG ships (`scripts/release.sh`). Direct notarized
distribution was always the only legitimate channel for an app of this shape.

## Compatibility posture

- Pin and verify the `MTTouch` layout per OS at startup (see backend doc). On
  mismatch, refuse to interpret frames and show an "unsupported macOS build"
  diagnostic instead of feeding garbage coordinates downstream.
- Keep a small compatibility table (OS version → verified struct/size/symbol
  names) in the adapter, updated as new macOS releases are tested.

## Distribution mechanics

- Ship a signed, notarized, stapled `.app` in a DMG or zip.
- Optional Sparkle-style auto-update (out of v1 scope).
- No sandbox (incompatible with the multitouch access and global event posting).

### As built (Phase 9.5) — `scripts/release.sh`

One command builds the Phase 9 exit artifact: a Release `.app` signed with **Developer
ID Application** (Hardened Runtime + secure timestamp),
packaged into a signed DMG, notarized, and stapled (DMG **and** the `.app`, which share
the notarized cdhash). The local-dev signing default in `AppShell/Signing.xcconfig`
(ad-hoc / Apple Development cert) is untouched — the script overrides signing on the
`xcodebuild` command line (highest precedence) for the release build only.

- **Entitlements confirmed:** the unsandboxed app + Hardened Runtime signs and passes
  `codesign --verify --deep --strict` with **no exceptions** — `dlopen` of the
  Apple-signed `MultitouchSupport` private framework is permitted under library
  validation, so `com.apple.security.cs.disable-library-validation` is *not* needed
  (as predicted above). Verified end-to-end locally through the DMG (`--skip-notarize`).
- **Notary credential (one-time), then it's automatic:**
  ```
  xcrun notarytool store-credentials "MagicButtons-Notary" \
    --apple-id "<apple-id>" --team-id "<team-id>" \
    --password "<app-specific-password from appleid.apple.com>"
  ```
  Then `scripts/release.sh` runs the full pipeline; `scripts/release.sh --skip-notarize`
  does everything except the Apple round-trip (for a local dry run).
- Output lands in `dist/` (gitignored): `MagicButtons.app` + `MagicButtons.dmg`.
- **Two public download channels, one command.** `scripts/release.sh --publish` pushes the
  notarized DMG to both the Sparkle feed (Codeberg Pages) **and** a **Codeberg Release** (git
  tag + notes + the same DMG), so the auto-updater and the hand-download never drift apart. See
  docs/14 §Sparkle for the mechanics and the one-time `MB_CODEBERG_TOKEN` setup.
- **`CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`** in the build: a plain `xcodebuild build`
  (vs archive) injects `com.apple.security.get-task-allow` (debug "attach a debugger"),
  which notarization rejects as a critical error. This disables that injection; the
  explicit `app-sandbox=false` entitlement still applies. First submission failed on
  exactly this and the re-submission was **Accepted** (2026-07-14) → `source=Notarized
  Developer ID` on both the DMG and the `.app`.

### Running a cut, and recovering from a failed one

The script is one command, but it is not atomic: it pushes a git tag and publishes to
Codeberg Pages before the last step. **A cut that dies partway is normally finished by
hand, not by re-running** — see Recovery below.

**Pre-flight.** All four are checked by the script, but failing at step 1 beats failing
after the notarize round-trip:

- On `main`, synced, **clean tree** — `do_codeberg_release` tags `HEAD`, so whatever is
  committed is what the tag claims shipped. A dirty tree only warns.
- `CURRENT_PROJECT_VERSION` bumped in `project.yml` (nothing bumps it automatically).
- `docs/release-notes/UNRELEASED.md` says something true about this build.
- `scripts/release.local.env` present (`MB_SIGN_IDENTITY`, `MB_TEAM_ID`,
  `MB_CODEBERG_TOKEN`), the `MagicButtons-Notary` keychain profile created, and the
  `pages` worktree checked out.

**Order of operations**, so a failure tells you what already happened:

1. `xcodegen` → clean Release build, Developer ID signed
2. re-sign the Sparkle helpers (see docs/14 §Sparkle — notarization fails without this)
3. **§2.5 build-number check** against the *published* feed
4. DMG → notarize (Apple round-trip) → staple → verify as a fresh Mac would
5. `gen_appcast` — copies the DMG into `updates/`, **rewrites `updates/appcast.xml`**
6. `do_publish` — **pushes `pages`**; the Sparkle feed is live from this moment
7. `do_codeberg_release` — **pushes the tag**, creates the Release, uploads the DMG
8. `clear_notes` — truncates `UNRELEASED.md` back to its stub

**Post-cut, verify against the served URL** rather than the local file — these two fail
silently, and `updates/` can agree with itself while the site disagrees:

```
curl -s https://anguiano.codeberg.page/MagicButtons/appcast.xml
```

The item for this build must carry an `edSignature` on its enclosure and a non-empty
`<description>` with no `# Unreleased` stub leak. Notes are matched to an archive **by
basename**, and a mismatch yields an item with no notes at all rather than an error.

**Recovery.** By step 6 the feed is public and by step 7 the tag is pushed, so
re-running the script is the wrong instinct: step 3 compares against the published feed,
which now contains this build, and the re-run dies "not newer". Finish the remaining
steps by hand instead — the Forgejo API for the release and its asset, then the
`UNRELEASED.md` truncation. Check whether `clear_notes` ran before rewriting anything;
if the cut died before step 8, the notes are still intact.

A 5xx from Codeberg is usually transient and clears on an identical retry; a 4xx is real
(start with the token's `repository:write` scope). The failure messages carry the status
and the server's own response — that distinction is the whole reason they do.

*Observed 2026-07-25 (the 1.1.2 cut):* everything through step 6 succeeded and the
release POST returned a transient 500. Recovery was the release + asset by hand, then
the truncation. See docs/14.

**Dry runs.** `scripts/release.sh --skip-notarize` does everything bar the Apple
round-trip. It writes to `build/updates-dryrun`, never to `updates/`, so it cannot
contaminate the next real cut — this was not always true, and a dry run of the build you
then tried to ship used to make the real cut fail step 3.

### Release notes

**`docs/release-notes/UNRELEASED.md` is tracked, and any PR with user-visible impact
updates it as part of that PR.** The cut publishes it and clears it back to the stub.
Published notes then live with the build — never as a second copy here.

*Why tracked, when the notes are only needed until the cut:* they are a description of
**what is on `main`**, and an untracked file can't track `main` — it describes the trunk as
seen from one working tree on one machine, and goes silently stale the moment a PR merges
from the web UI or a fresh clone, with nothing able to detect it. Branch protection means
PRs are the only path to `main`, so the PR is the one place every user-impacting change is
reliably seen. Writing the note *there* also puts the user-facing description in front of
the reviewer next to the change, while the author still knows what it means for users — a
check no out-of-repo file can offer.

*Why cleared at the cut, rather than kept as a per-version file:* once published, the notes
are an attribute of a shipped build and have two canonical homes — the **Codeberg Release**
body and the **embedded `<description>` in `appcast.xml`** (published on the `pages` branch,
which is what the updater reads). A repo copy afterwards is a duplicate that can only drift.
Past releases are read from those, not from here.

*Why `UNRELEASED.md` and not `1.1.1.md`:* a version-named file asserts a release that hasn't
happened and goes stale if the version bumps again. The cut reads the version from the build,
so the filename doesn't need it; clearing is then a truncate rather than a delete-and-rename.

Both destinations are fed from this one source at cut time, so they cannot disagree. The cut
reads `UNRELEASED.md` (override with `--notes FILE` for an ad-hoc cut), writes the notes to
`updates/<DMG basename>.md` for the appcast, posts the same text as the Codeberg Release
body, and clears the file once the publish succeeds. Embedding beats linking — no extra URL
and no 404 risk — and the copy has to happen at cut time because the DMG basename carries
the build number, so a hand-named file would go stale on every bump. `updates/` is
gitignored: it is the local staging dir for the pipeline, not a source of truth. (1.1.0
shipped before any of this and has an empty update-dialog body; 1.1.1 is the first release
whose notes reach the updater.)

*What the script strips, and why it has to:* `generate_appcast` embeds the notes file
**verbatim** as CDATA, and the Codeberg body is the file's text — so the stub preamble
(the `# Unreleased` heading and the workflow comment) would ship to users as an "Unreleased"
title in the update dialog. `notes_body()` drops everything through the end of that comment,
which is why the stub's shape is load-bearing rather than decoration. It's recognized by the
opening `# Unreleased` heading, so a file passed to `--notes` that doesn't use the
convention publishes verbatim.

*Why the cut unwraps the notes:* a single newline inside a paragraph is **ambiguous** in
markdown, and the two destinations resolve it differently — Sparkle reflows it as a soft
break, Forgejo (Codeberg) renders it as a hard `<br>`. So notes hard-wrapped at the repo's
width looked right in the update dialog and arrived visibly ragged on the release page, worst
where bold and links made the source line length diverge from the rendered one (observed on
the 1.1.1 cut: 15 `<br/>` in the release page). Feeding both renderers text with no
intra-block newlines removes the ambiguity rather than tuning for one of them — *identical
text is not identical rendering*, which is what "they cannot disagree" has to mean. Authors
keep wrapping at the repo's width and reviewing normal diffs; `notes_unwrap()` joins each
block at cut time.

It joins only what legitimately wraps — paragraphs and list items. Anything whose line
structure *is* its meaning passes through: fenced code, tables, indented code, and explicit
hard breaks (two trailing spaces or a backslash). Blockquotes pass through **deliberately**:
joining them safely would mean parsing what is nested inside, and collapsing a quoted list
into a single bullet would corrupt the notes, whereas a wrapped quote merely renders ragged.
The lesser failure is the one to prefer.

*Two forcing functions,* both guarding quiet failures rather than loud ones. `generate_appcast`
matches notes to an archive **by basename** and silently emits an item with no notes when
none matches, so the cut asserts that the item enclosing this build's DMG carries a non-empty
`<description>` — the same shape as the `edSignature` assertion next to it. And clearing runs
*after* the Codeberg Release, because that step tags the released source commit and clearing
first would dirty the tree it tags. Branch protection means the script can't commit the
cleared file; it prints a reminder and the clear lands with the next PR.
