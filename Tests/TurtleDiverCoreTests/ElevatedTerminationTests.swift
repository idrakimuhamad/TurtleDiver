import XCTest
@testable import TurtleDiverSystem

/// Ending a tunnel that belongs to root.
///
/// The defect behind this file: the connect elevates (the launch runs `sudo
/// openconnect …`), so the `openconnect` is root-owned and *every* signal this
/// user sends is refused with `EPERM`. `disconnect()` tried once as the user,
/// failed silently, and set the status to `.disconnected` anyway — a live tunnel
/// reported as a finished one. The user saw exactly that: a root-owned
/// `openconnect` still running after a Disconnect, and still running after a
/// quit, with the app claiming it had ended the tunnel both times.
///
/// So the tests here are about two things that must both hold: a root-owned
/// process can be ended through the same elevation the connect used, and nothing
/// is ever signalled as root until the target is verified to still be *this*
/// app's launch. Every process interaction is injected, so no test signals
/// anything (except the two at the end, which run `/bin/cat` and a busy loop).
final class ElevatedTerminationTests: XCTestCase {

    /// A pid that only ever appears in a fake process table.
    private let tunnelPid: Int32 = 4242
    /// The group the connect recorded, which holds the wrapper, the `sudo` and
    /// the `openconnect`.
    private let tunnelGroup: Int32 = 4240
    /// Some other group, i.e. this app's own.
    private let ownGroup: Int32 = 900

    // MARK: - The plan: what actually runs

    func testAWarmTimestampSendsTheSignalAsRootWithoutReadingAnything() throws {
        let plan = try XCTUnwrap(ElevatedTermination.plan(
            pid: tunnelGroup,
            isProcessGroup: true,
            signal: .terminate,
            strategy: .warmTimestamp,
            adminPassword: nil,
            ownProcessGroup: ownGroup
        ))

        XCTAssertEqual(plan.executable, ElevatedTermination.sudo)
        XCTAssertEqual(plan.arguments, ["-n", "/bin/kill", "-TERM", "-4240"])
        XCTAssertNil(plan.stdin, "`-n` never reads, so it must not be handed a pipe")
        XCTAssertFalse(plan.pipesTheStoredPassword)
    }

    /// The password is the one thing that must never be an argument: a process's
    /// argv is world-readable through `ps` in the same way this app reads it.
    func testTheStoredPasswordGoesDownThePipeAndNeverIntoTheArguments() throws {
        let password = "correct-horse-battery"
        let plan = try XCTUnwrap(ElevatedTermination.plan(
            pid: tunnelPid,
            isProcessGroup: false,
            signal: .terminate,
            strategy: .storedPassword,
            adminPassword: password,
            ownProcessGroup: ownGroup
        ))

        XCTAssertEqual(plan.arguments, ["-S", "/bin/kill", "-TERM", "4242"])
        XCTAssertEqual(plan.stdin, password + "\n")
        XCTAssertTrue(plan.pipesTheStoredPassword)
        for argument in plan.arguments {
            XCTAssertFalse(argument.contains(password), "the password must never be an argument")
        }
    }

    /// On a `pam_tid` Mac the asking form has no `-S`: nothing may pipe a
    /// password, and no `-n` either — that form exists precisely to fail fast.
    func testTheFormThatAsksCarriesNoInputSoSudoCannotWaitOnAPipe() throws {
        let plan = try XCTUnwrap(ElevatedTermination.plan(
            pid: tunnelPid,
            isProcessGroup: false,
            signal: .kill,
            strategy: .systemPrompt,
            adminPassword: nil,
            ownProcessGroup: ownGroup
        ))

        XCTAssertEqual(plan.arguments, ["/bin/kill", "-KILL", "4242"])
        XCTAssertNil(plan.stdin, "the dialog is raised by the system from inside PAM, not by this app writing a pipe")
    }

    /// An empty stored password is a missing one. The plan must degrade to the
    /// form that asks rather than run `sudo -S` with a newline for a password.
    func testAStoredPasswordThatIsMissingFallsBackToTheFormThatAsks() throws {
        for password: String? in [nil, ""] {
            let plan = try XCTUnwrap(ElevatedTermination.plan(
                pid: tunnelPid,
                isProcessGroup: false,
                signal: .terminate,
                strategy: .storedPassword,
                adminPassword: password,
                ownProcessGroup: ownGroup
            ))
            XCTAssertEqual(plan.arguments, ["/bin/kill", "-TERM", "4242"])
            XCTAssertNil(plan.stdin)
        }
    }

    func testThePlanRefusesAPidThatIsNotAProcess() {
        for pid: Int32 in [-1, 0, 1] {
            XCTAssertNil(ElevatedTermination.plan(
                pid: pid, isProcessGroup: true, signal: .terminate,
                strategy: .warmTimestamp, adminPassword: nil, ownProcessGroup: ownGroup
            ), "pid \(pid) must never reach a kill")
            XCTAssertNil(ElevatedTermination.plan(
                pid: pid, isProcessGroup: false, signal: .kill,
                strategy: .systemPrompt, adminPassword: nil, ownProcessGroup: ownGroup
            ))
        }
    }

    /// A group kill of this app's own group would take the app down with the
    /// tunnel. A *pid* that happens to equal the group number is a different
    /// thing, and is allowed.
    func testThePlanRefusesThisAppsOwnProcessGroupButNotAMatchingPid() {
        XCTAssertNil(ElevatedTermination.plan(
            pid: ownGroup, isProcessGroup: true, signal: .terminate,
            strategy: .warmTimestamp, adminPassword: nil, ownProcessGroup: ownGroup
        ))
        XCTAssertNotNil(ElevatedTermination.plan(
            pid: ownGroup, isProcessGroup: false, signal: .terminate,
            strategy: .warmTimestamp, adminPassword: nil, ownProcessGroup: ownGroup
        ))
    }

    // MARK: - Ending it

    func testTheGroupIsSignalledAsRootRatherThanThePid() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { plan in
            if plan.arguments.last == "-4240" { tunnel.running = false }
            return .success
        }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .group(tunnelGroup),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.arguments, ["-n", "/bin/kill", "-TERM", "-4240"],
                       "the whole launch is one group; signalling only the pid orphans the wrapper and the sudo")
    }

    func testAProcessThatSurvivesTheTermIsKilled() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { plan in
            if plan.arguments.contains("-KILL") { tunnel.running = false }
            return .success
        }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["-n", "/bin/kill", "-TERM", "4242"],
            ["-n", "/bin/kill", "-KILL", "4242"]
        ])
    }

    /// The verdict is the liveness check, never `sudo`'s exit status: a `sudo`
    /// that reports success for a `kill` of a pid that is somehow still there is
    /// not a reason to tell the user the tunnel is down.
    func testASuccessfulKillIsNotTakenAsProofThatTheTunnelEnded() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { _ in .success }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        guard case .stillRunning(let detail) = outcome else {
            return XCTFail("expected an honest failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("4242"), detail)
        XCTAssertTrue(tunnel.running)
    }

    func testAFailedSudoIsReportedWithWhatItSaid() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { _ in
            BoundedProcessResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "sudo: a password is required\n"
            )
        }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        guard case .stillRunning(let detail) = outcome else {
            return XCTFail("expected an honest failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("exited 1"), detail)
        XCTAssertTrue(detail.contains("a password is required"), detail)
    }

    func testASudoThatCouldNotBeRunAtAllIsStillAnHonestFailure() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.thrown = BoundedProcessError.launchFailed("no such file")

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        guard case .stillRunning(let detail) = outcome else {
            return XCTFail("expected an honest failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("Could not run the command"), detail)
        XCTAssertTrue(tunnel.running, "a command that never ran must not be reported as having ended anything")
    }

    /// The silence-first rule: a stored password is not fed to `sudo` when the
    /// timestamp was already warm — and not when the silent attempt was enough,
    /// so this also pins that the stronger form is not spent needlessly.
    func testAWarmTimestampIsTriedBeforeTheStoredPasswordIsSpent() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { plan in
            if plan.arguments.contains("-n") { tunnel.running = false }
            return .success
        }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .storedPassword,
            adminPassword: "correct-horse-battery",
            mayPrompt: true
        )

        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(runner.calls.count, 1, "the password must not be fed to a sudo that had nothing left to do")
        XCTAssertEqual(runner.calls.first?.arguments.first, "-n")
        XCTAssertNil(runner.calls.first?.stdin)
    }

    /// And when the silent attempt is not enough, the strategy's own form is
    /// what gets the second turn.
    func testAColdTimestampFallsBackToTheStoredPassword() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { plan in
            if plan.arguments.first == "-S" { tunnel.running = false }
            return BoundedProcessResult(terminationStatus: 1, timedOut: false, stdout: "", stderr: "sudo: a password is required\n")
        }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .storedPassword,
            adminPassword: "correct-horse-battery",
            mayPrompt: true
        )

        XCTAssertEqual(outcome, .ended)
        XCTAssertEqual(runner.calls.map { $0.arguments.first }, ["-n", "-S"])
        XCTAssertEqual(runner.calls.last?.stdin, "correct-horse-battery\n")
    }

    /// The quit path. It may not raise a dialog — a dialog nothing answers is
    /// what leaves a blocked root `sudo` behind — so every command it builds has
    /// to be the form that cannot ask.
    func testTheQuitPathBuildsOnlyCommandsThatCannotRaiseADialog() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { _ in
            BoundedProcessResult(terminationStatus: 1, timedOut: false, stdout: "", stderr: "sudo: a password is required\n")
        }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .group(tunnelGroup),
            openConnectPid: tunnelPid,
            strategy: .systemPrompt,
            adminPassword: "correct-horse-battery",
            mayPrompt: false
        )

        XCTAssertFalse(runner.calls.isEmpty)
        for plan in runner.calls {
            XCTAssertEqual(plan.arguments.first, "-n", "the quit may only use the form that never prompts: \(plan.arguments)")
            XCTAssertNil(plan.stdin, "and it must not fall back to piping a password on a pam_tid Mac")
        }
        guard case .stillRunning(let detail) = outcome else {
            return XCTFail("expected an honest failure, got \(outcome)")
        }
        XCTAssertTrue(detail.contains("may not ask"), "the log must say which door was shut: \(detail)")
    }

    /// The same caller *with* permission builds the asking form instead — this
    /// is the Disconnect path, where a person is there and asked for it.
    func testTheDisconnectPathMayUseTheFormThatAsks() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { _ in
            BoundedProcessResult(terminationStatus: 1, timedOut: false, stdout: "", stderr: "sudo: 1 incorrect password attempt\n")
        }

        _ = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .systemPrompt,
            adminPassword: nil,
            mayPrompt: true
        )

        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["-n", "/bin/kill", "-TERM", "4242"],
            ["/bin/kill", "-TERM", "4242"],
            ["-n", "/bin/kill", "-KILL", "4242"],
            ["/bin/kill", "-KILL", "4242"]
        ])
    }

    /// A stored password must not reach the failure detail. Only arguments are
    /// ever quoted, and only the arguments are what a `sudo` complaint is about.
    func testTheFailureDetailNeverQuotesTheStoredPassword() {
        let password = "correct-horse-battery"
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { _ in
            BoundedProcessResult(
                terminationStatus: 1,
                timedOut: false,
                stdout: "",
                stderr: "sudo: 1 incorrect password attempt\n"
            )
        }

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .storedPassword,
            adminPassword: password,
            mayPrompt: true
        )

        guard case .stillRunning(let detail) = outcome else {
            return XCTFail("expected an honest failure, got \(outcome)")
        }
        XCTAssertFalse(detail.contains(password), "the detail is written to the debug log: \(detail)")
    }

    /// Every plan the terminator sends is given the same bound. An unbounded
    /// elevated command is exactly what the §7 failure was.
    func testEveryElevatedCommandIsBounded() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        runner.answer = { _ in .success }

        _ = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        XCTAssertFalse(runner.timeouts.isEmpty)
        for timeout in runner.timeouts {
            XCTAssertGreaterThan(timeout, 0)
            XCTAssertLessThanOrEqual(timeout, ElevatedTermination.timeout)
            XCTAssertLessThanOrEqual(timeout, 60, "no elevated command may be given an open-ended deadline")
        }
    }

    // MARK: - Never signalling the wrong thing

    /// pids and groups are recycled, and the record can be from a previous run.
    /// A group is only signalled as root while it still lists this tunnel's pid.
    func testAGroupThatNoLongerHoldsTheTunnelIsNeverSignalled() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        tunnel.members = [9999, 9998]
        let runner = ScriptedElevatedRunner()

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .group(tunnelGroup),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        guard case .refused(let reason) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no longer holds"), reason)
        XCTAssertTrue(runner.calls.isEmpty, "a stale group record must not be signalled as root")
    }

    func testAPidThatIsNotAnOpenConnectIsNeverSignalled() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        tunnel.isOpenConnect = false
        let runner = ScriptedElevatedRunner()

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        guard case .refused(let reason) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("not an openconnect"), reason)
        XCTAssertTrue(runner.calls.isEmpty, "root must not be spent on a pid that was never verified")
    }

    /// Nothing to end: the tunnel is already gone, so no privilege is asked for.
    func testAProcessThatIsAlreadyGoneIsNotSignalledAndNeedsNoPrivilege() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        tunnel.running = false
        let runner = ScriptedElevatedRunner()

        let outcome = makeTerminator(tunnel: tunnel, runner: runner).end(
            .group(tunnelGroup),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        XCTAssertEqual(outcome, .ended)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testAnImpossibleTargetIsRefusedRatherThanLookedUp() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        let runner = ScriptedElevatedRunner()
        let terminator = makeTerminator(tunnel: tunnel, runner: runner)

        for pid: Int32 in [-1, 0, 1] {
            guard case .refused = terminator.end(
                .pid(pid), openConnectPid: pid, strategy: .warmTimestamp, adminPassword: nil, mayPrompt: true
            ) else {
                return XCTFail("pid \(pid) must be refused")
            }
        }
        for pid: Int32 in [-1, 0, 1] {
            guard case .refused = terminator.end(
                .pid(pid), openConnectPid: tunnelPid, strategy: .warmTimestamp, adminPassword: nil, mayPrompt: true
            ) else {
                return XCTFail("openconnect pid \(pid) must be refused")
            }
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    /// A group kill of the app's own group would take the app with it, so the
    /// terminator refuses even though `ElevatedTermination.plan` would have.
    func testThisAppsOwnProcessGroupIsRefused() {
        let tunnel = FakeTunnel(pid: tunnelPid)
        tunnel.members = [tunnelPid]
        let runner = ScriptedElevatedRunner()

        let outcome = ElevatedTerminator(
            runner: runner,
            isRunning: { _ in true },
            isOpenConnect: { _ in true },
            groupPids: { _ in [self.tunnelPid] },
            ownProcessGroup: tunnelGroup,
            sleep: { _ in }
        ).end(
            .group(tunnelGroup),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        guard case .refused(let reason) = outcome else {
            return XCTFail("expected a refusal, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("own"), reason)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    /// A pid that never becomes a process must not turn into an unbounded wait:
    /// the whole call costs at most two settle windows.
    func testTheWaitForExitIsBounded() {
        let runner = ScriptedElevatedRunner()
        runner.answer = { _ in .success }
        let slept = Slept()

        let outcome = ElevatedTerminator(
            runner: runner,
            isRunning: { _ in true },
            isOpenConnect: { _ in true },
            groupPids: { _ in [self.tunnelPid] },
            ownProcessGroup: ownGroup,
            sleep: { slept.add($0) }
        ).end(
            .pid(tunnelPid),
            openConnectPid: tunnelPid,
            strategy: .warmTimestamp,
            adminPassword: nil,
            mayPrompt: true
        )

        guard case .stillRunning = outcome else {
            return XCTFail("expected an honest failure, got \(outcome)")
        }
        XCTAssertLessThanOrEqual(slept.total, 2 * ElevatedTerminator.settleSeconds + 0.5)
    }

    // MARK: - Who owns a pid

    func testTheOwnerIsReadFromPsByName() {
        let runner = ScriptedBoundedRunner(stdout: "root\n")
        XCTAssertEqual(ProcessOwner.name(of: tunnelPid, using: runner), "root")
        XCTAssertEqual(runner.invocations.first?.arguments, ["-o", "user=", "-p", "4242"])
        XCTAssertTrue(ProcessOwner.belongsToAnotherUser(tunnelPid, ownUserName: "someone", using: runner))
    }

    func testTheAppsOwnProcessIsNotSomebodyElses() {
        let runner = ScriptedBoundedRunner(stdout: "someone\n")
        XCTAssertEqual(ProcessOwner.name(of: tunnelPid, using: runner), "someone")
        XCTAssertFalse(ProcessOwner.belongsToAnotherUser(tunnelPid, ownUserName: "someone", using: runner))
    }

    /// An unreadable answer is not an accusation: the caller's own signal gets
    /// tried, and it will say `EPERM` for itself if the process is root's.
    func testAnUnreadableOwnerIsNotAssumedToBeRoot() {
        for stdout in ["", "   \n"] {
            let runner = ScriptedBoundedRunner(stdout: stdout)
            XCTAssertNil(ProcessOwner.name(of: tunnelPid, using: runner))
            XCTAssertFalse(ProcessOwner.belongsToAnotherUser(tunnelPid, ownUserName: "someone", using: runner))
        }

        let timedOut = ScriptedBoundedRunner(stdout: "root\n", timedOut: true)
        XCTAssertNil(ProcessOwner.name(of: tunnelPid, using: timedOut))
        XCTAssertFalse(ProcessOwner.belongsToAnotherUser(tunnelPid, ownUserName: "someone", using: timedOut))
    }

    func testTheOwnerCheckRefusesToAskAboutAnImpossiblePid() {
        let runner = ScriptedBoundedRunner(stdout: "root\n")
        for pid: Int32 in [-1, 0, 1] {
            XCTAssertNil(ProcessOwner.name(of: pid, using: runner))
            XCTAssertFalse(ProcessOwner.belongsToAnotherUser(pid, ownUserName: "someone", using: runner))
        }
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    // MARK: - The reader itself (real processes, nothing privileged)

    func testTheRealOwnerCheckNamesThisProcessesUser() {
        XCTAssertEqual(ProcessOwner.name(of: getpid()), NSUserName())
        XCTAssertFalse(ProcessOwner.belongsToAnotherUser(getpid()))
        // pid 1 is refused by the same guard that keeps it away from a `kill`,
        // so a pid file naming it cannot become a root signal either.
        XCTAssertNil(ProcessOwner.name(of: 1))
        XCTAssertFalse(ProcessOwner.belongsToAnotherUser(1))
    }

    // MARK: - The runner

    /// `sudo -S` reads the password from the pipe, so the pipe has to be real.
    func testTheRunnerFeedsStandardInputToTheChild() throws {
        let plan = ElevatedKillPlan(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            stdin: "hello\n"
        )
        let result = try SystemElevatedCommandRunner().run(plan, timeout: 5)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.stdout, "hello\n")
    }

    func testTheRunnerReportsANonZeroExit() throws {
        let plan = ElevatedKillPlan(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo no >&2; exit 3"]
        )
        let result = try SystemElevatedCommandRunner().run(plan, timeout: 5)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.terminationStatus, 3)
        XCTAssertEqual(result.stderr, "no\n")
    }

    /// A child that never finishes is signalled and reported as timed out. The
    /// hang is driven through a script: a bare `sleep`-alike would read EOF on
    /// its standard input and exit, which is a different test.
    func testTheRunnerBoundsAChildThatNeverFinishes() throws {
        let plan = ElevatedKillPlan(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "i=0; while true; do i=$((i+1)); done"]
        )
        let result = try SystemElevatedCommandRunner().run(plan, timeout: 1)

        XCTAssertTrue(result.timedOut, "a command with no deadline is the §7 failure")
    }

    func testTheRunnerRefusesToLaunchSomethingThatIsNotThere() {
        let plan = ElevatedKillPlan(executable: URL(fileURLWithPath: "/nonexistent/not-a-tool"), arguments: [])
        XCTAssertThrowsError(try SystemElevatedCommandRunner().run(plan, timeout: 5)) { error in
            guard case BoundedProcessError.launchFailed = error else {
                return XCTFail("expected a launch failure, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    /// A process table with exactly one process in it.
    private final class FakeTunnel: @unchecked Sendable {        let pid: Int32
        var running = true
        var isOpenConnect = true
        var members: [Int32]

        init(pid: Int32) {
            self.pid = pid
            self.members = [pid]
        }
    }

    private func makeTerminator(
        tunnel: FakeTunnel,
        runner: any ElevatedCommandRunning,
        ownProcessGroup: Int32? = nil
    ) -> ElevatedTerminator {
        ElevatedTerminator(
            runner: runner,
            isRunning: { _ in tunnel.running },
            isOpenConnect: { _ in tunnel.isOpenConnect },
            groupPids: { _ in tunnel.members },
            ownProcessGroup: ownProcessGroup ?? ownGroup,
            sleep: { _ in }
        )
    }

    /// How long the terminator was told to wait, accumulated.
    private final class Slept: @unchecked Sendable {
        private var seconds: TimeInterval = 0

        var total: TimeInterval { seconds }

        func add(_ interval: TimeInterval) { seconds += interval }
    }

    private final class ScriptedElevatedRunner: ElevatedCommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [ElevatedKillPlan] = []
        private var recordedTimeouts: [TimeInterval] = []

        var answer: (ElevatedKillPlan) -> BoundedProcessResult = { _ in .success }
        var thrown: Error?

        var calls: [ElevatedKillPlan] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        var timeouts: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return recordedTimeouts
        }

        func run(_ plan: ElevatedKillPlan, timeout: TimeInterval) throws -> BoundedProcessResult {
            lock.lock()
            recorded.append(plan)
            recordedTimeouts.append(timeout)
            lock.unlock()

            if let thrown { throw thrown }
            return answer(plan)
        }
    }

    private final class ScriptedBoundedRunner: BoundedProcessRunning, @unchecked Sendable {
        struct Invocation: Equatable {
            let executable: URL
            let arguments: [String]
        }

        private let lock = NSLock()
        private var recorded: [Invocation] = []
        private let stdout: String
        private let timedOut: Bool

        init(stdout: String, timedOut: Bool = false) {
            self.stdout = stdout
            self.timedOut = timedOut
        }

        var invocations: [Invocation] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult {
            lock.lock()
            recorded.append(Invocation(executable: executable, arguments: arguments))
            lock.unlock()
            return BoundedProcessResult(
                terminationStatus: 0,
                timedOut: timedOut,
                stdout: stdout,
                stderr: ""
            )
        }
    }
}

private extension BoundedProcessResult {
    static let success = BoundedProcessResult(terminationStatus: 0, timedOut: false, stdout: "", stderr: "")
}
