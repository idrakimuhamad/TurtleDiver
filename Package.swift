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
            // The SwiftUI app files share this directory but are deliberately
            // not compiled here (they need AppKit/app lifecycle). Listing them
            // keeps `swift build` quiet and forces a decision for every new
            // app-side file: add it to `sources` (testable glue) or here.
            exclude: [
                "Info.plist",
                "VPNConnect.entitlements",
                "main.swift",
                "AppDelegate.swift",
                "MainView.swift",
                "SettingsView.swift",
                "SettingsWindowController.swift",
                "ToggleableSecureTextField.swift",
                "Views/AdvancedView.swift",
                "Views/DashboardView.swift",
                "Views/PolicyViews.swift",
                "Views/ProfilesView.swift",
                "Views/RequestsCard.swift",
                "Views/RoutingView.swift",
                "Views/RuleSetsView.swift",
                "Views/RulesEditorView.swift",
                "Views/SettingsDesign.swift",
                "Views/SetupView.swift",
                "Engine/DisplayFormat.swift",
                "Engine/RelayStreamObserver.swift",
                "Engine/RequestDetail.swift",
                "Engine/TLSClientHello.swift",
                "Engine/HTTPProxyServer.swift",
                "Engine/ProxyEngine.swift",
                "Engine/RelayConnection.swift",
                "Engine/SOCKS5Server.swift",
                "Profile/LatencyTester.swift",
                "Profile/PolicyStore.swift",
                "Profile/Profile.swift",
                "Profile/ProfileManager.swift",
                "Profile/ProfileParser.swift",
                "Profile/ProfileSerializer.swift",
                "Profile/RuleSet.swift",
                "Profile/TCPClient.swift",
                "Rules/DNSResolver.swift",
                "Rules/IPAddress.swift",
                "Rules/PACRuleConverter.swift",
                "Rules/ProcessPeerResolver.swift",
                "Rules/RuleSetStore.swift",
                "Rules/RuleMatcher.swift",
                "System/AppIdentity.swift",
                "System/BoundedProcess.swift",
                "System/ElevationPolicy.swift",
                "System/ExistingConnection.swift",
            "System/LifecycleLog.swift",
                "System/OpenConnectLaunch.swift",
                "System/ProcessStartTime.swift",
                "System/SystemProxyManager.swift",
                "System/ToolProcess.swift",
                "System/ToolResolver.swift",
                "System/UpdateFeed.swift",
                "System/VPNRuleGenerator.swift"
            ],
            sources: [
                "EngineController.swift",
                "KeychainHelper.swift",
                "SettingsManager.swift",
                "VPNManager.swift",
                "Views/MainWindowLayout.swift",
                "Views/SettingsCatalog.swift",
                "Views/SettingsDraft.swift",
                "Views/ToolSetupModel.swift"
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
