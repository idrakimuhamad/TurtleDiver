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

    /// With Touch ID answering and no helper prepared, the stored password is
    /// unused. Demanding it first would gate a connect that has no use for it —
    /// and would keep asking for a credential after the app stopped needing one.
    ///
    /// The question is no longer "does the strategy pipe the password" but "does
    /// this connect have any way to use one": the askpass route needs it too, so
    /// the requirement is gated on the resolved delivery — the same function the
    /// command line tool asks. A gate written twice is a gate that can be answered
    /// two ways.
    func testTheStoredPasswordIsRequiredWheneverTheConnectHasAWayToUseIt() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertTrue(code.contains("if delivery != nil && settings.adminPassword.isEmpty"),
                      "the admin-password requirement must be gated on the resolved delivery")
        XCTAssertTrue(code.contains("SudoPasswordDelivery.resolve(strategy: elevation, askpassHelper: askpass)"),
                      "the delivery must be resolved by the shared function, with the helper")
        XCTAssertFalse(code.contains("elevation.pipesTheStoredPassword && settings.adminPassword.isEmpty"),
                       "the pipe-only gate no longer covers the askpass route")
    }

    // MARK: - The askpass helper

    /// The helper is resolved once per connect, from the recorded approval *and*
    /// the program in the bundle, and it modifies the strategy rather than
    /// replacing it. Reading a code signature touches the disk, so it does not
    /// happen on the main thread — and nothing about it may prompt: a setup that
    /// was not done shows up as `nil` here, not as a dialog.
    func testTheHelperIsResolvedPerConnectAndComparedWithWhatWasApproved() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertTrue(code.contains("askpass = await Self.askpassHelper(recorded: settings.askpassHelperRequirement)"),
                      "the helper must be resolved from what the user approved")

        let resolver = try body(of: "private static func askpassHelper(")
        XCTAssertTrue(resolver.contains("DispatchQueue.global(qos: .userInitiated).async"),
                      "a code signature read must not run on the main thread")
        XCTAssertTrue(resolver.contains("AskpassSetup.usableHelperPath(recorded: recorded)"),
                      "the decision belongs to the tested core, not to this call site")
    }

    /// Both launch shapes carry the helper: the wrapper's plan (\(sudo -A\) in one
    /// script), and the agent path's warm-up (the variable in one child's
    /// environment, never a password in argv).
    func testBothLaunchShapesAreToldAboutTheHelper() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        let plan = try XCTUnwrap(code.range(of: "OpenConnectCommand.launchPlan("))
        XCTAssertTrue(code[plan.lowerBound...].prefix(900).contains("askpassHelper: askpass"),
                      "the wrapper's plan must be given the helper so its script uses `sudo -A`")

        let agent = try body(of: "private func prepareAgentLaunch(")
        XCTAssertTrue(agent.contains("askpass: askpass,"),
                      "the agent path's warm-up must be given the helper")
    }

    /// The warm-up and the launch have to agree about the door, and the plan's
    /// strategy is never overwritten by the helper: `askpass` is passed alongside
    /// it. The environment carries the helper's *path* — the password is printed
    /// by that program, so it is not in the child's environment either.
    func testTheWarmupUsesTheSameDoorAsTheLaunch() throws {
        let warm = try body(of: "private func warmElevation(")
        XCTAssertTrue(warm.contains("SudoPasswordDelivery.resolve(strategy: strategy, askpassHelper: askpass)"),
                      "the warm-up must resolve the delivery the same way the plan does")
        XCTAssertTrue(warm.contains("delivery: delivery == .askpass ? .askpass : .standardInput"),
                      "the askpass door must be the one the plan will use")
        XCTAssertTrue(warm.contains("TunnelAgentChannel.Launch.askpassEnvironment(helperPath: askpass)"),
                      "the helper's path is the only thing this child is given")
        XCTAssertTrue(warm.contains("environment: environment"),
                      "an environment built and not passed is a helper that never runs")
        XCTAssertTrue(warm.contains("return .askpassRefused"),
                      "a helper that supplied nothing is its own cause, not a failed password")
        XCTAssertTrue(warm.contains("if delivery == .askpass, let askpass {"),
                      "the helper's path is the only thing an askpass child is given")
        XCTAssertTrue(warm.contains("environment = [:]"),
                      "every other route inherits the environment untouched")
    }

    /// A disconnect elevates through the same door the connect used, and it may
    /// not fall back to a dialog on a path where none can be answered.
    func testTheTeardownElevatesThroughTheSameHelper() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let teardown = try body(of: "private func terminateWithElevation(")
        XCTAssertTrue(teardown.contains("askpass: askpass"),
                      "a teardown that forgets the helper fails on a Mac with `pam_tid`")
        XCTAssertTrue(code.contains("private var askpass: String?"),
                      "the helper has to be remembered for the teardown to reuse it")
    }

    /// The log may not claim the app sent a password the helper is the one
    /// reading, and it may not fall silent about a credential that did move.
    func testTheLogNamesWhichProgramSuppliesTheAdministratorPassword() throws {
        let logging = try body(of: "private static func logAdminPassword(")
        XCTAssertTrue(logging.contains("case .askpass:"))
        XCTAssertTrue(logging.contains("supplied by the askpass helper"))
        XCTAssertTrue(logging.contains("case .standardInput?:"))
        XCTAssertTrue(logging.contains("log.logSend(\"Admin password (for sudo)\", value: password)"))
        XCTAssertTrue(logging.contains("case nil:"))
        // The value itself is never logged on the helper's route: that process
        // read the Keychain, this one never had the password.
        let askpassCase = try XCTUnwrap(logging.range(of: "case .askpass:"))
        let nextCase = try XCTUnwrap(logging.range(of: "case .standardInput?:",
                                                 range: askpassCase.upperBound..<logging.endIndex))
        XCTAssertFalse(logging[askpassCase.lowerBound..<nextCase.lowerBound].contains("value: password"),
                       "the askpass log line must not carry the value")
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

    /// The connect must never *choose* the strategy that cannot ask.
    ///
    /// That is the whole `Failed - Elevation Expired` defect in one line: the app
    /// probed `sudo -n -v` in its own process and, on a warm answer, told the plan
    /// not to prompt. `sudo` keys its timestamp to the parent process when there
    /// is no terminal, so the answer said nothing about the record the `sudo`
    /// would actually find. It found a cold one, exited with its marker, and the
    /// connect died on a timestamp the app had just measured as warm.
    ///
    /// Handling the strategy is a different thing from selecting it: `ElevationStrategy`
    /// still has the case, and the warm-up on the agent path has to answer for it.
    /// What must not happen is a connect that resolves to it.
    func testTheConnectStrategyIsNeverTheOneThatCannotAsk() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertFalse(code.contains("= .neverPrompt"),
                       "connect must never choose the strategy that cannot ask")
        XCTAssertFalse(code.contains("ElevationStrategy.neverPrompt"),
                       "…nor name it outside the `case` that handles it")
        XCTAssertFalse(code.contains("SudoProbe"),
                       "no probe outside the plan may decide the strategy")
        XCTAssertFalse(code.contains("timestampWarm"),
                       "warmth is not an input to the decision any more")
        XCTAssertTrue(code.contains("let strategy = elevation ?? .storedPassword"),
                      "a connect with no strategy must use the one that can ask")
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
        XCTAssertTrue(launch.contains("hostsCleanupStep(elevation"),
                      "the plan must still remove stale entries")
        XCTAssertFalse(launch.contains("func hostsCleanupPlan"),
                       "no caller, no plan builder")
    }

    // MARK: - Helpers

    /// The text of one function, from its declaration to the next declaration at
    /// the same indentation. The nearest one, not the first pattern that matches.
    private func body(of function: String) throws -> Substring {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let start = try XCTUnwrap(code.range(of: function), "\(function) not found")
        let rest = code[start.upperBound...]
        let anchors = ["\n    func ", "\n    private func ", "\n    private static func ",
                       "\n    static func ", "\n    public func "]
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
