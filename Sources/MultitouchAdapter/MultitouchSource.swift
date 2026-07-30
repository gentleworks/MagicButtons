import Foundation
import CoreGraphics
import TouchKit
import MTPrivate

/// The real `TouchSource`: subscribes to every attached **Magic Mouse** and
/// emits `SurfaceTouch` frames. The only place private frames become domain
/// types — no private type escapes this file (docs/04-multitouch-backend.md).
///
/// `@unchecked Sendable`: contacts arrive on the framework's own thread; each
/// frame is built there and handed to a dedicated serial queue where `onFrame`
/// runs. `onFrame` must be set **before** `start()` and not mutated afterward
/// (matching `SimulatedTouchSource`); the mutable device tables are touched only
/// under `registryLock`.
public final class MultitouchSource: TouchSource, @unchecked Sendable {
    public var onFrame: (([SurfaceTouch]) -> Void)?

    /// `sizeof(MTTouch)` for the shim's own struct. `MTPrivate_touchStructSize()`
    /// reports our declared layout (not the framework's), so this guard catches an
    /// **accidental edit to our `MTTouch`** and refuses to interpret frames rather
    /// than feed garbage downstream. Cross-OS layout drift is caught empirically
    /// instead — see the per-OS verification table in docs/04 §Sanity checks (96
    /// bytes confirmed sane through macOS 26.5.2 / Darwin 25.5.0).
    static let expectedTouchStructSize = 96

    private let backend: MTBackend
    private let queue = DispatchQueue(label: "com.magicbuttons.multitouch.frames")

    /// The enumerated device list, kept alive for the source's lifetime so the
    /// device pointers stay valid.
    private var deviceList: CFArray?
    private var activeDevices: [UnsafeMutableRawPointer] = []

    /// `true` once any frame has arrived. A coordinator can check this shortly
    /// after `start()`; still false usually means Input Monitoring isn't granted.
    public private(set) var hasReceivedFrame = false

    public init() throws {
        backend = try MTBackend.resolve()
        guard MTPrivate_touchStructSize() == Self.expectedTouchStructSize else {
            throw TouchSourceError.backendUnavailable
        }
    }

    public func start() throws {
        guard let (list, devices) = backend.devices() else {
            throw TouchSourceError.noDevice
        }
        let mice = devices.filter(isMagicMouse)
        guard !mice.isEmpty else { throw TouchSourceError.noDevice }

        deviceList = list
        activeDevices = mice

        registryLock.lock()
        for device in mice {
            deviceIDForDevice[device] = MouseDeviceID(raw: backend.stableID(of: device))
            sourceForDevice[device] = self
            backend.registerCallback(device, multitouchFrameCallback)
        }
        registryLock.unlock()

        for device in mice { _ = backend.start(device, 0) }
    }

    public func stop() {
        registryLock.lock()
        for device in activeDevices {
            _ = backend.stop(device)
            sourceForDevice.removeValue(forKey: device)
            deviceIDForDevice.removeValue(forKey: device)
        }
        registryLock.unlock()
        activeDevices = []
        deviceList = nil
    }

    /// The Magic Mouse sensor is **portrait** (longer front-to-back); trackpads
    /// are landscape. Confirmed on-device: mouse `5152×9056`, trackpad
    /// `15780×9780`. Generalizes across Magic Mouse v1/v2 (same shell).
    private func isMagicMouse(_ device: UnsafeMutableRawPointer) -> Bool {
        guard let (w, h) = backend.surfaceSize(of: device) else { return false }
        return w < h
    }

    /// Build one `SurfaceTouch` frame from raw contacts (framework thread) and
    /// hand it to the serial queue. Called from the C callback.
    fileprivate func ingest(
        device: UnsafeMutableRawPointer,
        touches: UnsafeMutablePointer<MTTouch>?,
        count: Int32
    ) {
        guard let touches else { return }
        registryLock.lock()
        let deviceID = deviceIDForDevice[device]
        registryLock.unlock()
        guard let deviceID else { return }

        // Clamp against a bad count so a layout regression can't run wild.
        let n = max(0, min(Int(count), 32))
        var frame: [SurfaceTouch] = []
        frame.reserveCapacity(n)
        for i in 0..<n {
            let t = touches[i]
            guard let phase = TouchPhase(rawState: t.state) else { continue }
            frame.append(SurfaceTouch(
                deviceID: deviceID,
                id: t.identifier,
                position: CGPoint(x: CGFloat(t.normalized.position.x),
                                  y: CGFloat(t.normalized.position.y)),
                phase: phase,
                timestamp: t.timestamp,
                size: CGFloat(t.majorAxis),
                minorAxis: CGFloat(t.minorAxis),
                angle: CGFloat(t.angle)))
        }
        hasReceivedFrame = true
        let delivered = frame // immutable copy to hand across the queue boundary
        queue.async { [weak self] in self?.onFrame?(delivered) }
    }
}

// MARK: - C callback plumbing
//
// `MTContactFrameCallback` is a non-capturing C function pointer, so it reaches
// the owning source through a device-keyed registry (also what keeps contacts
// from different mice routed to the right `MouseDeviceID`). Guarded by a lock
// because registration/teardown (main) races the callback (framework thread).

nonisolated(unsafe) private var sourceForDevice: [UnsafeMutableRawPointer: MultitouchSource] = [:]
nonisolated(unsafe) private var deviceIDForDevice: [UnsafeMutableRawPointer: MouseDeviceID] = [:]
private let registryLock = NSLock()

private let multitouchFrameCallback: MTContactFrameCallback = { device, touches, count, _, _ in
    guard let device else { return 0 }
    registryLock.lock()
    let source = sourceForDevice[device]
    registryLock.unlock()
    source?.ingest(device: device, touches: touches, count: count)
    return 0
}
