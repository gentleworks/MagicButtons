import Foundation

/// Decides when an *enumerated but deaf* contact stream should be re-subscribed, and
/// whether we have positive proof it's deaf.
///
/// The failure this exists for: `MultitouchSource.start()` succeeds against a device
/// handle that later stops delivering. A Bluetooth Magic Mouse drops and re-registers
/// around sleep, and the re-registration doesn't reliably produce the IOKit add/remove
/// pair `DeviceMonitor` watches. `AppCoordinator.isDeviceConnected` latches true on a
/// *successful enumeration* — not on frames arriving — so the App's `!isDeviceConnected`
/// self-heal never fires again and the app stays silently deaf until a relaunch
/// (docs/08). Toggling the menu-bar switch can't help either: `setEnabled` scopes the
/// event tap, never the touch source.
///
/// Frame silence alone cannot be the trigger. The stream is delta-driven and
/// legitimately goes quiet — for seconds under a motionless finger, and indefinitely
/// whenever nobody is touching the mouse — so a plain silence watchdog would
/// re-enumerate on a loop all night, and because re-enumeration resets
/// `AppCoordinator.hasReceivedFrameSinceStart` it would leave the Status pane
/// permanently alarming "connected but no touches are arriving." That's the watchdog
/// docs/08 rejected, and rejecting it was right.
///
/// The signal used instead is a **cross-check**, not a heuristic: a physical click on a
/// Magic Mouse is impossible without a finger on its touch surface. A physical click
/// with no contact frame anywhere near it is therefore proof the stream is dead — and
/// it can only be observed while the user is actually using the mouse, never while
/// idle. Sleep/wake, the other common trigger, is handled precisely at its own moment
/// by the App's wake hook rather than inferred here.
///
/// Clock-free by the same rule as `AppCoordinator`: callers pass
/// `ProcessInfo.processInfo.systemUptime`, which is monotonic and so can't be skewed by
/// a clock change or by the very sleep this most often recovers from.
public struct StreamHealthMonitor: Sendable {
    /// How stale the last frame must be, measured against the click, before a physical
    /// click counts as proof of deafness. Contacts for the clicking finger land within
    /// milliseconds of the click, so this is generous by two orders of magnitude — it
    /// exists to absorb scheduling jitter, not to make a judgement call.
    public var silenceWindow: TimeInterval
    /// Floor between two recovery re-enumerations, so a burst of clicks against a
    /// stream that stays dead re-subscribes at a steady cadence instead of thrashing
    /// once per click.
    public var minimumRetryInterval: TimeInterval
    /// How recently a frame must have arrived for the stream to read as live in the
    /// Status pane's "frames flowing" line.
    public var liveWindow: TimeInterval

    private var lastFrameAt: TimeInterval?
    private var lastRecoveryAt: TimeInterval?

    /// A physical click has proved the stream deaf and no frame has arrived since.
    /// Distinct from `AppCoordinator.touchesNotArriving`, which is only ever "we
    /// haven't happened to see a frame yet" and so is indistinguishable from an idle
    /// mouse — this is the evidence that makes an alarm honest.
    public private(set) var isProvenDeaf = false

    public init(
        silenceWindow: TimeInterval = 2.0,
        minimumRetryInterval: TimeInterval = 5.0,
        liveWindow: TimeInterval = 2.0
    ) {
        self.silenceWindow = silenceWindow
        self.minimumRetryInterval = minimumRetryInterval
        self.liveWindow = liveWindow
    }

    /// Record an arriving contact frame. Frames are the only thing that clears the
    /// deaf proof — recovery on its own doesn't, so a re-subscription that didn't
    /// actually help keeps the Status pane honest.
    public mutating func noteFrame(at time: TimeInterval) {
        lastFrameAt = time
        isProvenDeaf = false
    }

    /// Whether frames are currently flowing, for the Status pane's live readout.
    public func isReceivingFrames(at time: TimeInterval) -> Bool {
        guard let lastFrameAt else { return false }
        return time - lastFrameAt < liveWindow
    }

    /// A physical mouse button went **down**. Returns whether the touch source should be
    /// re-enumerated, and records the deaf proof as a side effect — the recovery clock is
    /// stamped here too, so a caller can't forget to and defeat the rate limit.
    ///
    /// `hasActiveHolds` vetoes recovery: re-enumeration lifts every synthetic hold as a
    /// stuck-button safeguard (docs/05), so running it while a drag is in flight would
    /// drop that drag. A motionless finger mid-hold produces no frames, which is exactly
    /// the state that would otherwise look like proof of deafness.
    public mutating func shouldRecover(
        physicalClickAt time: TimeInterval,
        hasActiveHolds: Bool
    ) -> Bool {
        // A frame arrived alongside the click, so the stream is alive. Never let a click
        // during a legitimate hold be read as proof.
        guard !hasActiveHolds else { return false }
        if let lastFrameAt, time - lastFrameAt < silenceWindow { return false }

        isProvenDeaf = true

        if let lastRecoveryAt, time - lastRecoveryAt < minimumRetryInterval { return false }
        lastRecoveryAt = time
        return true
    }

    /// Forget the frame history across a deliberate re-subscription (wake, hot-plug), so
    /// the pre-wake frame time can't make a stale stream look live. Deliberately leaves
    /// `isProvenDeaf` alone: whether we're deaf is settled by evidence, not by having
    /// just tried a fix.
    public mutating func noteResubscribe() {
        lastFrameAt = nil
    }
}
