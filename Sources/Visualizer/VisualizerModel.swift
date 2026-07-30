import Foundation
import TouchKit

/// The visualizer's data feed: a read-only sink the `AppCoordinator` fans each
/// frame into (marshaled to main), in parallel with the recognizer, so the
/// picture and the behavior read the same stream and can never disagree
/// (docs/06-visualizer.md). It never drives behavior — strictly a view over the
/// stream.
///
/// *As built vs docs/06:* modeled with Apple's current `@Observable` rather than
/// the doc's illustrative `ObservableObject`/`@Published` (the project targets
/// macOS 14 + Swift 6, where `@Observable` is the recommended pattern). The public
/// surface — read-only `touches`, editable `layout`, `update(_:)` — is unchanged;
/// `activeZone` is added to expose the hysteresis readout the view highlights.
@MainActor
@Observable
public final class VisualizerModel {
    /// Live contacts for the current frame.
    public private(set) var touches: [SurfaceTouch] = []

    /// The hysteresis zone of the primary contact, or `nil` when no finger is
    /// present. Drives the highlighted band (docs/06).
    public private(set) var activeZone: MouseZone?

    /// One contact's tap-travel budget, in the visualizer's own TouchKit-only vocabulary
    /// so the package stays decoupled from `GestureEngine` (docs/06). `AppShell` maps
    /// `LiveContact` to this, exactly as it maps `ButtonGesture` to `RecognizedGesture`.
    public struct ContactBudget: Sendable, Equatable, Identifiable {
        /// Mirrors `GestureEngine.TapVerdict`. The cost of the package boundary.
        public enum Verdict: Sendable, Equatable {
            case wouldTap
            case rejectedPhysicalClick, rejectedDuration, rejectedTravel, rejectedSize
        }

        public let id: Int32
        /// Normalized, origin bottom-left — the point travel is measured from.
        public let origin: CGPoint
        /// Greatest distance from `origin` reached so far, normalized.
        public let travel: CGFloat
        /// The threshold `travel` is judged against, normalized.
        public let budget: CGFloat
        public let verdict: Verdict

        public init(id: Int32, origin: CGPoint, travel: CGFloat,
                    budget: CGFloat, verdict: Verdict) {
            self.id = id
            self.origin = origin
            self.travel = travel
            self.budget = budget
            self.verdict = verdict
        }
    }

    /// Travel budgets for the contacts the recognizer is tracking. Empty when nothing
    /// is being tracked, or when the source has no recognizer behind it.
    public private(set) var budgets: [ContactBudget] = []

    /// A recognized gesture, in the visualizer's own TouchKit-only vocabulary so the
    /// package stays decoupled from `GestureEngine` (docs/06: the visualizer never
    /// depends on the recognizer). The composition layer maps `ButtonGesture` to this.
    public enum RecognizedGesture: Sendable, Equatable {
        case click(MouseZone, count: Int)
        case holdBegan(MouseZone)
        case holdEnded(MouseZone)
    }

    /// A transient badge shown when a gesture registers, so the tuning panes give
    /// visible feedback that a tap / double-tap fired (docs/09 §Advanced). `id`
    /// increments per event so the view can re-trigger its animation on repeats.
    public struct GestureFlash: Identifiable, Equatable, Sendable {
        /// *What* registered, kept semantic rather than pre-worded: the badge's wording
        /// is chosen — and localized — at the drawing boundary (`VisualizerView`), the
        /// same rule the `y`-flip follows. Keeps the model free of display copy.
        public enum Kind: Equatable, Sendable {
            case tap(count: Int)
            case hold
        }

        public let id: Int
        public let zone: MouseZone
        public let kind: Kind
    }

    /// The most recent recognized gesture, or `nil` once it has aged out. Read-only;
    /// set through `register(_:)`.
    public private(set) var lastFlash: GestureFlash?

    @ObservationIgnored private var flashCounter = 0
    @ObservationIgnored private var flashClearTask: Task<Void, Never>?

    /// Zone boundaries, shared with the recognizer. Assigning re-points the
    /// hysteresis mapper, so a live calibration edit is reflected immediately.
    public var layout: ZoneLayout {
        didSet { mapper.layout = layout }
    }

    @ObservationIgnored private var mapper: ZoneMapper

    public init(layout: ZoneLayout = ZoneLayout()) {
        self.layout = layout
        self.mapper = ZoneMapper(layout: layout)
    }

    /// Push a frame. Call on the main actor. Picks the first live (non-`.ended`)
    /// contact as the "primary" for the active-zone readout; an all-`.ended` or
    /// empty frame means no finger, so the mapper resets and `activeZone` clears.
    ///
    /// `budgets` defaults empty so a source with no recognizer behind it — the
    /// `mb-dev visualize` harness, SwiftUI previews — still drives the picture, just
    /// without the travel rings.
    public func update(_ frame: [SurfaceTouch], budgets: [ContactBudget] = []) {
        touches = frame
        self.budgets = budgets
        if let primary = frame.first(where: { $0.phase != .ended }) {
            activeZone = mapper.update(x: primary.position.x)
        } else {
            mapper.reset()
            activeZone = nil
        }
    }

    /// Flash a recognized gesture (call on the main actor). Shows a badge that
    /// auto-clears shortly after, so a stream of taps reads as a series of flashes.
    /// A `holdEnded` clears any lingering badge rather than showing one.
    public func register(_ gesture: RecognizedGesture) {
        flashClearTask?.cancel()
        flashCounter += 1

        let zone: MouseZone
        let kind: GestureFlash.Kind
        switch gesture {
        case let .click(z, count):
            zone = z; kind = .tap(count: count)
        case let .holdBegan(z):
            zone = z; kind = .hold
        case .holdEnded:
            lastFlash = nil
            return
        }
        lastFlash = GestureFlash(id: flashCounter, zone: zone, kind: kind)

        let shownID = flashCounter
        flashClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.lastFlash?.id == shownID else { return }
            self.lastFlash = nil
        }
    }
}
