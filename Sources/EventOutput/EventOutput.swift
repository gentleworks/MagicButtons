import TouchKit

// EventOutput — ButtonEmitting (post buttons) + EventInterceptor (active tap:
// physical-click signal, move→drag promotion), public CoreGraphics only
// (docs/05-event-output.md).
//
// Phase 0 scaffold: click mechanism + interceptor skeleton land in Phase 3.
public enum EventOutput {
    public static let moduleName = "EventOutput"
}
