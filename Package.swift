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
        ),
        // The command line front door: installed by the .pkg alongside the app
        // and the agent, so a person or an agent can ask the same engine
        // questions without a window. `docs/CLI.md` is the contract.
        .executable(
            name: "turtlediver",
            targets: ["TurtleDiverCLI"]
        ),
        // The askpass helper, under the name `sudo` has to be pointed at. The
        // app ships this program inside its own bundle, built by Xcode (see
        // `docs/ELEVATION.md` §11); building it here as well means `swift build`
        // compiles the same source the app target does and a development build
        // can be pointed at directly:
        //
        //     SUDO_ASKPASS=.build/debug/turtlediver-askpass sudo -A -v
        .executable(
            name: "turtlediver-askpass",
            targets: ["TurtleDiverAskpass"]
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
        // The tunnel agent: the privileged process that owns a tunnel so the
        // app can end it later without authenticating again. It is deliberately
        // NOT part of the app bundle — a payload in a user-writable directory
        // that the app execs as root is an escalation surface. It is built here
        // and installed by the .pkg into a root-owned directory
        // (`docs/ELEVATION.md` §10). It links the same `TurtleDiverSystem`
        // sources the app does, so the protocol has one implementation.
        .executableTarget(
            name: "TurtleDiverAgent",
            dependencies: ["TurtleDiverSystem"],
            path: "Agent"
        ),
        // The CLI's logic lives in a library so the parts that decide *what to
        // run* can be tested without running it: argv building, config reading,
        // profile parsing, rule explanation, exit codes. `CLI/main.swift` is
        // then a one-line entry point with nothing to test.
        .target(
            name: "TurtleDiverCLIKit",
            dependencies: ["TurtleDiverCore", "TurtleDiverRules", "TurtleDiverSystem"],
            path: "CLI/Kit"
        ),
        // The helper `sudo -A` runs on a machine whose `pam_tid` would swallow a
        // piped password. It reads one Keychain item and prints it, and obeys the
        // same protocol as the command line tool's copy of itself
        // (`AskpassProgram`), so the two cannot drift apart.
        .executableTarget(
            name: "TurtleDiverAskpass",
            dependencies: ["TurtleDiverSystem"],
            path: "Askpass"
        ),
        .executableTarget(
            name: "TurtleDiverCLI",
            dependencies: ["TurtleDiverCLIKit"],
            path: "CLI",
            // `Kit` is its own target; without this the executable target's
            // path would claim the same sources and `swift build` would refuse
            // the overlap.
            exclude: ["Kit"]
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
                "Views/UpdatesView.swift",
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
                "System/AskpassProgram.swift",
                "System/BoundedProcess.swift",
                "System/ConnectSignals.swift",
                "System/ElevationPolicy.swift",
                "System/ElevatedTermination.swift",
                "System/ExistingConnection.swift",
                "System/LifecycleLog.swift",
                "System/OpenConnectLaunch.swift",
                "System/ProcessStartTime.swift",
                "System/StoredSecret.swift",
                "System/SystemProxyManager.swift",
                "System/ToolProcess.swift",
                "System/ToolResolver.swift",
                "System/TunnelAgentProtocol.swift",
                "System/TunnelAgentChannel.swift",
                "System/UpdateArtifact.swift",
                "System/UpdateBundle.swift",
                "System/UpdateFeed.swift",
                "System/UpdateRelaunch.swift",
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
                "Views/ToolSetupModel.swift",
                "Views/UpdateModel.swift"
            ]
        ),
        .testTarget(
            name: "TurtleDiverCLITests",
            dependencies: ["TurtleDiverCLIKit", "TurtleDiverCore", "TurtleDiverSystem"],
            path: "Tests/TurtleDiverCLITests"
        ),
        .testTarget(
            name: "TurtleDiverAppTests",
            dependencies: ["TurtleDiverAppGlue", "TurtleDiverCore", "TurtleDiverSystem"],
            path: "Tests/TurtleDiverAppTests"
        ),
        .testTarget(
            name: "TurtleDiverCoreTests",
            // `TurtleDiverAgent` is here for the build, not for the import: the
            // suite drives the installed agent as a child process, and depending
            // on the target is what guarantees `swift test` has built it. Nothing
            // would fail loudly otherwise — the suite would simply find no binary.
            dependencies: ["TurtleDiverCore", "TurtleDiverRules", "TurtleDiverEngine", "TurtleDiverSystem", "TurtleDiverAgent"],
            path: "Tests/TurtleDiverCoreTests"
        )
    ]
)
