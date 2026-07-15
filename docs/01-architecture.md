# Architecture

## Principle: quarantine the volatile, keep the core pure

The single most important structural rule:

> **Nothing downstream of `TouchSource` imports the private framework or
> references its types.** Everything speaks in `SurfaceTouch` (normalized,
> backend-agnostic domain types).

This makes the private `MultitouchSupport` dependency a *replaceable leaf*, not a
load-bearing assumption threaded through the codebase.

## Data flow

```
┌──────────── VOLATILE (private API, may change per macOS release) ───────────┐
│  MultitouchAdapter   ── conforms to ──▶  TouchSource                        │
└──────────────────────────────────────────────────┬────────────────────────┘
                                                    │ [SurfaceTouch]  (domain)
┌──────────── STABLE CORE (pure, unit-testable) ────▼────────────────────────┐
│  TouchKit:      SurfaceTouch, TouchPhase, TouchSource, MouseZone, ZoneLayout│
│  GestureEngine: ZoneMapper, MouseGestureRecognizer   (pure logic, no I/O)       │
└───────────┬───────────────────────────────────────┬────────────────────────┘
ButtonGesture│           physicalClickActive ▲       │ [SurfaceTouch]
┌───────────▼─────────────────────────────┴─┐  ┌────▼──────────────┐
│  EventOutput                               │  │  Visualizer       │
│  ButtonEmitting  (post click/press/release)│  │  (SwiftUI)        │
│  EventInterceptor(active tap: click state, │  │  dots + zones     │
│                   move→drag promotion)     │  └───────────────────┘
│  (public CoreGraphics)                     │
└────────────────────────────────────────────┘
              ▲
              │ AppCoordinator owns the source, fans frames to both branches,
        ┌─────┴─────┐  and routes ButtonGesture→policy→emitter
        │    App    │  (menu-bar app, settings, permission bootstrap)
        └───────────┘
```

Each frame from the source fans out to **two independent consumers**:
- the **recognizer → policy → emitter** branch (produces clicks / double-clicks /
  drags), and
- the **visualizer** branch (renders finger positions).

Note the one feedback edge: `EventInterceptor` (an active event tap) supplies
`physicalClickActive` *into* the recognizer, and — while a synthetic hold is
active — promotes `mouseMoved`→`…MouseDragged` so tap-and-a-half drags work
(`05-event-output.md`). They share read-only config (`ZoneLayout`) so picture and
behavior never drift apart.

## SwiftPM targets

| Target | Depends on | Imports private API? | Purpose |
|--------|-----------|----------------------|---------|
| `TouchKit` | — | No | Domain types + protocol seams. The stable contract. |
| `TouchTestSupport` | `TouchKit` | No | `SimulatedTouchSource` + `Codable` frame-record/replay format. Used by tests, previews, and the App's debug record feature. |
| `MultitouchAdapter` | `TouchKit`, `MTPrivate` | **Yes (only here)** | Wraps `MultitouchSupport`, emits `SurfaceTouch`. |
| `MTPrivate` | — | (C shim) | `module.modulemap` + header declaring private symbols. |
| `GestureEngine` | `TouchKit` | No | Zone mapping + gesture recognition (click/double/drag). Fully unit-tested. |
| `EventOutput` | `TouchKit` | No (public `CoreGraphics`) | `ButtonEmitting` (post buttons) + `EventInterceptor` (active tap: physical-click signal, move→drag promotion). |
| `Visualizer` | `TouchKit` | No | SwiftUI finger/zone graphic. |
| `AppCore` | `TouchKit`, `GestureEngine`, `EventOutput` | No | Testable App-layer logic the thin Xcode app + the harness both consume: `FeaturePolicy` (7.1), settings persistence (7.2), permissions model (7.3), `GesturePipeline` + `AppCoordinator` (7.4). Collaborators injected as protocols. |
| `App` | all above | No (transitively via adapter) | Menu-bar app, wiring, settings, TCC bootstrap. |

> **Interim (Phases 0–1):** `App` is an **executable target in the SwiftPM
> package** — a console stub that imports every library so the full dependency
> graph compiles and links in CI. The menu-bar (`LSUIElement`) shell it becomes
> is built in Phase 7; when bundle concerns (Info.plist, entitlements, Hardened
> Runtime, signing) arrive, `App` moves to a **thin Xcode app target** consuming
> the package, per `12-project-setup.md`.

Test targets: `TouchKitTests` (domain vocabulary + replay: `ZoneLayout` mapping,
`Codable` round-trips, and script→replay through `TouchSource`),
`GestureEngineTests` (drives `MouseGestureRecognizer` with fabricated
`SurfaceTouch` sequences — no hardware, CI-friendly) and `EventOutputTests`
(feeds synthetic `CGEvent`s to the interceptor, asserts move→drag rewrite).
`SimulatedTouchSource` and the `Codable` frame-recording format (`TouchRecording`)
live in a shared **`TouchTestSupport`** target (not test-only — the App's debug
"record" feature and demos use replay too), so every downstream target can run
against replayed frames.

## Why the boundaries fall where they do

- **`TouchKit` has no dependencies** so it can never be "polluted" by a backend
  concern. It's the vocabulary everything else agrees on.
- **`GestureEngine` depends only on `TouchKit`** — no hardware, no `CGEvent`, no
  UI. This is where requirement churn concentrates (click/double/drag logic lives
  in `MouseGestureRecognizer`), and it's the cheapest place to change because it's pure
  and fully testable.
- **`EventOutput` is a protocol (`ButtonEmitting`)** so the "what does a tap do"
  policy can be swapped/mocked, and so tests never post real system events.
- **The adapter is the only target that can fail to compile** when Apple changes
  the private framework. Blast radius = one target.

## Composition root

`AppCoordinator` is the runtime object that:
- takes an injected `TouchSource` + `PhysicalClickSource` + `ButtonEmitting`, wiring
  `physicalClickActive` from the click source into the recognizer via `GesturePipeline`,
- holds the **feature-enable policy** (`FeaturePolicy`: filters the
  `ButtonGesture`→emitter path by which features are on — the single seam per-app
  profiles will later extend),
- owns the `ZoneLayout` / `GestureConfig` / feature flags (loaded from settings),
- runs the lifecycle (start/stop, live master enable, device re-enumeration) and
  force-releases holds on disable/quit/device-loss.

It lives in **`AppCore`** (so it's unit-tested against a simulated source + spy
emitter). **`App` is the composition root that picks the concretes** —
`MultitouchSource` + `EventInterceptor` + `CGEventEmitter` + `DeviceMonitor` in
production, or `SimulatedTouchSource` in previews/tests — and hands them in.

Everything else receives its collaborators by injection — no singletons reaching
across module boundaries.

## Threading model (summary; details in backend/recognition docs)

- The private framework delivers callbacks on **its own thread**.
- The adapter hops frames onto a **dedicated serial queue** where recognition
  runs (keeps ordering, keeps the callback thread cheap).
- UI updates are marshaled to **`@MainActor`**.
- `EventOutput` posts on the serial queue; `CGEvent.post` is thread-safe.
