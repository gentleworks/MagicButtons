# MagicButtons

A macOS (Developer-ID, non–App Store) utility that adds a **middle mouse button**
and **tap-to-click for left / middle / right** to the Apple Magic Mouse, plus a
**live visualizer** of finger positions and zones.

[**Download the latest release**](https://codeberg.org/anguiano/MagicButtons/releases/latest) · macOS 14+ · Swift 6 · SwiftPM libraries + Xcode app ·
MIT · open source.

I built this app because I was frustrated that there weren't any other open 
versions of this kind of basic functionality.  The magic mouse may not be as 
popular as some other Apple products, but it has an incredible potential given
the full digitizer on top.  If only Apple hadn't made that framework private I
think many more things might have been written for it.

After much consideration, I've published not only the source and architecture
documents, but also the planning documents and build log.  This is what I would
have wanted to have access to when I started figuring out how to make this happen,
and I hope it will be of use to others who are trying to develop functionality
for the magic mouse.

There are a lot of open items on the Roadmap document, but I don't have concrete
plans to implement any of them.  Absent external motivation, I'll probably only
build the things that I personally want to use.  While feedback and contributions
will be considered, I'll be hesitant to add anything that compromises the clean,
timer-lite backend, or anything outside the scope of emulating hardware events.  
There are many other applications for mapping custom actions to given mouse events,
and those are better suited targets for results-driven additions.  Thus, an
extension to add a fourth mouse button emulation might be considered as a future
feature, but options to map gestures on the mouse to specific OS or application
behaviors, such as changing volume or open specific windows, would be out of scope.

## Private APIs

MagicButtons reads finger contacts from `MultitouchSupport`, a **private Apple
framework** with no public replacement — that is the whole reason it ships as a
Developer-ID app **outside the Mac App Store**, which forbids private-API use.
The dependency is deliberately quarantined behind a runtime-resolved shim
(`dlopen`/`dlsym`, no private-symbol linkage) so the rest of the code stays on
public API; see [`docs/04-multitouch-backend.md`](docs/04-multitouch-backend.md).

Because the framework is undocumented, its behavior and struct layout can change
between macOS releases and are verified empirically, not guaranteed. Use at your
own discretion. This project is not affiliated with or endorsed by Apple.

## Design documents

Start at [`docs/00-overview.md`](docs/00-overview.md), then
[`docs/01-architecture.md`](docs/01-architecture.md).

- `00-overview.md` — goals, scope, constraints
- `01-architecture.md` — layering, SwiftPM targets, the private-API quarantine
- `02-domain-model.md` — core types & protocol seams (`TouchKit`)
- `03-gesture-recognition.md` — zone mapping + tap recognition
- `04-multitouch-backend.md` — the private `MultitouchSupport` adapter
- `05-event-output.md` — synthesizing mouse buttons via `CGEvent`
- `06-visualizer.md` — the finger/zone graphic
- `07-permissions-distribution.md` — TCC, signing, notarization
- `08-open-questions.md` — decisions (most resolved; remaining tuning items)
- `09-settings-and-status.md` — settings view: feature toggles, status/diagnostics
- `10-roadmap.md` — deferred (v2+) features and the seams v1 leaves for them
- `11-build-plan.md` — milestone-by-milestone build order
- `12-project-setup.md` — fixed toolchain / packaging / signing / testing conventions
- `13-dev-harness.md` — the `mb-dev` command-line probes, from-scratch reference

## Development setup

Secrets are kept out of the repo by a [betterleaks](https://github.com/betterleaks/betterleaks)
pre-commit hook. After cloning:

```sh
brew install betterleaks            # the scanner (macOS)
git config core.hooksPath .githooks # enable the hook for this clone
```

The hook (`.githooks/pre-commit`) scans staged changes and blocks a commit that
contains a secret. If betterleaks isn't installed it warns and lets the commit
through, so the scanner is a hard requirement only where it's present.

## Building from source

The pure, testable logic is a SwiftPM package — `swift build` / `swift test` need no
extra tooling. The **menu-bar app** is a thin Xcode target generated from
[`project.yml`](project.yml) with [XcodeGen](https://github.com/yonaskolb/XcodeGen);
the generated `MagicButtons.xcodeproj` is **not** committed (it's `.gitignore`d and
regenerated from `project.yml`, the source of truth). After cloning:

```sh
brew install xcodegen        # the project generator (macOS)
xcodegen generate            # writes MagicButtons.xcodeproj from project.yml
open MagicButtons.xcodeproj  # build & run the "MagicButtons" scheme
```

Re-run `xcodegen generate` whenever `project.yml`, or the files it references
(`AppShell/`, the package products), change.

Signing: a fresh clone builds **ad-hoc** ("Sign to Run Locally") — no Apple ID account,
certificate, or provisioning profile needed, so it builds and runs immediately. Ad-hoc
identities change every rebuild, so macOS re-prompts for Accessibility each time. For a **stable** identity (grant once; persists across rebuilds), pin your
Apple Development certificate in a gitignored local override:

```sh
cp AppShell/Signing.local.xcconfig.example AppShell/Signing.local.xcconfig
security find-identity -p codesigning -v
#   1) 1B2C3D…(40 hex)… "Apple Development: Your Name (TEAMID)"   <- copy this hash
# then in Signing.local.xcconfig:   CODE_SIGN_IDENTITY = <that 40-char hash>
```

Pick the **Apple Development** line (not "Developer ID Application"); if you have no such
certificate, create one in Xcode → Settings → Accounts → Manage Certificates → **+**. Then
just **rebuild** — no `xcodegen generate` needed: the override is read at build time via
`AppShell/Signing.xcconfig`'s optional `#include?` (so it's never committed and survives
regeneration).

This signs Manually against that exact cert with **no team**, which is why Xcode needs no
account or provisioning profile. Do **not** set `DEVELOPMENT_TEAM` for local dev — it flips
Xcode into demanding a profile and fails with "No signing certificate 'Mac Development'
found …" unless your Apple ID is added in Xcode → Settings → Accounts. (If it *is* added and
you prefer Xcode-managed signing, set `CODE_SIGN_STYLE = Automatic` + `DEVELOPMENT_TEAM = <id>`
in the override and build from Xcode instead.) Developer-ID signing + notarization for a
distributable build is handled by [`scripts/release.sh`](scripts/release.sh).

The `swift run mb-dev <subcommand>` dev harnesses
(`verify-gesture`, `visualize`, `permissions`, …) remain available directly from the
package, no Xcode project required. See [`docs/13-dev-harness.md`](docs/13-dev-harness.md)
for a from-scratch reference to every subcommand.
