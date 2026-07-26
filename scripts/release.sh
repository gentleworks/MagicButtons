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
#   scripts/release.sh --publish       # …then push to Codeberg Pages (Sparkle) + cut a Codeberg Release
#   scripts/release.sh --publish --notes FILE   # …with release notes read from FILE (markdown)
#   scripts/release.sh --skip-notarize # build + sign + dmg + appcast only (no Apple round-trip)
#
# Release notes default to docs/release-notes/UNRELEASED.md (tracked; every user-impacting
# PR adds to it). One source feeds both destinations — the embedded appcast <description>
# Sparkle shows in its update dialog, and the Codeberg Release body — so they cannot
# disagree; a successful --publish then clears the file back to its stub. See
# docs/07 §Release notes.
#
# --publish pushes via a `pages` git worktree (MB_PAGES_WORKTREE, default ../MagicButtons-pages)
# AND publishes a Codeberg Release (git tag + notes + the SAME notarized DMG) via the Forgejo
# API, so the binary people download by hand always matches what Sparkle serves. That step needs
# MB_CODEBERG_TOKEN (repository:write scope); without it it's skipped with a warning (Pages still
# publishes). --publish cannot be combined with --skip-notarize (never publish un-notarized).
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

# ── Codeberg Releases (human-facing mirror of the Sparkle feed) ──────────────────
# Codeberg runs Forgejo, whose REST API creates releases and uploads assets — so the
# hand-download and the auto-updater stay in lockstep with no web-UI clicking. Token
# is per-signer, kept out of git (release.local.env); repo defaults to the public one.
CODEBERG_API="https://codeberg.org/api/v1"
CODEBERG_REPO="${MB_CODEBERG_REPO:-anguiano/MagicButtons}"
CODEBERG_TOKEN="${MB_CODEBERG_TOKEN:-}"

SKIP_NOTARIZE=0
PUBLISH=0
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --publish)       PUBLISH=1 ;;
    --notes)         shift; NOTES_FILE="${1:-}"
                     [[ -n "$NOTES_FILE" ]] || { echo "error: --notes needs a file path" >&2; exit 2; } ;;
    --notes=*)       NOTES_FILE="${1#--notes=}" ;;
    *) echo "usage: release.sh [--skip-notarize] [--publish] [--notes FILE]" >&2; exit 2 ;;
  esac
  shift
done
# Publishing an un-notarized build would warn Gatekeeper on every user's Mac — refuse it.
[[ "$SKIP_NOTARIZE" == 1 && "$PUBLISH" == 1 ]] \
  && { echo "error: --publish cannot be combined with --skip-notarize" >&2; exit 2; }

# A dry run must not write into the publish staging mirror. `gen_appcast` copies the DMG
# into $UPDATES and rewrites appcast.xml there, and `do_publish` later copies *every*
# versioned DMG out of that directory — so an un-stapled dry-run build left behind would
# be published for real. (It also used to poison the §2.5 forcing function, which read
# that same appcast; §2.5 now reads the published feed instead.) Divert dry runs somewhere
# inspectable but inert, so "dry run" is structurally true rather than a promise.
if [[ "$SKIP_NOTARIZE" == 1 ]]; then
  UPDATES="$REPO/build/updates-dryrun"
fi

# The pending notes for the next release. Tracked, so it describes what is on `main`
# rather than one working tree; --notes overrides it for an ad-hoc cut.
NOTES_FILE="${NOTES_FILE:-$REPO/docs/release-notes/UNRELEASED.md}"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null; }

# A curl that keeps the response body on an HTTP error, leaving it in API_BODY and the
# status in API_STATUS; succeeds only on 2xx. Deliberately NOT `curl -f`, which discards
# the body and so collapses a real API fault (bad token scope, malformed payload) and a
# transient Codeberg 5xx into the same opaque "(56) error 500" — the two want opposite
# responses, and the 1.1.2 cut hit the transient one with no way to tell which it was
# until a retry cleared it.
api() {
  local out
  out="$(curl -sS -w $'\n%{http_code}' "$@" 2>&1)" \
    || { API_STATUS="000"; API_BODY="$out"; return 1; }
  API_STATUS="${out##*$'\n'}"
  API_BODY="${out%$'\n'*}"
  [[ "$API_STATUS" == 2* ]]
}

# UNRELEASED.md opens with a stub preamble — an "# Unreleased" heading and an HTML comment
# carrying the workflow — that is scaffolding for whoever writes the notes, not something a
# user should meet in an update dialog. The notes body is everything after that comment.
# Both are recognized only when the file actually opens with the stub, so an ad-hoc
# --notes FILE is published verbatim.
notes_has_stub() { [[ -f "$1" ]] && [[ "$(awk 'NF { print; exit }' "$1")" == "# Unreleased" ]]; }

# Join each hard-wrapped block onto one line. A single newline inside a paragraph is
# AMBIGUOUS in markdown — CommonMark calls it a soft break, Forgejo (Codeberg) renders it as
# a hard <br>, Sparkle reflows it — so notes wrapped for the repo arrive ragged on the
# release page while looking right in the update dialog. Feeding both renderers text with no
# intra-block newlines removes the ambiguity instead of tuning for one of them: identical
# text is not identical rendering, which is what "they cannot disagree" has to mean.
# Authors keep wrapping at the repo's width; the cut unwraps.
#
# Only paragraphs and list items are joined — the blocks that actually wrap. Everything whose
# line structure IS its meaning passes through: fenced code, tables, indented code, and an
# explicit hard break (two trailing spaces or a backslash), so a note that means a break gets
# one. Blockquotes pass through too, deliberately: joining them safely would mean parsing
# what is nested inside the quote, and collapsing a quoted list into one bullet would corrupt
# the notes — a wrapped quote merely renders ragged, which is the lesser failure.
notes_unwrap() {
  awk '
    function emit() { if (buf != "") { print buf; buf = "" } }
    /^```/                       { emit(); print; fence = !fence; next }
    fence                        { print; next }
    /^[[:space:]]*$/             { emit(); print ""; next }
    /^#{1,6}[[:space:]]/         { emit(); print; next }
    /^[[:space:]]*[|>]/          { emit(); print; next }
    /^    /                      { emit(); print; next }
    /(  |\\)$/                   { emit(); print; next }
    /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/ { emit(); buf = $0; next }
                                 { sub(/^[[:space:]]+/, ""); buf = (buf == "" ? $0 : buf " " $0) }
    END                          { emit() }
  '
}

# The one source both destinations read: strips the stub and unwraps, leaving markdown that
# renders the same everywhere.
notes_body() {
  if notes_has_stub "$1"; then
    awk 'body { print } /^-->/ && !body { body = 1 }' "$1" | sed '/./,$!d'
  else
    cat "$1"
  fi | notes_unwrap
}

# generate_appcast attaches release notes from a file whose basename matches the archive's,
# and silently emits an item with no notes when none matches — the same quiet-failure shape
# as the unsigned-entry case, so assert the result rather than trust it. Checks the item
# carrying THIS build's enclosure, not just any description in the feed.
assert_embedded_notes() {
  local rc=0
  command -v python3 >/dev/null || die "python3 is needed to verify the appcast's release notes"
  WANT="$(basename "$1")" python3 - "$UPDATES/appcast.xml" <<'PY' || rc=$?
import os, sys, xml.etree.ElementTree as ET
want = os.environ["WANT"]
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    enclosure = item.find("enclosure")
    if enclosure is not None and enclosure.get("url", "").endswith("/" + want):
        description = item.find("description")
        sys.exit(0 if description is not None and (description.text or "").strip() else 1)
sys.exit(2)
PY
  case "$rc" in
    0) ;;
    1) die "appcast item for $(basename "$1") carries no release notes — expected them embedded from ${1%.dmg}.md" ;;
    2) die "appcast has no item enclosing $(basename "$1") — generate_appcast did not add this build" ;;
    *) die "could not verify the appcast's release notes (python3 exited $rc)" ;;
  esac
}

# Copy the just-built DMG into updates/ under a version-unique name, then (re)generate the
# EdDSA-signed appcast over the whole updates/ dir. generate_appcast reads SUPublicEDKey
# from the app inside each archive and signs with the matching private key in the Keychain;
# a mismatch/absent key makes it silently emit an UNSIGNED entry, so we assert the signature.
gen_appcast() {
  local short build versioned body
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] \
    || die "generate_appcast not found at $SPARKLE_BIN (did the Sparkle package resolve during the build?)"
  short="$(plist CFBundleShortVersionString)"; build="$(plist CFBundleVersion)"
  mkdir -p "$UPDATES"
  versioned="$UPDATES/$SCHEME-${short}-${build}.dmg"
  cp "$DMG" "$versioned"
  # Notes are matched to the archive by basename, so the copy belongs here rather than in a
  # hand-named file: the basename carries the build number and would go stale on every bump.
  # --embed-release-notes inlines them as CDATA, so the feed needs no second URL to 404 on.
  body="$(notes_body "$NOTES_FILE")"
  if [[ -n "$body" ]]; then
    printf '%s\n' "$body" > "${versioned%.dmg}.md"
  else
    printf '\033[33m  ⚠ no release notes in %s — Sparkle'\''s update dialog will show an empty body.\033[0m\n' \
      "${NOTES_FILE#$REPO/}" >&2
  fi
  step "Generating EdDSA-signed appcast"
  "$SPARKLE_BIN/generate_appcast" --download-url-prefix "$PAGES_URL_PREFIX" --embed-release-notes "$UPDATES"
  grep -q 'edSignature' "$UPDATES/appcast.xml" \
    || die "appcast.xml has no EdDSA signature — SUPublicEDKey in Info.plist must match the Keychain key (generate_keys -p)"
  if [[ -n "$body" ]]; then
    assert_embedded_notes "$versioned"
  fi
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

# Cut a Codeberg Release mirroring what Pages now serves: an annotated git tag on the
# released source commit, release notes, and the SAME notarized/stapled DMG attached as a
# hand-download. Uses the Forgejo REST API (Codeberg runs Forgejo — `gh` is GitHub-only).
# Best-effort: a missing token warns rather than aborting, since Pages is already published.
do_codeberg_release() {
  local short build versioned tag name sha body payload release_json id
  if [[ -z "$CODEBERG_TOKEN" ]]; then
    printf '\033[33m  ⚠ MB_CODEBERG_TOKEN not set — skipping the Codeberg Release.\033[0m\n' >&2
    echo   "    Sparkle is published; to mirror the download, create a token (repository:write) at" >&2
    echo   "    https://codeberg.org/user/settings/applications and set MB_CODEBERG_TOKEN." >&2
    return
  fi
  command -v python3 >/dev/null || die "python3 is needed to build the Codeberg API payload"
  short="$(plist CFBundleShortVersionString)"; build="$(plist CFBundleVersion)"
  versioned="$UPDATES/$SCHEME-${short}-${build}.dmg"
  [[ -f "$versioned" ]] || die "versioned DMG not found for the release: $versioned"
  tag="v${short}-${build}"
  name="$SCHEME $short (build $build)"
  sha="$(git -C "$REPO" rev-parse HEAD)"
  step "Publishing Codeberg Release $tag"

  # Idempotent: if the release already exists (e.g. a re-run), leave it untouched.
  if curl -fsS -o /dev/null -H "Authorization: token $CODEBERG_TOKEN" \
       "$CODEBERG_API/repos/$CODEBERG_REPO/releases/tags/$tag" 2>/dev/null; then
    echo "  release $tag already exists on Codeberg — leaving it as-is"
    return
  fi
  # The tag must point at the committed source that produced this build.
  if [[ -n "$(git -C "$REPO" status --porcelain)" ]]; then
    printf '\033[33m  ⚠ working tree is dirty — tagging HEAD (%s) anyway.\033[0m\n' "${sha:0:9}" >&2
  fi
  if ! git -C "$REPO" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git -C "$REPO" tag -a "$tag" -m "$name" "$sha"
  fi
  git -C "$REPO" push -q origin "refs/tags/$tag"

  # The same body the appcast embedded, from the same source, so the two can't disagree.
  # With nothing to say, a generic line beats a blank release page.
  body="$(notes_body "$NOTES_FILE")"
  [[ -n "$body" ]] \
    || body="$name — auto-updates via Sparkle, or download the DMG below (the same notarized build the updater serves). Requires macOS 14 or later."
  # python3 does the JSON escaping so arbitrary markdown notes can't break the payload.
  payload="$(TAG="$tag" SHA="$sha" NAME="$name" BODY="$body" python3 -c '
import json, os
print(json.dumps({
    "tag_name": os.environ["TAG"],
    "target_commitish": os.environ["SHA"],
    "name": os.environ["NAME"],
    "body": os.environ["BODY"],
    "draft": False, "prerelease": False,
}))')"
  # Note for whoever reads this after a failure: by this point the tag is pushed AND this
  # build is in the local appcast, so a full re-run dies on the newer-than-last check
  # (§2.5). Recovery is to redo *this step only*, not the script.
  api -X POST "$CODEBERG_API/repos/$CODEBERG_REPO/releases" \
    -H "Authorization: token $CODEBERG_TOKEN" -H "Content-Type: application/json" \
    -d "$payload" \
    || die "Codeberg release creation failed for $tag — HTTP $API_STATUS
  $API_BODY
  A 5xx here is usually transient and clears on an identical retry; a 4xx is real (check
  the token's repository:write scope). Pages is already published either way — retry this
  step alone, since a full re-run would fail the newer-than-last check."
  release_json="$API_BODY"
  id="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])' <<<"$release_json")" \
    || die "could not parse the release id from Codeberg's response:
  $release_json"
  api -X POST \
    "$CODEBERG_API/repos/$CODEBERG_REPO/releases/$id/assets?name=$(basename "$versioned")" \
    -H "Authorization: token $CODEBERG_TOKEN" \
    -F "attachment=@$versioned;type=application/octet-stream" \
    || die "release $tag created but the DMG upload failed — HTTP $API_STATUS
  $API_BODY
  The release exists and is missing only its download. Attach $versioned to it by hand,
  or delete the release and redo this step."
  echo "  ✓ https://codeberg.org/$CODEBERG_REPO/releases/tag/$tag  ($(basename "$versioned"))"
}

# Once published, the notes are an attribute of the shipped build — they live in the Codeberg
# Release body and the embedded appcast description, and a copy left here could only drift.
# Truncate back to the stub the file documents itself with, rather than rewriting a stub from
# here that could drift the other way. Branch protection means this can't be committed from
# the script; it lands with the next PR (docs/07 §Release notes).
clear_notes() {
  notes_has_stub "$NOTES_FILE" || return 0
  [[ -n "$(notes_body "$NOTES_FILE")" ]] || return 0
  awk '{ print } /^-->/ { exit }' "$NOTES_FILE" > "$NOTES_FILE.tmp"
  mv "$NOTES_FILE.tmp" "$NOTES_FILE"
  step "Cleared ${NOTES_FILE#$REPO/} back to its stub"
  echo "  The notes ship with the build now. Commit the cleared file in your next PR."
}

[[ -n "$IDENTITY" && -n "$TEAM" ]] || die "signing identity not set.
  Set MB_SIGN_IDENTITY and MB_TEAM_ID — either in scripts/release.local.env
  (cp scripts/release.local.env.example scripts/release.local.env, then fill it in)
  or in the environment. See the header of this script."

# Fail before the build rather than after the notarize round-trip.
[[ -f "$NOTES_FILE" ]] || die "release notes file not found: $NOTES_FILE"

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
# Asked against what is actually PUBLISHED. This used to read the local `updates/` mirror,
# which is wrong in both directions: `updates/` is gitignored, so on a fresh clone the file
# is absent and the guard silently passed (a build Sparkle would never offer, reported as
# ✓); and a dry run rewrote it, so it also raised false alarms. The served feed is the only
# thing that answers the question being asked.
PUBLISHED_APPCAST="$(curl -fsS "${PAGES_URL_PREFIX}appcast.xml" 2>/dev/null)" || PUBLISHED_APPCAST=""
if [[ -n "$PUBLISHED_APPCAST" ]]; then
  LAST_BUILD="$(grep -oE '<sparkle:version>[0-9]+</sparkle:version>' <<<"$PUBLISHED_APPCAST" \
    | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
  if [[ -n "$LAST_BUILD" && "$BUILD_NUM" -le "$LAST_BUILD" ]]; then
    die "build number $BUILD_NUM is not newer than the last published build ($LAST_BUILD).
  Bump CURRENT_PROJECT_VERSION in project.yml so Sparkle offers this build as an update."
  fi
  echo "  ✓ build $BUILD_NUM (version $(plist CFBundleShortVersionString)) — last published: ${LAST_BUILD:-none}"
elif [[ "$PUBLISH" == 1 ]]; then
  # Fail closed on the publishing path. Shipping a build Sparkle won't offer is precisely
  # what this guard exists to prevent, and it is invisible after the fact — nobody gets an
  # update and nothing errors. An unverifiable check must not read as a passing one.
  die "couldn't read the published appcast at ${PAGES_URL_PREFIX}appcast.xml, so build
  $BUILD_NUM can't be checked against what's already out there. Re-run when the feed is
  reachable (or publish by hand if the site is down but the build is known to be newer)."
else
  printf '\033[33m  ⚠ published appcast unreachable — build number NOT verified.\033[0m\n' >&2
  echo "    Not publishing, so continuing; a --publish run would stop here."
  echo "  ✓ build $BUILD_NUM (version $(plist CFBundleShortVersionString))"
fi

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

# ── 7. Publish to Codeberg Pages (Sparkle feed) + Codeberg Release (only with --publish) ─
# clear_notes runs last: do_codeberg_release tags the released source commit, and clearing
# first would dirty the tree it tags.
if [[ "$PUBLISH" == 1 ]]; then
  do_publish
  do_codeberg_release
  clear_notes
fi

printf '\n\033[32m✓ Release ready: %s\033[0m\n' "$DMG"
