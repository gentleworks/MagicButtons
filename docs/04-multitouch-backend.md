# Multitouch Backend (`MultitouchAdapter` + `MTPrivate`)

The **only** target that touches the private framework. Everything it exposes is
a `TouchKit` type. If Apple changes or removes the framework, the blast radius is
here.

## Why private API is unavoidable

The public stack (`NSEvent`, `CGEventTap`) never exposes **individual finger
positions on the mouse shell**. All three product features need exactly that:

- middle button ← which zone a finger is in,
- tap-to-click ← contact begin/end without a physical click,
- visualizer ← raw contact coordinates.

`MultitouchSupport.framework` (private, `/System/Library/PrivateFrameworks/`)
provides raw contact frames. This is the same mechanism BetterTouchTool,
MagicPrefs, and Mac Mouse Fix rely on.

## Scope of private-API exposure (deliberately minimal)

Decision: **runtime `dlopen`/`dlsym` resolution is used *only* for the moving
system surface — the multitouch contact stream** — and nothing else. Every other
capability (event posting, physical-click detection, drag promotion, device
notifications where public) uses **public, link-time** APIs.

Concretely, the private symbol set is confined to: device enumeration/creation,
the contact-frame callback registration, start/stop/release, and surface-
dimension query for device identification. That list lives in exactly one file
(`MTPrivate` + `MultitouchSource.swift`). This keeps our risk surface as small as
the feature set allows: if the private framework changes, only the touch-stream
plumbing is affected, and only that one target must adapt.

## Risks and how the architecture contains them

| Risk | Containment |
|------|-------------|
| Struct layout changes between macOS versions | One `MTTouch` definition in the C shim; verified at startup (see "Sanity checks"). |
| Symbols renamed / removed | Resolve dynamically where practical; fail with `TouchSourceError.backendUnavailable` → App shows a graceful "unsupported OS" state instead of crashing. |
| App notarization flags private-symbol linkage | **Decided:** `dlopen`/`dlsym` runtime resolution, scoped to the touch stream only (see "Scope of private-API exposure"). Also decouples build from SDK. |
| No touch data | `.noDevice` (no mouse) vs. connected-but-deaf (`touchesNotArriving`). The stream needs no TCC grant — `08 §C`. |

## The C shim (`MTPrivate`)

A `module.modulemap` + header declaring just the symbols we use. Illustrative
(exact field layout to be verified against the current OS at build time). The
development machine has a Magic Mouse attached and runs the target OS, so struct
layout, `state` values, and surface dimensions can be verified empirically here
during bring-up — a debug "dump raw frames + `sizeof`" mode is the first thing
built in this target:

```c
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTReadout;

typedef struct {
    int32_t   frame;
    double    timestamp;
    int32_t   identifier;      // stable per-contact id  → SurfaceTouch.id
    int32_t   state;           // raw phase              → TouchPhase (mapped)
    int32_t   fingerID, handID;
    MTReadout normalized;      // 0...1 position         → SurfaceTouch.position
    float     zTotal;          // pressure-ish
    int32_t   pad;
    float     angle, majorAxis, minorAxis;  // majorAxis → SurfaceTouch.size
    MTReadout absolute;
    int32_t   pad2, pad3;
    float     density;
} MTTouch;

typedef void* MTDeviceRef;
typedef int (*MTContactFrameCallback)(MTDeviceRef, MTTouch*, int32_t count,
                                       double timestamp, int32_t frame);

// Resolved via dlsym at runtime (names may need per-OS verification):
//   MTDeviceCreateDefault, MTDeviceCreateList,
//   MTRegisterContactFrameCallback(WithRefcon),
//   MTDeviceStart, MTDeviceStop, MTDeviceRelease,
//   MTDeviceGetSensorSurfaceDimensions (mouse vs trackpad discrimination)
```

## Phase mapping

The framework's raw `state` has ~7 values (not touching → making/breaking
contact → touching → lingering → out of range). The adapter collapses them:

| Raw state (typical) | `TouchPhase` |
|---------------------|--------------|
| making contact / touch start | `.began` |
| touching, position changed | `.moved` |
| touching, ~stationary | `.stationary` |
| breaking / left surface | `.ended` |

Exact numeric mapping verified empirically and pinned in one table in the
adapter, with a logging mode to dump raw states during bring-up.

## Device selection & multiple mice (v1 & v2 generations)

`MTDeviceCreateList` enumerates all multitouch devices — a machine may have a
built-in trackpad **and** one or more Magic Mice, of mixed generation (Magic
Mouse v1 and v2). Requirements:

- **Identify Magic Mice** and exclude trackpads, via surface dimensions
  (`MTDeviceGetSensorSurfaceDimensions`) and/or device family. The Magic Mouse
  shell is the same across v1/v2, so surface dimensions should match for both;
  generation is distinguished (for display only) by other device properties
  (e.g. Bluetooth product info) — not required for correctness.
- **Support several present at once.** The adapter subscribes to **every**
  matching Magic Mouse and tags each emitted `SurfaceTouch` with its
  `MouseDeviceID`. Because contact `id`s are only unique within a device, this
  tagging is what keeps the recognizer from conflating contacts across mice.
- **Active-device handling.** In practice one mouse is used at a time; v1 routes
  frames from whichever device is producing contacts. If two produce
  simultaneously, the `(deviceID, id)` keying keeps their gesture state machines
  independent.
- **Hot plug/unplug.** Re-enumerate on device attach/detach; start/stop
  callbacks accordingly; surface the current device list to the Status view
  (`09-settings-and-status.md`). On loss of a device mid-drag, the coordinator
  forces a hold release (safety).

Selection policy is configurable but v1 needs no user choice — all Magic Mice are
active. (A device picker / per-device settings is roadmap.)

## Threading

Callbacks arrive on the framework's own thread. The adapter immediately hops each
frame onto a **dedicated serial `DispatchQueue`** (`onFrame` is invoked there),
keeping ordering and keeping the framework's thread free. UI marshaling to
`@MainActor` happens further downstream, not here.

## Sanity checks at startup

- Confirm `sizeof(MTTouch)` matches expectation for the running OS; if not, log
  loudly and refuse to interpret frames (avoid feeding garbage coordinates
  downstream). **Nuance (as built):** `MTPrivate_touchStructSize()` returns
  `sizeof` of the shim's **own** `MTTouch`, so the `== 96` guard in
  `MultitouchSource` catches an accidental edit to *our* struct — it can **not**
  see the framework's real layout drifting under a fixed size. Cross-OS
  correctness therefore rests on the empirical coordinate check (`dump-frames` +
  the per-OS table below), not on the size guard alone.
- Confirm at least one device resolved; else `.noDevice`.
- Confirm callback fires within N seconds of `MTDeviceStart`; else surface a
  diagnostic (the "connected but deaf" state). **As built (Phase
  9.2):** `AppCoordinator.touchesNotArriving` is exactly this check — device
  enumerated, `sourceError == nil`, yet no frame has arrived → the "connected but
  deaf" degraded state, surfaced in the Status pane's Errors row. Clock-free: the
  coordinator latches "did a frame ever arrive since start"; the UI applies timing.

### Per-OS layout verification table (Phase 9)

The 96-byte community `MTTouch` layout, confirmed to yield sane coordinates
(normalized position in `0…1`, `majorAxis` ≈ 8–10 per finger) via `dump-frames` on
real hardware. **Verified further 2026-07-30:** `minorAxis` ≤ `majorAxis` always;
`angle` is quantized to π/64 steps and lands exactly on π/2, which pins the offsets
through `angle`/`majorAxis`/`minorAxis`; `zTotal` steps in 1/8. The axes are in
**millimetres** — `MTDeviceGetSensorSurfaceDimensions` returns ¹⁄₁₀₀ mm, so the
Magic Mouse surface is 51.52 × 90.56 mm and a fingertip patch is ~9–12 mm.
On raw state 7 the axes and `zTotal` zero out while `angle` holds its last value. Add a row whenever the app is verified on a new
macOS. A build whose `sizeof(MTTouch)` or coordinate sanity departs from a listed
row means the layout must be re-derived for that OS before trusting frames.

| macOS | Darwin | Build | `sizeof(MTTouch)` | Coordinates | Verified |
|-------|--------|-------|-------------------|-------------|----------|
| 26.5.2 | 25.5.0 | 25F84 | 96 bytes | sane (pos 0…1, size ≈8–10) | 2026-07-14 |

### Why travel is measured in millimetres

`normalized.position` is normalized **per axis**, and the surface is portrait — so a
distance computed in that space is not a distance on the mouse. Through 1.1.2 the tap
gate was Euclidean in normalized units at `maxTravel = 0.06`, which meant:

| direction | allowance |
|-----------|-----------|
| side to side | 3.09 mm (0.06 × 51.52) |
| fore / aft | 5.43 mm (0.06 × 90.56) |

1.76:1, chosen by nobody. The 2026-07-30 probe caught it in the data: on an angled still
press the centroid drifted **1.60 mm in `x` and 1.45 mm in `y`** — near-equal physically
— and the gate scored the `x` component ~2× because it was divided by the shorter axis.
Rolling a fingertip sideways is if anything *easier* than sliding it fore-aft, so the
bias ran the wrong way as well as being arbitrary.

Since 1.1.3 travel is Euclidean in millimetres (`MouseSurface.millimetres(dx:dy:)`, one
definition in `TouchKit` shared by the gate and the visualizer), so the budget is a
circle. The default converts the old one area-preservingly:
`0.06 × √(51.52 × 90.56)` = **4.1 mm**, which spends the same total allowance — 33%
looser sideways, 25% tighter fore-aft. Re-scored under it, the angled still press above
falls from 58% to 53% of budget, so the `pressAndHold` stillness guard (which gates drag
promotion on this same value) gains a little headroom rather than losing it.

Settings written before the change carry the old key and are converted on decode
(`GestureConfig.init(from:)`); the `log-gestures` CSV column was renamed `maxTravel` →
`maxTravelMM` so a pre-change log cannot be silently pooled with a post-change one.

## `SurfaceTouch` construction (the whole point)

```swift
let frame = (0..<Int(count)).map { i -> SurfaceTouch in
    let t = touches[i]
    return SurfaceTouch(
        id: t.identifier,
        position: CGPoint(x: CGFloat(t.normalized.position.x),
                          y: CGFloat(t.normalized.position.y)),
        phase: TouchPhase(rawState: t.state),
        timestamp: t.timestamp,
        size: CGFloat(t.majorAxis))
}
onFrameQueue.async { self.onFrame?(frame) }   // domain types only cross the seam
```

No private type escapes this file.
