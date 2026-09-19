import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverSystem

/// The app's half of the agent channel.
///
/// The three things here are the three things that can go wrong on this path
/// without a single byte of it reaching a network: a word misread (which would
/// make the app act on something the agent did not say), a launch built wrong
/// (which would start the wrong program as root), or a step that never returns
/// (which would leave a root `sudo` behind). Each is pinned to a value rather
/// than to a shape, except where only a shape will do.
final class TunnelAgentChannelTests: XCTestCase {

    // MARK: - The decoder

    func testTheDecoderReadsEveryWordTheProtocolDefines() {
        var decoder = TunnelAgentChannel.Decoder()
        let events = decoder.consume(Data("""
        \(TunnelAgentWord.supervising(412))
        \(TunnelAgentWord.stopped(412))
        \(TunnelAgentWord.killed(413))
        \(TunnelAgentWord.stubborn(414))
        \(TunnelAgentWord.peerGone)
        \(TunnelAgentWord.finished)
        \(TunnelAgentWord.refused)
        \(TunnelAgentWord.refusedStart)
        \(TunnelAgentWord.refusedUsage)
        \(TunnelAgentWord.refusedCommand)
        \(TunnelAgentWord.credentialsTruncated)

        """.utf8))
        XCTAssertEqual(events, [
            .supervising(412),
            .stopped(412),
            .killed(413),
            .stubborn(414),
            .peerGone,
            .finished,
            .refused(TunnelAgentWord.refused),
            .refused(TunnelAgentWord.refusedStart),
            .refused(TunnelAgentWord.refusedUsage),
            .refused(TunnelAgentWord.refusedCommand),
            .refused(TunnelAgentWord.credentialsTruncated)
        ])
    }

    /// A read can split a word anywhere. Matching on partial input would either
    /// miss a word or invent one, so the decoder waits for the newline.
    func testAWordSplitAcrossReadsIsDecodedOnce() {
        var decoder = TunnelAgentChannel.Decoder()
        let word = TunnelAgentWord.supervising(9001) + "\n"
        var events: [TunnelAgentChannel.Event] = []
        for byte in Array(word.utf8) {
            events += decoder.consume(Data([byte]))
        }
        XCTAssertEqual(events, [.supervising(9001)])
    }

    /// A line without its newline is not a word yet — it could still grow into
    /// one, or be the first half of garbage.
    func testAnUnterminatedWordIsNotDeliveredUntilItEnds() {
        var decoder = TunnelAgentChannel.Decoder()
        XCTAssertEqual(decoder.consume(Data(TunnelAgentWord.finished.utf8)), [])
        XCTAssertEqual(decoder.consume(Data("\n".utf8)), [.finished])
    }

    /// The same discipline the agent applies to the verb it accepts, for the same
    /// reason: `stopped 4\r` is not a stop.
    func testAnAlmostWordIsNotAWord() {
        var decoder = TunnelAgentChannel.Decoder()
        let lines = [
            TunnelAgentWord.stopped(4) + "\r",
            " " + TunnelAgentWord.stopped(4),
            TunnelAgentWord.stopped(4).uppercased(),
            "stopped 4 ",
            "stopped  4",
            "stopped4",
            // The plain words are matched exactly too: a line that merely begins
            // with one is not one, or a tunnel's log line could be read as the
            // end of the channel.
            TunnelAgentWord.peerGone + "x",
            TunnelAgentWord.peerGone + " ",
            TunnelAgentWord.finished + "x",
            TunnelAgentWord.refused + "-something"
        ]
        let events = decoder.consume(Data((lines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(events.count, lines.count)
        for event in events {
            guard case .unrecognised = event else {
                return XCTFail("decoded \(event) from a line that is not a word")
            }
        }
    }

    /// A pid the app could not act on must never become an event. `recordOwnTunnelPid`
    /// refuses these too, but an event that reaches it at all is already wrong.
    func testAPidThatCannotBeSignalledIsNotAPid() {
        var decoder = TunnelAgentChannel.Decoder()
        let events = decoder.consume(Data("""
        \(TunnelAgentWord.supervisingPrefix)0
        \(TunnelAgentWord.supervisingPrefix)1
        \(TunnelAgentWord.supervisingPrefix)-4
        \(TunnelAgentWord.supervisingPrefix)412
        \(TunnelAgentWord.stoppedPrefix)notanumber

        """.utf8))
        // 0 and 1 are refused by `> 1`, exactly as `recordOwnTunnelPid` refuses
        // them: 1 is launchd, and 0 is not a process.
        XCTAssertEqual(events, [
            .unrecognised("\(TunnelAgentWord.supervisingPrefix)0".utf8.count),
            .unrecognised("\(TunnelAgentWord.supervisingPrefix)1".utf8.count),
            .unrecognised("\(TunnelAgentWord.supervisingPrefix)-4".utf8.count),
            .supervising(412),
            .unrecognised("\(TunnelAgentWord.stoppedPrefix)notanumber".utf8.count)
        ])
    }

    /// The one event that could carry text the app did not write carries a count
    /// instead. Nothing here may echo a line back: it would land in the log the
    /// user reads.
    func testAnUnrecognisedLineIsCountedAndNeverEchoed() {
        var decoder = TunnelAgentChannel.Decoder()
        let secret = "a line nobody's protocol defines"
        let events = decoder.consume(Data((secret + "\n").utf8))
        XCTAssertEqual(events, [.unrecognised(secret.utf8.count)])
        for event in events {
            XCTAssertFalse(String(describing: event).contains("nobody"), "the decoder echoed the line")
        }
    }

    /// A line that cannot be a word is discarded rather than buffered: the agent
    /// is a process the app does not control, and a decoder that grows without
    /// bound is a decoder that can be made to use all the memory the app has.
    func testAnOverLongLineIsDiscardedAndReported() {
        var decoder = TunnelAgentChannel.Decoder()
        let overLong = String(repeating: "A", count: TunnelAgentChannel.Decoder.lineLimit * 4)
        let events = decoder.consume(Data((overLong + "\n").utf8))
        XCTAssertEqual(events.count, 1)
        guard case .unrecognised(let bytes) = events[0] else {
            return XCTFail("expected an unrecognised line, got \(events[0])")
        }
        XCTAssertGreaterThanOrEqual(bytes, TunnelAgentChannel.Decoder.lineLimit)
        // The count is the whole line, not the part that was kept: the report is
        // about how much arrived, and an honest count is what makes an unexpected
        // line identifiable in a log without the bytes themselves being kept.
        XCTAssertEqual(bytes, overLong.utf8.count)
        // The decoder is usable again afterwards.
        XCTAssertEqual(decoder.consume(Data((TunnelAgentWord.finished + "\n").utf8)), [.finished])
    }

    /// The limit is the protocol's, not a second number that could drift from it.
    func testTheDecoderUsesTheProtocolsOwnLineLimit() {
        XCTAssertEqual(TunnelAgentChannel.Decoder.lineLimit, TunnelAgent.maximumLineBytes)
    }

    /// The rule that an over-long line is refused is asserted above. What this
    /// adds is the reason the decoder is written the way it is: a refused line
    /// must not be *held* first. The thing on the other end of this pipe is a
    /// root process the app does not control, so a decoder that buffers until the
    /// newline arrives lets whoever writes to it choose how much memory the app
    /// uses — and the length test happens after the read.
    ///
    /// Measured as a delta between two readings a fraction of a second apart, not
    /// as an absolute figure: what is asserted is that 24 MB of input did not
    /// become 24 MB of this process's memory.
    func testAnOverLongLineIsDiscardedRatherThanHeld() throws {
        var decoder = TunnelAgentChannel.Decoder()
        let chunk = Data(repeating: 0x41, count: 256 * 1024)
        let chunks = 96                                  // 24 MB, and no newline anywhere
        let pid = ProcessInfo.processInfo.processIdentifier

        let baseline = try XCTUnwrap(residentKilobytes(of: pid))
        for _ in 0..<chunks { XCTAssertTrue(decoder.consume(chunk).isEmpty) }
        let grown = try XCTUnwrap(residentKilobytes(of: pid))

        XCTAssertLessThan(grown - baseline, 4 * 1024,
                          "the decoder held the line: \(baseline) kB → \(grown) kB")

        // The report is still about how much arrived, which is what makes the
        // line identifiable in a log without the bytes themselves being kept.
        XCTAssertEqual(decoder.consume(Data("\n".utf8)),
                       [.unrecognised(chunks * chunk.count)])
    }

    /// The host's resident size, from `ps`, in kilobytes.
    private func residentKilobytes(of pid: Int32) -> Int? {
        guard let result = try? SystemBoundedProcessRunner().run(
            executable: ProcessOwner.ps,
            arguments: ["-o", "rss=", "-p", "\(pid)"],
            timeout: ProcessOwner.timeout
        ), !result.timedOut else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - The launch

    func testTheAgentIsToldWhereOpenconnectIsAndGetsTheTunnelArgumentsUnchanged() {
        let tunnel = ["--force-dpd=10", "--user=somebody", "vpn.example.com"]
        let arguments = TunnelAgentChannel.Launch.agentArguments(
            agentPath: "/usr/local/libexec/turtlediver-agent",
            openconnectPath: "/opt/homebrew/bin/openconnect",
            tunnelArguments: tunnel,
            searchPath: "/opt/homebrew/bin:/usr/bin"
        )
        XCTAssertEqual(arguments, [
            "--credential-lines", "2",
            "--path", "/opt/homebrew/bin:/usr/bin",
            "/opt/homebrew/bin/openconnect"
        ] + tunnel)
    }

    /// The agent is started with `-n` and never with `-S`: it authenticates
    /// nothing. A `-S` here would read the tunnel's PIN as its own password.
    func testTheAgentIsLaunchedWithoutAPasswordOnItsStandardInput() {
        let arguments = TunnelAgentChannel.Launch.sudoArguments(agentArguments: ["--credential-lines", "2"])
        XCTAssertEqual(arguments, ["-n", "--credential-lines", "2"])
        XCTAssertFalse(arguments.contains("-S"))
    }

    /// The channel carries exactly two lines, and the second is the account
    /// password. The administrator password is not on this path at all.
    func testTheCredentialBlockIsThePinAndTheAccountPassword() {
        let block = TunnelAgentChannel.Launch.credentialBlock(pin: "123456", vpnPassword: "hunter2")
        XCTAssertEqual(String(decoding: block, as: UTF8.self), "123456\nhunter2\n")
        XCTAssertEqual(block.split(separator: 0x0A).count, TunnelAgentChannel.Launch.credentialLineCount)
        XCTAssertEqual(TunnelAgentChannel.Launch.credentialLineCount, 2)
        // The agent must accept what the app sends: the protocol's own range.
        XCTAssertNoThrow(try TunnelAgentSession(credentialLines: TunnelAgentChannel.Launch.credentialLineCount))
    }

    func testTheSearchPathPutsTheKnownDirectoriesInFront() {
        XCTAssertEqual(
            TunnelAgentChannel.Launch.searchPath(inherited: "/usr/bin", defaults: "/opt/homebrew/bin"),
            "/opt/homebrew/bin:/usr/bin"
        )
        XCTAssertEqual(
            TunnelAgentChannel.Launch.searchPath(inherited: nil, defaults: "/opt/homebrew/bin"),
            "/opt/homebrew/bin"
        )
        XCTAssertEqual(
            TunnelAgentChannel.Launch.searchPath(inherited: "", defaults: "/opt/homebrew/bin"),
            "/opt/homebrew/bin"
        )
    }

    /// The three shapes the launch script used to run inside its own process
    /// group. Only the mode that cannot raise a dialog may pipe a password.
    func testTheWarmupMatchesTheStrategy() {
        XCTAssertEqual(TunnelAgentChannel.Launch.warmupArguments(.storedPassword), ["-S", "-v"])
        XCTAssertEqual(TunnelAgentChannel.Launch.warmupArguments(.systemPrompt), ["-v"])
        XCTAssertEqual(TunnelAgentChannel.Launch.warmupArguments(.neverPrompt), ["-n", "-v"])

        XCTAssertEqual(
            String(decoding: TunnelAgentChannel.Launch.warmupInput(.storedPassword, adminPassword: "pw"), as: UTF8.self),
            "pw\n"
        )
        // Empty means "connect it to /dev/null", not "give it an empty pipe": a
        // pipe nobody writes is a `sudo` blocked on a read it will never finish.
        XCTAssertTrue(TunnelAgentChannel.Launch.warmupInput(.systemPrompt, adminPassword: "pw").isEmpty)
        XCTAssertTrue(TunnelAgentChannel.Launch.warmupInput(.neverPrompt, adminPassword: "pw").isEmpty)
    }

    /// The cleanup is the same `sed` the wrapper ran, and it is `-n`: by the time
    /// it runs the timestamp belongs to the app, which is the point of moving it
    /// out of the wrapper.
    func testTheStaleRouteCleanupIsUnattendedAndTargetsTheHostsFile() {
        XCTAssertEqual(
            TunnelAgentChannel.Launch.hostsCleanupArguments,
            ["-n", "/usr/bin/sed", "-i", "", "/# vpn-slice-/d", "/etc/hosts"]
        )
    }

    // MARK: - The trust check

    /// A runner that answers the two `codesign` invocations by name, so the
    /// verification logic is testable without a signed binary.
    private final class FakeCodesign: BoundedProcessRunning, @unchecked Sendable {
        var verifyStatus: Int32 = 0
        var details = "Identifier=turtlediver-agent\nTeamIdentifier=KT7QU923S8\n"
        private(set) var invoked: [String] = []

        func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult {
            invoked.append(arguments.first ?? "")
            // `codesign -d` writes its fields to stderr; the happy path must
            // therefore be satisfied by stderr alone.
            return arguments.first == "--verify"
                ? BoundedProcessResult(terminationStatus: verifyStatus, timedOut: false, stdout: "", stderr: "")
                : BoundedProcessResult(terminationStatus: 0, timedOut: false, stdout: "", stderr: details)
        }
    }

    /// Nothing at the path is not a failure: the app has always worked without
    /// an agent, and a drag-to-Applications install has no agent at all.
    func testAMissingAgentIsNotAFailure() {
        let availability = TunnelAgentChannel.Verifier.check(
            path: "/nonexistent/turtlediver-agent",
            expectedTeam: "KT7QU923S8",
            expectedOwner: "root",
            runner: FakeCodesign()
        )
        XCTAssertEqual(availability, .notInstalled)
        XCTAssertFalse(availability.isReady)
    }

    /// Something is there, and it is not this app's agent: the file is refused,
    /// with a reason, and no `codesign` is even consulted about its owner.
    func testAFileOwnedBySomeoneElseIsRefused() {
        guard let owner = (try? FileManager.default.attributesOfItem(atPath: "/bin/ls"))?[.ownerAccountName] as? String else {
            return XCTFail("could not read an owner for the fixture")
        }
        let availability = TunnelAgentChannel.Verifier.check(
            path: "/bin/ls",
            expectedTeam: "KT7QU923S8",
            // The real owner of the fixture, so this asserts the branch and not
            // the machine's user.
            expectedOwner: owner == "root" ? "someone-else" : "root",
            runner: FakeCodesign()
        )
        guard case .refused(let why) = availability else {
            return XCTFail("expected a refusal, got \(availability)")
        }
        XCTAssertTrue(why.contains("owned by"), why)
    }

    func testAnAgentWithABadSignatureIsRefused() {
        let codesign = FakeCodesign()
        codesign.verifyStatus = 1
        let availability = TunnelAgentChannel.Verifier.check(
            path: "/bin/ls",
            expectedTeam: "KT7QU923S8",
            expectedOwner: ownerOfFixture(),
            runner: codesign
        )
        guard case .refused(let why) = availability else {
            return XCTFail("expected a refusal, got \(availability)")
        }
        XCTAssertTrue(why.contains("valid code signature"), why)
    }

    func testAnAgentSignedForAnotherTeamIsRefused() {
        let codesign = FakeCodesign()
        codesign.details = "Identifier=something-else\nTeamIdentifier=NOTMYTEAM\n"
        let availability = TunnelAgentChannel.Verifier.check(
            path: "/bin/ls",
            expectedTeam: "KT7QU923S8",
            expectedOwner: ownerOfFixture(),
            runner: codesign
        )
        guard case .refused(let why) = availability else {
            return XCTFail("expected a refusal, got \(availability)")
        }
        XCTAssertTrue(why.contains("NOTMYTEAM"), why)
        XCTAssertTrue(why.contains("KT7QU923S8"), why)
    }

    /// The identifier is checked as well as the team: a file called
    /// `turtlediver-agent` is not evidence that the code inside it is the agent.
    func testAFileSignedAsSomethingElseIsRefused() {
        let codesign = FakeCodesign()
        codesign.details = "Identifier=com.example.other\nTeamIdentifier=KT7QU923S8\n"
        let availability = TunnelAgentChannel.Verifier.check(
            path: "/bin/ls",
            expectedTeam: "KT7QU923S8",
            expectedOwner: ownerOfFixture(),
            runner: codesign
        )
        guard case .refused(let why) = availability else {
            return XCTFail("expected a refusal, got \(availability)")
        }
        XCTAssertTrue(why.contains("com.example.other"), why)
    }

    func testAVerifiedAgentIsReady() {
        let availability = TunnelAgentChannel.Verifier.check(
            path: "/bin/ls",
            expectedTeam: "KT7QU923S8",
            expectedOwner: ownerOfFixture(),
            runner: FakeCodesign()
        )
        XCTAssertEqual(availability, .ready)
        XCTAssertTrue(availability.isReady)
    }

    private func ownerOfFixture() -> String {
        ((try? FileManager.default.attributesOfItem(atPath: "/bin/ls"))?[.ownerAccountName] as? String) ?? "root"
    }

    /// The defaults are the ones the installer and the protocol agree on. A
    /// verifier pointed at a different path would check one file and run another.
    func testTheVerifierDefaultsToTheProtocolsOwnPath() throws {
        let source = try String(contentsOfFile: Self.corePath("VPNConnect/System/TunnelAgentChannel.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("path: String = TunnelAgent.installedPath"))
        XCTAssertTrue(source.contains("expectedTeam: String = AppIdentity.updateTeamIdentifier"))
        XCTAssertTrue(source.contains("expectedOwner: String = \"root\""))
    }

    // MARK: - The step runner

    /// The credential path: bytes given to the runner arrive on the child's
    /// standard input. `/bin/cat` is the child because this test is about the
    /// pipe, not about `sudo`.
    func testTheStepRunnerFeedsItsChildAndSeesItExit() {
        let result = TunnelAgentChannel.SudoStepRunner(executable: "/bin/cat").run(
            arguments: [],
            stdin: Data("pin\npassword\n".utf8),
            timeout: 10
        )
        XCTAssertTrue(result.succeeded, "\(result)")
        XCTAssertFalse(result.timedOut)
    }

    /// The property that makes a wait on a system dialog safe: a step that never
    /// returns is signalled, reaped, and reported as timed out. Its status is not
    /// reported as a status, because after a `SIGKILL` there is no status to
    /// report.
    func testTheStepRunnerBoundsAStepThatNeverReturns() {
        let started = Date()
        let result = TunnelAgentChannel.SudoStepRunner(executable: "/bin/sleep").run(
            arguments: ["30"],
            stdin: nil,
            timeout: 1
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.timedOut, "\(result)")
        XCTAssertEqual(result.terminationStatus, -1, "a timed-out step must not report a status")
        XCTAssertFalse(result.succeeded)
        // The bound is the point: without it this call would have waited 30 s.
        XCTAssertLessThan(elapsed, 20, "the deadline did not hold")
    }

    func testTheStepRunnerReportsAChildItCouldNotStart() {
        let result = TunnelAgentChannel.SudoStepRunner(executable: "/nonexistent/not-a-program").run(
            arguments: [], stdin: nil, timeout: 5
        )
        XCTAssertNotNil(result.launchError)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(result.timedOut)
    }

    // MARK: - Diagnoses

    /// Every refusal the protocol defines has a diagnosis, and the words the user
    /// would act on differently do not share one. `refused-usage` and
    /// `refused-command` deliberately do: both mean the installed agent and this
    /// app disagree about the protocol, which is one remedy.
    func testEveryRefusalHasADiagnosisAndTheDistinctOnesAreDistinct() {
        XCTAssertEqual(
            TunnelAgentChannel.diagnosis(forRefusal: TunnelAgentWord.credentialsTruncated).historyStatus,
            "Failed - Agent Lost Credentials"
        )
        XCTAssertEqual(
            TunnelAgentChannel.diagnosis(forRefusal: TunnelAgentWord.refusedStart).historyStatus,
            "Failed - Agent Could Not Start Tunnel"
        )
        XCTAssertEqual(
            TunnelAgentChannel.diagnosis(forRefusal: TunnelAgentWord.refusedUsage).historyStatus,
            TunnelAgentChannel.diagnosis(forRefusal: TunnelAgentWord.refusedCommand).historyStatus
        )
        XCTAssertEqual(
            TunnelAgentChannel.diagnosis(forRefusal: TunnelAgentWord.refused).historyStatus,
            "Failed - Agent Refused"
        )

        let words = [
            TunnelAgentWord.refused,
            TunnelAgentWord.refusedStart,
            TunnelAgentWord.refusedUsage,
            TunnelAgentWord.refusedCommand,
            TunnelAgentWord.credentialsTruncated
        ]
        var statuses: Set<String> = []
        for word in words {
            let diagnosis = TunnelAgentChannel.diagnosis(forRefusal: word)
            XCTAssertFalse(diagnosis.detail.isEmpty, word)
            XCTAssertTrue(diagnosis.historyStatus.hasPrefix("Failed - "), word)
            statuses.insert(diagnosis.historyStatus)
        }
        XCTAssertEqual(statuses.count, 4, "a refusal with no status of its own, or one that shares one it should not")
    }

    /// A word that is not a refusal is still not nothing: the app never shows an
    /// empty reason after being told something.
    func testAnUnknownRefusalStillHasADiagnosis() {
        let diagnosis = TunnelAgentChannel.diagnosis(forRefusal: "refused-something-new")
        XCTAssertTrue(diagnosis.historyStatus.hasPrefix("Failed - "))
        XCTAssertFalse(diagnosis.detail.isEmpty)
    }

    private static func corePath(_ relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
            .path
    }
}
