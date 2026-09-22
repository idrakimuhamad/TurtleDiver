import XCTest
import Foundation
import TurtleDiverCore

/// Structure pins for the agent path in `VPNManager`.
///
/// Commit B replaces the connect's *step*, not the connect: the tail after the
/// launch — the pipes, the readability handlers, the timers, the termination
/// handler — is shared by both shapes, and it is where the core of the VPN
/// lives. These pins exist because the failures they describe are silent ones:
/// a channel closed a moment too early ends the tunnel just started, and a
/// success check that lives in only one handler stops noticing the tunnel on the
/// path that redirects its output.
///
/// They assert structure, not values, and they are written as what they are. The
/// behaviour behind them is pinned by `TunnelAgentChannelTests` (the app's half),
/// `TunnelAgentProcessTests` (the agent's half) and the launch plans in
/// `TunnelAgentProtocolTests`.
final class TunnelAgentWiringTests: XCTestCase {

    // MARK: - Which shape a connect uses

    /// The agent is used when it verifies, and not otherwise — but "not
    /// otherwise" is a fallback, never a refusal to connect. An app that stopped
    /// connecting because a helper it cannot trust is present would turn a
    /// security check into an outage.
    func testTheAgentIsUsedOnlyWhenItVerifiesAndSomethingElseIsFallenBackTo() throws {
        let connect = try body(of: "private func executeVPNConnection() async {")
        XCTAssertTrue(
            connect.contains("switch await Self.agentAvailability()"),
            "the availability check must be awaited: it runs `codesign` off the main thread"
        )
        XCTAssertTrue(connect.contains("guard let agentLaunch = await prepareAgentLaunch("),
                      "the agent shape must be prepared before it is used")
        // Two arms fall back to the wrapper, and one of them must say why.
        let fallbacks = connect.components(separatedBy: "launch = wrapperLaunch(").count - 1
        XCTAssertEqual(fallbacks, 2, "both the missing agent and the refused one must fall back")
        XCTAssertTrue(connect.contains("case .refused(let why):"), "the refusal must be named")
        XCTAssertTrue(connect.contains("log.write(\"Agent not used: \\(why)\")"),
                      "a refused agent must be reported, not silently skipped")
        XCTAssertTrue(connect.contains("self.debugOutput += \"WARN: \\(why)\\n\""),
                      "a refused agent must be visible to the user")

        // …and the refusal must not end the attempt. A `return` in that arm would
        // turn the security check into an outage: nothing would be launched at
        // all, and the log would say only that the app did not like a file.
        let refusal = try XCTUnwrap(
            slice(from: "case .refused(let why):", to: "\n        }\n", in: String(connect)),
            "the refusal arm is gone"
        )
        XCTAssertTrue(refusal.contains("launch = wrapperLaunch("),
                      "the refusal must fall back to the wrapper")
        XCTAssertFalse(refusal.contains("return"),
                       "a refused agent must not end the connect")
    }

    /// The launch is a value, so there is one copy of the connect tail. A second
    /// `Process()` for the agent path would drift from the first within a release.
    func testBothShapesAreLaunchedThroughTheSameTail() throws {
        let connect = try connectBody()
        XCTAssertTrue(connect.contains("proc.executableURL = launch.executable"))
        XCTAssertTrue(connect.contains("proc.arguments = launch.arguments"))
        XCTAssertFalse(connect.contains("/bin/bash"), "the launch executable must come from the shape")
    }

    /// The `-n` on the agent is what turns a cold timestamp into an error instead
    /// of a dialog. Only the wrapper may carry `-S`, and only for its own sudo.
    func testTheAgentIsLaunchedUnattended() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let agent = try XCTUnwrap(
            slice(from: "static func agent(", to: "private func wrapperLaunch(", in: code),
            "the agent launch factory is gone"
        )
        XCTAssertTrue(agent.contains("TunnelAgentChannel.Launch.sudoArguments"),
                      "the agent must be started through the argv builder that adds `-n`")
        XCTAssertFalse(agent.contains("\"-S\""), "the agent authenticates nothing and must never get `-S`")
        XCTAssertTrue(agent.contains("keepsInputOpen: true"),
                      "the agent's channel stays open for the tunnel's lifetime")
    }

    // MARK: - The pipe

    /// The measured fact behind this pin: the app closes `inputPipe` right after
    /// writing the credentials, which was correct while a wrapper read them. The
    /// agent reads until end of input and *then* ends the tunnel, so the same
    /// close on this path kills the tunnel at birth — in about the time it takes
    /// to write two lines.
    func testOnlyTheWrapperLetsGoOfItsInput() throws {
        let connect = try connectBody()
        let publication = try XCTUnwrap(
            connect.range(of: "self.agentChannelInput = inPipe"),
            "the agent's pipe must be held: a deallocated Pipe closes both of its descriptors"
        )
        let closeIsGuarded = try XCTUnwrap(
            connect.range(of: "if !launch.keepsInputOpen {"),
            "the close must be conditional on the shape"
        )
        let close = try XCTUnwrap(
            connect.range(of: "inPipe.fileHandleForWriting.close()"),
            "the close is gone"
        )
        XCTAssertLessThan(closeIsGuarded.lowerBound, close.lowerBound,
                          "the close must be inside the guard, not before it")
        // The publication is in the *other* arm, and after the credentials are on
        // the pipe: the agent reads commands after the credential block, so a
        // `stop` written before it would be consumed as a credential line.
        XCTAssertGreaterThan(publication.lowerBound, close.lowerBound,
                             "the channel is published before the credentials are on it")
    }

    // MARK: - Noticing that the tunnel came up

    /// The main risk this commit carries to the core VPN function.
    ///
    /// The success check used to live in the standard-output handler alone, which
    /// was right while the app launched `bash` itself — openconnect's output
    /// arrived there. The agent redirects its child's output to its *own* stderr,
    /// so on that path the same lines arrive on the other pipe. If the check
    /// lived in only one handler again, the agent path would connect and never be
    /// noticed as connected.
    func testTheSuccessCheckIsOneFunctionThatBothStreamsCall() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertTrue(code.contains("private func noteTunnelSignals("), "the shared check is gone")
        XCTAssertEqual(
            code.components(separatedBy: "self.noteTunnelSignals(").count - 1, 2,
            "exactly one call from each stream handler"
        )
        let stdoutHandler = try XCTUnwrap(code.range(of: "log.logStream(\"STDOUT\", data: data)"),
                                         "the stdout handler is gone")
        let stderrHandler = try XCTUnwrap(code.range(of: "log.logStream(\"STDERR\", data: data)"),
                                          "the stderr handler is gone")
        let firstCall = try XCTUnwrap(code.range(of: "self.noteTunnelSignals(output, log: log, source: \"STDOUT\")"))
        let secondCall = try XCTUnwrap(code.range(of: "self.noteTunnelSignals(cleanLine, log: log, source: \"STDERR\")"))
        XCTAssertLessThan(stdoutHandler.lowerBound, firstCall.lowerBound)
        XCTAssertLessThan(stderrHandler.lowerBound, secondCall.lowerBound)
        XCTAssertLessThan(firstCall.lowerBound, secondCall.lowerBound,
                          "the calls must be in the two different handlers, in file order")
    }

    /// The six strings appear once, in the list the shared function reads. A
    /// second copy is how the old shape comes back.
    func testTheSuccessSignalsAreListedOnce() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        for signal in ["Established DTLS", "ESP session established", "Connected as",
                       "CSTP connected", "Configured as", "Got CONNECT response"] {
            XCTAssertEqual(
                code.components(separatedBy: "\"\(signal)\"").count - 1, 1,
                "\(signal) must be listed exactly once"
            )
        }
    }

    /// It acts once. The first signal wins; a second word from the same tunnel
    /// must not restart the duration timer or write a second history row.
    func testNoticingTheTunnelIsIdempotent() throws {
        let body = try body(of: "private func noteTunnelSignals(_ text: String, log: VpnConnectionLogger, source: String) {")
        let guardAt = try XCTUnwrap(body.range(of: "guard case .connecting = status else { return }"),
                                    "the idempotence guard is gone")
        let statusAt = try XCTUnwrap(body.range(of: "status = .connected"))
        XCTAssertLessThan(guardAt.lowerBound, statusAt.lowerBound,
                          "the guard must come before the state change")
    }

    /// The agent's stdout carries words, not tunnel output. Decoding it as the
    /// tunnel's output would feed the protocol into the user's log and could
    /// match a success signal that nothing established.
    func testTheAgentStreamIsDecodedAndNotTreatedAsTunnelOutput() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let stdoutHandler = try XCTUnwrap(code.range(of: "outPipe.fileHandleForReading.readabilityHandler"),
                                          "the stdout handler is gone")
        let rest = code[stdoutHandler.upperBound...]
        let branch = try XCTUnwrap(rest.range(of: "if launch.keepsInputOpen {"), "the agent branch is gone")
        let agentCall = try XCTUnwrap(rest.range(of: "self.handleAgentChannel(data: data, log: log)"),
                                      "the agent's stream is not decoded")
        XCTAssertLessThan(branch.lowerBound, agentCall.lowerBound)
        // The `return` is what keeps the agent's words out of the tunnel path.
        let upToReturn = rest[agentCall.upperBound...]
        let returned = try XCTUnwrap(upToReturn.range(of: "return"), "the agent branch must not fall through")
        let tunnelPath = try XCTUnwrap(upToReturn.range(of: "debugOutput"),
                                       "the tunnel-output path follows the agent branch")
        XCTAssertLessThan(returned.lowerBound, tunnelPath.lowerBound)
    }

    // MARK: - The elevation steps

    /// The whole reason for this design: `sudo` records its timestamp against the
    /// parent process when there is no terminal, so every step that authenticates
    /// has to be a direct child of the app. A wrapper shell here would warm the
    /// wrapper's record and leave the app's cold — which is the defect that made
    /// the disconnect prompt for a password.
    func testEveryElevationStepIsADirectChildThatRunsOffTheMainThread() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let runner = try body(of: "private static func runSudoStep(")
        XCTAssertTrue(runner.contains("DispatchQueue.global(qos: .userInitiated).async"),
                      "`codesign` and a Touch ID dialog must never run on the main thread")
        XCTAssertTrue(runner.contains("TunnelAgentChannel.SudoStepRunner().run("))
        // The availability check runs two `codesign` processes, so it may not run
        // in the middle of the connect's UI work either.
        let availability = try body(of: "private static func agentAvailability() async")
        XCTAssertTrue(availability.contains("DispatchQueue.global(qos: .userInitiated).async"))
        XCTAssertTrue(availability.contains("TunnelAgentChannel.Verifier.check()"))
        // Both steps go through it, so neither can bypass the off-main hop.
        XCTAssertTrue(code.contains("let cleanup = await Self.runSudoStep("))
        XCTAssertTrue(code.contains("let result = await Self.runSudoStep("))
        let prepare = try body(of: "private func prepareAgentLaunch(")
        XCTAssertFalse(prepare.contains("/bin/bash"),
                       "the agent path must not introduce a wrapper shell")
    }

    /// The one authentication at connect goes through the plan that matches the
    /// strategy, and its input is `/dev/null` when there is nothing to pipe —
    /// an empty pipe is not the same thing as no input.
    func testTheWarmupUsesThePlanForItsStrategy() throws {
        let warm = try body(of: "private func warmElevation(")
        XCTAssertTrue(warm.contains("TunnelAgentChannel.Launch.warmupArguments(strategy)"))
        XCTAssertTrue(warm.contains("TunnelAgentChannel.Launch.warmupInput(strategy, adminPassword: password)"))
        XCTAssertTrue(warm.contains("stdin: input.isEmpty ? nil : input"),
                      "empty input must mean /dev/null, not a pipe nobody writes")
        // Every strategy that fails gets a reason a user can act on.
        for reason in ["systemPromptUnanswered", "storedPasswordRejected", "timestampExpired"] {
            XCTAssertTrue(warm.contains(reason), "\(reason) is not reported")
        }
    }

    /// The credential block carries two labels and no administrator password —
    /// it is the only thing the app ever writes down the channel, and it stays
    /// open for hours.
    func testTheChannelCarriesOnlyThePinAndTheAccountPassword() throws {
        let prepare = try body(of: "private func prepareAgentLaunch(")
        XCTAssertTrue(prepare.contains("TunnelAgentChannel.Launch.credentialBlock("),
                      "the block must be built by the tested builder")
        XCTAssertTrue(prepare.contains("pin: pin,"))
        XCTAssertTrue(prepare.contains("vpnPassword: settings.vpnPassword"))
        XCTAssertFalse(prepare.contains("Data((pin"), "the block must not be assembled inline")
    }

    // MARK: - The agent's words

    func testEveryWordTheAgentCanSayIsAccountedFor() throws {
        let body = try body(of: "private func handleAgentChannel(data: Data, log: VpnConnectionLogger) {")
        for event in [".supervising(let pid)", ".stopped(let pid), .killed(let pid)", ".stubborn(let pid)",
                      ".peerGone, .finished", ".refused(let word)", ".unrecognised(let bytes)"] {
            XCTAssertTrue(body.contains("case \(event)"), "\(event) is not handled")
        }
        XCTAssertTrue(body.contains("recordOwnTunnelPid(pid)"),
                      "the pid the agent names is the one worth recording")
        XCTAssertTrue(body.contains("agentDiagnosis = diagnosis"),
                      "a refusal must become a diagnosis the termination handler can report")
        XCTAssertTrue(body.contains("agentDecoder.consume(data)"),
                      "the stream must be decoded by the tested decoder")
    }

    /// A refusal is a diagnosis an exit status cannot carry: exit 4 is "the agent
    /// would not start that", which is not something to show a user.
    func testAnAgentRefusalBecomesAStatusWithADetail() throws {
        let handler = try body(of: "private func handleAgentChannel(data: Data, log: VpnConnectionLogger) {")
        XCTAssertTrue(handler.contains("TunnelAgentChannel.diagnosis(forRefusal: word)"))
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let branch = try XCTUnwrap(
            slice(from: "if let diagnosis = self.agentDiagnosis {",
                  to: "\n                }",
                  in: code),
            "the termination handler does not report the agent's own reason"
        )
        XCTAssertTrue(branch.contains("self.status = .error(diagnosis.historyStatus)"))
        XCTAssertTrue(branch.contains("self.logFailedAttempt(status: diagnosis.historyStatus)"),
                      "a refused connect must leave a history row that says why")
    }

    // MARK: - Helpers

    /// The connect itself, up to the point where the launch shapes are declared.
    ///
    /// Deliberately not `body(of:)`: the shape factories that follow are at the
    /// same indentation inside a `struct`, which is not one of the anchors, so a
    /// body slice would run on into them and an assertion about "the connect does
    /// not do X" would be answered by code that is not the connect.
    // MARK: - Ending the tunnel through the agent

    /// A disconnect asks the agent before it looks at the process table.
    ///
    /// The order is the whole point of the agent: it owns the tunnel as root, so
    /// asking it is what makes a disconnect need no elevation at all. But the
    /// scan still runs after it, and it is still what decides — a word on a pipe
    /// can never by itself produce a "Disconnected".
    func testTheTeardownAsksTheAgentBeforeItLooksAtTheProcessTable() throws {
        let detect = try body(of: "private func detectTunnelForTeardown() async -> ExistingConnectionDetection {")
        let asked = try XCTUnwrap(detect.range(of: "await askAgentToStop("), "the agent was never asked")
        let scanned = try XCTUnwrap(detect.range(of: "ExistingConnectionScanner.detect("),
                                    "the process table stopped being consulted")
        XCTAssertLessThan(asked.lowerBound, scanned.lowerBound,
                          "the tunnel was resolved before the agent was asked to end it")
        XCTAssertTrue(detect.contains("debugOutput += stop.explanation"),
                      "what the agent said never reaches the log")
    }

    /// The wait that follows a disconnect runs off the main thread.
    ///
    /// The spike measured the answer at about twenty milliseconds, but a wait is
    /// a wait: a disconnect that held the window for five seconds on a loaded
    /// machine would be the responsiveness bug this path was rebuilt to avoid.
    func testTheDisconnectsWaitDoesNotRunOnTheMainThread() throws {
        let ask = try body(of: "private func askAgentToStop(")
        XCTAssertTrue(ask.contains("DispatchQueue.global(qos: .userInitiated).async"),
                      "the bounded wait runs on the main thread")
        XCTAssertTrue(ask.contains("continuation.resume(returning: box.wait(within: seconds))"),
                      "the wait is somewhere else than where the bound says")
    }

    /// A quit asks the agent *before* it signals the agent, and before it stops
    /// reading the channel.
    ///
    /// Both orderings are load-bearing. A signalled agent cannot run the code
    /// that would end its tunnel — its child leads a process group of its own and
    /// outlives it — and an answer written back to a pipe nobody is reading would
    /// never be seen, which is the difference between a quit that reports what
    /// happened and one that reports a timeout.
    func testTheQuitAsksTheAgentBeforeAnythingElseHappens() throws {
        let cleanup = try body(of: "func cleanupOnTermination() {")
        let asked = try XCTUnwrap(cleanup.range(of: "AgentStopOutcome.request(to: channel"),
                                   "the quit never asks the agent")
        let signalled = try XCTUnwrap(cleanup.range(of: "proc.terminate()"))
        let stoppedReading = try XCTUnwrap(cleanup.range(of: "readabilityHandler = nil"))
        XCTAssertLessThan(asked.lowerBound, signalled.lowerBound,
                          "the agent was signalled before it was asked to end its tunnel")
        XCTAssertLessThan(asked.lowerBound, stoppedReading.lowerBound,
                          "the answer had nowhere left to arrive")
        XCTAssertTrue(cleanup.contains("agentStopBox.wait(within: Self.agentStopQuitGraceSeconds)"),
                      "the quit's wait is not the bounded one")
    }

    /// The verb is built in one place, and the box is the only thing that waits.
    func testTheVerbHasOneBuilderAndEveryWaitIsBounded() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertEqual(code.components(separatedBy: "TunnelAgentChannel.Launch.stopRequest()").count - 1, 1,
                       "the verb is spelled at more than one call site")
        XCTAssertFalse(code.contains("\"stop\\n\""), "the verb is a literal again")
        XCTAssertEqual(code.components(separatedBy: "func wait(within seconds: TimeInterval)").count - 1, 1,
                       "there is more than one wait to keep bounded")
        XCTAssertTrue(code.contains("if Date() >= deadline { return .unanswered(seconds) }"),
                      "the wait has no deadline, or one that does not report itself")
    }

    /// What the agent says is recorded from its own words, on both the paths that
    /// mean the tunnel ended.
    func testTheAnswerComesFromTheAgentsOwnWords() throws {
        let handler = try body(of: "private func handleAgentChannel(data: Data, log: VpnConnectionLogger) {")
        XCTAssertTrue(handler.contains("case .stopped(let pid), .killed(let pid):"))
        XCTAssertTrue(handler.contains("case .stubborn(let pid):"))
        XCTAssertTrue(handler.contains("case .peerGone, .finished:"))
        XCTAssertEqual(handler.components(separatedBy: "agentStopBox.record(.stopped)").count - 1, 2,
                       "the verb's answer and the channel's end must both release the wait")
        XCTAssertTrue(handler.contains("agentStopBox.record(.stubborn)"),
                      "a tunnel that would not stop must not be recorded as stopped")
    }

    /// The pipe becomes the channel only once the credentials are on it, and only
    /// once a broken pipe can no longer kill the app.
    ///
    /// The agent reads commands *after* the credential block, so a `stop` written
    /// in the window between the launch and the credentials would be consumed as
    /// a credential line — the tunnel would start with a replaced PIN. The
    /// descriptor is marked first so that a write to a channel whose far end has
    /// already gone is an error and not a fatal signal.
    func testTheChannelIsPublishedOnlyAfterTheCredentialsAreOnIt() throws {
        let connect = try connectBody()
        let written = try XCTUnwrap(connect.range(of: "write(contentsOf: launch.input)"))
        let marked = try XCTUnwrap(connect.range(of: "ignoreBrokenPipe(on: inPipe"))
        let published = try XCTUnwrap(connect.range(of: "self.agentChannelInput = inPipe"))
        XCTAssertLessThan(written.lowerBound, marked.lowerBound, "the channel was marked before it was fed")
        XCTAssertLessThan(marked.lowerBound, published.lowerBound,
                          "the channel was published before it was safe to write to")
    }

    /// One attempt's channel is not the next attempt's, and a channel is let go
    /// when the tunnel it was the handle on is gone.
    func testAChannelBelongsToOneAttemptAndIsReleasedWithItsTunnel() throws {
        let connect = try connectBody()
        XCTAssertTrue(connect.contains("self.agentStopBox.clear()"),
                      "a new attempt would read the previous one's answer")
        XCTAssertTrue(connect.contains("self.agentChannelInput = nil"),
                      "a new attempt would hold the previous tunnel's channel open")
        XCTAssertTrue(try strippedCode(at: "VPNConnect/VPNManager.swift")
            .contains("Released the tunnel agent's channel"),
                      "a channel outlives the tunnel it was the handle on")
    }

    /// The two bounds, which are the difference between a disconnect that asks
    /// the agent and one that waits on it.
    ///
    /// A finite bound is not enough: the spike measured the answer at about
    /// twenty milliseconds, so five seconds is already fifty times the cost and
    /// one second is the same statement made for a quit that runs on the main
    /// thread. A bound in the minutes would satisfy "it always ends" while being
    /// exactly the hang this path exists to avoid.
    func testTheWaitsAreBoundedBySecondsNotByHope() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertTrue(code.contains("private static let agentStopGraceSeconds: TimeInterval = 5"),
                      "the disconnect's bound changed")
        XCTAssertTrue(code.contains("private static let agentStopQuitGraceSeconds: TimeInterval = 1"),
                      "the quit's bound changed")
    }

    /// A log line is a claim about what happened, and this one used to name a
    /// process that was not the one started: the agent path runs `/usr/bin/sudo`
    /// directly, and the log said "bash". A live connect is diagnosed from this
    /// file, so a line that misnames the child sends the reader the wrong way —
    /// it did exactly that while the `--credential-lines` refusal was being
    /// tracked down.
    func testTheLaunchLogNamesTheProcessItActuallyStarted() throws {
        let body = try connectBody()
        XCTAssertTrue(body.contains("[INIT] \\(launch.executable.lastPathComponent) process started"),
                      "the launch log no longer names the executable it started")
        XCTAssertFalse(body.contains("bash process started"),
                       "the launch log claims a bash process on every shape")
    }

    /// The administrator password is not on the agent's channel, and in
    /// `.systemPrompt` mode it is not sent anywhere at all — the system's dialog
    /// answers. Logging it as sent either way is a claim about a credential that
    /// never moved.
    func testTheAdministratorPasswordIsLoggedOnlyWhenItIsSent() throws {
        let prepare = try body(of: "private func prepareAgentLaunch(")
        XCTAssertTrue(prepare.contains("logAdminPassword("),
                      "the agent path logs the administrator password without asking whether it is sent")
        XCTAssertFalse(prepare.contains("logSend(\"Admin password"),
                       "the agent path logs the administrator password as sent")
    }

    private func connectBody() throws -> Substring {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        return try XCTUnwrap(
            slice(from: "private func executeVPNConnection() async {",
                  to: "private struct TunnelLaunch",
                  in: code),
            "the connect is gone"
        )
    }

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

    private func slice(from start: String, to end: String, in code: String) -> Substring? {
        guard let startRange = code.range(of: start),
              let endRange = code.range(of: end, range: startRange.upperBound..<code.endIndex) else { return nil }
        return code[startRange.lowerBound..<endRange.lowerBound]
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
