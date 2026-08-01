import GestureEngine
import TouchKit
import Visualizer

/// Translates the recognizer's vocabulary into the visualizer's own, in **one** place.
///
/// `Visualizer` depends on `TouchKit` alone and never on `GestureEngine` (docs/06), so
/// somebody has to carry `LiveContact` and `ButtonGesture` across that boundary. Until
/// now only `AppShell` did, privately — which is why `mb-dev visualize` drew no travel
/// rings and flashed no gesture badges: it had no recognizer behind it and no way to
/// speak its language. Both consumers share this rather than keeping parallel copies,
/// for the reason `ContactAccumulator` is shared: the picture and the behaviour must not
/// be able to disagree.
///
/// Pure and un-isolated on purpose — no `@MainActor` — so it is testable without a main
/// actor and callable from wherever a frame lands. Every mapping is an exhaustive switch,
/// so a new `TapVerdict` or `ButtonGesture` case fails the build here instead of quietly
/// diverging between two copies.
public enum VisualizerFeed {
    /// The recognizer's in-flight contacts as travel budgets the picture can draw.
    public static func budgets(_ contacts: [LiveContact]) -> [VisualizerModel.ContactBudget] {
        contacts.map {
            VisualizerModel.ContactBudget(
                id: $0.id,
                origin: $0.origin,
                maxTravelMM: $0.maxTravelMM,
                displacementMM: $0.displacementMM,
                budgetMM: $0.travelBudgetMM,
                verdict: verdict($0.verdictSoFar))
        }
    }

    /// A recognized gesture in the visualizer's own terms, for the flash badge and the
    /// spoken announcement.
    public static func recognized(_ gesture: ButtonGesture) -> VisualizerModel.RecognizedGesture {
        switch gesture {
        case let .click(zone, count): return .click(zone, count: count)
        case let .holdBegan(zone):    return .holdBegan(zone)
        case let .holdEnded(zone):    return .holdEnded(zone)
        }
    }

    /// `TapVerdict` → the visualizer's mirror of it. The mirror is the price of the
    /// package boundary above, paid deliberately.
    public static func verdict(_ verdict: TapVerdict) -> VisualizerModel.ContactBudget.Verdict {
        switch verdict {
        case .tap:                   return .wouldTap
        case .rejectedPhysicalClick: return .rejectedPhysicalClick
        case .rejectedDuration:      return .rejectedDuration
        case .rejectedTravel:        return .rejectedTravel
        case .rejectedSize:          return .rejectedSize
        }
    }
}
