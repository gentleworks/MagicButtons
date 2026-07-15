import TouchKit

// MultitouchAdapter — wraps the private MultitouchSupport framework and emits
// SurfaceTouch. The ONLY target that imports MTPrivate (docs/01-architecture.md,
// docs/04-multitouch-backend.md).
//
// Phase 4: `MTBackend` (dlopen/dlsym resolution), `MultitouchDump` (bring-up
// verification), `PhaseMapping` (raw state → TouchPhase, pinned on hardware),
// and `MultitouchSource` (the real TouchSource emitting SurfaceTouch).
public enum MultitouchAdapter {
    public static let moduleName = "MultitouchAdapter"
}
