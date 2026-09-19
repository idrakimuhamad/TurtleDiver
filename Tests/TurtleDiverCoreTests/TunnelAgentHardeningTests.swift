import XCTest

/// Structure pins for the agent's safety guards.
///
/// These are not behaviour tests and are not written as if they were. They exist
/// because the guards below have no failing behaviour to observe: an agent that
/// signalled an unverified pid, or inherited the protocol stream into the tunnel,
/// would pass every behavioural test in `TunnelAgentProcessTests` while being
/// wrong in the way that matters. The only way to pin "this check is still there,
/// and still before the signal" is to read the source and say so.
///
/// `TunnelAgentProcessTests` covers what can be executed; this file covers what
/// can only be read.
final class TunnelAgentHardeningTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/TurtleDiverCoreTests/TunnelAgentHardeningTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private struct MissingAnchor: Error, CustomStringConvertible {
        let description: String
    }

    /// The body of the named function, from its declaration to the next one at
    /// the same indentation. Anchored rather than searched for, so a loose
    /// `contains` over the whole file cannot answer a question about one function.
    private func body(of function: String, in text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.hasPrefix("    func \(function)(") }) else {
            XCTFail("no function named \(function) — the anchor moved")
            throw MissingAnchor(description: function)
        }
        var end = lines.count
        for index in (start + 1)..<lines.count where lines[index].hasPrefix("    func ") ||
                                                    lines[index].hasPrefix("    private func ") ||
                                                    lines[index].hasPrefix("    // MARK:") {
            end = index
            break
        }
        return lines[start..<end].joined(separator: "\n")
    }

    // MARK: - The signal path

    func testTheTunnelIsVerifiedBeforeItIsSignalled() throws {
        let text = try source("Agent/AgentRuntime.swift")
        let end = try body(of: "endTunnel", in: text)

        let verify = try XCTUnwrap(end.range(of: "namesOpenConnect"), "endTunnel signals without verifying")
        let firstSignal = try XCTUnwrap(end.range(of: "signalGroup"),
                                        "endTunnel has no signalling step at all")
        XCTAssertLessThan(verify.lowerBound, firstSignal.lowerBound,
                          "the pid is signalled before it is verified to be an openconnect")
    }

    func testTheVerifiedCommandIsTheOnlyOneTheAgentCanStart() throws {
        let text = try source("Agent/main.swift")
        XCTAssertTrue(text.contains("TunnelAgent.mayStart(command: command)"),
                      "the agent starts a command it never validated")
        XCTAssertTrue(text.contains("TunnelAgentWord.refusedCommand"))
    }

    func testTheAgentCannotRunAnArbitraryCommand() throws {
        // The rule for anything privileged: no generic runner. A `system(`,
        // `popen(` or `Process(` here would turn "start an openconnect" into
        // "run this as root", which is the shape of every privilege-escalation
        // bug this design exists to avoid.
        for path in ["Agent/AgentRuntime.swift", "Agent/main.swift"] {
            let text = try source(path)
            for forbidden in ["system(", "popen(", "Process(", "/bin/sh", "/bin/bash", "/bin/zsh"] {
                XCTAssertFalse(text.contains(forbidden),
                               "\(path) contains \(forbidden)")
            }
        }
    }

    // MARK: - The two streams

    func testTheTunnelIsStartedWithItsOutputOffTheChannel() throws {
        let text = try source("Agent/AgentRuntime.swift")
        let start = try body(of: "startTunnel", in: text)

        XCTAssertTrue(start.contains("adddup2(&fileActions, 2, 1)"),
                      "the tunnel inherits the protocol stream — anything it prints becomes a word")
        // The channel is standard output and the log stream is standard error;
        // that assignment is what makes the `dup2` above mean what it says.
        XCTAssertTrue(text.contains("Darwin.write(1,"),
                      "the agent's own words do not go to standard output")
        XCTAssertTrue(text.contains("read(0,"), "the channel is not read from standard input")
    }

    // MARK: - The process group

    func testTheTunnelLeadsItsOwnProcessGroup() throws {
        let text = try source("Agent/AgentRuntime.swift")
        let start = try body(of: "startTunnel", in: text)

        XCTAssertTrue(start.contains("POSIX_SPAWN_SETPGROUP"),
                      "the tunnel shares a group — ending it could end the agent, or the app")
        XCTAssertTrue(start.contains("posix_spawnattr_setpgroup"),
                      "a group was requested but never set")
    }

    // MARK: - Surviving a closed channel

    func testTheAgentIgnoresABrokenPipe() throws {
        // Without this, writing the greeting to a channel the app has closed
        // raises SIGPIPE and kills the agent before it reads end of input —
        // leaving the tunnel running, which is the one outcome the EOF rule
        // exists to prevent.
        let text = try source("Agent/main.swift")
        XCTAssertTrue(text.contains("signal(SIGPIPE, SIG_IGN)"), "SIGPIPE is not ignored")
    }

    func testTheCredentialCountIsValidatedBeforeAnythingRuns() throws {
        let text = try source("Agent/main.swift")
        let session = try XCTUnwrap(text.range(of: "TunnelAgentSession(credentialLines:"))
        let runtime = try XCTUnwrap(text.range(of: "AgentRuntime("),
                                    "the runtime is built before the session is validated")
        XCTAssertLessThan(session.lowerBound, runtime.lowerBound)
    }

    // The `installed outside the app bundle` pin belongs to the installer step,
    // where the installed path exists to assert about. Writing it here would have
    // meant asserting that the protocol file's own prose does not say `bundle` —
    // which it does, because that is where the rule is written down.
}
