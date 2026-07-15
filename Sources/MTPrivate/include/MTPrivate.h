// MTPrivate — C shim for the private MultitouchSupport framework.
//
// Declares ONLY the data layout the touch-frame callback hands us, plus the
// function-pointer signatures we resolve at runtime. The functions themselves
// are NOT linked here — MultitouchAdapter resolves them with dlopen/dlsym so the
// binary carries no private-symbol linkage (docs/04-multitouch-backend.md
// §Scope of private-API exposure).
//
// IMPORTANT: the struct layout below is ILLUSTRATIVE and must be verified
// against the running OS empirically. `dump-frames` prints sizeof + raw fields
// for exactly that purpose before any coordinate is trusted downstream.

#ifndef MTPRIVATE_H
#define MTPRIVATE_H

#include <stdint.h>
#include <stddef.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTReadout;

/// One finger contact in one frame, as the framework lays it out in memory.
/// Field names follow the community-reverse-engineered layout; `majorAxis` is
/// used as `SurfaceTouch.size`, `normalized` as the 0...1 position, `state` as
/// the raw phase, `identifier` as the stable per-contact id.
typedef struct {
    int32_t   frame;
    double     timestamp;
    int32_t   identifier;
    int32_t   state;
    int32_t   fingerID;
    int32_t   handID;
    MTReadout normalized;
    float      zTotal;
    int32_t   pad;
    float      angle;
    float      majorAxis;
    float      minorAxis;
    MTReadout absolute;
    int32_t   pad2;
    int32_t   pad3;
    float      density;
} MTTouch;

/// Opaque handle to a multitouch device.
typedef void *MTDeviceRef;

/// Contact-frame callback the framework invokes on its own thread. `touches`
/// points to `numTouches` contiguous `MTTouch`. The refcon variant carries our
/// context pointer so one callback can serve several devices.
typedef int (*MTContactFrameCallback)(
    MTDeviceRef device, MTTouch *touches, int32_t numTouches,
    double timestamp, int32_t frame);
typedef int (*MTContactFrameCallbackWithRefcon)(
    MTDeviceRef device, MTTouch *touches, int32_t numTouches,
    double timestamp, int32_t frame, void *refcon);

/// Our own notion of `sizeof(MTTouch)`, so Swift can guard against an accidental
/// edit to the struct above (the real framework's size is confirmed by the
/// empirical coordinate-sanity check in `dump-frames`).
size_t MTPrivate_touchStructSize(void);

#endif /* MTPRIVATE_H */
