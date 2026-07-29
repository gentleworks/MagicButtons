// swift-tools-version: 6.0
import PackageDescription

// MagicButtons — SwiftPM package holding all pure, unit-testable logic.
//
// Structural rule (see docs/01-architecture.md): nothing downstream of
// `TouchSource` may import the private framework. That invariant is enforced
// here — `MTPrivate` is a dependency of `MultitouchAdapter` and nothing else.
//
// The thin Xcode `App` target that owns Info.plist / LSUIElement / entitlements /
// signing (docs/12-project-setup.md) is layered on top later; the `App`
// executable target below is a Phase 0 scaffold stub that proves the full
// dependency graph compiles and links.
let package = Package(
    name: "MagicButtons",
    // Required for any target to carry localized resources. The two targets that own
    // user-visible text (AppCore's permission copy, Visualizer's badge/caption) ship a
    // String Catalog; everything else stays resource-free.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TouchKit", targets: ["TouchKit"]),
        .library(name: "TouchTestSupport", targets: ["TouchTestSupport"]),
        .library(name: "MultitouchAdapter", targets: ["MultitouchAdapter"]),
        .library(name: "GestureEngine", targets: ["GestureEngine"]),
        .library(name: "EventOutput", targets: ["EventOutput"]),
        .library(name: "Visualizer", targets: ["Visualizer"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        // The dev-harness CLI (verify-*/visualize/permissions). Named distinctly from
        // the shipping `MagicButtons.app` (the Xcode target in project.yml) so the two
        // don't collide as duplicate schemes when the app project embeds this package.
        .executable(name: "mb-dev", targets: ["App"]),
    ],
    targets: [
        // Stable core — no dependencies, the vocabulary everything agrees on.
        .target(name: "TouchKit"),

        // Simulated source + replay format. Not test-only: the App's debug
        // "record" feature and previews use it too.
        .target(name: "TouchTestSupport", dependencies: ["TouchKit"]),

        // C shim declaring the private MultitouchSupport symbols. The only
        // quarantined target.
        .target(name: "MTPrivate"),

        // The ONLY target allowed to see MTPrivate.
        .target(name: "MultitouchAdapter", dependencies: ["TouchKit", "MTPrivate"]),

        // Pure gesture logic — zone mapping + recognition. Fully unit-tested.
        .target(name: "GestureEngine", dependencies: ["TouchKit"]),

        // Public CoreGraphics event emit + interceptor. No private API.
        .target(name: "EventOutput", dependencies: ["TouchKit"]),

        // SwiftUI finger/zone graphic.
        .target(name: "Visualizer", dependencies: ["TouchKit"],
                resources: [.process("Resources")]),

        // Package-side App-layer logic — pure, testable composition pieces the
        // thin Xcode app target and the executable harness both consume: feature
        // policy (Phase 7.1), settings persistence (Phase 7.2). Keeps App-layer
        // logic in SwiftPM/CI rather than the untestable executable
        // (docs/01-architecture.md §Composition root, docs/12-project-setup.md).
        .target(name: "AppCore", dependencies: ["TouchKit", "GestureEngine", "EventOutput"],
                resources: [.process("Resources")]),

        // Composition root (scaffold stub for now — see note above).
        .executableTarget(
            name: "App",
            dependencies: [
                "TouchKit",
                "TouchTestSupport",
                "MultitouchAdapter",
                "GestureEngine",
                "EventOutput",
                "Visualizer",
                "AppCore",
            ]
        ),

        // Hardware-free test targets (Swift Testing).
        .testTarget(
            name: "TouchKitTests",
            dependencies: ["TouchKit", "TouchTestSupport"]
        ),
        .testTarget(
            name: "GestureEngineTests",
            dependencies: ["GestureEngine", "TouchTestSupport"]
        ),
        .testTarget(
            name: "EventOutputTests",
            dependencies: ["EventOutput"]
        ),
        .testTarget(
            name: "VisualizerTests",
            dependencies: ["Visualizer", "TouchKit"]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "GestureEngine", "TouchKit", "EventOutput", "TouchTestSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
