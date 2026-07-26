import TouchKit
import GestureEngine
import EventOutput

/// The recognizer → policy → emitter core (docs/01 §Composition root). Promoted from
/// the Phase 6 `verify-gesture` harness into a reusable, testable object and given
/// the `FeaturePolicy` filter: the recognizer stays feature-agnostic and this decides
/// what actually reaches the emitter.
///
/// `@MainActor`-confined (so it is implicitly `Sendable`): frames and the
/// physical-click signal are marshaled onto main before they arrive, so the
/// recognizer — which is not itself `Sendable` — is never touched concurrently.
@MainActor
public final class GesturePipeline {
    private var recognizer: MouseGestureRecognizer
    private let emitter: any ButtonEmitting
    /// Which features are on. Mutable so the master toggle / settings apply live
    /// without tearing down the pipeline.
    public var policy: FeaturePolicy
    /// Which side the system assigns the secondary click. When `.left`, the left/right
    /// tap zones are swapped at emission so a left-handed mouse config is honored
    /// (docs/05 §Zone → button). Live-settable from the coordinator; the recognizer and
    /// the diagnostic tee stay spatial — only the *emitted* button follows this.
    public var secondaryClickSide: SecondaryClickSide = .right
    /// Read-only tee of **every** recognized gesture — fired *before* the policy
    /// filter, so a diagnostic view (the visualizer) can show taps/double-taps as
    /// they register even when a feature is toggled off. Never influences routing.
    public var onGesture: ((ButtonGesture) -> Void)?
    private var physicalClickActive = false
    /// Zones with a synthetic button currently held (Phase 8 drag), tracked so a
    /// safety release can never miss one.
    private var heldZones: Set<MouseZone> = []

    public init(
        layout: ZoneLayout,
        config: GestureConfig,
        emitter: any ButtonEmitting,
        policy: FeaturePolicy
    ) {
        self.recognizer = MouseGestureRecognizer(layout: layout, config: config)
        self.emitter = emitter
        self.policy = policy
        wireRecognizer()
    }

    private func wireRecognizer() {
        // `onGesture` is a nonisolated closure but is only ever invoked from `ingest`,
        // which runs on main — so bridge back with `assumeIsolated`.
        recognizer.onGesture = { [weak self] gesture in
            MainActor.assumeIsolated { self?.route(gesture) }
        }
    }

    public func setPhysicalClick(_ active: Bool) { physicalClickActive = active }

    public func ingest(_ touches: [SurfaceTouch]) {
        recognizer.ingest(touches, physicalClickActive: physicalClickActive)
    }

    /// Apply new tunables/zone layout (a settings change) **in place**, preserving any
    /// in-flight hold. Rebuilding the recognizer here used to require releasing the hold
    /// first (a rebuild drops the tracked contact, which would otherwise strand the
    /// pressed button); updating in place keeps the contact so the eventual lift still
    /// releases it. This is what lets a MagicButtons drag operate the app's own settings
    /// sliders — a live edit no longer cancels the very drag driving it — while keeping
    /// the edit fully live (the zone-line preview updates every increment).
    public func reconfigure(layout: ZoneLayout, config: GestureConfig) {
        recognizer.update(layout: layout, config: config)
    }

    private func route(_ gesture: ButtonGesture) {
        onGesture?(gesture)   // diagnostic tee (pre-policy, spatial zone); never gates routing
        switch gesture {
        case let .click(zone, count):
            guard policy.allows(gesture) else { return }
            emitter.click(effectiveZone(zone), count: count)
        case let .holdBegan(zone):
            guard policy.allows(gesture) else { return }
            let target = effectiveZone(zone)
            heldZones.insert(target)
            emitter.press(target)
        case let .holdEnded(zone):
            // Never drop a button-up for a button we pressed, even if the feature was
            // toggled off mid-hold — release exactly what is held (docs/05 §Press/release).
            let target = effectiveZone(zone)
            if heldZones.remove(target) != nil { emitter.release(target) }
        }
    }

    /// The zone whose button is actually emitted for a spatial `zone`, honoring the
    /// system's secondary-click side: left/right swap under `.left`, `.middle` never.
    /// Applied at emission (not in the recognizer) so `heldZones`, the emitter, and the
    /// drag-promotion interceptor all agree on one zone, while the visualizer keeps
    /// showing where the finger truly is.
    private func effectiveZone(_ zone: MouseZone) -> MouseZone {
        guard secondaryClickSide == .left else { return zone }
        switch zone {
        case .left:   return .right
        case .right:  return .left
        case .middle: return .middle
        }
    }

    /// Whether any synthetic button is currently held. Read before a *recovery*
    /// re-enumeration, which releases holds as a safety measure and so must not run
    /// mid-drag (`StreamHealthMonitor`).
    public var hasActiveHolds: Bool { !heldZones.isEmpty }

    /// Release every synthetic hold now — the coordinator's safety hook for feature
    /// disable, quit, or device loss (docs/05). Idempotent; a no-op until Phase 8
    /// produces holds, but wired now so the safety guarantee exists from the start.
    public func cancelActiveHolds() {
        recognizer.cancelActiveHolds()
        for zone in heldZones { emitter.release(zone) }
        heldZones.removeAll()
    }
}
