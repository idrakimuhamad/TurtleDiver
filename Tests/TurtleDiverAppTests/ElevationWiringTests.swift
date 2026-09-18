import XCTest
@testable import TurtleDiverAppGlue
@testable import TurtleDiverSystem

/// The elevation decision exists as a pure core (`ElevationPolicyTests` pins that
/// half). These pin the wiring, which is where the original defect lived: the
/// right logic, called in the wrong order or with the wrong strategy, is how a
/// connect ends up waiting 90 s on a dialog nobody was told about.
///
/// Every assertion here is a source scan, deliberately: the call sites are in
/// `VPNManager`/`AppDelegate`, which the SPM harness does not compile. Comments
/// are stripped first, so prose cannot stand in for a call.
final class ElevationWiringTests: XCTestCase {

    // MARK: - Choosing the strategy

    /// The strategy has to be detected *from the machine* and handed to the plan.
    /// A hard-coded `.storedPassword` is exactly the bug: on a Mac with
    /// `pam_tid` enabled, `sudo -S` never reads the pipe.
    func testTheConnectPathDetectsAndPassesTheChosenStrategy() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertTrue(code.contains("ElevationProbe.live("),
                      "the connect path must ask the machine which way elevation goes")
        XCTAssertTrue(code.contains("elevation = snapshot.strategy"),
                      "the resolved strategy must be what the plan is given")

        let plan = try XCTUnwrap(code.range(of: "OpenConnectCommand.launchPlan("))
        let planCall = code[plan.lowerBound...].prefix(900)
        XCTAssertTrue(planCall.contains("elevation: elevation"),
                      "the launch plan must receive the probed strategy, not a default")
    }

    /// The snapshot reads two files and, so, has to stay off the main thread. It
    /// deliberately asks `sudo` nothing, so it has no business spawning one.
    func testTheElevationProbeRunsOffTheMainThreadAndAsksSudoNothing() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let start = try XCTUnwrap(code.range(of: "private static func elevationSnapshot"))
        let body = code[start.lowerBound...].prefix(700)

        XCTAssertTrue(body.contains("DispatchQueue.global"),
                      "the elevation probe must not run on the main thread")
        XCTAssertTrue(body.contains("ElevationProbe.live("),
                      "it must still detect what the PAM stack does")
        XCTAssertFalse(body.lowercased().contains("sudo"),
                       "it must not shell out to sudo — by any spelling — to decide this")
    }

    /// With Touch ID answering, the stored password is unused. Demanding it first
    /// would gate a connect that has no use for it — and would keep asking for a
    /// credential after the app stopped needing one.
    func testTheStoredPasswordIsOnlyRequiredWhenItIsTheOneBeingPiped() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertTrue(code.contains("elevation.pipesTheStoredPassword && settings.adminPassword.isEmpty"),
                      "the admin-password requirement must be gated on the strategy that pipes it")
    }

    /// The named failure has to win over the generic one, and the user has to be
    /// told the timeout is a dialog — the two halves of "fail loud".
    func testTheTimeoutIsBoundedAndItsCauseIsNamed() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertTrue(code.contains("private static let connectionTimeoutSeconds = 90"),
                      "the 90 s bound must be named, because the preflight message quotes it")
        XCTAssertTrue(code.contains("startConnectionTimer(timeoutSeconds: Self.connectionTimeoutSeconds)"),
                      "the bound must actually be used by the connect path")

        let timeout = try XCTUnwrap(code.range(of: "Connection timeout reached."))
        let handler = code[timeout.lowerBound...].prefix(1200)
        XCTAssertTrue(handler.contains("self.elevation.timeoutHistoryStatus"),
                      "a timeout must be classified, not reported as a bare \"Connection timeout\"")
        XCTAssertTrue(handler.contains("timeoutDetail(timeoutSeconds:"),
                      "the classified timeout must explain itself in the log")
    }

    // MARK: - Reading the cause back

    /// The marker lines contain the word "sudo", so the keyword rules further
    /// down would re-file them as an administrator-password problem. The exact
    /// match (never `contains`) has to be consulted first.
    func testTheExactMarkerIsCheckedBeforeTheLooseSudoKeyword() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        let marker = try XCTUnwrap(code.range(of: "ElevationBlockReason.match(markerLine:"))
        let keyword = try XCTUnwrap(code.range(of: "lower.contains(\"sudo\")"))
        XCTAssertLessThan(marker.lowerBound, keyword.lowerBound,
                          "the exact marker must be matched before the loose keyword rule")

        // A bare `contains` on the marker would let openconnect's own output pass
        // for a classified failure.
        XCTAssertFalse(code.contains("elevationBlock = ."),
                       "the failure reason must come from the parser, not a guessed case")
    }

    /// A marker that cannot round-trip through `shellEscape` is a marker that
    /// silently stops matching: the script is a single-quoted string.
    func testTheMarkersSurviveBeingSingleQuotedIntoTheScript() {
        for reason in ElevationBlockReason.allCases {
            XCTAssertFalse(reason.rawValue.contains("'"),
                           "\(reason) contains an apostrophe, which the script builder would escape")
            XCTAssertFalse(reason.rawValue.contains("\n"),
                           "\(reason) spans lines, so it could never match as one")
            XCTAssertTrue(reason.markerLine.hasPrefix(ElevationBlockReason.markerPrefix))
        }
    }

    // MARK: - Leaving nothing behind

    /// Every teardown path — the timeout, an explicit disconnect, and quitting —
    /// has to go through the group reaper. Otherwise the wrapper the launch
    /// recorded is the only thing left holding the group, and it dies with us.
    func testEveryTeardownPathReapsTheRecordedGroup() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertTrue(code.contains("ElevationReaper.reapStaleGroup"),
                      "teardown must go through the reaper, which refuses a live connection")

        let reaps = code.components(separatedBy: "reapLaunchProcessGroupInBackground()").count - 1
        // One definition pair plus one call per teardown path: forceTerminate,
        // disconnect, cleanupOnTermination.
        XCTAssertGreaterThanOrEqual(reaps, 4,
                                    "expected the reaper helper plus three teardown call sites, found \(reaps)")
    }

    /// The sweep is a launch-time job, and it must happen before anything can
    /// connect — a connect that races it would fight over the same group.
    func testTheLaunchSweepHappensBeforeTheEngineStarts() throws {
        let code = try strippedCode(at: "VPNConnect/AppDelegate.swift")

        let sweep = try XCTUnwrap(code.range(of: "ElevationReaper.reapStaleGroup"))
        let engine = try XCTUnwrap(code.range(of: "_ = EngineController.shared"))
        XCTAssertLessThan(sweep.lowerBound, engine.lowerBound,
                          "the stale-group sweep must run before the engine starts")

        let start = code[sweep.lowerBound...].prefix(500)
        XCTAssertTrue(code.contains("DispatchQueue.global"),
                      "the sweep shells out to ps and must not run on the main thread")
        XCTAssertTrue(start.contains("debugOutput += message"),
                      "the sweep must report what it did rather than work silently")
    }

    /// The connect must never resolve to the strategy that cannot ask.
    ///
    /// That is the whole `Failed - Elevation Expired` defect in one line: the app
    /// probed `sudo -n -v` in its own process and, on a warm answer, told the plan
    /// not to prompt. `sudo` keys its timestamp to the parent process when there
    /// is no terminal, and the plan's `sudo` runs under the wrapper shell — a
    /// different parent. It found a cold timestamp, exited with its marker, and
    /// the connect died on a timestamp the app had just measured as warm.
    func testTheConnectStrategyIsNeverTheOneThatCannotAsk() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertFalse(code.contains(".neverPrompt"),
                       "connect must never refuse to ask for elevation")
        XCTAssertFalse(code.contains("SudoProbe"),
                       "no probe outside the plan may decide the strategy")
        XCTAssertFalse(code.contains("timestampWarm"),
                       "warmth is not an input to the decision any more")
    }

    /// Stale `/etc/hosts` entries belong to the launch plan, whose `sudo` runs in
    /// the context that just authenticated. The app used to clean them before the
    /// plan started, from a `sudo` that is a child of the app — a different
    /// timestamp record — so the attempt could only fail, and said so, loudly, in
    /// the connection log the user reads.
    func testTheHostsCleanupBelongsToTheLaunchPlan() throws {
        let manager = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertFalse(manager.contains("cleanupVpnSliceHosts"),
                       "the app must not run its own pre-connect cleanup")
        XCTAssertFalse(manager.contains("hostsCleanupPlan"),
                       "…nor build a standalone cleanup plan")

        let launch = try strippedCode(at: "VPNConnect/System/OpenConnectLaunch.swift")
        XCTAssertTrue(launch.contains("hostsCleanupStep(elevation)"),
                      "the plan must still remove stale entries")
        XCTAssertFalse(launch.contains("func hostsCleanupPlan"),
                       "no caller, no plan builder")
    }

    // MARK: - Helpers

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
