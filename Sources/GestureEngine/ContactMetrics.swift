import Foundation
import CoreGraphics
import TouchKit

// Calibration instrument (docs/11 §Phase 9, docs/08 §"To determine empirically").
//
// Every threshold default in `GestureConfig` / `ZoneLayout` is still a guess. To
// replace guesses with data we need to *measure* real contacts — not just watch the
// recognizer's yes/no verdicts, but capture the raw per-contact numbers (duration,
// travel, size, begin/end position, zone) for **every** contact regardless of
// whether it currently passes the tap gates. Feeding a real logging session through
// `ContactMetricsRecorder` yields one `ContactSample` per completed contact; the
// distribution of those samples is what the Phase 9 tuning pass reads to set the
// shipped defaults (and to decide the optional `y` rejection band, docs/08 §A).
//
// This is a *diagnostic* type that sits beside `MouseGestureRecognizer` rather than
// inside it. It no longer *mirrors* the recognizer's contact accounting — both now
// accumulate through the shared `ContactAccumulator`, so the logged numbers are by
// construction the ones the recognizer judges — but it never filters, so nothing is
// lost to the current thresholds. Pure logic: no hardware, no I/O, fully testable
// with scripted frames.

/// The raw measurements of one completed finger contact — the tuning record. All
/// fields are captured over the contact's full life (`.began`→`.ended`), matching
/// how the recognizer accumulates them, so `verdict(against:)` reproduces the
/// recognizer's decision for the same contact.
public struct ContactSample: Sendable, Equatable, Codable {
    public let deviceID: UInt64
    public let contactID: Int32
    /// `.began` timestamp (seconds).
    public let beganTime: TimeInterval
    /// `.ended` timestamp (seconds).
    public let endedTime: TimeInterval
    /// `.began` position, normalized `0…1`, origin bottom-left.
    public let origin: CGPoint
    /// `.ended` position (last seen), same coordinate space.
    public let end: CGPoint
    /// Zone captured at `.began` (the recognizer never reassigns on drift).
    public let beganZone: MouseZone
    /// Max Euclidean travel from `origin` over the contact's life, in **millimetres**
    /// (normalized in logs written before 1.1.3 — hence the renamed CSV column).
    public let maxTravelMM: CGFloat
    /// Max contact size over the contact's life (major-axis scale, ~8–10 per
    /// finger; [[touch-size-scale]]).
    public let maxSize: CGFloat
    /// A physical click was active during any frame of the contact's life.
    public let sawPhysicalClick: Bool
    /// How many frames the contact was observed in (`.began` + interims + `.ended`).
    /// A count of 2 means no interim frame arrived — the "frame-starved" case the
    /// recognizer guards defensively.
    public let frameCount: Int

    public init(
        deviceID: UInt64,
        contactID: Int32,
        beganTime: TimeInterval,
        endedTime: TimeInterval,
        origin: CGPoint,
        end: CGPoint,
        beganZone: MouseZone,
        maxTravelMM: CGFloat,
        maxSize: CGFloat,
        sawPhysicalClick: Bool,
        frameCount: Int
    ) {
        self.deviceID = deviceID
        self.contactID = contactID
        self.beganTime = beganTime
        self.endedTime = endedTime
        self.origin = origin
        self.end = end
        self.beganZone = beganZone
        self.maxTravelMM = maxTravelMM
        self.maxSize = maxSize
        self.sawPhysicalClick = sawPhysicalClick
        self.frameCount = frameCount
    }

    /// `.began`→`.ended` elapsed time.
    public var duration: TimeInterval { endedTime - beganTime }

    /// Reproduces `MouseGestureRecognizer.isTap` for this contact against `config`,
    /// but reports the *reason* rather than a bool — so a logging session shows not
    /// just how many real taps are rejected, but by which gate. Gate order matches
    /// the recognizer (physical-click → duration → travel → size).
    public func verdict(against config: GestureConfig) -> TapVerdict {
        ContactAccumulator.verdict(
            duration: duration, maxTravelMM: maxTravelMM, maxSize: maxSize,
            sawPhysicalClick: sawPhysicalClick, config: config)
    }
}

// MARK: - CSV

extension ContactSample {
    /// Column header for the logged CSV (matches `csvRow`). The trailing `verdict`
    /// column is evaluated against whatever config the session ran on.
    ///
    /// `maxTravelMM` was `maxTravel`, holding a *normalized* distance, before 1.1.3.
    /// The column is renamed rather than reused so a pre-change log and a post-change
    /// one cannot be concatenated and analyzed as one distribution — the numbers differ
    /// by ~68× and nothing else in the row would give that away.
    public static let csvHeader =
        "device,contactID,beganTime,duration,originX,originY,endX,endY,zone,maxTravelMM,maxSize,sawPhysicalClick,frameCount,verdict"

    /// One CSV line for this sample, with the tap `verdict` evaluated against
    /// `config`. Floats are fixed to a few decimals so the file stays diff-friendly
    /// and readable; timestamps keep more precision for timing analysis.
    public func csvRow(verdictAgainst config: GestureConfig) -> String {
        func f(_ v: CGFloat, _ p: Int = 4) -> String { String(format: "%.\(p)f", Double(v)) }
        func t(_ v: TimeInterval) -> String { String(format: "%.4f", v) }
        return [
            String(deviceID),
            String(contactID),
            t(beganTime),
            t(duration),
            f(origin.x), f(origin.y),
            f(end.x), f(end.y),
            String(describing: beganZone),
            f(maxTravelMM), f(maxSize, 2),
            sawPhysicalClick ? "1" : "0",
            String(frameCount),
            verdict(against: config).rawValue,
        ].joined(separator: ",")
    }
}

// MARK: - Recorder

/// Consumes the frame stream and emits one `ContactSample` per contact that
/// completes (`.began`…`.ended`). Pure and hardware-free — drive it from a real
/// `MultitouchSource` in the harness, or from scripted frames in tests. Contacts
/// keyed on `(deviceID, id)` like the recognizer, since ids are only unique within
/// a device.
public final class ContactMetricsRecorder {
    /// Called on the ingesting thread as each contact ends.
    public var onSample: ((ContactSample) -> Void)?

    private let layout: ZoneLayout

    private struct Key: Hashable {
        let device: UInt64
        let id: Int32
    }

    private var live: [Key: ContactAccumulator] = [:]

    public init(layout: ZoneLayout) {
        self.layout = layout
    }

    /// One call per frame, mirroring the recognizer's signature so the same live
    /// stream (touches + physical-click state) feeds both.
    public func ingest(_ touches: [SurfaceTouch], physicalClickActive: Bool) {
        for touch in touches {
            let key = Key(device: touch.deviceID.raw, id: touch.id)
            switch touch.phase {
            case .began:
                live[key] = ContactAccumulator(
                    began: touch, zone: layout.zone(for: touch.position),
                    physicalClickActive: physicalClickActive)
            case .moved, .stationary:
                guard var s = live[key] else { continue }
                s.accumulate(touch, physicalClickActive: physicalClickActive)
                live[key] = s
            case .ended:
                guard var s = live[key] else { continue }
                s.accumulate(touch, physicalClickActive: physicalClickActive)
                live.removeValue(forKey: key)
                onSample?(ContactSample(
                    deviceID: touch.deviceID.raw,
                    contactID: touch.id,
                    beganTime: s.startTime,
                    endedTime: touch.timestamp,
                    origin: s.origin,
                    end: s.last,
                    beganZone: s.zone,
                    maxTravelMM: s.maxTravelMM,
                    maxSize: s.maxSize,
                    sawPhysicalClick: s.sawPhysicalClick,
                    frameCount: s.frameCount))
            }
        }
    }

    /// Drop all in-flight contacts without emitting (a contact with no `.ended`
    /// frame — device loss, disable — has no meaningful duration, so it is not a
    /// sample). Matches the recognizer dropping its state on cancel.
    public func reset() { live.removeAll() }
}

// MARK: - Summary

/// A tuning-oriented aggregate over logged samples: how many contacts, how they
/// split by zone and by tap verdict, and the min/mean/max of each measurement that
/// backs a threshold. This is the at-a-glance readout the harness prints at the end
/// of a session — enough to see, e.g., "real taps cluster at size ≤ 11 but maxSize
/// default is 14, headroom is fine" or "12 taps rejected on duration, raise
/// maxDuration". Pure; build it from an array or stream samples in with `add`.
public struct ContactSummary: Sendable, Equatable {
    /// min / mean / max of one measurement across the samples (empty → all zero).
    public struct Stat: Sendable, Equatable {
        public var count: Int = 0
        public var min: Double = 0
        public var mean: Double = 0
        public var max: Double = 0
    }

    public private(set) var count = 0
    public private(set) var byZone: [MouseZone: Int] = [:]
    /// Verdicts evaluated against the config passed to `add` / the initializer.
    public private(set) var byVerdict: [TapVerdict: Int] = [:]

    // Running sums, kept private; exposed as `Stat`s below.
    private var durationSum = 0.0, durationMin = Double.infinity, durationMax = 0.0
    private var travelSum = 0.0, travelMin = Double.infinity, travelMax = 0.0
    private var sizeSum = 0.0, sizeMin = Double.infinity, sizeMax = 0.0
    private var beganYSum = 0.0, beganYMin = Double.infinity, beganYMax = 0.0

    public init() {}

    public init(samples: [ContactSample], config: GestureConfig) {
        for s in samples { add(s, config: config) }
    }

    public mutating func add(_ s: ContactSample, config: GestureConfig) {
        count += 1
        byZone[s.beganZone, default: 0] += 1
        byVerdict[s.verdict(against: config), default: 0] += 1
        accumulate(&durationSum, &durationMin, &durationMax, s.duration)
        accumulate(&travelSum, &travelMin, &travelMax, Double(s.maxTravelMM))
        accumulate(&sizeSum, &sizeMin, &sizeMax, Double(s.maxSize))
        accumulate(&beganYSum, &beganYMin, &beganYMax, Double(s.origin.y))
    }

    public var duration: Stat { stat(durationSum, durationMin, durationMax) }
    public var travel: Stat { stat(travelSum, travelMin, travelMax) }
    public var size: Stat { stat(sizeSum, sizeMin, sizeMax) }
    /// Begin-`y` distribution — the input to the optional `y` rejection-band
    /// decision (docs/08 §A): where on the front-to-back axis real taps land.
    public var beganY: Stat { stat(beganYSum, beganYMin, beganYMax) }

    private func accumulate(_ sum: inout Double, _ lo: inout Double, _ hi: inout Double, _ v: Double) {
        sum += v; lo = Swift.min(lo, v); hi = Swift.max(hi, v)
    }

    private func stat(_ sum: Double, _ lo: Double, _ hi: Double) -> Stat {
        guard count > 0 else { return Stat() }
        return Stat(count: count, min: lo, mean: sum / Double(count), max: hi)
    }
}
