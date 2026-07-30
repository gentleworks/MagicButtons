import Foundation
import CoreGraphics
import TouchKit

/// Turns the frame stream into `ButtonGesture`s. Pure logic: no hardware, no
/// `CGEvent`, no UI — a deterministic function of `(frames, config)` so it is
/// fully testable with scripted `SurfaceTouch` frames (docs/03-gesture-recognition.md).
///
/// **Scope:** the *tap primitive*, **multi-click** (`click(zone, N)` for single,
/// double, and triple — up to `config.maxClickCount`), and **tap-and-a-half drag**
/// (`holdBegan`/`holdEnded`). The first click is emitted the instant a tap releases
/// (no single-click latency); each further contact that lands in the same zone within
/// `doubleTapGap` continues the run — `click(zone, 2)`, `click(zone, 3)` — or, as the
/// *second* contact, is held past `holdThreshold` → `holdBegan(zone)` then
/// `holdEnded(zone)` on lift (Phase 8, docs/03 §The unified state machine).
/// A read-only snapshot of one contact the recognizer is currently tracking — what it
/// has measured *so far* and how it would be judged if it ended now. This is the feed
/// the visualizer draws its tap-travel budget from, so the picture comes from the
/// machinery that decides rather than a parallel copy of it (docs/10 §Visualizer).
public struct LiveContact: Sendable, Equatable, Identifiable {
    public let id: Int32
    public let deviceID: MouseDeviceID
    /// The `.began` position travel is measured from, normalized, origin bottom-left.
    public let origin: CGPoint
    public let zone: MouseZone
    /// Greatest Euclidean distance from `origin` reached so far, in normalized space.
    public let maxTravel: CGFloat
    /// The `maxTravel` this contact will actually be judged against — carried from the
    /// recognizer's own live config so a drawn ring cannot show a stale threshold.
    public let travelBudget: CGFloat
    /// Why this contact would be rejected **if it ended at the last frame seen**, or
    /// `.tap`. Evaluated at that frame's timestamp, never a wall clock, so reading it
    /// does not put a clock into the recognizer.
    public let verdictSoFar: TapVerdict
    public let didBeginHold: Bool

    public init(
        id: Int32, deviceID: MouseDeviceID, origin: CGPoint, zone: MouseZone,
        maxTravel: CGFloat, travelBudget: CGFloat, verdictSoFar: TapVerdict,
        didBeginHold: Bool
    ) {
        self.id = id
        self.deviceID = deviceID
        self.origin = origin
        self.zone = zone
        self.maxTravel = maxTravel
        self.travelBudget = travelBudget
        self.verdictSoFar = verdictSoFar
        self.didBeginHold = didBeginHold
    }
}

public final class MouseGestureRecognizer {
    /// Emitted on the calling thread as gestures are recognized.
    public var onGesture: ((ButtonGesture) -> Void)?

    /// Live tunables/zone layout. `var` so a settings edit can be applied **in place**
    /// (`update`) without discarding tracking state — see `update` for why that
    /// matters to an in-flight drag.
    private var layout: ZoneLayout
    private var config: GestureConfig

    /// Contact ids are only unique *within* a device, so tracking is keyed on
    /// `(deviceID, id)` (docs/02-domain-model.md).
    private struct ContactKey: Hashable {
        let device: UInt64
        let id: Int32
    }

    /// What we accumulate over a live contact to judge it against the tap rules
    /// at `.ended`, plus the click-run bookkeeping that is the recognizer's alone.
    /// The measurements live in the shared `ContactAccumulator` — one implementation
    /// for the recognizer, the calibration recorder, and the visualizer.
    private struct ContactState {
        var contact: ContactAccumulator
        /// Set at `.began`: the click-count of the in-gap click run this contact
        /// *continues* (the count of a live WAIT_SECOND for its zone), or 0 if none.
        /// If it finalizes as a tap it emits `click(zone, followsCount + 1)` — 0→
        /// single, 1→double, 2→triple — up to `config.maxClickCount`. Also gates the
        /// `tapAndAHalf` drag: only the immediate second contact (`followsCount == 1`)
        /// hold-promotes; a later tap in a longer run does not (double-tap-then-hold
        /// drag is a separate roadmap feature).
        var followsCount: Int
        /// A second-tap contact that has been held past `holdThreshold` and
        /// promoted to a drag: `holdBegan` has fired and a matching `holdEnded`
        /// must follow on `.ended` (or on `cancelActiveHolds`). Guards against a
        /// double `holdBegan` and against a held contact leaking into the
        /// double-click branch.
        var didBeginHold: Bool
    }

    private var contacts: [ContactKey: ContactState] = [:]

    /// The per-zone WAIT_SECOND memory: the end time **and click-count** of the most
    /// recent click emitted in each zone. A contact that `.begins` in the same zone
    /// within `doubleTapGap` continues the run, emitting `click(zone, count + 1)` — a
    /// single arms a double, a double arms a triple — up to `config.maxClickCount`,
    /// where the run ends. An entry is consumed (removed) the moment any contact
    /// begins in its zone — either continued, or dropped as expired (WAIT_SECOND→IDLE).
    private struct PendingClick {
        let endTime: TimeInterval
        let count: Int
    }
    private var pendingClick: [MouseZone: PendingClick] = [:]

    public init(layout: ZoneLayout, config: GestureConfig) {
        self.layout = layout
        self.config = config
    }

    /// Apply new tunables/zone layout **in place**, preserving all live tracking
    /// (`contacts`, `pendingClick`). This is what lets a settings slider be dragged
    /// *by* a MagicButtons hold without the edit cancelling that hold: rebuilding the
    /// recognizer would drop the in-flight contact, so the eventual `.ended` frame
    /// couldn't fire the matching `holdEnded` — a stuck button — which is why the
    /// caller used to release the hold first. Updating in place keeps the contact, so
    /// the lift still releases cleanly and no release is needed. A live hold's button
    /// is unaffected because its zone was captured at `.began` (see `ContactState`);
    /// only *future* contacts see the new layout/config.
    public func update(layout: ZoneLayout, config: GestureConfig) {
        self.layout = layout
        self.config = config
    }

    /// One call per frame: **all** current contacts plus the current
    /// physical-click state (sourced by the coordinator from a public event tap;
    /// keeping it a parameter leaves the recognizer pure — docs/03 §Physical-click
    /// input).
    public func ingest(_ touches: [SurfaceTouch], physicalClickActive: Bool) {
        // `pressAndHold` only arms a drag from a *single* live contact, so a
        // two-finger gesture (e.g. a swipe) can't be mistaken for a press-drag.
        let singleContact = touches.count == 1
        for touch in touches {
            let key = ContactKey(device: touch.deviceID.raw, id: touch.id)
            switch touch.phase {
            case .began:
                let zone = layout.zone(for: touch.position)
                // Any prior WAIT_SECOND for this zone is now resolved: this contact
                // continues its run if still in-gap (carrying that count), otherwise
                // the run expired and this is a fresh single.
                let prior = pendingClick.removeValue(forKey: zone)
                let followsCount = prior.map {
                    touch.timestamp - $0.endTime <= config.doubleTapGap ? $0.count : 0
                } ?? 0
                contacts[key] = ContactState(
                    contact: ContactAccumulator(began: touch, zone: zone,
                                                physicalClickActive: physicalClickActive),
                    followsCount: followsCount,
                    didBeginHold: false
                )
            case .moved, .stationary:
                guard var state = contacts[key] else { continue }
                state.contact.accumulate(touch, physicalClickActive: physicalClickActive)
                promoteToHoldIfNeeded(&state, now: touch.timestamp, singleContact: singleContact)
                contacts[key] = state
            case .ended:
                guard var state = contacts[key] else { continue }
                state.contact.accumulate(touch, physicalClickActive: physicalClickActive)
                contacts.removeValue(forKey: key)
                if state.didBeginHold {
                    // A promoted drag: mirror the `holdBegan` with a `holdEnded` on
                    // lift so the pressed button is released (docs/03 §state machine).
                    onGesture?(.holdEnded(zone: state.contact.zone))
                } else {
                    finalize(state, endTime: touch.timestamp)
                }
            }
        }
    }

    /// Every contact currently tracked, ordered by `(device, id)` so a consumer sees a
    /// stable sequence frame to frame. Read *after* `ingest` to see the current frame.
    public var liveContacts: [LiveContact] {
        contacts.map { key, state in
            LiveContact(
                id: key.id,
                deviceID: MouseDeviceID(raw: key.device),
                origin: state.contact.origin,
                zone: state.contact.zone,
                maxTravel: state.contact.maxTravel,
                travelBudget: config.maxTravel,
                verdictSoFar: state.contact.verdict(at: state.contact.lastTime,
                                                    against: config),
                didBeginHold: state.didBeginHold)
        }
        .sorted { ($0.deviceID.raw, $0.id) < ($1.deviceID.raw, $1.id) }
    }

    /// Safety hook: the coordinator calls this when a feature is disabled or the
    /// app is quitting, so any in-flight synthetic hold is released and no button
    /// stays stuck (docs/03 §Recognizer shape, docs/05 §Press/release). Emits a
    /// `holdEnded` for every promoted drag, then drops all tracking state so a
    /// later `.ended` frame for the cancelled contact can't emit a stray release.
    public func cancelActiveHolds() {
        for state in contacts.values where state.didBeginHold {
            onGesture?(.holdEnded(zone: state.contact.zone))
        }
        contacts.removeAll()
        pendingClick.removeAll()
    }

    /// Promote a still-live contact to a drag once it has been held at least
    /// `holdThreshold`: fire `holdBegan` exactly once (`didBeginHold` latches it).
    /// Called from each `.moved`/`.stationary` frame, so the button goes down *while
    /// the finger is still on the shell* — that is what makes the hold a drag rather
    /// than a delayed click. Which contacts qualify depends on `dragStyle`:
    ///
    /// - `.tapAndAHalf`: only a **second** contact (a completed tap preceded it).
    /// - `.pressAndHold`: **any single** contact that stayed **still** (on-shell
    ///   travel ≤ `maxTravel`), so a resting/deliberate press drags but a finger
    ///   *slide* (a scroll) does not. No leading tap → a clean single-press drag.
    ///
    /// Either way a contact that saw a **physical click** never promotes (when
    /// `requireNoPhysicalClick`) — the same rule the tap primitive applies, for the same
    /// reason: that click is the OS's to deliver, not ours to duplicate.
    ///
    /// The frame-starved case (no interim frame inside the hold window) is handled
    /// defensively in `finalize`.
    private func promoteToHoldIfNeeded(
        _ state: inout ContactState, now: TimeInterval, singleContact: Bool
    ) {
        guard !state.didBeginHold else { return }
        guard now - state.contact.startTime >= config.holdThreshold else { return }
        // A hardware click during this contact's life disqualifies the **hold**, exactly as
        // it disqualifies a tap (`isTap`): the user is driving the button themselves, so
        // synthesizing a drag on top would duplicate the OS's own click — and, with
        // de-confliction armed, would then swallow their *later* physical clicks. That is
        // what broke physical double-click under `pressAndHold`, where a merely resting
        // finger promotes: click 1 landed before `holdThreshold`, the still contact then
        // promoted, and click 2 was swallowed as a "mid-drag squeeze" (docs/14 §Click/drag
        // de-confliction, finding #2 / scenario #9). Checked here rather than at `.began`
        // because the flag is set irreversibly mid-contact.
        if config.requireNoPhysicalClick, state.contact.sawPhysicalClick { return }
        switch config.dragStyle {
        case .tapAndAHalf:
            // Only the immediate second contact hold-promotes; a later tap in a
            // longer click run (followsCount ≥ 2) does not (double-tap-then-hold
            // drag is a separate roadmap feature).
            guard state.followsCount == 1 else { return }
        case .pressAndHold:
            guard singleContact, state.contact.maxTravel <= config.maxTravel else { return }
        }
        state.didBeginHold = true
        onGesture?(.holdBegan(zone: state.contact.zone))
    }

    private func finalize(_ state: ContactState, endTime: TimeInterval) {
        // A contact that continued a click run but lived to the drag threshold is a
        // hold, not a tap, so it must never fall through to the click branch below. A
        // real drag already fired `holdBegan` on a live `.moved`/`.stationary` frame
        // (so `didBeginHold` is set and `.ended` never calls `finalize`); this only
        // guards the frame-starved case — no interim frame arrived inside the hold
        // window — where we never observed the contact held, so we emit nothing and
        // the run so far stands (safer than synthesizing a press/release that never
        // dragged, or upgrading the click count on a contact that was really held).
        if state.followsCount >= 1,
           endTime - state.contact.startTime >= config.holdThreshold { return }
        // A non-tap contact fizzles. If it was continuing a run, that run's pending
        // was already consumed at `.began`, so the clicks emitted so far simply stand.
        guard isTap(state, endTime: endTime) else { return }
        // Continue the run: 0→single, 1→double, 2→triple. `clickState = count`
        // downstream makes the OS see a genuine N-click (e.g. triple → line select).
        let count = state.followsCount + 1
        onGesture?(.click(zone: state.contact.zone, count: count))
        // Arm the next step unless we've hit the cap (a triple does not arm a
        // quadruple), so a further in-gap tap continues to `count + 1`.
        if count < config.maxClickCount {
            pendingClick[state.contact.zone] = PendingClick(endTime: endTime, count: count)
        }
    }

    /// The tap primitive (docs/03 §What counts as a tap): short enough, still
    /// enough, small enough, and no hardware click during its life. The gates
    /// themselves live in `ContactAccumulator` so the visualizer's live readout and
    /// a logged sample evaluate the identical rules.
    private func isTap(_ state: ContactState, endTime: TimeInterval) -> Bool {
        state.contact.verdict(at: endTime, against: config) == .tap
    }
}
