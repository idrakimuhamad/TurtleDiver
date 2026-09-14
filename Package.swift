// swift-tools-version:5.9
// Test harness for the TurtleDiver engine (Phases 0–4).
//
// The app target is defined by VPNConnect.xcodeproj; this package does NOT
// build the SwiftUI app (the views depend on AppKit/SwiftUI). Instead it
// compiles the Foundation-only engine sources directly from VPNConnect/Profile,
// VPNConnect/Rules, VPNConnect/Engine and VPNConnect/System via path-based
// targets so `swift test` runs the XCTest suites against the exact same files
// the app compiles.
//
// `TurtleDiverAppGlue` additionally compiles the app-side files that the
// engine toggle lives in (EngineController + the managers it talks to), plus
// the main window's layout maths (`MainWindowLayout`), so both can be
// regression-tested without SwiftUI. Those files carry
// `#if canImport(TurtleDiverCore)` guards so the same source works in the app
// target, where these modules do not exist.
import PackageDescription

let package = Package(
    name: "TurtleDiverCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "TurtleDiverCore",
            targets: ["TurtleDiverCore", "TurtleDiverRules", "TurtleDiverEngine", "TurtleDiverSystem"]
        )
    ],
    targets: [
        .target(
            name: "TurtleDiverCore",
            path: "VPNConnect/Profile"
        ),
        .target(
            name: "TurtleDiverRules",
            dependencies: ["TurtleDiverCore"],
            path: "VPNConnect/Rules"
        ),
        .target(
            name: "TurtleDiverEngine",
            dependencies: ["TurtleDiverCore", "TurtleDiverRules"],
            path: "VPNConnect/Engine"
        ),
        .target(
            name: "TurtleDiverSystem",
            dependencies: ["TurtleDiverCore", "TurtleDiverRules"],
            path: "VPNConnect/System"
        ),
        .target(
            name: "TurtleDiverAppGlue",
            dependencies: ["TurtleDiverCore", "TurtleDiverRules", "TurtleDiverEngine", "TurtleDiverSystem"],
            path: "VPNConnect",
            sources: [
                "EngineController.swift",
                "KeychainHelper.swift",
                "SettingsManager.swift",
                "VPNManager.swift",
                "Views/MainWindowLayout.swift"
            ]
        ),
        .testTarget(
            name: "TurtleDiverAppTests",
            dependencies: ["TurtleDiverAppGlue", "TurtleDiverCore", "TurtleDiverSystem"],
            path: "Tests/TurtleDiverAppTests"
        ),
        .testTarget(
            name: "TurtleDiverCoreTests",
            dependencies: ["TurtleDiverCore", "TurtleDiverRules", "TurtleDiverEngine", "TurtleDiverSystem"],
            path: "Tests/TurtleDiverCoreTests"
        )
    ]
)
