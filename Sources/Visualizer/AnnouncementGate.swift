import Foundation
import TouchKit

/// Decides *when* the visualizer has something worth saying out loud — never what to
/// say. The wording is chosen at the drawing boundary (`VisualizerView`), the same
/// rule `GestureFlash.Kind` follows, so this stays free of display copy.
///
/// Two signals compete for one voice, and the obvious gate — "the value changed AND
/// ≥0.3 s since the last" — gets them backwards. A finger landing changes the active
/// zone immediately; the tap it turns out to be registers ~180 ms later. Rate-limit
/// both together and the zone speaks first, which means the *gesture* — the thing
/// actually worth hearing — is the one suppressed. So they are separated by intent
/// instead of by rate:
///
/// - **Gestures always speak.** They are discrete and already rare, so they need no
///   limiter. The view posts them and tells this gate afterwards, through
///   `noteGestureSpoken(in:at:)`.
/// - **A zone speaks only once a finger has settled in it** for `dwell`. A tap lifts
///   long before that, so it never narrates its own landing; a finger resting or
///   sliding does cross it, which is exactly the exploring-the-surface case the
///   picture exists to serve.
///
/// Lifting is silent. The user knows they lifted their own finger, and announcing it
/// would double the chatter for every single contact.
struct AnnouncementGate {
    /// How long a finger must sit in one zone before that zone is worth speaking.
    /// Comfortably past the defaults of both gesture thresholds it has to clear —
    /// `maxDuration` and `holdThreshold`, 180 ms each — so an ordinary tap or hold
    /// speaks only its gesture. Raise either slider past this and you hear the zone
    /// first as well: wordier, but not wrong, and the gesture still speaks.
    static let dwell: TimeInterval = 0.35

    /// Floor between anything spoken and a zone spoken after it. Narrower than it
    /// looks, and deliberately kept: two *zone* announcements can never crowd each
    /// other, because a change of zone restarts the dwell, so they are always at least
    /// `dwell` apart on their own. What this catches is a zone landing on the heels of
    /// a **gesture**, which is only reachable with more than one finger down — one
    /// resting in the middle while another taps left, say, where the tap names its zone
    /// and the resting finger's dwell would come due a moment later.
    static let minimumGap: TimeInterval = 0.3

    /// The zone last announced for the contact currently down. Cleared on lift, so a
    /// new contact narrates itself rather than being taken for a repeat.
    private var spokenZone: MouseZone?
    private var dwellingIn: MouseZone?
    private var dwellingSince: TimeInterval?
    private var lastSpokenAt: TimeInterval?

    /// Feed the frame's active zone. Returns the zone to speak, or `nil` — which is
    /// the overwhelmingly common answer, since this is called at frame rate.
    mutating func zoneToSpeak(_ zone: MouseZone?, at now: TimeInterval) -> MouseZone? {
        guard let zone else {
            // Finger up. Forget everything, `spokenZone` included: putting a finger
            // back down is a new contact, and it should name its zone again rather
            // than be silenced as a repeat of the last one.
            dwellingIn = nil
            dwellingSince = nil
            spokenZone = nil
            return nil
        }
        // A new zone restarts the clock rather than inheriting the old one's dwell,
        // so sliding across a band doesn't announce it on arrival.
        if zone != dwellingIn {
            dwellingIn = zone
            dwellingSince = now
            return nil
        }
        guard zone != spokenZone,
              let since = dwellingSince, now - since >= Self.dwell,
              lastSpokenAt.map({ now - $0 >= Self.minimumGap }) ?? true
        else { return nil }

        spokenZone = zone
        lastSpokenAt = now
        return zone
    }

    /// Record that a gesture was announced. It names its own zone, so the zone the
    /// finger is dwelling in counts as spoken too — otherwise a press-and-hold says
    /// "Hold, left" and then plain "left" a fraction of a second later.
    mutating func noteGestureSpoken(in zone: MouseZone, at now: TimeInterval) {
        spokenZone = zone
        lastSpokenAt = now
    }
}
