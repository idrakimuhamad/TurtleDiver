import XCTest

/// A quit that skips its cleanup — leaving the system proxy pointing at a dead
/// engine, or a privileged group behind — used to be indistinguishable from a
/// clean one, because `applicationWillTerminate` left no trace anywhere. These
/// pin the two ends of the trace, and the order they are written in.
final class LifecycleWiringTests: XCTestCase {

    private let appDelegate = "VPNConnect/AppDelegate.swift"

    func testTheQuitIsTracedAtBothEndsAndInOrder() throws {
        let code = try strippedCode(at: appDelegate)
        let body = try body(of: "func applicationWillTerminate(", in: code)
        XCTAssertLessThan(body.count, 4_000, "the slice must be the method, not the rest of the file")

        let began = try XCTUnwrap(body.range(of: "LifecycleLog.append(.willTerminateBegan)"),
                                  "the quit must be recorded before any cleanup starts")
        let shutdown = try XCTUnwrap(body.range(of: "EngineController.shared.shutdown()"),
                                     "the engine must still be shut down")
        let vpnCleanup = try XCTUnwrap(body.range(of: "VPNManager.shared.cleanupOnTermination()"),
                                       "the VPN must still be cleaned up")
        let ended = try XCTUnwrap(body.range(of: "LifecycleLog.append(.willTerminateEnded)"),
                                  "the quit must be recorded after cleanup returns")

        // The order is the diagnostic: a `began` with no `ended` is a quit that
        // hung part-way through the cleanup.
        XCTAssertLessThan(began.lowerBound, shutdown.lowerBound)
        XCTAssertLessThan(shutdown.lowerBound, vpnCleanup.lowerBound)
        XCTAssertLessThan(vpnCleanup.lowerBound, ended.lowerBound)

        // `StartupLog` writes on a queue. At quit the process can be gone before
        // that queue is drained, which is the whole reason for a second log.
        XCTAssertFalse(body.contains("StartupLog"),
                       "the quit trace must be written synchronously, not through the queue")
    }

    func testTheLaunchIsTracedBeforeAnythingElse() throws {
        let code = try strippedCode(at: appDelegate)

        let launch = try XCTUnwrap(code.range(of: "LifecycleLog.append(.launch)"),
                                   "the launch must be recorded")
        let reset = try XCTUnwrap(code.range(of: "StartupLog.reset()"),
                                  "the startup log is still reset at launch")
        let migration = try XCTUnwrap(code.range(of: "SettingsDomainMigration.copyLegacyDomains()"),
                                      "the settings migration still runs")

        // First, so that a run that never reaches its quit — a hang in the
        // credential migration, a crash — is still on the record.
        XCTAssertLessThan(launch.lowerBound, reset.lowerBound)
        XCTAssertLessThan(launch.lowerBound, migration.lowerBound)
    }

    /// The delegate method the teardown lives in is not guaranteed to run just
    /// because the app is quitting: macOS can decide the process has nothing to
    /// lose and end it outright. Both halves of the guarantee are pinned here —
    /// what the app declares about itself, and what it enforces.
    func testTheAppNeverOptsIntoBeingKilledWithoutItsTeardown() throws {
        let url = repoRoot.appendingPathComponent("VPNConnect/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "the app's Info.plist must parse"
        )

        // Absent also means "not opted in"; only `true` is dangerous.
        XCTAssertNotEqual(plist["NSSupportsSuddenTermination"] as? Bool, true,
                          "sudden termination ends the process without calling applicationWillTerminate")
        XCTAssertNotEqual(plist["NSSupportsAutomaticTermination"] as? Bool, true,
                          "automatic termination can end a hidden, idle app — a live tunnel is neither")
    }

    func testTheDelegateDisablesSuddenTerminationAtLaunch() throws {
        let code = try strippedCode(at: appDelegate)
        let body = try body(of: "func applicationDidFinishLaunching", in: code)
        XCTAssertLessThan(body.count, 4_000)

        let disable = try XCTUnwrap(body.range(of: "ProcessInfo.processInfo.disableSuddenTermination()"),
                                    "the teardown guarantee must be enforced, not assumed")
        XCTAssertFalse(code.contains("enableSuddenTermination"),
                       "nothing may hand this capability back")

        // Enforced before anything that could leave state behind.
        let startup = try XCTUnwrap(body.range(of: "StartupLog.reset()"))
        XCTAssertLessThan(disable.lowerBound, startup.lowerBound)
        let migration = try XCTUnwrap(body.range(of: "SettingsDomainMigration.copyLegacyDomains()"))
        XCTAssertLessThan(disable.lowerBound, migration.lowerBound)
    }

    // MARK: Helpers

    /// The text of one function, from its declaration to the next declaration at
    /// the same indentation — the nearest, not the first pattern that matches.
    private func body(of function: String, in code: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: function), "\(function) not found")
        let rest = code[start.upperBound...]
        let anchors = ["\n    func ", "\n    private func ", "\n    static func ", "\n    public func "]
        let ends = anchors.compactMap { rest.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return rest }
        return rest[..<end]
    }

    private func strippedCode(at path: String) throws -> String {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
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
