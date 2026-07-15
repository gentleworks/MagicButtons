import CoreGraphics
import TouchKit

/// Pure zone → `CGMouseButton` + event-type mapping (docs/05 §Zone → button).
/// Split out from the emitter so the mapping is unit-testable without posting
/// real events. `.middle` maps to `.center` + the `.otherMouse*` family (button
/// number 2), which is what apps read as a middle click.
enum ButtonMapping {
    static func button(for zone: MouseZone) -> CGMouseButton {
        switch zone {
        case .left:   return .left
        case .middle: return .center
        case .right:  return .right
        }
    }

    static func downType(for zone: MouseZone) -> CGEventType {
        switch zone {
        case .left:   return .leftMouseDown
        case .middle: return .otherMouseDown
        case .right:  return .rightMouseDown
        }
    }

    static func upType(for zone: MouseZone) -> CGEventType {
        switch zone {
        case .left:   return .leftMouseUp
        case .middle: return .otherMouseUp
        case .right:  return .rightMouseUp
        }
    }

    /// The dragged-event type the interceptor rewrites `mouseMoved` into while a
    /// synthetic hold on this zone is active (used in Phase 8).
    static func draggedType(for zone: MouseZone) -> CGEventType {
        switch zone {
        case .left:   return .leftMouseDragged
        case .middle: return .otherMouseDragged
        case .right:  return .rightMouseDragged
        }
    }
}
