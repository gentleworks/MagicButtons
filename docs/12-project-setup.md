# Project Setup & Conventions

Fixed facts a clean session needs to start deterministically. Settled before any
code. Phase 0 of `11-build-plan.md` implements this.

## Toolchain & platform

- **Minimum deployment target:** macOS 14 (Sonoma). Chosen for modern SwiftUI,
  `SMAppService` login item, and current toolchain. (The dev machine runs the
  target OS and has a Magic Mouse — the bring-up/verification target.)
- **Swift:** latest stable tools version; **Swift 6 language mode** with strict
  concurrency **on**. The design already assumes it (`Sendable` domain types,
  serial queues for the touch/output pipeline, `@MainActor` for UI).
- **Xcode:** latest stable.

## Identity

- **Product name:** MagicButtons.
- **Bundle identifier:** `com.gentleworks.MagicButtons`.
  - The TCC grant (Accessibility; Input Monitoring was dropped, `08 §C`) is keyed to
    bundle ID + signature — **do not change these after users grant**, or they must
    re-grant.
- **Signing:** Developer ID (Gentleworks team); Hardened Runtime on; notarized +
  stapled for distribution (`07-permissions-distribution.md`).

## Packaging model

- **SwiftPM package** holds the six libraries + `TouchTestSupport`
  (`TouchKit`, `TouchTestSupport`, `MTPrivate`, `MultitouchAdapter`,
  `GestureEngine`, `EventOutput`, `Visualizer`) and their test targets. The
  private-API quarantine lives entirely in the package.
- **Thin Xcode app target** (`App`) consumes the package and owns everything that
  doesn't fit pure SwiftPM: `Info.plist` (`LSUIElement`), entitlements, Hardened
  Runtime, TCC usage strings, `SMAppService`, code signing, notarization.
- An **Xcode workspace** ties the package and app together.
- Rationale: keep all pure/testable logic in SwiftPM (fast, CI-able, no app
  scaffolding), isolate app/bundle/signing concerns to the one place that needs
  them.
- **Interim (until Phase 7):** there is no Xcode app target/workspace yet. `App`
  currently exists as an **executable target inside the package** — a console
  stub that links every library so CI (`swift build`/`swift test`) exercises the
  whole graph. It migrates to the thin Xcode app target when the app shell and
  bundle/signing concerns land.

## Repository & licensing

- **Git:** repository initialized at the project root.
- **License:** MIT (`LICENSE`, © 2026 Paul Anguiano).
- **Open source:** yes — the project will be public. Distribution is still a
  **signed, notarized binary** (source-available does not remove the Developer
  ID / notarization requirement for a runnable app users will trust with input
  and Accessibility access).
- Because updates ship outside the App Store, an **in-app auto-updater (Sparkle)**
  is the first roadmap item (`10-roadmap.md`).

## Testing

- **Framework:** Swift Testing (not XCTest).
- **Hardware-free core:** the `TouchKit` domain types + replay (`TouchKitTests`),
  `GestureEngine`, and the interceptor's event-rewrite logic are fully unit-tested
  via `TouchTestSupport` replay + `SpyEmitter` and synthetic `CGEvent`s. Hardware
  phases get manual/integration verification.
- **CI:** local `swift test` for now (no hosted CI assumed); the package is
  structured to be CI-ready if added later.

## Naming conventions

- The recognizer type is **`MouseGestureRecognizer`** (avoids confusion with
  AppKit's `NSGestureRecognizer`).
- Domain vocabulary is defined once in `TouchKit` (`02-domain-model.md`); nothing
  downstream of `TouchSource` references private-framework types.

## Settled defaults recap

| Area | Decision |
|------|----------|
| Deployment target | macOS 14 |
| Swift mode | Swift 6, strict concurrency |
| Bundle ID | `com.gentleworks.MagicButtons` |
| Packaging | SwiftPM libs + Xcode app target (workspace) |
| Signing | Developer ID, notarized + stapled |
| VCS / license | git + MIT, open source |
| Test framework | Swift Testing |
| Replay/support | `TouchTestSupport` target |
| Recognizer name | `MouseGestureRecognizer` |
| Updater | Sparkle → first roadmap item |
