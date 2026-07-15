import Testing
import Foundation
import CoreGraphics
import TouchKit

// Phase 9 two-mouse separation invariant — pure, hardware-free (docs/11 §Phase 9,
// docs/02 §keys on (deviceID, id)). Proves the tracker that backs `verify-two-mouse`
// distinguishes concurrent contacts from different mice, including the id-collision
// case that id-only keying would merge.

private func touch(_ device: UInt64, _ id: Int32, _ phase: TouchPhase,
                   x: CGFloat = 0.5, t: TimeInterval = 0) -> SurfaceTouch {
    SurfaceTouch(deviceID: MouseDeviceID(raw: device), id: id,
                 position: CGPoint(x: x, y: 0.5), phase: phase, timestamp: t, size: 9)
}

@Suite struct MultiDeviceContactTrackerTests {
    @Test func singleMouseIsNotSeparation() {
        let tracker = MultiDeviceContactTracker()
        tracker.ingest([touch(1, 1, .began)])
        tracker.ingest([touch(1, 1, .ended)])
        #expect(tracker.devicesSeen == [1])
        #expect(tracker.maxConcurrentDevices == 1)
        #expect(!tracker.didSeparateTwoMice)
    }

    @Test func sequentialTwoMiceSeenButNotConcurrent() {
        // Mouse 1 taps and lifts, THEN mouse 2 taps — two devices seen, but never
        // live at the same time, so separation isn't actually exercised.
        let tracker = MultiDeviceContactTracker()
        tracker.ingest([touch(1, 1, .began)])
        tracker.ingest([touch(1, 1, .ended)])
        tracker.ingest([touch(2, 1, .began)])
        tracker.ingest([touch(2, 1, .ended)])
        #expect(tracker.devicesSeen == [1, 2])
        #expect(tracker.maxConcurrentDevices == 1)
        #expect(!tracker.didSeparateTwoMice)          // seen ≠ separated
    }

    @Test func concurrentTwoMiceIsSeparation() {
        // Real frames are single-device and interleaved: both mice have a live
        // contact at the same time.
        let tracker = MultiDeviceContactTracker()
        tracker.ingest([touch(1, 1, .began)])
        tracker.ingest([touch(2, 7, .began)])         // both now live
        #expect(tracker.concurrentDevices == 2)
        tracker.ingest([touch(1, 1, .ended)])
        tracker.ingest([touch(2, 7, .ended)])
        #expect(tracker.maxConcurrentDevices == 2)
        #expect(tracker.didSeparateTwoMice)
        #expect(!tracker.observedCrossDeviceIDCollision)   // ids 1 and 7 never collided
    }

    @Test func crossDeviceIDCollisionIsKeptSeparate() {
        // The critical case: the SAME contact id (4) is live on both mice at once.
        // id-only keying would merge them; the tracker flags that it kept them apart.
        let tracker = MultiDeviceContactTracker()
        tracker.ingest([touch(1, 4, .began)])
        tracker.ingest([touch(2, 4, .began)])          // same id, other device
        #expect(tracker.concurrentDevices == 2)
        #expect(tracker.observedCrossDeviceIDCollision)
        #expect(tracker.didSeparateTwoMice)
        // Ending id 4 on device 1 must not end it on device 2.
        tracker.ingest([touch(1, 4, .ended)])
        #expect(tracker.concurrentDevices == 1)        // device 2's id-4 still live
        tracker.ingest([touch(2, 4, .ended)])
        #expect(tracker.concurrentDevices == 0)
    }

    @Test func resetClearsEverything() {
        let tracker = MultiDeviceContactTracker()
        tracker.ingest([touch(1, 1, .began)])
        tracker.ingest([touch(2, 1, .began)])
        tracker.reset()
        #expect(tracker.devicesSeen.isEmpty)
        #expect(tracker.concurrentDevices == 0)
        #expect(tracker.maxConcurrentDevices == 0)
        #expect(!tracker.observedCrossDeviceIDCollision)
    }
}
