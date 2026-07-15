import Foundation
import TouchKit
import MTPrivate

/// Runtime-resolved entry points into the private `MultitouchSupport` framework.
/// Resolution is `dlopen` + `dlsym`, scoped to the touch stream only — the
/// binary links no private symbols (docs/04-multitouch-backend.md §Scope). If
/// any required symbol is missing, we fail with `.backendUnavailable` so the App
/// can show a graceful "unsupported OS" state instead of crashing.
///
/// All device handles are raw pointers; no private type escapes this target.
struct MTBackend {
    typealias DeviceRef = UnsafeMutableRawPointer

    // C signatures resolved via dlsym. Names may need per-OS verification.
    typealias CreateListFn      = @convention(c) () -> Unmanaged<CFArray>?
    typealias RegisterCbFn      = @convention(c) (DeviceRef?, MTContactFrameCallback?) -> Void
    typealias StartFn           = @convention(c) (DeviceRef?, Int32) -> Int32
    typealias StopFn            = @convention(c) (DeviceRef?) -> Int32
    typealias ReleaseFn         = @convention(c) (DeviceRef?) -> Void
    typealias SurfaceDimsFn     = @convention(c) (DeviceRef?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Int32
    typealias DeviceIDFn        = @convention(c) (DeviceRef?, UnsafeMutablePointer<UInt64>?) -> Int32

    let createList: CreateListFn
    let registerCallback: RegisterCbFn
    let start: StartFn
    let stop: StopFn
    let release: ReleaseFn
    let surfaceDimensions: SurfaceDimsFn
    /// Optional: not present on every OS; used only for a stable `MouseDeviceID`.
    let deviceID: DeviceIDFn?

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"

    /// Open the framework and bind every required symbol, or throw.
    static func resolve() throws -> MTBackend {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY) else {
            throw TouchSourceError.backendUnavailable
        }
        func required<T>(_ name: String, as type: T.Type) throws -> T {
            guard let sym = dlsym(handle, name) else {
                throw TouchSourceError.backendUnavailable
            }
            return unsafeBitCast(sym, to: T.self)
        }
        func optional<T>(_ name: String, as type: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        return MTBackend(
            createList:        try required("MTDeviceCreateList", as: CreateListFn.self),
            registerCallback:  try required("MTRegisterContactFrameCallback", as: RegisterCbFn.self),
            start:             try required("MTDeviceStart", as: StartFn.self),
            stop:              try required("MTDeviceStop", as: StopFn.self),
            release:           try required("MTDeviceRelease", as: ReleaseFn.self),
            surfaceDimensions: try required("MTDeviceGetSensorSurfaceDimensions", as: SurfaceDimsFn.self),
            deviceID:          optional("MTDeviceGetDeviceID", as: DeviceIDFn.self)
        )
    }

    /// All multitouch devices currently enumerated by the framework, returned
    /// together with the backing `CFArray` the caller MUST keep alive while it
    /// uses the device pointers.
    ///
    /// Despite the "Create" in its name, `MTDeviceCreateList` returns an
    /// **autoreleased** (+0) array, so we take it unretained and let ARC manage a
    /// real reference — taking it retained over-releases when the autorelease pool
    /// drains (a CFRelease SIGTRAP). Device elements are owned by the list/
    /// framework; callers must NOT `MTDeviceRelease` them.
    func devices() -> (list: CFArray, refs: [DeviceRef])? {
        guard let list = createList()?.takeUnretainedValue() else { return nil }
        let count = CFArrayGetCount(list)
        var refs: [DeviceRef] = []
        refs.reserveCapacity(count)
        for i in 0..<count {
            if let ptr = CFArrayGetValueAtIndex(list, i) {
                refs.append(UnsafeMutableRawPointer(mutating: ptr))
            }
        }
        return (list, refs)
    }

    /// Sensor surface dimensions (hundredths of a mm) for `device`, or nil on
    /// failure. Used to tell a Magic Mouse from a trackpad.
    func surfaceSize(of device: DeviceRef) -> (width: Int32, height: Int32)? {
        var w: Int32 = 0, h: Int32 = 0
        let rc = surfaceDimensions(device, &w, &h)
        guard rc == 0, w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// A stable device id if the framework exposes one, else a pointer-derived
    /// fallback (unique per session, sufficient for keeping contacts separate).
    func stableID(of device: DeviceRef) -> UInt64 {
        if let deviceID {
            var id: UInt64 = 0
            if deviceID(device, &id) == 0, id != 0 { return id }
        }
        return UInt64(UInt(bitPattern: device))
    }
}
