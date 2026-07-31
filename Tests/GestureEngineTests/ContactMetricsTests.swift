import Testing
import Foundation
import CoreGraphics
@testable import GestureEngine
import TouchKit

// Phase 9 calibration instrument — pure per-contact measurement (docs/11 §Phase 9,
// docs/08 §"To determine empirically"). Verifies the recorder mirrors the
// recognizer's contact accounting and that verdict/CSV/summary are correct, so the
// numbers a logging session writes can be trusted for tuning.

private let device = MouseDeviceID(raw: 1)

/// One contact described phase-by-phase. `began` at `t0`, `ended` at `t0 + duration`;
/// optional interim points become `.moved` frames (used to drive travel/size).
private func contact(
    id: Int32 = 1,
    device: MouseDeviceID = device,
    at position: CGPoint,
    interim: [(CGPoint, CGFloat)] = [],
    t0: TimeInterval = 0,
    duration: TimeInterval = 0.10,
    size: CGFloat = 9,
    physicalClick: Bool = false,
    endSize: CGFloat? = nil
) -> [(touches: [SurfaceTouch], click: Bool)] {
    var frames: [(touches: [SurfaceTouch], click: Bool)] = []
    frames.append(([SurfaceTouch(deviceID: device, id: id, position: position,
                                 phase: .began, timestamp: t0, size: size)], physicalClick))
    let step = interim.isEmpty ? 0 : duration / Double(interim.count + 1)
    for (i, pt) in interim.enumerated() {
        frames.append(([SurfaceTouch(deviceID: device, id: id, position: pt.0,
                                     phase: .moved, timestamp: t0 + step * Double(i + 1),
                                     size: pt.1)], physicalClick))
    }
    frames.append(([SurfaceTouch(deviceID: device, id: id, position: position,
                                 phase: .ended, timestamp: t0 + duration,
                                 size: endSize ?? size)], physicalClick))
    return frames
}

private func record(_ frames: [(touches: [SurfaceTouch], click: Bool)],
                    layout: ZoneLayout = ZoneLayout()) -> [ContactSample] {
    let recorder = ContactMetricsRecorder(layout: layout)
    var out: [ContactSample] = []
    recorder.onSample = { out.append($0) }
    for f in frames { recorder.ingest(f.touches, physicalClickActive: f.click) }
    return out
}

@Suite struct ContactRecorderTests {
    @Test func emitsOneSamplePerCompletedContact() {
        let out = record(contact(at: CGPoint(x: 0.1, y: 0.5)))
        #expect(out.count == 1)
        let s = out[0]
        #expect(s.beganZone == .left)          // x 0.1 < leftEdge 0.38
        #expect(s.contactID == 1)
        #expect(s.deviceID == 1)
        #expect(abs(s.duration - 0.10) < 1e-9)
        #expect(s.frameCount == 2)             // began + ended, no interim
    }

    @Test func zoneIsCapturedAtBeganNotEnd() {
        // Begins right (0.9 > rightEdge 0.62), drifts across to left by end. The
        // `.ended` frame carries a different position than `.began`, so this is
        // built by hand rather than with the fixed-position `contact` helper.
        let recorder = ContactMetricsRecorder(layout: ZoneLayout())
        var got: ContactSample?
        recorder.onSample = { got = $0 }
        recorder.ingest([SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: 0.9, y: 0.5),
                                      phase: .began, timestamp: 0, size: 9)], physicalClickActive: false)
        recorder.ingest([SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: 0.1, y: 0.5),
                                      phase: .ended, timestamp: 0.1, size: 9)], physicalClickActive: false)
        #expect(got?.beganZone == .right)
        #expect(got?.end.x == 0.1)
    }

    @Test func maxTravelIsEuclideanPeakOverLife() {
        // Interim point 5 mm away, then returns — peak travel must be recorded.
        let origin = CGPoint(x: 0.5, y: 0.5)
        let out = record(contact(at: origin,
                                  interim: [(offsetMM(origin, dxMM: 3, dyMM: 4), 9)]))
        #expect(out.count == 1)
        #expect(abs(out[0].maxTravelMM - 5.0) < 1e-6)   // 3-4-5, in millimetres
    }

    /// The logged number is a physical distance, so it must not depend on which way the
    /// finger went — the same property the gate now has (docs/04).
    @Test func travelIsRecordedInMillimetresNotNormalizedUnits() {
        let origin = CGPoint(x: 0.5, y: 0.5)
        let sideways = record(contact(at: origin, interim: [(offsetMM(origin, dxMM: 4), 9)]))
        let foreAft = record(contact(at: origin, interim: [(offsetMM(origin, dyMM: 4), 9)]))
        #expect(abs(sideways[0].maxTravelMM - 4.0) < 1e-6)
        #expect(abs(foreAft[0].maxTravelMM - 4.0) < 1e-6)
    }

    @Test func maxSizeIsPeakOverLife() {
        let out = record(contact(at: CGPoint(x: 0.5, y: 0.5),
                                  interim: [(CGPoint(x: 0.5, y: 0.5), 30)], size: 9))
        #expect(out[0].maxSize == 30)
        #expect(out[0].frameCount == 3)
    }

    @Test func physicalClickLatchesOnceSeen() {
        // Click only on the interim frame — still latched at end.
        let recorder = ContactMetricsRecorder(layout: ZoneLayout())
        var got: ContactSample?
        recorder.onSample = { got = $0 }
        recorder.ingest([SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: 0.5, y: 0.5),
                                      phase: .began, timestamp: 0, size: 9)], physicalClickActive: false)
        recorder.ingest([SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: 0.5, y: 0.5),
                                      phase: .moved, timestamp: 0.05, size: 9)], physicalClickActive: true)
        recorder.ingest([SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: 0.5, y: 0.5),
                                      phase: .ended, timestamp: 0.1, size: 9)], physicalClickActive: false)
        #expect(got?.sawPhysicalClick == true)
    }

    @Test func separatesContactsByDeviceAndID() {
        let a = MouseDeviceID(raw: 1)
        let b = MouseDeviceID(raw: 2)
        let recorder = ContactMetricsRecorder(layout: ZoneLayout())
        var out: [ContactSample] = []
        recorder.onSample = { out.append($0) }
        // Same contact id (1) on two devices, interleaved — must not cross-contaminate.
        recorder.ingest([
            SurfaceTouch(deviceID: a, id: 1, position: CGPoint(x: 0.1, y: 0.5), phase: .began, timestamp: 0, size: 9),
            SurfaceTouch(deviceID: b, id: 1, position: CGPoint(x: 0.9, y: 0.5), phase: .began, timestamp: 0, size: 9),
        ], physicalClickActive: false)
        recorder.ingest([SurfaceTouch(deviceID: a, id: 1, position: CGPoint(x: 0.1, y: 0.5), phase: .ended, timestamp: 0.1, size: 9)], physicalClickActive: false)
        recorder.ingest([SurfaceTouch(deviceID: b, id: 1, position: CGPoint(x: 0.9, y: 0.5), phase: .ended, timestamp: 0.1, size: 9)], physicalClickActive: false)
        #expect(out.count == 2)
        #expect(out[0].deviceID == 1 && out[0].beganZone == .left)
        #expect(out[1].deviceID == 2 && out[1].beganZone == .right)
    }

    @Test func resetDropsInFlightContactsWithoutEmitting() {
        let recorder = ContactMetricsRecorder(layout: ZoneLayout())
        var out: [ContactSample] = []
        recorder.onSample = { out.append($0) }
        recorder.ingest([SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: 0.5, y: 0.5),
                                      phase: .began, timestamp: 0, size: 9)], physicalClickActive: false)
        recorder.reset()
        // A late `.ended` for the dropped contact must not resurrect it.
        recorder.ingest([SurfaceTouch(deviceID: device, id: 1, position: CGPoint(x: 0.5, y: 0.5),
                                      phase: .ended, timestamp: 0.1, size: 9)], physicalClickActive: false)
        #expect(out.isEmpty)
    }
}

@Suite struct TapVerdictTests {
    private func sample(
        duration: TimeInterval = 0.10, travelMM: CGFloat = 0, size: CGFloat = 9,
        click: Bool = false
    ) -> ContactSample {
        ContactSample(deviceID: 1, contactID: 1, beganTime: 0, endedTime: duration,
                      origin: .zero, end: .zero, beganZone: .middle,
                      maxTravelMM: travelMM, maxSize: size, sawPhysicalClick: click,
                      frameCount: 2)
    }

    @Test func acceptsAContactWithinAllGates() {
        #expect(sample().verdict(against: GestureConfig()) == .tap)
    }

    @Test func rejectionOrderMatchesRecognizer() {
        let c = GestureConfig()  // maxDuration 0.18, maxTravelMM 4.1, maxSize 14
        // Physical click wins even when every other measure is also out of range.
        #expect(sample(duration: 1, travelMM: 20, size: 99, click: true)
                    .verdict(against: c) == .rejectedPhysicalClick)
        // Then duration, before travel/size.
        #expect(sample(duration: 0.5, travelMM: 20, size: 99).verdict(against: c) == .rejectedDuration)
        // Then travel, before size.
        #expect(sample(duration: 0.10, travelMM: 20, size: 99).verdict(against: c) == .rejectedTravel)
        // Then size.
        #expect(sample(duration: 0.10, travelMM: 0, size: 99).verdict(against: c) == .rejectedSize)
    }

    @Test func matchesTheRecognizersRealDecision() {
        // A borderline-long tap the recognizer would reject on duration: recorder's
        // verdict must agree with the recognizer's actual output.
        let config = GestureConfig()
        let frames = contact(at: CGPoint(x: 0.1, y: 0.5), duration: 0.30)  // > maxDuration
        let samples = record(frames)
        #expect(samples[0].verdict(against: config) == .rejectedDuration)

        let recognizer = MouseGestureRecognizer(layout: ZoneLayout(), config: config)
        var gestures: [ButtonGesture] = []
        recognizer.onGesture = { gestures.append($0) }
        for f in frames { recognizer.ingest(f.touches, physicalClickActive: f.click) }
        #expect(gestures.isEmpty)  // recognizer also rejected it
    }
}

@Suite struct ContactSummaryAndCSVTests {
    @Test func csvHeaderMatchesRowColumnCount() {
        let s = ContactSample(deviceID: 1, contactID: 2, beganTime: 1.5, endedTime: 1.6,
                              origin: CGPoint(x: 0.1, y: 0.4), end: CGPoint(x: 0.11, y: 0.41),
                              beganZone: .left, maxTravelMM: 1.0, maxSize: 9.5,
                              sawPhysicalClick: false, frameCount: 3)
        let header = ContactSample.csvHeader.split(separator: ",").count
        let row = s.csvRow(verdictAgainst: GestureConfig()).split(separator: ",", omittingEmptySubsequences: false).count
        #expect(header == row)
    }

    @Test func csvRowCarriesVerdictAndKeyFields() {
        let s = ContactSample(deviceID: 7, contactID: 3, beganTime: 0, endedTime: 0.5,
                              origin: CGPoint(x: 0.9, y: 0.5), end: CGPoint(x: 0.9, y: 0.5),
                              beganZone: .right, maxTravelMM: 0, maxSize: 9,
                              sawPhysicalClick: false, frameCount: 2)
        let row = s.csvRow(verdictAgainst: GestureConfig())
        #expect(row.hasPrefix("7,3,"))
        #expect(row.contains("right"))
        #expect(row.hasSuffix("rejectedDuration"))  // 0.5s > maxDuration 0.18
    }

    @Test func summaryCountsZonesVerdictsAndStats() {
        let config = GestureConfig()
        let samples = [
            record(contact(at: CGPoint(x: 0.1, y: 0.3)))[0],   // left, tap, y 0.3
            record(contact(at: CGPoint(x: 0.9, y: 0.7)))[0],   // right, tap, y 0.7
            record(contact(at: CGPoint(x: 0.1, y: 0.5), duration: 0.30))[0],  // left, rejectedDuration
        ]
        let summary = ContactSummary(samples: samples, config: config)
        #expect(summary.count == 3)
        #expect(summary.byZone[.left] == 2)
        #expect(summary.byZone[.right] == 1)
        #expect(summary.byVerdict[.tap] == 2)
        #expect(summary.byVerdict[.rejectedDuration] == 1)
        #expect(summary.beganY.min == 0.3)
        #expect(summary.beganY.max == 0.7)
        #expect(abs(summary.beganY.mean - 0.5) < 1e-9)
        #expect(summary.duration.max > 0.29)
    }

    @Test func emptySummaryIsAllZero() {
        let summary = ContactSummary()
        #expect(summary.count == 0)
        #expect(summary.duration == ContactSummary.Stat())
        #expect(summary.byZone.isEmpty)
    }
}
