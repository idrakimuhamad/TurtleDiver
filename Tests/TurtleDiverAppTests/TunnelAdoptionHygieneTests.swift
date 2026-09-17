import XCTest
import Foundation
@testable import TurtleDiverAppGlue
import TurtleDiverCore
import TurtleDiverSystem

/// Pins the two things that keep a test run away from the user's own tunnel.
///
/// The suite used to adopt the machine's real `openconnect` — creating
/// `VPNManager.shared` performs the launch-time adoption of a tunnel the app did
/// not start, which records the pid, writes the user's `run/openconnect.pid` and
/// publishes `.connected`. Those tests were then not hermetic: the rule-set path
/// depended on whether a tunnel happened to be up.
final class TunnelAdoptionHygieneTests: XCTestCase {

    // MARK: The test host does not adopt

    func testATestHostDoesNotAdoptATunnelItDidNotStart() {
        XCTAssertFalse(
            VPNManager.adoptsExistingConnectionsAtLaunch,
            "a test process must not adopt the machine's own tunnel"
        )
    }

    /// The flag is `!isTestHost`, so the detector is what stands between the
    /// suite and the machine's tunnel. If this harness ever stops looking like a
    /// test host, the flag silently flips and the suite adopts again.
    func testThisProcessIsDetectedAsATestHost() {
        let byEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let byFramework = NSClassFromString("XCTestCase") != nil
        XCTAssertTrue(
            byEnvironment || byFramework,
            "neither test-host signal is present, so `adoptsExistingConnectionsAtLaunch` would be true"
        )
    }

    func testTheManagerConsultsTheFlagBeforeAdopting() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let manager = try XCTUnwrap(
            slice(after: "class VPNManager: ObservableObject", in: code),
            "the manager's declaration is gone"
        )
        let initBody = try XCTUnwrap(body(of: "private init()", in: manager), "`private init()` not found")
        XCTAssertTrue(
            initBody.contains("guard Self.adoptsExistingConnectionsAtLaunch else { return }"),
            "the initializer must refuse to adopt before it schedules the scan"
        )
        let guardAt = try XCTUnwrap(initBody.range(of: "adoptsExistingConnectionsAtLaunch"))
        let adoptAt = try XCTUnwrap(initBody.range(of: "checkForExistingConnection()"))
        XCTAssertLessThan(
            guardAt.lowerBound, adoptAt.lowerBound,
            "the refusal must come before the adoption"
        )
    }

    // MARK: The controller reads the injected tunnel, not the manager

    func testTheEngineControllerNeverNamesTheSharedManager() throws {
        // `strippedCode` drops the `// MARK:` line itself, so the split happens
        // on the raw file and the comment stripping follows it.
        let marker = try XCTUnwrap(
            slice(after: "// MARK: - Engine Controller", in: try rawText(at: "VPNConnect/EngineController.swift")),
            "the controller section marker is gone"
        )
        let controller = marker.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(
            controller.contains("VPNManager"),
            "the controller must reach the tunnel only through `TunnelStatusSource`"
        )
    }

    /// Every controller a test builds must say which tunnel it is watching; a
    /// call site that falls back to the default constructs the real manager.
    func testEveryTestControllerInjectsATunnel() throws {
        let files = [
            "Tests/TurtleDiverAppTests/EngineTogglePersistenceTests.swift",
            "Tests/TurtleDiverAppTests/RuleSetControllerTests.swift",
            "Tests/TurtleDiverAppTests/SystemProxyIntentTests.swift",
        ]
        for file in files {
            let code = try strippedCode(at: file)
            var search = code.startIndex
            var found = 0
            while let call = code.range(of: "EngineController(", range: search..<code.endIndex) {
                found += 1
                let tail = code[call.upperBound...].prefix(400)
                XCTAssertTrue(
                    tail.contains("tunnel:"),
                    "\(file): an EngineController is built without an injected tunnel"
                )
                search = call.upperBound
            }
            XCTAssertGreaterThan(found, 0, "\(file): no EngineController found — has the test moved?")
        }
    }

    // MARK: The stub is a tunnel a test can drive

    @MainActor
    func testTheStubReportsWhatTheTestSets() {
        let tunnel = StubTunnelStatus()
        XCTAssertEqual(tunnel.status, .disconnected)
        tunnel.set(.connected)
        XCTAssertEqual(tunnel.status, .connected)
        tunnel.log("line\n")
        XCTAssertEqual(tunnel.logged, ["line\n"])
    }

    // MARK: Helpers

    /// The body of a declaration, from its first line to the line that closes it
    /// at the same indentation.
    private func body(of declaration: String, in code: String) -> String? {
        guard let start = code.range(of: declaration) else { return nil }
        let tail = code[start.lowerBound...]
        guard let open = tail.firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < tail.endIndex {
            switch tail[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(tail[open...index]) }
            default: break
            }
            index = tail.index(after: index)
        }
        return nil
    }

    private func slice(after declaration: String, in code: String) -> String? {
        guard let start = code.range(of: declaration) else { return nil }
        return String(code[start.upperBound...])
    }

    private func strippedCode(at path: String) throws -> String {
        try rawText(at: path).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func rawText(at path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
