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
/// (matching `SimulatedTouchSource`); the mutable device tables are confined
/// to the lifecycle queue, and the global registry is touched only under
/// `registryLock`.
///
/// **Every private-framework call runs on the lifecycle queue, never on the
/// caller's thread.** `MTDeviceStop` (and its sibling `MTDeviceStart`) have no
/// timeout contract and have been observed blocking forever — a mouse mid
/// sleep/wake re-registration sits in the framework's own sleep loop and the
/// call never returns (docs/14, 2026-09 incident). Parking that wait on this
/// worker thread instead of the main run loop is what keeps the menu bar, the
/// event tap, and every timer alive when it happens; the coordinator's timeout
/// is what marks the source stuck instead of letting the app sit silently
/// "re-enumerating". A stuck queue is leaked, not cancelled: nothing can pull
/// a thread out of a kernel wait, and the source is dead until a fresh
/// process.
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

    /// Frame delivery: the framework calls its callback on its own thread; each
    /// frame is built there and handed here, where `onFrame` runs.
    private let frameQueue = DispatchQueue(label: "com.magicbuttons.multitouch.frames")
    /// Lifecycle: `MTDeviceCreateList` / `MTDeviceStart` / `MTDeviceStop` all run
    /// here, serially (see the type note for why they must never run on the
    /// caller's thread). `start` → `stop` ordering within one re-enumeration is
    /// guaranteed by the queue's FIFO.
    private let lifecycleQueue = DispatchQueue(label: "com.magicbuttons.multitouch.lifecycle")

    /// The enumerated device list, kept alive for the source's lifetime so the
    /// device pointers stay valid. Confined to `lifecycleQueue`.
    private var deviceList: CFArray?
    /// Confined to `lifecycleQueue`; snapshotted under `registryLock` before the
    /// blocking stops run, so the frame-callback thread is never parked on the
    /// lock while `MTDeviceStop` waits.
    private var activeDevices: [UnsafeMutableRawPointer] = []

    /// `true` once any frame has arrived. A coordinator can check this shortly
    /// after `start()`; still false usually means Input Monitoring isn't
    /// granted. Written on the framework thread (the same benign race the
    /// pre-queue design had); read-only downstream.
    public private(set) var hasReceivedFrame = false

    public init() throws {
        // `MTBackend.resolve()` is dlopen/dlsym only — fast, and safe on any
        // thread; device calls are what need the lifecycle queue.
        backend = try MTBackend.resolve()
        guard MTPrivate_touchStructSize() == Self.expectedTouchStructSize else {
            throw TouchSourceError.backendUnavailable
        }
    }

    public func start(completion: @escaping @Sendable (Result<Void, TouchSourceError>) -> Void) {
        lifecycleQueue.async {
            guard let (list, devices) = self.backend.devices() else {
                completion(.failure(.noDevice))
                return
            }
            let mice = devices.filter(self.isMagicMouse)
            guard !mice.isEmpty else {
                completion(.failure(.noDevice))
                return
            }

            self.deviceList = list
            self.activeDevices = mice

            // Register the callback + tables under the lock (brief critical
            // section — no framework call inside). The actual `MTDeviceStart`
            // runs after the unlock so a slow start can't park the frame thread
            // on the lock.
            registryLock.lock()
            for device in mice {
                deviceIDForDevice[device] = MouseDeviceID(raw: self.backend.stableID(of: device))
                sourceForDevice[device] = self
                self.backend.registerCallback(device, multitouchFrameCallback)
            }
            registryLock.unlock()

            for device in mice { _ = self.backend.start(device, 0) }
            completion(.success(()))
        }
    }

    public func stop(completion: @escaping @Sendable () -> Void) {
        lifecycleQueue.async {
            // Snapshot and clear the tables under the lock, then stop **outside**
            // it. Holding `registryLock` across `MTDeviceStop` (which can block
            // indefinitely — see the type note) would park the framework's
            // frame-callback thread on the lock for the whole hang, deafening
            // even a source that only partially stuck. Clearing the tables
            // first also means a late frame for a stopping device is dropped by
            // the registry lookup instead of racing the teardown.
            registryLock.lock()
            let devices = self.activeDevices
            self.activeDevices = []
            self.deviceList = nil
            for device in devices {
                sourceForDevice.removeValue(forKey: device)
                deviceIDForDevice.removeValue(forKey: device)
            }
            registryLock.unlock()

            for device in devices { _ = self.backend.stop(device) }
            completion()
        }
    }

    /// The Magic Mouse sensor is **portrait** (longer front-to-back); trackpads
    /// are landscape. Confirmed on-device: mouse `5152×9056`, trackpad
    /// `15780×9780`. Generalizes across Magic Mouse v1/v2 (same shell).
    /// Runs on the lifecycle queue (it calls the private `MTDeviceGetSensorSurfaceDimensions`).
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
        frameQueue.async { [weak self] in self?.onFrame?(delivered) }
    }
}

// MARK: - C callback plumbing
//
// `MTContactFrameCallback` is a non-capturing C function pointer, so it reaches
// the owning source through a device-keyed registry (also what keeps contacts
// from different mice routed to the right `MouseDeviceID`). Guarded by a lock
// because registration/teardown (lifecycle queue) races the callback
// (framework thread). The critical sections are brief by construction — never
// a private-framework call — so a stuck `MTDeviceStop` can't park the frame
// thread on the lock.

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
