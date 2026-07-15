import CoreGraphics

/// Derives the single `physicalClickActive` bool the recognizer needs from the
/// stream of real mouse down/up events (docs/05 §Interceptor sketch). Pure and
/// value-typed so the state machine is unit-tested without a live `CGEventTap`.
///
/// "Active" means **any** hardware button is currently down (tracked per button
/// number, so holding right while tapping left is still active).
struct PhysicalClickTracker {
    private(set) var pressedButtons: Set<Int64> = []

    var isActive: Bool { !pressedButtons.isEmpty }

    /// Fold one event into the state. Returns `true` iff `isActive` flipped, so
    /// the caller only notifies the recognizer on real transitions.
    mutating func handle(_ type: CGEventType, buttonNumber: Int64) -> Bool {
        let wasActive = isActive
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedButtons.insert(buttonNumber)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pressedButtons.remove(buttonNumber)
        default:
            break // not a button event we track
        }
        return wasActive != isActive
    }
}
