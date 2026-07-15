import SwiftUI
import TouchKit

/// A stylized top-view of the Magic Mouse surface: rounded shell outline, three
/// tinted zone bands driven by the live `ZoneLayout`, a dot per live contact, and
/// the hysteresis active zone highlighted (docs/06-visualizer.md). Read-only over
/// `VisualizerModel`; it never touches the recognizer or emitter.
///
/// `SurfaceTouch.position` is normalized `0...1`, origin **bottom-left**; SwiftUI
/// is top-left, so `y` is flipped once here, at the drawing boundary.
public struct VisualizerView: View {
    private let model: VisualizerModel

    /// Magic Mouse sensor is portrait (docs/04: ~5152×9056). The surface keeps
    /// that aspect so dot positions read true.
    private let mouseAspect: CGFloat = 5152.0 / 9056.0

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
                touchDots(in: size)
            }
            .overlay(alignment: .top) { flashBadge }
        }
        .aspectRatio(mouseAspect, contentMode: .fit)
        .animation(.easeOut(duration: 0.2), value: model.lastFlash?.id)
    }

    /// A transient badge for the most recently recognized gesture (tap / double-tap),
    /// so the tuning panes show that a gesture registered. Keyed on the flash `id` so
    /// repeats re-trigger the transition even for the same title.
    @ViewBuilder
    private var flashBadge: some View {
        if let flash = model.lastFlash {
            Text(flash.title)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(color(for: flash.zone)))
                .padding(.top, 8)
                .id(flash.id)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
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

    // MARK: Contacts

    private func touchDots(in size: CGSize) -> some View {
        ForEach(model.touches, id: \.id) { t in
            let d = dotDiameter(for: t)
            Circle()
                .fill(phaseColor(t.phase))
                .frame(width: d, height: d)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.5), lineWidth: 1))
                .position(point(for: t, in: size))
        }
    }

    /// Flip `y` once, here at the drawing boundary (docs/06).
    private func point(for t: SurfaceTouch, in size: CGSize) -> CGPoint {
        CGPoint(x: t.position.x * size.width,
                y: (1 - t.position.y) * size.height)
    }

    /// `SurfaceTouch.size` (major axis) runs ~8–10, not `0...1` (see the
    /// touch-size-scale note / docs/04), so scale it into a sensible dot.
    private func dotDiameter(for t: SurfaceTouch) -> CGFloat {
        min(max(t.size * 3.0, 12), 44)
    }

    // MARK: Caption

    private var caption: some View {
        HStack(spacing: 12) {
            Text("Active: \(title(model.activeZone))")
                .foregroundStyle(model.activeZone.map(color) ?? .secondary)
            Spacer()
            Text("\(model.touches.count) contact\(model.touches.count == 1 ? "" : "s")")
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

    private func title(_ zone: MouseZone?) -> String {
        switch zone {
        case .left: return "left"
        case .middle: return "middle"
        case .right: return "right"
        case nil: return "—"
        }
    }
}

#Preview("Visualizer — scripted") {
    let model = VisualizerModel()
    model.update([
        SurfaceTouch(deviceID: MouseDeviceID(raw: 1), id: 1,
                     position: CGPoint(x: 0.5, y: 0.7),
                     phase: .moved, timestamp: 0, size: 9),
    ])
    return VisualizerView(model: model)
        .frame(width: 240, height: 460)
}
