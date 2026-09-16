import Foundation
import TouchKit
import GestureEngine
import EventOutput

/// The composition root's runtime object (docs/01 §Composition root): owns the touch
/// source, the physical-click source, and the `GesturePipeline`, and manages their
/// lifecycle. Promotes the ad-hoc Phase 6 `verify-gesture` wiring into a real app
/// object with start/stop, a live master enable, safety release, and device
/// presence + re-enumeration.
///
/// Collaborators are injected as protocols so this is unit-tested with a simulated
/// source, a fake physical-click source, and a spy emitter; production wires
/// `MultitouchSource` + `EventInterceptor` + `CGEventEmitter` (in `App`). `@MainActor`
/// — every collaborator callback is marshaled to main before it reaches the
/// recognizer, which is not `Sendable`.
@MainActor
public final class AppCoordinator {
    private let source: any TouchSource
    private let clickSource: any PhysicalClickSource
    private let pipeline: GesturePipeline

    /// The live configuration (docs/01: coordinator owns zones/config/features from
    /// settings). Mutated by `setEnabled` / `apply`.
    public private(set) var settings: AppSettings

    // MARK: Observable status (drives the Phase 7.6 Status panel)

    /// The touch source's lifecycle, as this coordinator sees it (docs/14, 2026-09
    /// incident).
    public enum SourceState: Equatable {
        /// The coordinator is stopped; the source is not running.
        case idle
        /// The last (re)enumeration **completed**. Whether a device actually came
        /// back is `isDeviceConnected` / `sourceError` — a completed enumeration
        /// that found no mouse is still a healthy lifecycle.
        case live
        /// A (re)enumeration's completion is outstanding — stop/start in flight on
        /// the source's own queue.
        case reEnumerating
        /// The in-flight (re)enumeration's completion never arrived within
        /// `reenumerationTimeout`. The source's lifecycle is wedged: the private
        /// `MTDeviceStop`/`MTDeviceStart` have no timeout contract and can block
        /// forever on a device mid sleep/wake re-registration (docs/14). Nothing
        /// sent to the source will answer; a fresh process is the only recovery
        /// (the App's watchdog + "Quit & Reopen" prompt).
        case stuck
    }

    /// The source's lifecycle state. `stuck` is what the UI turns into
    /// "stream stuck — Quit & Reopen"; it is deliberately a *state*, not an
    /// error: no `TouchSourceError` covers "the call never returned."
    public private(set) var sourceState: SourceState = .idle

    /// The source + click-source are started (app active), independent of the master
    /// feature toggle.
    public private(set) var isRunning = false
    /// A Magic Mouse was found at the last (re)enumeration.
    public private(set) var isDeviceConnected = false
    /// Last touch-source failure (`.noDevice` / `.notAuthorized` / `.backendUnavailable`).
    public private(set) var sourceError: TouchSourceError?
    /// The event tap couldn't install — almost always Accessibility not granted, so
    /// physical-click tracking is off and synthesized clicks won't post (degraded).
    public private(set) var interceptorFailed = false

    /// Whether the event tap is currently installed. The tap is scoped to when it has a
    /// job — running, master-enabled, and Accessibility-granted — so a disabled or
    /// unauthorized app holds no system-wide HID tap. Guards install/teardown idempotency
    /// (`EventInterceptor.start()` is not itself idempotent) and, crucially, lets the tap
    /// be pulled the instant Accessibility is revoked: a `.cghidEventTap` left installed
    /// after the process loses trust wedges every physical click (docs/05 §Interceptor
    /// lifetime).
    private var clickInterceptionInstalled = false

    /// At least one touch frame has arrived since the last (re)start — the *observed*
    /// truth that the multitouch stream came alive, complementing the TCC permission
    /// snapshot. A latch: reset on stop / re-enumeration, flips true on the first
    /// frame and stays true (a *live* "frames still flowing" readout is the App's
    /// time-windowed concern; this is the "did it ever start" one behind
    /// `touchesNotArriving`).
    public private(set) var hasReceivedFrameSinceStart = false

    /// Optional live tap of every frame (already marshaled to main), fired in
    /// parallel with the recognizer so the Visualizer window renders the exact
    /// stream the recognizer judges — the picture and the behavior can't drift
    /// (docs/06). The App points this at its `VisualizerModel`; `nil` when no
    /// visualizer is showing. Read-only: it never influences behavior.
    public var onFrame: (([SurfaceTouch]) -> Void)?

    /// Optional read-only tee of every recognized gesture (tap/double-tap/hold),
    /// fired on main before the policy filter — the App points this at its
    /// `VisualizerModel` so the tuning panes flash when a gesture registers (docs/09).
    /// Read-only: it never influences behavior.
    public var onGesture: ((ButtonGesture) -> Void)?

    /// Optional read-only tee of physical mouse button state (already on main), fired
    /// after the recognizer has been told. The App cross-checks it against the contact
    /// stream: a physical click is impossible without a finger on the touch surface, so
    /// one that arrives with no frames around it proves the stream went deaf and should
    /// be re-subscribed (`StreamHealthMonitor`, docs/08). Read-only: it never influences
    /// behavior.
    ///
    /// Fires **inside the event-tap callback**, after the recognizer has been told (which
    /// must stay synchronous — the tap's decision depends on it). A consumer that does
    /// real work here has to hop off first, or it stalls event delivery and can trip
    /// `tapDisabledByTimeout`.
    public var onPhysicalClick: ((Bool) -> Void)?

    /// Whether recognized gestures are currently allowed through to the emitter.
    public var isMasterEnabled: Bool { settings.features.masterEnabled }

    /// Whether a synthetic button is currently held. Consulted before a recovery
    /// re-enumeration, which lifts every hold (docs/05) and so must not run mid-drag.
    public var hasActiveHolds: Bool { pipeline.hasActiveHolds }

    /// The recognizer's in-flight contacts, for the visualizer's travel budget. Read
    /// inside `onFrame`, which fires after the pipeline has ingested this frame.
    public var liveContacts: [LiveContact] { pipeline.liveContacts }

    /// The Magic Mouse secondary-click side currently honored by the emitter (read from
    /// the system by the App and pushed in via `setSecondaryClickSide`). Observable so
    /// the Status panel can show which arrangement is active.
    public private(set) var secondaryClickSide: SecondaryClickSide = .right

    /// Honor a (possibly changed) system secondary-click side. Idempotent — a no-op when
    /// unchanged — so the App can call it from its steady poll without churn. Applies to
    /// *future* emissions; an in-flight hold is unaffected (its zone is already fixed).
    public func setSecondaryClickSide(_ side: SecondaryClickSide) {
        guard side != secondaryClickSide else { return }
        secondaryClickSide = side
        pipeline.secondaryClickSide = side
    }

    /// A Magic Mouse was enumerated but no frame has arrived since (re)start — the
    /// app is effectively deaf. The framework enumerates the mouse **without** Input
    /// Monitoring, so `sourceError` stays `nil` and clicks silently never fire; this
    /// is the distinct degraded state the Status panel shows instead of a silent
    /// no-op (docs/07, docs/08 open question). Transiently true at startup until the
    /// first frame lands, so a UI should treat it as "checking…" briefly before
    /// alarming — the coordinator stays clock-free and reports only the raw truth.
    public var touchesNotArriving: Bool {
        isRunning && isDeviceConnected && !hasReceivedFrameSinceStart
    }

    /// How long a (re)enumeration's completion may be outstanding before the
    /// source is marked `stuck`. Generous on purpose: a Bluetooth Magic Mouse
    /// mid sleep/wake re-registration can take many seconds to enumerate, and
    /// the honest alternative to a timeout is the pre-fix behavior — sit
    /// silently "re-enumerating" forever (docs/14). Injectable so tests can
    /// use fractions of a second.
    public let reenumerationTimeout: TimeInterval

    /// The in-flight (re)enumeration's generation. Completions and timeouts
    /// carry theirs and act only while it is still current, so a superseded
    /// (or very late) completion can't clobber newer state.
    private var reenumerationGeneration = 0
    /// The timeout task for the current generation, cancelled the moment the
    /// completion arrives (or the coordinator stops).
    private var reenumerationTimeoutTask: Task<Void, Never>?

    public init(
        source: any TouchSource,
        clickSource: any PhysicalClickSource,
        emitter: any ButtonEmitting,
        settings: AppSettings = .init(),
        reenumerationTimeout: TimeInterval = 30
    ) {
        self.source = source
        self.clickSource = clickSource
        self.settings = settings
        self.reenumerationTimeout = reenumerationTimeout
        self.pipeline = GesturePipeline(
            layout: settings.zones,
            config: settings.gestures,
            emitter: emitter,
            policy: settings.features)
        wire()
    }

    /// Callbacks must be set **before** `start()` (`MultitouchSource` requires
    /// `onFrame` pre-start). Frames arrive on the source's serial queue → hop to main;
    /// the tap callback already fires on the main run loop → assume isolation.
    private func wire() {
        source.onFrame = { [weak self] touches in
            Task { @MainActor in
                guard let self else { return }
                self.hasReceivedFrameSinceStart = true
                self.pipeline.ingest(touches)
                self.onFrame?(touches)
            }
        }
        clickSource.onPhysicalClickChange = { [weak self] active in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pipeline.setPhysicalClick(active)
                self.onPhysicalClick?(active)
            }
        }
        // The pipeline outlives recognizer rebuilds (`reconfigure` swaps only the
        // recognizer), so forwarding its gesture tee once here survives a settings change.
        pipeline.onGesture = { [weak self] gesture in self?.onGesture?(gesture) }
    }

    // MARK: Lifecycle

    /// Start the touch source and (if the master toggle is on) the event tap. Idempotent.
    /// A missing device or a failed tap is recorded as status rather than thrown — the app
    /// stays up and degrades (docs/07). Launched disabled installs no tap: the touch source
    /// alone drives the visualizer, and the tap is armed later by `setEnabled(true)`.
    ///
    /// The source's start is completion-based (the real backend's framework calls have
    /// no timeout contract — docs/14), so "started" here means *requested*; the outcome
    /// lands in `sourceState` / `sourceError` when the completion arrives, or the
    /// source is marked `stuck` if it never does.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        beginStart()
        installClickInterceptionIfWanted()
    }

    /// Stop both streams, releasing any held button first so nothing can stick
    /// (docs/05 §Press/release). Idempotent.
    ///
    /// The source's stop is issued and *not awaited*: on a wedged source it queues
    /// behind the stuck framework call and never runs — which is fine, because the
    /// only path that matters here is process exit, and exit frees the queue with
    /// the process. Awaiting it would be the pre-fix hang wearing a different hat.
    public func stop() {
        guard isRunning else { return }
        pipeline.cancelActiveHolds()
        reenumerationTimeoutTask?.cancel()
        reenumerationTimeoutTask = nil
        reenumerationGeneration += 1   // invalidate any in-flight completion
        source.stop {}
        clickSource.stop()
        clickInterceptionInstalled = false
        isDeviceConnected = false
        hasReceivedFrameSinceStart = false
        isRunning = false
        sourceState = .idle
    }

    /// Install the event tap iff it currently has a job: running and master-enabled. A tap
    /// that can't arm (Accessibility not granted) records `interceptorFailed` for the App's
    /// permission flow rather than throwing. Idempotent — a no-op when already installed,
    /// stopped, or disabled.
    private func installClickInterceptionIfWanted() {
        guard isRunning, settings.features.masterEnabled, !clickInterceptionInstalled else { return }
        do {
            try clickSource.start()
            clickInterceptionInstalled = true
            interceptorFailed = false
        } catch {
            interceptorFailed = true
        }
    }

    /// Remove the event tap, lifting any in-flight synthetic hold first so a button can't be
    /// stranded when drag promotion's tap disappears (docs/05 §Stuck-button safeguards). The
    /// tap's absence is intentional here, so `interceptorFailed` is cleared. Idempotent.
    private func teardownClickInterception() {
        guard clickInterceptionInstalled else { return }
        pipeline.cancelActiveHolds()
        clickSource.stop()
        clickInterceptionInstalled = false
        interceptorFailed = false
    }

    /// Pull the event tap out of the HID path in response to Accessibility being revoked
    /// mid-run (the App detects the revocation in its permission poll and calls this). An
    /// active `.cghidEventTap` left installed after the process loses trust wedges every
    /// physical click system-wide; removing it restores normal clicking at once. A later
    /// re-grant reinstalls it in place via `retryStream(for: .accessibility)`.
    public func suspendClickInterception() {
        teardownClickInterception()
    }

    /// Re-enumerate the touch source — the reaction to a device attach/detach
    /// (the App wires an IOKit `DeviceMonitor` to this; carried over from the Phase 4
    /// hot-plug deferral). Safe no-op while stopped.
    ///
    /// Releasing active holds here is a **deliberate safety guarantee**, not just
    /// re-enumeration housekeeping: a Magic Mouse that disconnects mid-drag never
    /// sends the `.ended` frame that would lift the synthetic button, so device loss
    /// must lift it instead or it stays stuck (docs/05 §Stuck-button safeguards,
    /// stuck-button Tier 2). A frame-*silence* watchdog was considered and rejected —
    /// the multitouch stream is delta-driven and legitimately goes quiet for seconds
    /// under a motionless finger, so silence can't stand in for a lift (docs/08).
    /// `AppCoordinatorTests.deviceLossReleasesAnInFlightDrag` locks this in.
    public func refreshDevices() {
        guard isRunning else { return }
        // A (re)enumeration already in flight, or a source already wedged:
        // issuing another one would queue behind the outstanding (or stuck)
        // work on the source's serial queue and never answer. The in-flight
        // enumeration covers this request, and a device the in-flight pass
        // missed is picked up by the App's 1.5 s poll self-heal once the pass
        // settles (docs/14). While `stuck` nothing we send can help at all —
        // the state stays for the UI's "Quit & Reopen" prompt and the
        // watchdog.
        guard sourceState == .live else { return }
        pipeline.cancelActiveHolds()   // device may have vanished mid-drag — lift any held button
        hasReceivedFrameSinceStart = false   // the re-enumerated device hasn't delivered a frame yet
        beginRefresh()
    }

    /// Retry a stream that failed to come up at launch, after the user grants its
    /// permission mid-session (docs/07 step 3). Accessibility → re-install the event
    /// tap in place: unlike Input Monitoring, an Accessibility grant usually lets the
    /// tap arm without a relaunch, so a mid-run grant "just works." No-op if the tap is
    /// already installed or while stopped; the App falls back to a relaunch prompt if
    /// this leaves `interceptorFailed` still set. (The touch source needs no grant —
    /// a missing device is recovered by `refreshDevices`, not here.)
    public func retryStream(for permission: Permission) {
        switch permission {
        case .accessibility:
            installClickInterceptionIfWanted()
        }
    }

    // MARK: Source lifecycle (completion-based, docs/14)

    /// Request a fresh enumeration from a stopped source (launch). Only
    /// reachable from `start()` while `.idle`.
    private func beginStart() {
        let generation = nextReenumerationGeneration()
        sourceState = .reEnumerating
        source.start { [weak self] result in
            self?.routeCompletion(result, forGeneration: generation)
        }
        scheduleReenumerationTimeout(generation)
    }

    /// Request a stop-then-start re-enumeration of a running source. Only
    /// reachable from `refreshDevices()` while `.live` — the source's own
    /// serial queue runs the pair in order, so the stop always precedes the
    /// start and a caller can never wedge between them.
    private func beginRefresh() {
        let generation = nextReenumerationGeneration()
        sourceState = .reEnumerating
        source.refresh { [weak self] result in
            self?.routeCompletion(result, forGeneration: generation)
        }
        scheduleReenumerationTimeout(generation)
    }

    /// The protocol hands us the completion "on an unspecified thread." Sources
    /// that complete synchronously (the simulated source, the test fakes) do
    /// so on the caller's thread — main here — which is served inline; the real
    /// source completes from its lifecycle queue, which is hopped to main. Both
    /// land in `sourceCompleted` without ever touching coordinator state off
    /// main. `nonisolated`: the completion fires where the source chose
    /// (possibly a bare queue), so this hop itself can't be main-isolated.
    nonisolated private func routeCompletion(_ result: Result<Void, TouchSourceError>, forGeneration generation: Int) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.sourceCompleted(generation: generation, result: result)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.sourceCompleted(generation: generation, result: result)
            }
        }
    }

    private func sourceCompleted(generation: Int, result: Result<Void, TouchSourceError>) {
        // A superseded generation (we stopped, or a newer pass is in flight)
        // is stale — ignore it. A *late* completion for the generation that
        // already timed out means the source's queue unblocked — the source is
        // alive again, so honor the outcome and clear the stuck flag (docs/14).
        guard generation == reenumerationGeneration,
              sourceState == .reEnumerating || sourceState == .stuck else { return }
        reenumerationTimeoutTask?.cancel()
        reenumerationTimeoutTask = nil
        switch result {
        case .success:
            isDeviceConnected = true
            sourceError = nil
        case .failure(let error):
            isDeviceConnected = false
            sourceError = error
        }
        sourceState = .live
    }

    /// Main-actor liveness guard for the in-flight (re)enumeration. Sleeping on
    /// the main *actor* suspends without blocking the run loop — the loop keeps
    /// turning while the source's own queue is wedged (that is the whole point
    /// of the fix, docs/14) — so the timeout fires even in the incident's
    /// scenario, and the status pane says "stream stuck" instead of sitting
    /// silently "re-enumerating" for days.
    private func scheduleReenumerationTimeout(_ generation: Int) {
        reenumerationTimeoutTask?.cancel()
        reenumerationTimeoutTask = Task { [weak self, timeout = reenumerationTimeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.markSourceStuck(generation: generation)
        }
    }

    private func markSourceStuck(generation: Int) {
        guard generation == reenumerationGeneration, sourceState == .reEnumerating else { return }
        sourceState = .stuck
    }

    private func nextReenumerationGeneration() -> Int {
        reenumerationGeneration += 1
        return reenumerationGeneration
    }

    // MARK: Configuration (live)

    /// Global master enable (also the menu-bar toggle). The **touch source** keeps running
    /// either way, so the visualizer still shows the finger picture while off (docs/09). The
    /// **event tap** does not: it exists only to feed physical-click state and drag promotion
    /// into synthesis, which is gated off here, so switching off tears it down (releasing any
    /// held button first) and switching on re-arms it. Holding a system-wide HID tap with no
    /// job is exactly what let a later Accessibility revocation wedge clicking (docs/05).
    public func setEnabled(_ enabled: Bool) {
        settings.features.masterEnabled = enabled
        pipeline.policy.masterEnabled = enabled
        if enabled {
            installClickInterceptionIfWanted()
        } else {
            teardownClickInterception()   // lifts any hold as part of teardown
        }
    }

    /// Apply an edited settings value: feature toggles take effect immediately;
    /// changed zones/tunables rebuild the recognizer (which safely releases first).
    public func apply(_ newSettings: AppSettings) {
        let recognizerChanged =
            newSettings.zones != settings.zones || newSettings.gestures != settings.gestures
        settings = newSettings
        pipeline.policy = newSettings.features
        if recognizerChanged {
            pipeline.reconfigure(layout: newSettings.zones, config: newSettings.gestures)
        }
    }
}
