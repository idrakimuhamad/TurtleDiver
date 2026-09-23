import XCTest

@testable import TurtleDiverCLIKit
import TurtleDiverCore
import TurtleDiverSystem

/// What a connect does on a machine that exempts the agent command from
/// authentication — the setup that lets one run with nobody at the machine while
/// Touch ID still guards every other use of `sudo`.
///
/// The whole decision rests on one question, `sudo -n -l <agent>`, so these tests
/// are about the answers to it. Every answer that is not an unmistakable yes has
/// to be read as the ordinary case, because the two mistakes are not equal: an
/// unnecessary refresh costs a prompt, and a skipped refresh costs a failed
/// launch after the caller has been told nothing was needed.
final class CLIUnattendedTests: XCTestCase {

    private let agentPath = "/usr/local/libexec/turtlediver-agent"

    // MARK: - Reading the machine's answer

    func testAnExemptAgentCommandNeedsNoAuthentication() {
        let sudo = FakeBoundedProcess(
            exitStatus: 0,
            stdout: "Matching Defaults entries for someone on this host:\n"
                + "    !authenticate\n\n"
                + "User someone may run the following commands on this host:\n"
                + "    (root) \(agentPath)\n"
        )
        XCTAssertEqual(
            ConnectCommand.launchAuthentication(agentPath: agentPath, runner: sudo),
            .notRequired
        )
        // A question, not an attempt: nothing here may authenticate, pipe a
        // password or ask for one.
        XCTAssertEqual(sudo.calls.count, 1)
        XCTAssertEqual(sudo.calls[0].arguments, ["-n", "-l", agentPath])
        XCTAssertEqual(sudo.calls[0].executable.path, "/usr/bin/sudo")
    }

    func testAnOrdinaryMachineNeedsAuthentication() {
        // Measured on this Mac for a user with no exemption: exit 1, and the
        // sentence on stderr that says why.
        let sudo = FakeBoundedProcess(exitStatus: 1, stderr: "sudo: a password is required\n")
        XCTAssertEqual(
            ConnectCommand.launchAuthentication(agentPath: agentPath, runner: sudo),
            .required
        )
    }

    func testSuccessWithoutTheCommandInTheAnswerIsNotPermission() {
        // A `sudo` that exits 0 for some other reason must not be read as an
        // exemption: the direction of the mistake is the one that hurts.
        let sudo = FakeBoundedProcess(exitStatus: 0, stdout: "")
        XCTAssertEqual(
            ConnectCommand.launchAuthentication(agentPath: agentPath, runner: sudo),
            .required
        )
    }

    func testAnUnansweredProbeIsTheOrdinaryCase() {
        let sudo = FakeBoundedProcess(exitStatus: 0, stdout: agentPath, timedOut: true)
        XCTAssertEqual(
            ConnectCommand.launchAuthentication(agentPath: agentPath, runner: sudo),
            .required
        )
    }

    func testAProbeThatCannotRunIsTheOrdinaryCase() {
        let sudo = FakeBoundedProcess(fails: true)
        XCTAssertEqual(
            ConnectCommand.launchAuthentication(agentPath: agentPath, runner: sudo),
            .required
        )
    }

    // MARK: - Saying what the answer means

    func testTheExemptionNotesSkipTheRefreshAndSaySoFirst() {
        let lines = ConnectCommand.exemptionNotes(hasPassword: false)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("needs no authentication"), lines[0])
        XCTAssertTrue(lines[0].contains("not refreshed"), lines[0])
        XCTAssertTrue(lines[0].contains("no prompt"), lines[0])
    }

    func testAnOfferedPasswordIsNotReadWhenNothingWouldReadIt() throws {
        // The caller offered a door; the machine needs none. Reading it would
        // raise a Keychain dialog for a value that is then thrown away, which is
        // exactly what the no-op `disconnect` was fixed for.
        let lines = ConnectCommand.exemptionNotes(hasPassword: true)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("was not read"), lines[1])
    }

    // MARK: - The interface that has to carry the recipe

    func testTheHelpNamesBothUnattendedRoutes() {
        // The refusal points here, so this text is the shipped half of the
        // remedy: a caller who is told their password cannot be used has to be
        // able to find out what to do instead.
        let help = TurtleDiverCLI.usageText
        XCTAssertTrue(help.contains("Unattended connects"), "the help has no such section")
        XCTAssertTrue(help.contains("!authenticate"), "the help does not give the rule")
        XCTAssertTrue(help.contains("/etc/sudoers.d/turtlediver"), "the help does not name the file")
        XCTAssertTrue(help.contains("pam_tid"), "the help does not name the other route")
        XCTAssertTrue(help.contains("sudo visudo -f"), "the help does not say how to write it safely")
    }

    func testTheDocsDescribeTheUnattendedRoutes() throws {
        let docs = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/CLI.md"),
            encoding: .utf8
        )
        XCTAssertTrue(docs.contains("!authenticate"), "docs/CLI.md does not give the rule")
        XCTAssertTrue(docs.contains("/etc/sudoers.d/turtlediver"), "docs/CLI.md does not name the file")
        XCTAssertTrue(docs.contains("sudo -n -l"), "docs/CLI.md does not say how it is detected")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// A `sudo` that answers the policy question and starts nothing.
///
/// The real one is never asked: what is under test is how each answer is read,
/// including the ones a healthy machine never gives.
private final class FakeBoundedProcess: BoundedProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executable: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let result: BoundedProcessResult?
    private let launchFailure: Bool

    init(
        exitStatus: Int32 = 0,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false,
        fails: Bool = false
    ) {
        result = BoundedProcessResult(
            terminationStatus: exitStatus,
            timedOut: timedOut,
            stdout: stdout,
            stderr: stderr
        )
        launchFailure = fails
    }

    var calls: [Call] { lock.withLock { recorded } }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult {
        lock.withLock { recorded.append(Call(executable: executable, arguments: arguments, timeout: timeout)) }
        if launchFailure { throw BoundedProcessError.launchFailed("sudo is not there") }
        return result ?? BoundedProcessResult(
            terminationStatus: 0,
            timedOut: false,
            stdout: "",
            stderr: ""
        )
    }
}
