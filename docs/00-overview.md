# MagicButtons — Overview

A macOS utility that adds richer button behavior to the Apple Magic Mouse:

1. **Middle mouse button** — a *physical click* while a finger is in a
   configurable "middle" zone emits the middle button. The hardware has no
   middle button; we create one.
2. **Tap-to-click** — a light finger *tap* (down → quick lift, no physical
   click) in the left / right zone emits the corresponding button.
3. **Middle tap-to-click** — a tap in the middle zone emits the middle button.
4. **Live zone visualizer** — a small graphic showing where fingers are on the
   mouse surface and which zone (left / middle / right) each finger is in.

Each input feature (1–3) is **independently enable/disable** in Settings, and
all three support **double-click** and **drag** (tap-and-a-half) — both required
for v1. See `09-settings-and-status.md`.

## Non-goals (initial scope)

- No App Store distribution (we rely on a private Apple framework — see
  `04-multitouch-backend.md`). Direct / notarized distribution only.
- No trackpad support in v1 (architecture doesn't preclude it later).
- No remapping of existing system gestures (scroll, swipe) — additive only.
- **Not suppressing physical clicks in v1** — features are additive; we only
  avoid *duplicating* the OS's own click. Click suppression is v2
  (`10-roadmap.md`).
- Magic Mouse only (v1 **and** v2 mice), but multiple mice present is supported.
  No explicit multi-finger gesture *support* in v1 (only rejection of
  problematic cases if testing surfaces them).

## Guiding constraints

- **Modularity first.** The project is organized so that two expected change
  vectors are cheap to absorb:
  - *Requirement churn* (new gestures, new zones, chords) → isolated to pure,
    testable logic in `GestureEngine`.
  - *Backend / private-API change* → isolated to a single adapter target behind
    the `TouchSource` protocol. Nothing downstream imports the private framework.
- **Hardware-free development.** A `SimulatedTouchSource` replays recorded or
  synthetic frames so the recognizer, output, and UI can be built and tested
  without a Magic Mouse and run in CI.

## Document map

| Doc | Topic |
|-----|-------|
| `00-overview.md` | This file — goals, scope, constraints |
| `01-architecture.md` | Layering, targets, the quarantine boundary |
| `02-domain-model.md` | Core types and protocol seams (`TouchKit`) |
| `03-gesture-recognition.md` | Zone mapping + tap recognition details |
| `04-multitouch-backend.md` | The private `MultitouchSupport` adapter |
| `05-event-output.md` | Synthesizing mouse buttons via `CGEvent` |
| `06-visualizer.md` | The finger/zone graphic |
| `07-permissions-distribution.md` | TCC, signing, notarization |
| `08-open-questions.md` | Remaining open decisions (most now resolved) |
| `09-settings-and-status.md` | Settings view: feature toggles, status/diagnostics, advanced |
| `10-roadmap.md` | Deferred (v2+) features, carried-forward tuning items, seams |
| `11-build-plan.md` | v1 build history (Phases 0–9) — **frozen/historical** |
| `12-project-setup.md` | Fixed toolchain / packaging / signing / testing conventions |
| `13-dev-harness.md` | The `mb-dev` command-line probes — newcomer reference |
| `14-post-v1.md` | Post-v1 build log — the successor to `11` |

Read `01-architecture.md` next.
