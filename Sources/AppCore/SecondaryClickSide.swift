import Foundation

/// Which side of the Magic Mouse the user has assigned the **secondary** (button-2)
/// click, read from the system so MagicButtons' left/right tap zones match how the
/// physical mouse is configured (docs/05 §Zone → button).
///
/// - `.right`: the default / right-handed arrangement — left zone = primary
///   (button 1), right zone = secondary (button 2). No swap.
/// - `.left`: the left-handed arrangement — the sides are swapped, so the left zone
///   emits the secondary click and the right zone the primary.
public enum SecondaryClickSide: Sendable, Equatable {
    case right
    case left
}

/// Reads the Magic Mouse secondary-click side from the system's
/// `com.apple.AppleMultitouchMouse` preferences. The side is encoded entirely in the
/// `MouseButtonMode` key (confirmed empirically on macOS by toggling the setting):
///
/// | `MouseButtonMode`  | System UI                     | Side     |
/// |--------------------|-------------------------------|----------|
/// | `TwoButton`        | Secondary click, right side   | `.right` |
/// | `TwoButtonSwapped` | Secondary click, left side    | `.left`  |
/// | `OneButton`        | Secondary click off           | `.right` |
///
/// `MouseButtonDivision` (the split position) is *not* involved — it stays put when
/// the side flips. Reading works because the app is unsandboxed (docs/07); a
/// sandboxed app couldn't see another domain. The raw read is injected so tests can
/// drive every branch without touching real preferences.
public struct SecondaryClickReader {
    private let readMode: @Sendable () -> String?

    /// Default reader consults the live per-user preference via `CFPreferencesCopyAppValue`,
    /// which searches current-user/any-host **and** current-host so it finds the value
    /// wherever the mouse pane wrote it.
    public init(readMode: @escaping @Sendable () -> String? = {
        CFPreferencesCopyAppValue(
            "MouseButtonMode" as CFString,
            "com.apple.AppleMultitouchMouse" as CFString) as? String
    }) {
        self.readMode = readMode
    }

    public func currentSide() -> SecondaryClickSide {
        readMode() == "TwoButtonSwapped" ? .left : .right
    }
}
