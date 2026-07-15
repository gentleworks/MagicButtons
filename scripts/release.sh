#!/usr/bin/env bash
#
# MagicButtons — Developer ID release pipeline (docs/11 §Phase 9, docs/07 §Distribution).
#
# Builds a Release .app signed with the **Developer ID Application** identity + Hardened
# Runtime + a secure timestamp, packages it into a DMG, notarizes the DMG with Apple,
# and staples the ticket to both the DMG and the .app. The result is a build that
# launches on any Mac with no Gatekeeper warning — the Phase 9 exit artifact.
#
# The local-dev signing default (ad-hoc / Apple Development cert, in
# AppShell/Signing.xcconfig) is untouched: this script overrides signing on the
# xcodebuild command line (highest precedence) for the release build only.
#
# Usage:
#   scripts/release.sh                 # build → dmg → notarize → staple → signed appcast
#   scripts/release.sh --publish       # …then push the appcast + DMG to Codeberg Pages
#   scripts/release.sh --skip-notarize # build + sign + dmg + appcast only (no Apple round-trip)
#
# --publish pushes via a `pages` git worktree (MB_PAGES_WORKTREE, default ../MagicButtons-pages);
# it cannot be combined with --skip-notarize (never publish an un-notarized build).
#
# Signing identity is NOT baked in — set it per-signer (see below) so the committed
# script carries no one developer's account details.
#
# One-time notary setup (creates the keychain profile this script reads):
#   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
#     --apple-id "<your-apple-id>" --team-id "<your-team-id>" \
#     --password "<app-specific-password from appleid.apple.com>"
#
set -euo pipefail

# ── Signer config (per-developer; kept out of git) ──────────────────────────────
# Provide your Developer ID via a gitignored local file or the environment:
#   1. cp scripts/release.local.env.example scripts/release.local.env  and fill it in, or
#   2. export MB_SIGN_IDENTITY / MB_TEAM_ID before running.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
[[ -f "$REPO/scripts/release.local.env" ]] && source "$REPO/scripts/release.local.env"

IDENTITY="${MB_SIGN_IDENTITY:-}"
TEAM="${MB_TEAM_ID:-}"

# ── Config ──────────────────────────────────────────────────────────────────────
SCHEME="MagicButtons"
CONFIGURATION="Release"
BUNDLE_ID="com.gentleworks.MagicButtons"
VOLNAME="MagicButtons"
NOTARY_PROFILE="${NOTARY_PROFILE:-MagicButtons-Notary}"

DERIVED="$REPO/build/release"
DIST="$REPO/dist"
APP="$DIST/$SCHEME.app"
DMG="$DIST/$SCHEME.dmg"

# ── Sparkle appcast (docs/07 §Distribution, docs/14 §Sparkle) ────────────────────
# updates/ is the local staging mirror of the Codeberg Pages site that serves updates:
# it accumulates the versioned DMGs + the EdDSA-signed appcast.xml. It's gitignored here;
# publishing = syncing its contents to the Pages location (see the end of this script).
# generate_appcast lives in the resolved Sparkle SPM artifacts under the derived data.
UPDATES="$REPO/updates"
PAGES_URL_PREFIX="${MB_PAGES_URL_PREFIX:-https://anguiano.codeberg.page/MagicButtons/}"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

# Where the `pages` orphan branch is checked out (a linked git worktree). Create it once:
#   git worktree add --orphan -b pages "$MB_PAGES_WORKTREE"
# Default sits beside the repo so it's outside the main working tree (docs/14 §Sparkle).
PAGES_WORKTREE="${MB_PAGES_WORKTREE:-$REPO/../MagicButtons-pages}"

SKIP_NOTARIZE=0
PUBLISH=0
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --publish)       PUBLISH=1 ;;
    *) echo "usage: release.sh [--skip-notarize] [--publish]" >&2; exit 2 ;;
  esac
done
# Publishing an un-notarized build would warn Gatekeeper on every user's Mac — refuse it.
[[ "$SKIP_NOTARIZE" == 1 && "$PUBLISH" == 1 ]] \
  && { echo "error: --publish cannot be combined with --skip-notarize" >&2; exit 2; }

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }

# Copy the just-built DMG into updates/ under a version-unique name, then (re)generate the
# EdDSA-signed appcast over the whole updates/ dir. generate_appcast reads SUPublicEDKey
# from the app inside each archive and signs with the matching private key in the Keychain;
# a mismatch/absent key makes it silently emit an UNSIGNED entry, so we assert the signature.
gen_appcast() {
  local short build versioned
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] \
    || die "generate_appcast not found at $SPARKLE_BIN (did the Sparkle package resolve during the build?)"
  short="$(plist CFBundleShortVersionString)"; build="$(plist CFBundleVersion)"
  mkdir -p "$UPDATES"
  versioned="$UPDATES/$SCHEME-${short}-${build}.dmg"
  cp "$DMG" "$versioned"
  step "Generating EdDSA-signed appcast"
  "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$PAGES_URL_PREFIX" "$UPDATES"
  grep -q 'edSignature' "$UPDATES/appcast.xml" \
    || die "appcast.xml has no EdDSA signature — SUPublicEDKey in Info.plist must match the Keychain key (generate_keys -p)"
  echo "  ✓ $UPDATES/appcast.xml  (enclosure: $(basename "$versioned"))"
  # When --publish is set, do_publish handles the upload; only nudge for the manual case.
  if [[ "$PUBLISH" != 1 ]]; then
    printf '\n  \033[1mPublish:\033[0m re-run with --publish, or sync updates/ to %s\n' "$PAGES_URL_PREFIX"
    echo "  (appcast.xml + the versioned DMGs). See docs/14 §Sparkle for the Codeberg Pages step."
  fi
}

# Push the freshly generated feed to Codeberg Pages via the `pages` git worktree. Copies
# the appcast + all versioned DMGs from updates/ into the worktree, commits, and pushes;
# Pages then serves them at PAGES_URL_PREFIX. Only ever runs for a full (notarized) build.
do_publish() {
  local short build
  [[ -e "$PAGES_WORKTREE/.git" ]] || die "pages worktree not found at $PAGES_WORKTREE.
  Create it once:  git worktree add --orphan -b pages \"$PAGES_WORKTREE\"
  (or point MB_PAGES_WORKTREE at your existing pages checkout). See docs/14 §Sparkle."
  step "Publishing to Codeberg Pages"
  # Fast-forward the worktree first so the push can't hit a non-fast-forward rejection.
  git -C "$PAGES_WORKTREE" pull --ff-only >/dev/null 2>&1 || true
  cp "$UPDATES/appcast.xml" "$PAGES_WORKTREE/"
  cp "$UPDATES/$SCHEME"-*.dmg "$PAGES_WORKTREE/"
  # generate_appcast emits binary-delta patches (<SCHEME><new>-<old>.delta) and advertises
  # them in the feed; publish them too or those delta URLs 404 (Sparkle then wastes a round
  # trip before falling back to the full DMG).
  cp "$UPDATES"/*.delta "$PAGES_WORKTREE/" 2>/dev/null || true
  git -C "$PAGES_WORKTREE" add -A
  if git -C "$PAGES_WORKTREE" diff --cached --quiet; then
    echo "  nothing to publish — appcast + DMGs already up to date on origin/pages"
    return
  fi
  short="$(plist CFBundleShortVersionString)"; build="$(plist CFBundleVersion)"
  git -C "$PAGES_WORKTREE" commit -q -m "pages: $SCHEME $short (build $build)"
  git -C "$PAGES_WORKTREE" push
  echo "  ✓ published — ${PAGES_URL_PREFIX}appcast.xml"
}

[[ -n "$IDENTITY" && -n "$TEAM" ]] || die "signing identity not set.
  Set MB_SIGN_IDENTITY and MB_TEAM_ID — either in scripts/release.local.env
  (cp scripts/release.local.env.example scripts/release.local.env, then fill it in)
  or in the environment. See the header of this script."

cd "$REPO"

# ── 1. Generate project + clean Release build, Developer ID signed ──────────────
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO: a plain `build` (vs archive) otherwise injects
# com.apple.security.get-task-allow (the "let a debugger attach" entitlement), which
# notarization rejects ("critical validation errors"). Our explicit entitlements file
# (app-sandbox=false) still applies; we just don't want the debug base entitlement.
step "Building $SCHEME ($CONFIGURATION), Developer ID signed"
command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null
rm -rf "$DIST" && mkdir -p "$DIST"

mkdir -p "$REPO/build"
xcodebuild \
  -project "$REPO/MagicButtons.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_STYLE=Manual \
  "CODE_SIGN_IDENTITY=$IDENTITY" \
  "DEVELOPMENT_TEAM=$TEAM" \
  "OTHER_CODE_SIGN_FLAGS=--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  clean build | tee "$REPO/build/xcodebuild-release.log" | tail -1

cp -R "$DERIVED/Build/Products/$CONFIGURATION/$SCHEME.app" "$APP"

# ── 1.5 Re-sign Sparkle's nested helpers (Developer ID + hardened runtime + timestamp) ──
# `xcodebuild build` re-signs the app and Sparkle.framework's shell, but leaves Sparkle's
# deeply-nested executables — Autoupdate, Updater.app, and the XPC services — carrying
# Sparkle's own (ad-hoc) signature. That passes `codesign --deep --strict` (valid
# signatures) but notarization REJECTS them: not signed with our Developer ID, no secure
# timestamp. Re-sign them inside-out, then re-seal the framework and the app over them.
step "Re-signing Sparkle helpers (Developer ID + hardened runtime + timestamp)"
SPK="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPK" ]] || die "Sparkle.framework not found at $SPK"
SPKV="$SPK/Versions/Current"
for nested in \
  "$SPKV/XPCServices/Downloader.xpc" \
  "$SPKV/XPCServices/Installer.xpc" \
  "$SPKV/Autoupdate" \
  "$SPKV/Updater.app" \
  "$SPK"; do
  [[ -e "$nested" ]] || die "expected Sparkle component missing: $nested (Sparkle layout changed?)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
done
# Re-sealing the framework invalidated the app's signature over it — re-sign the app with
# its entitlements (manual codesign never injects get-task-allow, so the build stays clean).
codesign --force --options runtime --timestamp \
  --entitlements "$REPO/AppShell/MagicButtons.entitlements" \
  --sign "$IDENTITY" "$APP"

# ── 2. Verify the signature before going further ────────────────────────────────
step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Capture once into a variable — piping into `grep -q` closes the pipe early, and
# under `set -o pipefail` the SIGPIPE'd codesign would fail the whole pipeline.
SIGINFO="$(codesign -dvvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIGINFO" \
  || die "not signed with Developer ID Application"
grep -q "flags=.*runtime" <<<"$SIGINFO" \
  || die "Hardened Runtime not enabled"
echo "  ✓ Developer ID + Hardened Runtime + timestamp"

# ── 2.5 Forcing function: this build number MUST exceed the last published one ──
# Sparkle decides "is there an update?" by comparing CFBundleVersion. Nothing in this
# repo auto-bumps CURRENT_PROJECT_VERSION (only `xcodegen generate` runs), so guard
# against shipping a build Sparkle would consider "not newer" than the newest appcast
# entry. Fail fast — before the DMG/notarize round-trip.
step "Checking build number is newer than the last release"
BUILD_NUM="$(plist CFBundleVersion)"
[[ -n "$BUILD_NUM" ]] || die "could not read CFBundleVersion from the built app"
if [[ -f "$UPDATES/appcast.xml" ]]; then
  LAST_BUILD="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' "$UPDATES/appcast.xml" \
    | grep -oE '[0-9]+' | sort -n | tail -1)"
  if [[ -n "$LAST_BUILD" && "$BUILD_NUM" -le "$LAST_BUILD" ]]; then
    die "build number $BUILD_NUM is not newer than the last published build ($LAST_BUILD).
  Bump CURRENT_PROJECT_VERSION in project.yml so Sparkle offers this build as an update."
  fi
fi
echo "  ✓ build $BUILD_NUM (version $(plist CFBundleShortVersionString))"

# ── 3. Package a DMG (app + /Applications drop target), then sign it ────────────
step "Building DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
echo "  ✓ $DMG"

# ── 4. Notarize + staple (unless skipped) ───────────────────────────────────────
if [[ "$SKIP_NOTARIZE" == 1 ]]; then
  step "Skipping notarization (--skip-notarize)"
  echo "  DMG is signed but NOT notarized — it will warn on other Macs."
  echo "  Run without --skip-notarize once the notary profile exists."
  # Still generate the appcast so the Sparkle signing chain can be exercised in a dry run.
  # NB: the enclosed DMG here is NOT stapled — do not publish a --skip-notarize appcast.
  gen_appcast
  exit 0
fi

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notary profile '$NOTARY_PROFILE' not found. Create it with:
  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
    --apple-id \"<your-apple-id>\" --team-id \"$TEAM\" --password \"<app-specific-password>\""

step "Notarizing DMG (this waits for Apple)"
# `notarytool submit --wait` exits 0 as long as processing COMPLETED — even when the
# result is Invalid — so we must inspect the status ourselves, or we'd staple a rejected
# build. On failure, auto-fetch Apple's per-issue log so the reason is right here.
NOTARY_JSON="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
echo "$NOTARY_JSON"
NOTARY_STATUS="$(grep -o '"status":"[^"]*"' <<<"$NOTARY_JSON" | head -1 | cut -d'"' -f4)"
SUBMISSION_ID="$(grep -o '"id":"[^"]*"' <<<"$NOTARY_JSON" | head -1 | cut -d'"' -f4)"
if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  printf '\n\033[31mnotarization %s — Apple'\''s issue log:\033[0m\n' "${NOTARY_STATUS:-unknown}" >&2
  [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2
  die "notarization failed ($NOTARY_STATUS) — nothing stapled or published. See the issues above."
fi
echo "  ✓ Accepted (submission $SUBMISSION_ID)"

step "Stapling the ticket"
xcrun stapler staple "$DMG"
# The standalone .app shares the notarized cdhash, so it can be stapled too.
xcrun stapler staple "$APP"

# ── 5. Final verification (as a fresh Mac would see it) ─────────────────────────
step "Verifying notarization"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
spctl -a -t exec -vv "$APP"

# ── 6. Appcast (over the stapled DMG) — the Sparkle update feed ─────────────────
gen_appcast

# ── 7. Publish to Codeberg Pages (only with --publish) ──────────────────────────
[[ "$PUBLISH" == 1 ]] && do_publish

printf '\n\033[32m✓ Release ready: %s\033[0m\n' "$DMG"
