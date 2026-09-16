import XCTest
@testable import TurtleDiverAppGlue
@testable import TurtleDiverSystem

/// A missing tool must be reported as *missing*, in both places it surfaces: the
/// History pill and the connect message.
final class MissingToolReportingTests: XCTestCase {

    func testTheHistoryPillSaysMissingToolRatherThanTokenError() {
        // The trap: "stoken is not installed" contains the word "token", so the
        // old rules answered "Token error" — the exact misdiagnosis this ends.
        let label = SettingsDisplay.connectionStatus("Failed - Missing Tool")
        XCTAssertEqual(label.title, "Missing tool")
        XCTAssertEqual(label.tone, .error)

        XCTAssertEqual(SettingsDisplay.connectionStatus("stoken not installed — see Settings ▸ Setup").title,
                       "Missing tool")
        XCTAssertEqual(SettingsDisplay.connectionStatus("openconnect not found").title,
                       "Missing tool")
    }

    func testARealTokenFailureStillReadsAsATokenError() {
        XCTAssertEqual(SettingsDisplay.connectionStatus("Failed - Token Error").title, "Token error")
    }

    /// The message the main window shows verbatim in its status hero.
    func testTheConnectMessageNamesTheToolAndThePane() {
        XCTAssertEqual(ToolPreflight.message(for: [.openconnect, .stoken]),
                       "openconnect and stoken are not installed — see Settings ▸ Setup")
    }
}

/// The install path runs a real installer, so it must not also feed the VPN log
/// — that file is on disk and outlives the app.
final class ToolSetupHygieneTests: XCTestCase {

    func testTheSetupPathNeverWritesToTheVpnLog() throws {
        let files = ["VPNConnect/Views/ToolSetupModel.swift",
                     "VPNConnect/Views/SetupView.swift",
                     "VPNConnect/System/ToolProcess.swift",
                     "VPNConnect/System/ToolResolver.swift"]
        let forbidden = ["debugOutput", "logSend(", "VpnConnectionLogger", "vpn.log", "VpnLog"]

        for file in files {
            let text = try String(contentsOf: repoRoot.appendingPathComponent(file), encoding: .utf8)
            let code = strippedComments(text)
            for symbol in forbidden {
                XCTAssertFalse(code.contains(symbol),
                               "\(file) mentions \(symbol): installer output must not reach the VPN log")
            }
        }
    }

    /// The pane exists to report, not to remember: it must not gain a settings
    /// dependency (a "don't ask again", a flag that gates a connect elsewhere).
    func testTheSetupModelHasNoPreferencesOfItsOwn() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("VPNConnect/Views/ToolSetupModel.swift"),
                              encoding: .utf8)
        for forbidden in ["UserDefaults", "SettingsManager", "@AppStorage"] {
            XCTAssertFalse(text.contains(forbidden),
                           "ToolSetupModel gained a settings dependency: \(forbidden)")
        }
    }

    /// The resolver the connect path uses must be the shared one — the four
    /// hard-coded directories did not include MacPorts.
    func testTheConnectPathResolvesToolsThroughTheSharedResolver() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("VPNConnect/VPNManager.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("ToolResolver.locate"),
                      "binaryPath must delegate to the shared resolver")
        XCTAssertFalse(text.contains("\"/opt/homebrew/bin/\\(name)\""),
                       "the hand-rolled prefix list must be gone")
    }

    /// A connect that cannot start because a tool is absent must say so before
    /// asking stoken for anything. Comment lines are stripped first so a
    /// mention in prose cannot stand in for the call itself.
    func testTheConnectPathChecksForMissingToolsFirst() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("VPNConnect/VPNManager.swift"),
                              encoding: .utf8)
        let code = strippedComments(text)
        let preflight = try XCTUnwrap(code.range(of: "ToolPreflight.missing"))
        let token = try XCTUnwrap(code.range(of: "generateToken(passcode:"))
        XCTAssertLessThan(preflight.lowerBound, token.lowerBound,
                          "the tool check must come before the token is generated")
    }

    private func strippedComments(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
