import Foundation
import CoreGraphics

/// The Magic Mouse touch surface's physical size, and the one place a normalized
/// position becomes millimetres.
///
/// `MTDeviceGetSensorSurfaceDimensions` reports ¹⁄₁₀₀ mm, so the "5152 × 9056" in
/// docs/04 is **51.52 × 90.56 mm** — a real surface, not an abstract sensor grid
/// (measured on hardware 2026-07-30). It lives in TouchKit because the gate
/// (`GestureEngine`) and the picture (`Visualizer`) both need it and must agree: a
/// second copy of these numbers is exactly how a drawn budget and a judged one drift
/// apart.
///
/// Hardcoded to the Magic Mouse, the only surface this app tracks. The adapter
/// already reads the real dimensions per device (`MTBackend.surfaceDimensions`), so
/// when a second surface shape matters that value replaces these constants *here*,
/// rather than at either use site.
public enum MouseSurface {
    public static let widthMM: CGFloat = 51.52
    public static let heightMM: CGFloat = 90.56

    /// Portrait aspect, for drawing the shell true. Because the visualizer locks to
    /// this, `width / widthMM` and `height / heightMM` are the same number — one
    /// points-per-mm converts in every direction.
    public static var aspect: CGFloat { widthMM / heightMM }

    /// The length of a normalized displacement, in millimetres.
    ///
    /// The two axes scale by different amounts, and that asymmetry is the whole point:
    /// a distance measured *before* this conversion is 1.76× more permissive fore-aft
    /// than sideways, purely because the sensor is portrait.
    public static func millimetres(dx: CGFloat, dy: CGFloat) -> CGFloat {
        let x = dx * widthMM
        let y = dy * heightMM
        return (x * x + y * y).squareRoot()
    }

    /// Converts a pre-millimetre travel threshold (normalized-Euclidean) to the
    /// equivalent millimetre radius, preserving the area the old *elliptical* budget
    /// enclosed — `√(w·h)` is the geometric mean of its two axis allowances. Used only
    /// to migrate a settings file written before the gate became isotropic
    /// (`GestureConfig.init(from:)`).
    public static let legacyTravelScale: CGFloat = (widthMM * heightMM).squareRoot()
}
