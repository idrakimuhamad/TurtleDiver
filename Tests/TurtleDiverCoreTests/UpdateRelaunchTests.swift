import XCTest
@testable import TurtleDiverSystem

/// The command that reopens the app after it has replaced its own bundle.
///
/// What is asserted here is the shape of that command, because the shape is the
/// safety: the pid and the bundle path travel as *arguments* and the script is a
/// constant, so no path can ever become shell text, and the wait is bounded so a
/// pid that outlives it cannot leave a shell spinning.
final class UpdateRelaunchTests: XCTestCase {

    private let app = URL(fileURLWithPath: "/Applications/TurtleDiver.app")

    // MARK: - The command

    func testTheWaiterWatchesThisProcessAndThenOpensTheBundle() throws {
        let plan = UpdateRelaunch.plan(pid: 4711, appURL: app)

        XCTAssertEqual(plan.executable.path, "/bin/sh")
        XCTAssertEqual(plan.arguments.count, 5)
        XCTAssertEqual(plan.arguments[0], "-c")
        XCTAssertEqual(plan.arguments[2], "sh", "the script's own $0")
        XCTAssertEqual(plan.pid, "4711")
        XCTAssertEqual(plan.appPath, "/Applications/TurtleDiver.app")

        // It has to wait for *this* process, and it has to open the app itself.
        XCTAssertTrue(plan.script.contains("kill -0 \"$pid\""), plan.script)
        XCTAssertTrue(plan.script.contains("open -a \"$app\""), plan.script)
    }

    /// The pid and the path are arguments, so neither may appear in the script.
    /// A script built by interpolation is a script a path can add a command to.
    func testTheScriptIsAConstantThatMentionsNeitherThePidNorThePath() {
        let plan = UpdateRelaunch.plan(pid: 4711, appURL: app)

        XCTAssertFalse(plan.script.contains("4711"), plan.script)
        XCTAssertFalse(plan.script.contains("/Applications"), plan.script)
        XCTAssertFalse(plan.script.contains("TurtleDiver.app"), plan.script)
    }

    func testAPathFullOfShellMetacharactersIsPassedThroughAsAnArgument() throws {
        let hostile = URL(fileURLWithPath: "/Users/someone/My \"Apps\"; rm -rf ~/TurtleDiver.app")
        let plan = UpdateRelaunch.plan(pid: 12, appURL: hostile)

        XCTAssertEqual(plan.appPath, hostile.path, "the path must survive verbatim")
        XCTAssertFalse(plan.script.contains("rm -rf"), "the path must never become script text")
        XCTAssertFalse(plan.script.contains("My"), "not even a fragment of it")
        // The only thing the script ever quotes is the variable that holds it.
        XCTAssertTrue(plan.script.contains("\"$app\""), plan.script)
    }

    /// The wait has to end on its own. Sixty seconds of tenths, and the shell
    /// gives up rather than waiting on a pid that will never go away.
    func testTheWaitIsBoundedAndGivesUpRatherThanSpinningForever() {
        let plan = UpdateRelaunch.plan(pid: 1, appURL: app)

        XCTAssertEqual(UpdateRelaunch.waitTicks, 600)
        XCTAssertEqual(UpdateRelaunch.tickSeconds, 0.1)
        XCTAssertTrue(plan.script.contains("600"), plan.script)
        XCTAssertTrue(plan.script.contains("exit 0"), "the bound must end the script, not loop on")
        XCTAssertTrue(plan.script.contains("sleep 0.1"), plan.script)
        // The bound is what makes the waiting shell finite, so it must be short
        // enough to be a bound and long enough to outlast any quit.
        let bound = Double(UpdateRelaunch.waitTicks) * UpdateRelaunch.tickSeconds
        XCTAssertLessThanOrEqual(bound, 60)
        XCTAssertGreaterThanOrEqual(bound, 10)
    }

    /// `exec`, so the wait does not leave a second shell behind for the lifetime
    /// of the app it opens.
    func testTheShellReplacesItselfRatherThanSittingBehindTheApp() {
        let plan = UpdateRelaunch.plan(pid: 1, appURL: app)
        XCTAssertTrue(plan.script.contains("exec open -a"), plan.script)
    }

    /// Not `/usr/bin/env sh`, and not a shell found on the user's `PATH`.
    func testTheShellIsNamedByPath() {
        XCTAssertEqual(UpdateRelaunch.shell.path, "/bin/sh")
        XCTAssertTrue(UpdateRelaunch.shell.isFileURL)
    }

    // MARK: - Starting it

    func testTheLauncherIsHandedExactlyThePlanAndIsNotWaitedFor() throws {
        let launcher = RecordingLauncher()
        try UpdateRelaunch(launcher: launcher).relaunch(pid: 9001, appURL: app)

        XCTAssertEqual(launcher.plans, [UpdateRelaunch.plan(pid: 9001, appURL: app)])
        XCTAssertEqual(launcher.plans.count, 1)
    }

    /// A waiter that cannot start has to reach the caller: the app quits only
    /// once something is arranged to reopen it.
    func testALauncherThatCannotStartIsAnErrorTheCallerSees() {
        let launcher = RecordingLauncher(failure: UpdateRelaunchError.launchFailed("no fork today"))
        XCTAssertThrowsError(try UpdateRelaunch(launcher: launcher).relaunch(pid: 9001, appURL: app)) {
            guard case .launchFailed(let detail)? = $0 as? UpdateRelaunchError else {
                return XCTFail("expected a launch failure, got \($0)")
            }
            XCTAssertEqual(detail, "no fork today")
        }
        XCTAssertEqual((UpdateRelaunchError.launchFailed("x").errorDescription ?? "").isEmpty, false)
    }

    /// The real launcher starts a real `/bin/sh`. The command is harmless by
    /// construction: the pid is one that cannot be running and the bundle does
    /// not exist, so the shell gives up on `open` and exits.
    func testTheRealLauncherStartsAShellThatExitsOnItsOwn() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("turtle-relaunch-\(UUID().uuidString)")
            .appendingPathComponent("TurtleDiver.app")
        let plan = UpdateRelaunch.plan(pid: Int32.max, appURL: missing)
        XCTAssertNoThrow(try DetachedProcessLauncher().launchDetached(plan))
    }

    // MARK: - Fakes

    private final class RecordingLauncher: ProcessLaunching, @unchecked Sendable {
        private let lock = NSLock()
        private let failure: Error?
        private var launched: [RelaunchPlan] = []

        init(failure: Error? = nil) { self.failure = failure }

        var plans: [RelaunchPlan] {
            lock.lock()
            defer { lock.unlock() }
            return launched
        }

        func launchDetached(_ plan: RelaunchPlan) throws {
            if let failure { throw failure }
            lock.lock(); launched.append(plan); lock.unlock()
        }
    }
}
