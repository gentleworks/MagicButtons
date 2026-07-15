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
        public let id: Int
        public let zone: MouseZone
        public let title: String
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
    public func update(_ frame: [SurfaceTouch]) {
        touches = frame
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
        let title: String
        switch gesture {
        case let .click(z, count):
            zone = z
            switch count {
            case 1:  title = "Tap"
            case 2:  title = "Double-tap"
            default: title = "\(count)× tap"
            }
        case let .holdBegan(z):
            zone = z; title = "Hold"
        case .holdEnded:
            lastFlash = nil
            return
        }
        lastFlash = GestureFlash(id: flashCounter, zone: zone, title: title)

        let shownID = flashCounter
        flashClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.lastFlash?.id == shownID else { return }
            self.lastFlash = nil
        }
    }
}
