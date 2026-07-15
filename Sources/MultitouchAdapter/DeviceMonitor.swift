import Foundation
import IOKit
import IOKit.hid

/// Fires `onChange` when any HID device is attached or removed, so the coordinator
/// can re-enumerate mice (the Phase 4 hot-plug deferral, now owned by Phase 7). It
/// matches **all** `IOHIDDevice`s rather than filtering to mice: over-triggering is
/// harmless — `AppCoordinator.refreshDevices()` just re-checks — and it avoids
/// fragile usage-page matching-dictionary juggling, while a Bluetooth Magic Mouse
/// reliably shows up as an `IOHIDDevice` add/remove.
///
/// Callbacks are delivered on the run loop the monitor is `start()`ed from (the main
/// run loop in the App). Not `Sendable`; drive it from main.
public final class DeviceMonitor {
    public var onChange: (() -> Void)?

    private var port: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    public init() {}

    public func start() {
        guard port == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            guard let refcon else { return }
            let monitor = Unmanaged<DeviceMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.drain(iterator)      // consume so the notification re-arms
            monitor.onChange?()
        }

        // Each notification consumes one reference to its matching dictionary, so the
        // add and remove registrations get their own dict.
        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification, IOServiceMatching(kIOHIDDeviceKey),
            callback, refcon, &addedIterator)
        drain(addedIterator)             // arm delivery + ignore the initial set

        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, IOServiceMatching(kIOHIDDeviceKey),
            callback, refcon, &removedIterator)
        drain(removedIterator)
    }

    public func stop() {
        if addedIterator != 0 { IOObjectRelease(addedIterator); addedIterator = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            IONotificationPortDestroy(port)
        }
        port = nil
    }

    private func drain(_ iterator: io_iterator_t) {
        var object = IOIteratorNext(iterator)
        while object != 0 {
            IOObjectRelease(object)
            object = IOIteratorNext(iterator)
        }
    }
}
