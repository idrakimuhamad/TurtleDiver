import XCTest
import Darwin
import Foundation

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Drives the built agent as an unprivileged child process, with no VPN.
///
/// This is the committed form of the throwaway spike that proved the mechanism
/// on this machine before any of it was wired to a tunnel: one authenticated
/// start, then a stop in milliseconds with no dialog and a provably cold `sudo`
/// timestamp. What is asserted here is the part that does not need privilege —
/// the channel, the process group, and the credential path.
///
/// The agent is built by `swift test` because the test target depends on the
/// executable target (`Package.swift`). Its absence is a failure, not a skip:
/// a skip here would quietly remove the only end-to-end check of the protocol.
final class TunnelAgentProcessTests: XCTestCase {

    private var scratch: URL!
    /// A tunnel stand-in started by the agent, killed on the way out however the
    /// test ended — the suite must not leave a process behind on this machine.
    private var startedChild: Int32?

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tdagent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
    }

    override func tearDownWithError() throws {
        if let pid = startedChild, pid > 1 { _ = kill(pid, SIGKILL) }
        startedChild = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Locating and building what to drive

    private var repoRoot: URL {
        // …/Tests/TurtleDiverCoreTests/TunnelAgentProcessTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var agentURL: URL {
        repoRoot.appendingPathComponent(".build/debug/TurtleDiverAgent")
    }

    /// A stand-in for openconnect: **always a symlink, never a copy.**
    ///
    /// Two reasons, both measured on this machine. A copied platform-signed
    /// binary run from a writable path is killed by the kernel (`Killed: 9`), so
    /// a copy cannot stand in for anything. And the agent's rule is about the
    /// path's last component, so a *symlink* named `openconnect` exercises
    /// exactly the check the real launch goes through — while `/bin/sleep` gives
    /// the test a process that stays alive until the agent ends it.
    private func makeStandIn(named name: String = "openconnect",
                             pointingAt target: String = "/bin/sleep",
                             in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target)
        return url
    }

    /// A stand-in for openconnect that reports the environment it was given.
    ///
    /// A shell script rather than a symlink, because what is under test here is
    /// what the *tunnel* can see. It is not a copy of a signed binary, so AMFI
    /// has no opinion about it.
    private func makeStandInScript(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("openconnect")
        try "#!/bin/sh\necho \"<CHILD-PATH>$PATH</CHILD-PATH>\" >&2\n/usr/bin/sleep 180\n"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - The tests

    /// `--path` exists because the agent is started as root by an app, and the
    /// search path a tunnel needs (`vpn-slice`, `sed`) is not the one an app has.
    /// The agent replaces the child's `PATH` with the one it is given, and leaves
    /// it alone when it is not given one — both asserted here, because a tunnel
    /// that cannot find its helpers fails in a way that shows up as a broken
    /// route table rather than as a missing program.
    func testTheAgentGivesTheTunnelTheSearchPathItWasGiven() throws {
        let standIn = try makeStandInScript(in: scratch)
        let agent = try AgentDriver(agent: agentURL,
                                    arguments: ["--credential-lines", "1",
                                                "--path", "/nonexistent/bin",
                                                standIn.path, "180"])
        agent.send("PIN-placeholder")
        startedChild = try XCTUnwrap(agent.supervisedPid(within: 5))

        // The closing tag is what makes this deterministic: waiting for the
        // opening one would read a line that is still arriving.
        XCTAssertTrue(agent.awaitError(containing: "</CHILD-PATH>", within: 10),
                      "the tunnel never reported its path")
        XCTAssertTrue(agent.errors.contains("<CHILD-PATH>/nonexistent/bin</CHILD-PATH>"),
                      "the tunnel got the wrong path: \(agent.errors)")

        agent.closeInput()
        _ = agent.awaitExit(within: 15)
    }

    func testTheAgentLeavesThePathAloneWhenItIsNotGivenOne() throws {
        let standIn = try makeStandInScript(in: scratch)
        let agent = try AgentDriver(agent: agentURL,
                                    arguments: ["--credential-lines", "1", standIn.path, "180"])
        agent.send("PIN-placeholder")
        startedChild = try XCTUnwrap(agent.supervisedPid(within: 5))

        XCTAssertTrue(agent.awaitError(containing: "</CHILD-PATH>", within: 10),
                      "the tunnel never reported its path")
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        XCTAssertFalse(inherited.isEmpty, "this test host has no PATH to inherit")
        XCTAssertTrue(agent.errors.contains("<CHILD-PATH>\(inherited)</CHILD-PATH>"),
                      "the tunnel did not inherit the path: \(agent.errors)")

        agent.closeInput()
        _ = agent.awaitExit(within: 15)
    }

    /// The app's own argument builder has to produce an argument list this agent
    /// accepts.
    ///
    /// Every other test in this file spells the agent's arguments by hand, and
    /// that is exactly how a live connect came to fail: the app put the agent's
    /// flags where `sudo` reads its *own* options, `sudo` answered
    /// `unrecognized option '--credential-lines'`, and no test had ever fed what
    /// the app builds to the real binary. This one does: it builds the arguments
    /// with `TunnelAgentChannel.Launch.agentArguments` and starts the agent with
    /// them. It is the smallest check that would have caught that failure.
    func testTheArgumentsTheAppBuildsAreArgumentsTheAgentAccepts() throws {
        let standIn = try makeStandIn(in: scratch)
        let built = TunnelAgentChannel.Launch.agentArguments(
            agentPath: agentURL.path,
            openconnectPath: standIn.path,
            tunnelArguments: ["180"],
            searchPath: TunnelAgentChannel.Launch.searchPath(inherited: nil)
        )
        // The first element is the agent's own argv[0], and `Process` supplies
        // argv[0] from the executable URL — the same way the app's own launch
        // gives `sudo` its `-n` as argv[1].
        let agent = try AgentDriver(agent: agentURL, arguments: Array(built.dropFirst()))
        // The same two lines the app's credential block carries, because the
        // agent reads them before it starts anything: a block that ends early
        // starts nothing, and a test that sent one line would be measuring that
        // instead of the arguments.
        agent.send("PIN-placeholder")
        agent.send("account-password-placeholder")

        startedChild = agent.supervisedPid(within: 5)
        if startedChild == nil {
            // The agent's own words are the diagnosis: a refusal says what it
            // refused, and silence says the arguments were never the problem.
            XCTFail("the agent did not start from \(built) — stdout: \(agent.output) stderr: \(agent.errors)")
            agent.closeInput()
            _ = agent.awaitExit(within: 15)
            return
        }
        XCTAssertFalse(agent.output.contains("refused"),
                       "the agent refused what the app builds: \(agent.output)")

        agent.closeInput()
        _ = agent.awaitExit(within: 15)
    }

    func testTheAgentStartsTheTunnelAndSaysSo() throws {
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "2", standIn.path, "180"])
        agent.send("PIN-placeholder")
        agent.send("VPN-pw-placeholder")

        let greeting = try XCTUnwrap(agent.awaitLine(within: 5), "the agent announced nothing")
        XCTAssertTrue(greeting.hasPrefix(TunnelAgentWord.supervisingPrefix), greeting)
        let pid = try XCTUnwrap(Int32(greeting.dropFirst(TunnelAgentWord.supervisingPrefix.count)))
        startedChild = pid

        // It really is a running process, started by the agent.
        XCTAssertTrue(OpenConnectProcess.isRunning(pid: pid))
        XCTAssertEqual(OpenConnectProcess.commandName(pid: pid)
                        .map { ($0 as NSString).lastPathComponent }, "openconnect")
    }

    func testTheVerbEndsTheTunnelAndTheAgentExitsClean() throws {
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "2", standIn.path, "180"])
        agent.send("PIN-placeholder")
        agent.send("VPN-pw-placeholder")

        let pid = try XCTUnwrap(agent.supervisedPid(within: 5))
        startedChild = pid

        agent.send(TunnelAgent.stopVerb)
        let answer = try XCTUnwrap(agent.awaitLine(within: 15))
        XCTAssertEqual(answer, TunnelAgentWord.stopped(pid))

        XCTAssertEqual(agent.awaitExit(within: 10), TunnelAgent.ExitCode.ok.rawValue)
        XCTAssertFalse(childIsAlive(pid), "the tunnel outlived the stop")
        XCTAssertEqual(agent.output,
                       TunnelAgentWord.supervising(pid) + "\n" + TunnelAgentWord.stopped(pid) + "\n",
                       "the agent wrote more than the two words it owes")
        XCTAssertTrue(agent.errors.isEmpty, "the agent wrote to the log stream: \(agent.errors)")
    }

    func testTheTunnelGetsItsOwnProcessGroup() throws {
        // The agent signals the *group*, so that openconnect's helpers
        // (vpn-slice and whatever it spawns) go with it. That is only safe if
        // the group is one the agent created: if the tunnel shared the agent's
        // own group, ending it would end the agent, and if it shared the app's,
        // ending it could take the app down with it.
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "1", standIn.path, "180"])
        agent.send("PIN-placeholder")

        let pid = try XCTUnwrap(agent.supervisedPid(within: 5))
        startedChild = pid

        let group = getpgid(pid)
        XCTAssertEqual(group, pid, "the tunnel did not lead its own process group")
        XCTAssertNotEqual(group, getpgrp(), "the tunnel shares the test runner's group")
        XCTAssertNotEqual(group, getpgid(agent.process.processIdentifier), "the tunnel shares the agent's group")
    }

    func testTheTunnelRunsAsWhoeverTheAgentRunsAs() throws {
        // The agent does not re-elevate anything. Under a user it starts a
        // tunnel owned by that user; run through `sudo` it starts a root-owned
        // tunnel, which is the property the spike measured with a root-owned
        // decoy and a cold sudo timestamp.
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "1", standIn.path, "180"])
        agent.send("PIN-placeholder")

        let pid = try XCTUnwrap(agent.supervisedPid(within: 5))
        startedChild = pid

        XCTAssertEqual(ProcessOwner.name(of: pid), NSUserName())
    }

    func testTheOneVerbStillWorksAfterARefusal() throws {
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "1", standIn.path, "180"])
        agent.send("PIN-placeholder")
        let pid = try XCTUnwrap(agent.supervisedPid(within: 5))
        startedChild = pid

        // Every one of these is a line a lenient reader would have honoured. The
        // tunnel must survive all of them, and the channel must stay usable.
        for line in ["stop ", "STOP", "Stop", "stop\r", "stop now", "stop;kill -9 \(pid)",
                     String(repeating: "x", count: TunnelAgent.maximumLineBytes + 512), ""] {
            agent.send(line)
            XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 10)), TunnelAgentWord.refused,
                           "\(line.prefix(20).debugDescription) was not refused")
            XCTAssertTrue(childIsAlive(pid), "\(line.prefix(20).debugDescription) ended the tunnel")
        }

        agent.send(TunnelAgent.stopVerb)
        XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 15)), TunnelAgentWord.stopped(pid))
        XCTAssertEqual(agent.awaitExit(within: 10), TunnelAgent.ExitCode.ok.rawValue)
        XCTAssertFalse(childIsAlive(pid))
    }

    func testEndOfInputEndsTheTunnel() throws {
        // The app's death is the backstop: nothing has to be sent for the tunnel
        // to end, so a quit that cannot run its own teardown still leaves no
        // orphaned tunnel behind.
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "1", standIn.path, "180"])
        agent.send("PIN-placeholder")
        let pid = try XCTUnwrap(agent.supervisedPid(within: 5))
        startedChild = pid

        agent.closeInput()
        XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 10)), TunnelAgentWord.peerGone)
        XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 10)), TunnelAgentWord.finished)
        XCTAssertEqual(agent.awaitExit(within: 10), TunnelAgent.ExitCode.ok.rawValue)
        XCTAssertFalse(childIsAlive(pid), "the tunnel outlived the end of the channel")
    }

    func testACredentialBlockThatEndsEarlyStartsNothing() throws {
        // A tunnel that has not received its credentials must never be started,
        // and the agent must say so instead of waiting for input that is not
        // coming.
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "3", standIn.path, "180"])
        agent.send("PIN-placeholder")
        agent.send("VPN-pw-placeholder")
        agent.closeInput()

        XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 10)), TunnelAgentWord.credentialsTruncated)
        XCTAssertEqual(agent.awaitExit(within: 10), TunnelAgent.ExitCode.credentialsTruncated.rawValue)
        XCTAssertNil(startedChild)
        XCTAssertEqual(agent.output, TunnelAgentWord.credentialsTruncated + "\n",
                       "a tunnel was announced without a complete credential block")
    }

    func testACommandThatIsNotOpenconnectIsRefused() throws {
        // The rule that keeps the agent from being a general way to run something
        // as root. `/bin/sleep` is absolute and harmless, and it is still refused
        // because it is not an openconnect.
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "1", "/bin/sleep", "180"])
        agent.send("PIN-placeholder")

        XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 10)), TunnelAgentWord.refusedCommand)
        XCTAssertEqual(agent.awaitExit(within: 10), TunnelAgent.ExitCode.cannotStart.rawValue)
        XCTAssertEqual(agent.output, TunnelAgentWord.refusedCommand + "\n")
    }

    func testACommandWithNoUsableArgumentsIsRefused() throws {
        for arguments in [[String](), ["--credential-lines"], ["--credential-lines", "2"],
                          ["--credential-lines", "0", "/opt/homebrew/bin/openconnect"],
                          ["--credential-lines", "not-a-number", "/opt/homebrew/bin/openconnect"],
                          ["--credential-lines", "99", "/opt/homebrew/bin/openconnect"]] {
            let agent = try AgentDriver(agent: agentURL, arguments: arguments)
            agent.closeInput()
            XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 10)), TunnelAgentWord.refusedUsage,
                           "\(arguments) was accepted")
            XCTAssertEqual(agent.awaitExit(within: 10), TunnelAgent.ExitCode.usage.rawValue)
            XCTAssertEqual(agent.output, TunnelAgentWord.refusedUsage + "\n",
                           "\(arguments) wrote more than the refusal")
        }
    }

    func testTheCredentialsReachTheTunnelAndNeverTheChannel() throws {
        // Two properties at once, and the second is the reason the agent redirects
        // the tunnel's standard output to the log stream. If the tunnel inherited
        // the channel, whatever openconnect printed would arrive where the app is
        // parsing words — and a stand-in that prints is the only way to see it.
        // The spike missed this: its stand-in printed nothing.
        //
        // `/bin/cat` echoes its standard input, so the credentials coming back out
        // on the log stream is proof they were delivered to the tunnel's standard
        // input, and the channel staying clean is proof they went nowhere else.
        let standIn = try makeStandIn(pointingAt: "/bin/cat", in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "2", standIn.path])
        agent.send("PIN-CANARY-placeholder")
        agent.send("VPN-CANARY-placeholder")

        let greeting = try XCTUnwrap(agent.awaitLine(within: 10))
        XCTAssertTrue(greeting.hasPrefix(TunnelAgentWord.supervisingPrefix), greeting)
        agent.closeInput()
        _ = agent.awaitExit(within: 10)

        XCTAssertEqual(agent.errors, "PIN-CANARY-placeholder\nVPN-CANARY-placeholder\n",
                       "the tunnel did not receive the credential block on its standard input")
        XCTAssertFalse(agent.output.contains("CANARY"),
                       "a credential reached the channel: \(agent.output)")
    }

    func testTheTunnelsOwnOutputDoesNotReachTheChannel() throws {
        let standIn = try makeStandIn(pointingAt: "/bin/cat", in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "1", standIn.path])
        agent.send("PRINTED-BY-THE-TUNNEL")
        _ = try XCTUnwrap(agent.awaitLine(within: 10))
        agent.closeInput()
        _ = agent.awaitExit(within: 10)

        XCTAssertTrue(agent.errors.contains("PRINTED-BY-THE-TUNNEL"),
                      "the tunnel's output did not reach the log stream")
        XCTAssertFalse(agent.output.contains("PRINTED-BY-THE-TUNNEL"),
                       "the tunnel wrote onto the channel the app parses")
    }

    func testAnOverLongLineDoesNotGrowTheAgent() throws {
        // The rule that an over-long line is refused is asserted above. What this
        // adds is the reason the reader is written the way it is: a refused line
        // must not be *held* first. An agent that buffered the whole line before
        // deciding would let whoever writes to the pipe decide how much memory a
        // root process uses — and the length check happens after the read.
        let standIn = try makeStandIn(in: scratch)
        let agent = try AgentDriver(agent: agentURL, arguments: ["--credential-lines", "1", standIn.path, "180"])
        agent.send("PIN-placeholder")
        let pid = try XCTUnwrap(agent.supervisedPid(within: 5))
        startedChild = pid

        let agentPid = agent.process.processIdentifier
        let baseline = try XCTUnwrap(residentKilobytes(of: agentPid))
        // One line, no newline until the end of it: 64 MB that must never be kept.
        agent.send(String(repeating: "x", count: 64 * 1024 * 1024))
        XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 30)), TunnelAgentWord.refused)
        let grown = try XCTUnwrap(residentKilobytes(of: agentPid))

        XCTAssertLessThan(grown - baseline, 8 * 1024,
                          "the reader held the line: \(baseline) kB → \(grown) kB")

        // And the channel is still usable, which is what the refusal promises.
        agent.send(TunnelAgent.stopVerb)
        XCTAssertEqual(try XCTUnwrap(agent.awaitLine(within: 15)), TunnelAgentWord.stopped(pid))
        XCTAssertEqual(agent.awaitExit(within: 10), TunnelAgent.ExitCode.ok.rawValue)
    }

    // MARK: - Helpers

    /// The agent's resident size, from `ps`. A delta between two readings a
    /// fraction of a second apart, not an absolute figure: what is asserted is
    /// that 64 MB of input did not become 64 MB of the agent's memory.
    private func residentKilobytes(of pid: Int32) -> Int? {
        guard let result = try? SystemBoundedProcessRunner().run(
            executable: ProcessOwner.ps,
            arguments: ["-o", "rss=", "-p", "\(pid)"],
            timeout: ProcessOwner.timeout
        ), !result.timedOut else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A zombie is not a running tunnel, which is exactly the distinction the
    /// agent has to make: the child is its own child, so it stays visible to
    /// `kill(pid, 0)` until it is reaped.
    private func childIsAlive(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return false }
        return OpenConnectProcess.isRunning(pid: pid)
    }
}

/// Drives the agent over pipes with bounded waits.
///
/// Every read is bounded and the output descriptor is non-blocking, so a protocol
/// bug shows up as a failed assertion rather than a suite that never finishes.
private final class AgentDriver {
    let process = Process()
    private let input = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private var buffer: [UInt8] = []
    private(set) var output = ""
    private(set) var errors = ""
    private var atEndOfOutput = false

    init(agent: URL, arguments: [String]) throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: agent.path),
                      "the agent was not built at \(agent.path) — swift test builds it via the test target's dependency")
        process.executableURL = agent
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        // Non-blocking reads: `read` then answers EAGAIN rather than waiting for
        // a word that may never come.
        _ = fcntl(outputPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
        _ = fcntl(errorPipe.fileHandleForReading.fileDescriptor, F_SETFL, O_NONBLOCK)
    }

    /// Waits for the tunnel's own log to say something. Read while the agent is
    /// still running, which `awaitExit` cannot do: it only drains the log stream
    /// once the process is gone.
    func awaitError(containing needle: String, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            _ = drainErrors()
            if errors.contains(needle) { return true }
            if !process.isRunning { _ = drainErrors(); return errors.contains(needle) }
            if Date() >= deadline { return false }
            usleep(2_000)
        }
    }

    @discardableResult
    private func drainErrors() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(errorPipe.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
        guard count > 0 else { return false }
        errors += String(decoding: chunk[0..<count], as: UTF8.self)
        return true
    }

    func send(_ line: String) {
        input.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    func closeInput() {
        try? input.fileHandleForWriting.close()
    }

    /// The pid from the agent's own announcement, recorded so a failed test still
    /// leaves nothing running.
    func supervisedPid(within seconds: TimeInterval) -> Int32? {
        guard let line = awaitLine(within: seconds),
              line.hasPrefix(TunnelAgentWord.supervisingPrefix) else { return nil }
        return Int32(line.dropFirst(TunnelAgentWord.supervisingPrefix.count))
    }

    /// The next word, or `nil` at end of input or on timeout.
    @discardableResult
    func awaitLine(within seconds: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let line = takeLine() { return line }
            if atEndOfOutput { break }
            drain()
            if Date() >= deadline { break }
            usleep(2_000)
        }
        _ = drain()
        return takeLine()
    }

    func awaitExit(within seconds: TimeInterval) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !process.isRunning { break }
            usleep(2_000)
        }
        guard !process.isRunning else { return nil }
        // The pipes are finished once the process is gone.
        output += String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        errors += String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        atEndOfOutput = true
        return process.terminationStatus
    }

    @discardableResult
    private func drain() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(outputPipe.fileHandleForReading.fileDescriptor, &chunk, chunk.count)
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
            output += String(decoding: chunk[0..<count], as: UTF8.self)
            return true
        }
        if count == 0 { atEndOfOutput = true }
        return false
    }

    private func takeLine() -> String? {
        guard let index = buffer.firstIndex(of: 0x0A) else { return nil }
        let line = String(decoding: buffer[0..<index], as: UTF8.self)
        buffer.removeFirst(index + 1)
        return line
    }
}
