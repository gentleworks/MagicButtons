import SwiftUI
import TouchKit

/// A stylized top-view of the Magic Mouse surface: rounded shell outline, three
/// tinted zone bands driven by the live `ZoneLayout`, a dot per live contact, and
/// the hysteresis active zone highlighted (docs/06-visualizer.md). Read-only over
/// `VisualizerModel`; it never touches the recognizer or emitter.
///
/// `SurfaceTouch.position` is normalized `0...1`, origin **bottom-left**; SwiftUI
/// is top-left, so `y` is flipped once here, at the drawing boundary.
/// The Magic Mouse touch surface's physical size. `MTDeviceGetSensorSurfaceDimensions`
/// reports ¹⁄₁₀₀ mm, so the "5152×9056" in docs/04 is **51.52 × 90.56 mm** — not an
/// abstract sensor grid. Contact axes arrive in millimetres, and the surface is
/// aspect-locked to the shell, so `width / widthMM` and `height / heightMM` are the
/// same number: one points-per-mm converts a contact in every direction.
private enum MouseSurface {
    static let widthMM: CGFloat = 51.52
    static let heightMM: CGFloat = 90.56
    static var aspect: CGFloat { widthMM / heightMM }
}

public struct VisualizerView: View {
    private let model: VisualizerModel

    /// Portrait, at the shell's true aspect, so contact positions read true.
    private let mouseAspect: CGFloat = MouseSurface.aspect

    /// The gesture badge's scale-in is decorative — the badge appearing at all is the
    /// signal — so it cross-fades instead for anyone who's asked for less motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: VisualizerModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 12) {
            surface
            caption
        }
        .padding()
        // A low floor so the view embeds cleanly at small sizes (the Advanced-pane
        // mini-map); the standalone window sets its own larger size and fills it.
        .frame(minWidth: 120, minHeight: 140)
    }

    private var surface: some View {
        GeometryReader { geo in
            let size = geo.size
            let outline = RoundedRectangle(cornerRadius: size.width * 0.46, style: .continuous)
            ZStack {
                // Shell fill, then bands + boundaries clipped to the shell.
                outline.fill(Color.primary.opacity(0.04))
                zoneBands(in: size).clipShape(outline)
                boundaryLines(in: size).clipShape(outline)
                outline.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5)
                // Rings *over* the contact, not under. The budget is 6.2 x 10.9 mm and a
                // fingertip patch is ~11 x 8 mm — they are nearly the same size, so the
                // two always overlap and the annotation has to sit on top or it is buried
                // in exactly the cases worth reading.
                touchDots(in: size)
                budgetRings(in: size).clipShape(outline)
            }
            .overlay(alignment: .top) { flashBadge }
        }
        .aspectRatio(mouseAspect, contentMode: .fit)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.lastFlash?.id)
    }

    /// A transient badge for the most recently recognized gesture (tap / double-tap),
    /// so the tuning panes show that a gesture registered. Keyed on the flash `id` so
    /// repeats re-trigger the transition even for the same title.
    @ViewBuilder
    private var flashBadge: some View {
        if let flash = model.lastFlash {
            VStack(spacing: 0) {
                badgeLabel(flash.kind)
                // Which zone fired, in words. The capsule's tint was previously the only
                // thing separating left/middle/right, and green-vs-orange is the commonest
                // colour-blind confusion pair — precisely the middle/right distinction this
                // app exists to draw. Reuses the caption's zone words, so no new strings.
                Text(title(flash.zone)).font(.caption2)
            }
                .font(.caption.bold())
                // Dark on the vivid tint, not white: white measured 2.0:1 on green and
                // 2.2:1 on orange, under the 3:1 floor for bold text. Deepening the fills
                // instead fixed the ratio but turned orange brown and green muddy, so the
                // palette stays as-is and the text carries the change (8.7 / 7.8 / 5.4:1).
                // A fixed near-black, deliberately not `.primary` — that would flip to
                // white in dark mode and put the bug straight back.
                .foregroundStyle(Color(white: 0.10))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(color(for: flash.zone)))
                .padding(.top, 8)
                .id(flash.id)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
        }
    }

    /// One and two taps get their own names because that's how people say them; beyond
    /// that the count carries the meaning, so a single counted string covers the tail.
    private func badgeLabel(_ kind: VisualizerModel.GestureFlash.Kind) -> Text {
        switch kind {
        case .hold:
            return Text("Hold", bundle: #bundle, comment: "Badge shown when a press-and-hold registers.")
        case .tap(1):
            return Text("Tap", bundle: #bundle, comment: "Badge shown when a single tap registers.")
        case .tap(2):
            return Text("Double-tap", bundle: #bundle, comment: "Badge shown when a double tap registers.")
        case let .tap(count):
            return Text("\(count)× tap", bundle: #bundle,
                        comment: "Badge for three or more rapid taps, e.g. '3× tap'.")
        }
    }

    // MARK: Zones

    private func zoneBands(in size: CGSize) -> some View {
        let l = model.layout.leftEdge
        let r = model.layout.rightEdge
        return HStack(spacing: 0) {
            band(.left, width: l * size.width)
            band(.middle, width: (r - l) * size.width)
            band(.right, width: (1 - r) * size.width)
        }
        .frame(height: size.height)
    }

    private func band(_ zone: MouseZone, width: CGFloat) -> some View {
        Rectangle()
            .fill(color(for: zone).opacity(model.activeZone == zone ? 0.55 : 0.16))
            .frame(width: max(0, width))
    }

    private func boundaryLines(in size: CGSize) -> some View {
        Path { p in
            for edge in [model.layout.leftEdge, model.layout.rightEdge] {
                let x = edge * size.width
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: size.height))
            }
        }
        .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }

    // MARK: Travel budget

    /// The tap-travel budget around each contact's origin: how far this finger may drift
    /// before it stops being a tap. The gate is Euclidean in **normalized** space, and
    /// the surface is aspect-true, so it draws as a portrait ellipse ~1.76:1 — that shape
    /// *is* the gate's real anisotropy, not a drawing artifact (docs/10 §Visualizer).
    private func budgetRings(in size: CGSize) -> some View {
        ForEach(model.budgets) { b in
            // Latched on the **high-water**, not on live displacement: coming back inside
            // does not restore a spent budget, so once this is true it stays true for the
            // contact's life. Tested on the measurement rather than on
            // `verdict == .rejectedTravel`, because the verdict reports the *first* gate to
            // fail in order — a contact that outran both the tap window and the budget
            // names duration, and would otherwise never show as tripped here.
            let exceeded = b.maxTravel > b.budget
            ZStack {
                // Where the finger is **now**, relative to where it started: a ring through
                // the contact's own centre that grows and shrinks as you move. This is the
                // reading you can calibrate against — a high-water ring only ratchets, so
                // it can never show what a threshold *feels* like. The high-water is not
                // drawn: its whole observable consequence is whether the budget was ever
                // spent, and the latch below says that. Both cross the boundary at the same
                // instant, since the high-water is set by this very value.
                if !exceeded {
                    Ellipse()
                        // `.primary`, not the accent: the contact underneath is accent-filled,
                        // so an accent ring on top of it disappears into its own colour.
                        .stroke(Color.primary.opacity(0.85), lineWidth: 1)
                        .frame(width: b.displacement * size.width * 2,
                               height: b.displacement * size.height * 2)
                }
                // The budget itself. Solid once travel has exceeded it, dashed while
                // there is headroom — so the state is not carried by colour alone.
                Ellipse()
                    .stroke(exceeded ? Color.red : Color.primary.opacity(0.55),
                            style: exceeded ? StrokeStyle(lineWidth: 2)
                                            : StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: b.budget * size.width * 2,
                           height: b.budget * size.height * 2)
                // The origin, so the ring's anchor stays visible once the finger drifts.
                Circle().fill(Color.primary.opacity(0.5)).frame(width: 4, height: 4)
            }
            .position(point(for: b.origin, in: size))
        }
    }

    // MARK: Contacts

    private func touchDots(in size: CGSize) -> some View {
        ForEach(model.touches, id: \.id) { t in
            // The contact patch at its true physical size and orientation. The old dot
            // was clamped absolute points, so it did not scale with the surface — 58% of
            // true size in the Visualizer window and 113% of it in the Advanced mini-map —
            // and being a circle it drew the *major* axis in both directions.
            let ppmm = size.width / MouseSurface.widthMM
            // The ring carries more weight than it did: a `.began` dot is green sitting on
            // the green middle band, and the outline is the only thing separating the two.
            // 1.5pt rather than 2 because `.primary` inverts — 2pt is right in dark mode but
            // heavy-handed in light. A hollow dot for `.ended` was tried and reverted: it
            // reads as *less* present, and `.ended` spans only raw states 5–7 (~3 frames), so
            // no amount of restyling makes it legible — that needs a timed hold, not a style.
            Ellipse()
                .fill(phaseColor(t.phase))
                .frame(width: t.size * ppmm, height: minorAxis(of: t) * ppmm)
                .overlay(Ellipse().strokeBorder(Color.primary.opacity(0.75), lineWidth: 1.5))
                // Sensor space is y-up and SwiftUI is y-down, so the orientation negates —
                // the same single flip `point(for:in:)` applies to the position.
                .rotationEffect(.radians(-Double(t.angle)))
                .position(point(for: t, in: size))
        }
    }

    /// Flip `y` once, here at the drawing boundary (docs/06).
    private func point(for t: SurfaceTouch, in size: CGSize) -> CGPoint {
        point(for: t.position, in: size)
    }

    /// The same single flip for any normalized point — a contact's origin as much as
    /// its current position, so both go through one place.
    private func point(for normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width,
                y: (1 - normalized.y) * size.height)
    }

    /// A frame that predates the minor axis — an old recording, or a synthetic source —
    /// reports `0`; fall back to a circle rather than drawing a degenerate sliver.
    private func minorAxis(of t: SurfaceTouch) -> CGFloat {
        t.minorAxis > 0 ? t.minorAxis : t.size
    }

    // MARK: Caption

    private var caption: some View {
        HStack(spacing: 12) {
            Text("Active: \(title(model.activeZone))", bundle: #bundle,
                 comment: "Caption naming the zone the finger is currently in.")
                .foregroundStyle(model.activeZone.map(color) ?? .secondary)
            Spacer()
            // Counted, not hand-suffixed: the plural forms live in the String Catalog so
            // languages that don't pluralize like English get their own variations.
            Text("\(model.touches.count) contacts", bundle: #bundle,
                 comment: "Number of fingers currently on the mouse surface.")
                .foregroundStyle(.secondary)
        }
        .font(.callout.monospacedDigit())
    }

    // MARK: Palette

    private func color(for zone: MouseZone) -> Color {
        switch zone {
        case .left: return .blue
        case .middle: return .green
        case .right: return .orange
        }
    }

    private func phaseColor(_ phase: TouchPhase) -> Color {
        switch phase {
        case .began: return .green
        case .moved, .stationary: return .accentColor
        case .ended: return .secondary
        }
    }

    /// Lower-case on purpose — these read as the tail of "Active: …", not as headings.
    private func title(_ zone: MouseZone?) -> String {
        switch zone {
        case .left:
            return String(localized: "left", bundle: #bundle, comment: "Left zone of the mouse surface.")
        case .middle:
            return String(localized: "middle", bundle: #bundle, comment: "Middle zone of the mouse surface.")
        case .right:
            return String(localized: "right", bundle: #bundle, comment: "Right zone of the mouse surface.")
        case nil:
            return "—"   // em dash: no finger down; not translated
        }
    }
}

#Preview("Visualizer — scripted") {
    let model = VisualizerModel()
    model.update([
        SurfaceTouch(deviceID: MouseDeviceID(raw: 1), id: 1,
                     position: CGPoint(x: 0.5, y: 0.7),
                     phase: .moved, timestamp: 0,
                     size: 9.6, minorAxis: 7.6, angle: 1.571),
    ])
    return VisualizerView(model: model)
        .frame(width: 240, height: 460)
}
