import XCTest

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// The tunnel agent's channel, as logic.
///
/// The agent exists so the app authenticates **once**: the connect starts a
/// privileged process that owns `openconnect` as its own child, and every later
/// teardown is one word down a pipe — no second `sudo`, no dialog, no dependency
/// on a credential timestamp that is keyed to whichever parent happened to run
/// it (`docs/ELEVATION.md` §1a). The price of that design is that this pipe is a
/// privilege boundary: whoever writes to it can make a root process end a
/// tunnel. Everything here is an assertion about that boundary.
///
/// `TunnelAgentProcessTests` drives the built agent as a child process; this file
/// covers the rules without a process, a signal or a VPN.
final class TunnelAgentProtocolTests: XCTestCase {

    // MARK: - What the agent will accept as work

    func testTheCredentialLineCountIsBounded() throws {
        XCTAssertEqual(try TunnelAgentSession(credentialLines: 1).credentialLines, 1)
        XCTAssertEqual(try TunnelAgentSession(credentialLines: 2).credentialLines, 2)
        XCTAssertEqual(try TunnelAgentSession(credentialLines: 8).credentialLines, 8)

        // Zero is refused rather than accepted as "no credentials": an agent in
        // that state could never start a tunnel, so honouring it would mean
        // reporting success for a tunnel that was never started.
        for count in [0, -1, 9, 1000] {
            XCTAssertThrowsError(try TunnelAgentSession(credentialLines: count)) { error in
                XCTAssertEqual(error as? TunnelAgentError,
                               .credentialLineCountOutOfRange(count))
            }
        }
    }

    func testTheTunnelStartsOnlyWhenTheLastCredentialArrives() throws {
        var session = try TunnelAgentSession(credentialLines: 2)

        XCTAssertEqual(session.receive(line: "PIN-placeholder"), .credential)
        XCTAssertEqual(session.phase, .credentials(remaining: 1))
        XCTAssertEqual(session.credentials, ["PIN-placeholder"])

        XCTAssertEqual(session.receive(line: "VPN-pw-placeholder"), .start)
        XCTAssertEqual(session.phase, .commands)
        XCTAssertEqual(session.credentials, ["PIN-placeholder", "VPN-pw-placeholder"])
    }

    func testTheCredentialBlockIsKeptInOrderAndNothingElse() throws {
        var session = try TunnelAgentSession(credentialLines: 3)

        XCTAssertEqual(session.receive(line: "one"), .credential)
        XCTAssertEqual(session.receive(line: "two"), .credential)
        XCTAssertEqual(session.receive(line: "three"), .start)
        XCTAssertEqual(session.credentials, ["one", "two", "three"])
    }

    func testAnOverLongCredentialLineStopsTheAgentRatherThanBuffering() throws {
        var session = try TunnelAgentSession(credentialLines: 1)
        let huge = String(repeating: "x", count: TunnelAgent.maximumLineBytes + 1)

        XCTAssertEqual(session.receive(line: huge), .credentialsTruncated)
        XCTAssertEqual(session.phase, .finished)
    }

    func testACredentialLineExactlyAtTheLimitIsAccepted() throws {
        var session = try TunnelAgentSession(credentialLines: 1)
        let atLimit = String(repeating: "y", count: TunnelAgent.maximumLineBytes)

        XCTAssertEqual(session.receive(line: atLimit), .start)
    }

    func testEndOfInputInsideTheCredentialBlockStartsNothing() throws {
        var session = try TunnelAgentSession(credentialLines: 2)

        XCTAssertEqual(session.receive(line: "PIN-placeholder"), .credential)
        // The app died mid-block. Nothing has been started, so there is nothing
        // to stop — and the agent must not start a tunnel it has no credentials
        // for.
        XCTAssertEqual(session.receive(line: nil), .credentialsTruncated)
        XCTAssertEqual(session.phase, .finished)
        XCTAssertEqual(session.credentials, ["PIN-placeholder"])
    }

    func testEndOfInputInTheCommandPhaseEndsTheTunnel() throws {
        var session = try TunnelAgentSession(credentialLines: 1)
        XCTAssertEqual(session.receive(line: "PIN-placeholder"), .start)

        XCTAssertEqual(session.receive(line: nil), .end(.peerGone))
        XCTAssertEqual(session.phase, .finished)
    }

    // MARK: - The one verb

    func testOnlyTheExactLineIsTheVerb() throws {
        // Each of these is something a lenient reader would have accepted. The
        // channel would then be doing something the app did not ask for, on the
        // strength of a guess — so all of them are refusals, and the tunnel is
        // left exactly as it was.
        let notTheVerb = [
            "stop ",            // trailing space
            " stop",            // leading space
            "STOP",             // case
            "Stop",
            "stop\r",           // a CRLF line, whose \r is part of the line
            "stop\n",           // a second newline the reader did not take
            "stop now",         // a phrase
            "stop;kill -9 1",   // a compound command
            "stop && rm -rf /",
            "stopped",
            "stops",
            "",
            "\t",
            "stop\0"
        ]

        for line in notTheVerb {
            var session = try TunnelAgentSession(credentialLines: 1)
            XCTAssertEqual(session.receive(line: "PIN-placeholder"), .start)

            XCTAssertEqual(session.receive(line: line), .refuse, "\(line.debugDescription) was accepted")
            XCTAssertEqual(session.phase, .commands,
                           "\(line.debugDescription) ended the session instead of being refused")
        }
    }

    func testTheVerbIsAcceptedAndEndsTheSession() throws {
        var session = try TunnelAgentSession(credentialLines: 1)
        XCTAssertEqual(session.receive(line: "PIN-placeholder"), .start)

        XCTAssertEqual(session.receive(line: TunnelAgent.stopVerb), .end(.stop))
        XCTAssertEqual(session.phase, .finished)
    }

    /// The verb is not a verb until the credential block is complete.
    ///
    /// This is a fact about the *channel*, not a curiosity: the app keeps its
    /// writing end open for the life of the tunnel and writes the verb when the
    /// user disconnects, and it publishes that end only once the credentials are
    /// on it. The window is small but it is real — a disconnect pressed while a
    /// connect is still launching — and what it would cost is the PIN: `stop`
    /// would be handed to openconnect as a credential and the tunnel would start
    /// with a replaced secret, or with one line fewer than it needs.
    func testTheVerbArrivingInsideTheCredentialBlockIsJustAnotherLine() throws {
        var session = try TunnelAgentSession(credentialLines: 2)
        XCTAssertEqual(session.receive(line: TunnelAgent.stopVerb), .credential)
        XCTAssertEqual(session.credentials, [TunnelAgent.stopVerb])
        XCTAssertEqual(session.phase, .credentials(remaining: 1))

        // And it is a credential line even as the last line of the block: the
        // block is what starts the tunnel, so there is no room for a command
        // before it.
        XCTAssertEqual(session.receive(line: "VPN-pw-placeholder"), .start)
        XCTAssertEqual(session.credentials, [TunnelAgent.stopVerb, "VPN-pw-placeholder"])
        XCTAssertEqual(session.receive(line: TunnelAgent.stopVerb), .end(.stop))
    }

    func testAnOverLongLineCannotBeTruncatedIntoTheVerb() throws {
        // A reader that kept the first N bytes of an over-long line could turn a
        // 5000-byte line into `stop` if the verb happened to be at the front.
        // The length check therefore comes first, and a line over the limit is
        // refused regardless of what it starts with.
        for tail in ["stop", "", "stop stop"] {
            var session = try TunnelAgentSession(credentialLines: 1)
            XCTAssertEqual(session.receive(line: "PIN-placeholder"), .start)

            let line = "stop" + String(repeating: "z", count: TunnelAgent.maximumLineBytes) + tail
            XCTAssertEqual(session.receive(line: line), .refuse)
            XCTAssertEqual(session.phase, .commands)
        }
    }

    func testInputAfterTheEndIsRefused() throws {
        var session = try TunnelAgentSession(credentialLines: 1)
        XCTAssertEqual(session.receive(line: "PIN-placeholder"), .start)
        XCTAssertEqual(session.receive(line: TunnelAgent.stopVerb), .end(.stop))

        // A closed channel can still be written to until the writer notices.
        XCTAssertEqual(session.receive(line: TunnelAgent.stopVerb), .refuse)
        XCTAssertEqual(session.receive(line: nil), .refuse)
    }

    // MARK: - What the agent will start

    func testTheAgentOnlyStartsAnAbsoluteOpenconnect() {
        XCTAssertTrue(TunnelAgent.mayStart(command: "/opt/homebrew/bin/openconnect"))
        XCTAssertTrue(TunnelAgent.mayStart(command: "/usr/local/bin/openconnect"))
        XCTAssertTrue(TunnelAgent.mayStart(command: "/openconnect"))

        // Relative: a `PATH` lookup would let the caller's environment choose
        // which program root runs.
        XCTAssertFalse(TunnelAgent.mayStart(command: "openconnect"))
        XCTAssertFalse(TunnelAgent.mayStart(command: "./openconnect"))
        // Named something else, however suggestive: this is the rule that keeps
        // the agent from being a general way to run a command as root.
        XCTAssertFalse(TunnelAgent.mayStart(command: "/bin/sh"))
        XCTAssertFalse(TunnelAgent.mayStart(command: "/bin/kill"))
        XCTAssertFalse(TunnelAgent.mayStart(command: "/tmp/not-openconnect-at-all"))
        XCTAssertFalse(TunnelAgent.mayStart(command: "/tmp/openconnect.sh"))
        XCTAssertFalse(TunnelAgent.mayStart(command: "/tmp/openconnect "))
        XCTAssertFalse(TunnelAgent.mayStart(command: "/tmp/"))
        XCTAssertFalse(TunnelAgent.mayStart(command: ""))
    }

    func testTheAgentsRuleAgreesWithTheAppsClassification() {
        // "What the agent started" and "what the app will accept as the tunnel"
        // are the same question, asked from two sides. If these ever disagree the
        // app would refuse to adopt the tunnel its own agent started.
        for name in ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"] {
            let last = (name as NSString).lastPathComponent
            XCTAssertEqual(TunnelAgent.mayStart(command: name),
                           OpenConnectProcess.namesOpenConnect(last))
        }
    }

    func testTheInstalledNameIsNotInTheAppBundle() {
        // A payload the app execs as root must live in a root-owned directory. A
        // copy inside the bundle would be writable by the user who installed it.
        XCTAssertFalse(TunnelAgent.executableName.contains("/"))
        XCTAssertTrue(TunnelAgent.executableName.hasPrefix("turtlediver-"))
    }

    // MARK: - The loop

    func testAStopEndsTheTunnelAndReportsWhatHappened() {
        for (outcome, word) in [(TunnelAgentOutcome.stopped, TunnelAgentWord.stoppedPrefix),
                                (.killed, TunnelAgentWord.killedPrefix)] {
            let runtime = FakeRuntime(lines: ["PIN", "stop"])
            runtime.outcome = outcome
            let code = TunnelAgentLoop.run(session: try! TunnelAgentSession(credentialLines: 1),
                                           runtime: runtime)

            XCTAssertEqual(code, TunnelAgent.ExitCode.ok.rawValue)
            XCTAssertEqual(runtime.words, [TunnelAgentWord.supervising(runtime.pid), word + String(runtime.pid)])
            XCTAssertEqual(runtime.startedWith, ["PIN"])
            XCTAssertEqual(runtime.ended, [runtime.pid])
        }
    }

    func testATunnelThatWillNotStopIsNotReportedAsStopped() {
        let runtime = FakeRuntime(lines: ["PIN", "stop"])
        runtime.outcome = .stubborn
        let code = TunnelAgentLoop.run(session: try! TunnelAgentSession(credentialLines: 1),
                                       runtime: runtime)

        XCTAssertEqual(code, TunnelAgent.ExitCode.tunnelNotStopped.rawValue)
        XCTAssertEqual(runtime.words.last, TunnelAgentWord.stubborn(runtime.pid))
        // The request was made; the tunnel did not go. The app must be able to
        // tell those apart, so the exit code follows the observation.
        XCTAssertEqual(runtime.ended, [runtime.pid])
    }

    func testARefusalLeavesTheTunnelAliveAndTheChannelOpen() {
        let runtime = FakeRuntime(lines: ["PIN", "stop now", "STOP", "stop ", "stop"])
        let code = TunnelAgentLoop.run(session: try! TunnelAgentSession(credentialLines: 1),
                                       runtime: runtime)

        XCTAssertEqual(code, TunnelAgent.ExitCode.ok.rawValue)
        XCTAssertEqual(runtime.words,
                       [TunnelAgentWord.supervising(runtime.pid),
                        TunnelAgentWord.refused,
                        TunnelAgentWord.refused,
                        TunnelAgentWord.refused,
                        TunnelAgentWord.stopped(runtime.pid)])
        // Refusals must not end anything: the tunnel is ended once, by the verb.
        XCTAssertEqual(runtime.ended, [runtime.pid])
    }

    func testEndOfInputEndsTheTunnelAndSaysWhy() {
        let runtime = FakeRuntime(lines: ["PIN"])   // then end of input
        let code = TunnelAgentLoop.run(session: try! TunnelAgentSession(credentialLines: 1),
                                       runtime: runtime)

        XCTAssertEqual(code, TunnelAgent.ExitCode.ok.rawValue)
        XCTAssertEqual(runtime.words,
                       [TunnelAgentWord.supervising(runtime.pid),
                        TunnelAgentWord.peerGone,
                        TunnelAgentWord.finished])
        XCTAssertEqual(runtime.ended, [runtime.pid])
    }

    func testEndOfInputInsideTheCredentialBlockStartsNothingAtAll() {
        let runtime = FakeRuntime(lines: ["PIN"])   // one short of the block
        let code = TunnelAgentLoop.run(session: try! TunnelAgentSession(credentialLines: 2),
                                       runtime: runtime)

        XCTAssertEqual(code, TunnelAgent.ExitCode.credentialsTruncated.rawValue)
        XCTAssertEqual(runtime.words, [TunnelAgentWord.credentialsTruncated])
        XCTAssertNil(runtime.startedWith, "a tunnel was started without a complete credential block")
        XCTAssertTrue(runtime.ended.isEmpty)
    }

    func testAStartThatFailsIsReportedAndNothingIsStopped() {
        let runtime = FakeRuntime(lines: ["PIN", "stop"])
        runtime.startError = FakeRuntime.Failure.refused
        let code = TunnelAgentLoop.run(session: try! TunnelAgentSession(credentialLines: 1),
                                       runtime: runtime)

        XCTAssertEqual(code, TunnelAgent.ExitCode.cannotStart.rawValue)
        XCTAssertEqual(runtime.words, [TunnelAgentWord.refusedStart])
        XCTAssertTrue(runtime.ended.isEmpty, "something was ended that was never started")
    }

    func testNothingFromTheChannelEverComesBackOut() {
        // The strongest property this file can assert. The app writes the agent's
        // words straight into its log, so if any word could contain channel input
        // then whoever writes to the pipe could put text of their choosing into
        // the log — the one place this protocol must never be a formatting
        // surface for.
        let hostile = ["$(whoami)", "`id`", "PIN-LEAK-CANARY", "stop\nsupervising 1", "%s", "{0}"]
        let runtime = FakeRuntime(lines: ["PIN-LEAK-CANARY"] + hostile + [TunnelAgent.stopVerb])
        _ = TunnelAgentLoop.run(session: try! TunnelAgentSession(credentialLines: 1),
                                runtime: runtime)

        let vocabulary = [
            TunnelAgentWord.refused,
            TunnelAgentWord.refusedStart,
            TunnelAgentWord.refusedUsage,
            TunnelAgentWord.refusedCommand,
            TunnelAgentWord.credentialsTruncated,
            TunnelAgentWord.peerGone,
            TunnelAgentWord.finished
        ]
        let pidWords = [TunnelAgentWord.supervisingPrefix,
                        TunnelAgentWord.stoppedPrefix,
                        TunnelAgentWord.killedPrefix,
                        TunnelAgentWord.stubbornPrefix]
        for word in runtime.words {
            if let fixed = vocabulary.first(where: { $0 == word }) {
                XCTAssertEqual(word, fixed)
            } else if let prefix = pidWords.first(where: { word.hasPrefix($0) }) {
                XCTAssertEqual(word, prefix + String(runtime.pid),
                               "a word carried something other than the pid the agent observed")
            } else {
                XCTFail("the agent wrote a word it has no business writing: \(word.debugDescription)")
            }
        }
        for secret in hostile + ["PIN-LEAK-CANARY"] {
            XCTAssertFalse(runtime.words.joined(separator: "\n").contains(secret),
                           "channel input came back out: \(secret.debugDescription)")
        }
    }

    func testTheWordsAreDistinctAndCannotBreakAFrame() {
        // Note what this test does *not* claim: that no word is a prefix of
        // another. It is not true, and it is not meant to be — `refused` is a
        // prefix of the four refusal reasons, which is precisely why a reader
        // must compare whole lines (`testOnlyTheExactLineIsTheVerb` asserts the
        // same discipline for the verb). What is asserted here is what a reader
        // can rely on: two different events never produce the same word, and no
        // word can be read as two words.
        let words = [TunnelAgentWord.supervisingPrefix, TunnelAgentWord.stoppedPrefix,
                     TunnelAgentWord.killedPrefix, TunnelAgentWord.stubbornPrefix,
                     TunnelAgentWord.refused, TunnelAgentWord.refusedStart,
                     TunnelAgentWord.refusedUsage, TunnelAgentWord.refusedCommand,
                     TunnelAgentWord.credentialsTruncated, TunnelAgentWord.peerGone,
                     TunnelAgentWord.finished]

        XCTAssertEqual(Set(words).count, words.count, "two events share a word")
        for word in words {
            XCTAssertFalse(word.isEmpty)
            XCTAssertFalse(word.contains("\n"), "\(word) would be read as two words")
            XCTAssertFalse(word.contains("\r"), "\(word) would be read as two words")
        }

        // The four pid-bearing words are the only ones a pid is appended to, and
        // the app reads the pid from the remainder — so the separator has to be
        // exactly one space, or `supervising 12` and `supervising12` would mean
        // the same thing to one reader and not to another.
        let pidWords: [(prefix: String, make: (Int32) -> String)] = [
            (TunnelAgentWord.supervisingPrefix, TunnelAgentWord.supervising),
            (TunnelAgentWord.stoppedPrefix, TunnelAgentWord.stopped),
            (TunnelAgentWord.killedPrefix, TunnelAgentWord.killed),
            (TunnelAgentWord.stubbornPrefix, TunnelAgentWord.stubborn)
        ]
        for pair in pidWords {
            XCTAssertTrue(pair.prefix.hasSuffix(" "), "\(pair.prefix) has no separator before the pid")
            XCTAssertEqual(pair.make(123), pair.prefix + "123")
        }
    }
}

/// A runtime that answers from a script, so the loop can be driven through
/// outcomes a real tunnel would not produce on demand — including one that will
/// not stop.
private final class FakeRuntime: TunnelAgentRuntime {
    enum Failure: Error { case refused }

    private let lines: [String?]
    private var index = 0
    let pid: Int32 = 4242
    var outcome: TunnelAgentOutcome = .stopped
    var startError: Error?
    private(set) var words: [String] = []
    private(set) var startedWith: [String]?
    private(set) var ended: [Int32] = []

    init(lines: [String]) { self.lines = lines.map { Optional($0) } }

    func startTunnel(credentials: [String]) throws -> Int32 {
        startedWith = credentials
        if let startError { throw startError }
        return pid
    }

    func endTunnel(pid: Int32) -> TunnelAgentOutcome {
        ended.append(pid)
        return outcome
    }

    func nextLine() -> String? {
        guard index < lines.count else { return nil }
        defer { index += 1 }
        return lines[index]
    }

    func write(_ word: String) { words.append(word) }
}
