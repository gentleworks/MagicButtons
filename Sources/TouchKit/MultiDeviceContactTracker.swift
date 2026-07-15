import Foundation

// Two-mouse separation checker (docs/11 §Phase 9, docs/08 §7, docs/02 — contact ids
// are unique only *within* a device, so tracking keys on `(deviceID, id)`).
//
// Multiple Magic Mice are a v1 feature: every attached mouse is subscribed and each
// contact is tagged with its `deviceID`. Phase 4 verified this only *structurally*;
// Phase 9 must show it on real hardware. The subtle failure this guards against is
// **id collision across devices** — mouse A and mouse B can each hand out contact
// `id = 4` at the same instant, and anything that keyed on `id` alone would merge
// them into one phantom contact (or leak one device's press into the other). This
// pure tracker consumes the frame stream and reports whether two mice were ever
// live at once and whether their contacts stayed separate — hardware-free and
// unit-testable, then driven by the real source in the `verify-two-mouse` harness.
public final class MultiDeviceContactTracker {
    /// Every device that has produced at least one contact.
    public private(set) var devicesSeen: Set<UInt64> = []
    /// The most devices observed with a live contact **simultaneously** — the real
    /// proof of separation is `≥ 2` (both mice touched at once, each attributed).
    public private(set) var maxConcurrentDevices = 0
    /// A contact `id` was live on two different devices at the same time, and the
    /// tracker kept them as distinct `(device, id)` entries — the case that would
    /// break naive id-only keying. Strong evidence the `deviceID` tag is doing its job.
    public private(set) var observedCrossDeviceIDCollision = false

    /// Live contact ids per device (a contact is live from `.began` to `.ended`).
    private var liveIDsByDevice: [UInt64: Set<Int32>] = [:]

    public init() {}

    /// One call per frame. Real frames are single-device (each mouse's callback
    /// delivers its own contacts), so concurrency across mice is observed as
    /// *interleaved* frames whose live state overlaps — which is why live state
    /// persists across calls rather than being read within one frame.
    public func ingest(_ touches: [SurfaceTouch]) {
        for touch in touches {
            let device = touch.deviceID.raw
            switch touch.phase {
            case .began:
                devicesSeen.insert(device)
                liveIDsByDevice[device, default: []].insert(touch.id)
            case .moved, .stationary:
                break
            case .ended:
                liveIDsByDevice[device]?.remove(touch.id)
                if liveIDsByDevice[device]?.isEmpty == true {
                    liveIDsByDevice.removeValue(forKey: device)
                }
            }
        }
        refreshDerivedState()
    }

    /// Devices with at least one live contact right now.
    public var concurrentDevices: Int { liveIDsByDevice.count }

    /// The separation invariant the HW gate checks: two distinct mice were seen and
    /// were live at the same time (so their contacts were concurrently attributed).
    public var didSeparateTwoMice: Bool {
        devicesSeen.count >= 2 && maxConcurrentDevices >= 2
    }

    public func reset() {
        devicesSeen.removeAll()
        liveIDsByDevice.removeAll()
        maxConcurrentDevices = 0
        observedCrossDeviceIDCollision = false
    }

    private func refreshDerivedState() {
        maxConcurrentDevices = max(maxConcurrentDevices, liveIDsByDevice.count)

        // An id value live on ≥2 devices simultaneously, kept separate by keying.
        guard liveIDsByDevice.count >= 2 else { return }
        var seenIDs: Set<Int32> = []
        for ids in liveIDsByDevice.values {
            if !seenIDs.isDisjoint(with: ids) { observedCrossDeviceIDCollision = true; return }
            seenIDs.formUnion(ids)
        }
    }
}
