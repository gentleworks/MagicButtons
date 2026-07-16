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
