import XCTest
@testable import TurtleDiverAppGlue
@testable import TurtleDiverSystem

/// The decision table and the name check live in `ExistingConnection.swift` and
/// are pinned by `ExistingConnectionTests`. These pin the *wiring*, because that
/// is where the defect actually was: correct-looking detection that asked
/// `pgrep` for command lines, adopted whatever pid came back, and had a cleanup
/// path that signalled by the same match.
///
/// Every assertion is a source scan, deliberately: the call sites are in
/// `VPNManager`, whose logic the SPM harness compiles but whose private methods
/// it cannot call. Comments are stripped first, so prose cannot stand in for a
/// call — and, just as importantly, so a comment *mentioning* the removed
/// pattern cannot be mistaken for a use of it.
final class ExistingConnectionWiringTests: XCTestCase {

    // MARK: - No matching by command line

    /// The whole defect in one assertion: nothing in the app asks the system to
    /// match a *command line* for openconnect, and nothing signals by that match.
    func testTheAppNeverMatchesOrSignalsByCommandLine() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertFalse(code.contains("pgrep"), "the app must not shell out to pgrep itself")
        XCTAssertFalse(code.contains("pkill"), "a name-wide pkill cannot tell a tunnel from a shell that mentions one")
        XCTAssertFalse(code.contains("\"-f\""), "`-f` is the command-line match that caused the false adoption")
        XCTAssertFalse(code.contains("\"openconnect\"]"),
                       "the binary name must come from `OpenConnectProcess.name`, not a literal in this file")

        // The one place the app looks for an existing connection is the scanner.
        XCTAssertTrue(code.contains("ExistingConnectionScanner.detect("),
                      "detection must go through the verified scanner")
    }

    // MARK: - Verifying before adopting

    /// Adoption is a claim about the network. It has to be gated on a *verified*
    /// pid, and the guard has to come before the status and the history entry —
    /// a false "Connected" with a running duration timer is what was observed.
    func testAdoptionIsGatedOnAVerifiedPid() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let start = try XCTUnwrap(code.range(of: "private func adoptExistingConnection(ifVerified detection:"))
        let end = try XCTUnwrap(code.range(of: "private func processStartTime(pid:"))
        let body = code[start.lowerBound..<end.lowerBound]

        let guardRange = try XCTUnwrap(body.range(of: "guard let pid = detection.pid else"))
        let statusRange = try XCTUnwrap(body.range(of: "status = .connected"))
        let adoptedRange = try XCTUnwrap(body.range(of: "\"Connected (adopted from existing process)\""))

        XCTAssertLessThan(guardRange.lowerBound, statusRange.lowerBound,
                          "the UI must not be told Connected before the pid is verified")
        XCTAssertLessThan(guardRange.lowerBound, adoptedRange.lowerBound,
                          "the history must not record an adoption before the pid is verified")

        // And the refusal has to be visible: a pid file that names no openconnect
        // is reported and discarded, not left for the next launch to re-read.
        XCTAssertTrue(body.contains("detection.rejections"), "a refusal must reach the debug log")
        XCTAssertTrue(body.contains("OpenConnectPidFile.discard()"),
                      "a PID file that named no openconnect must not survive the launch")
    }

    /// The pid file is plain text in Application Support. Reading it is fine;
    /// treating what it holds as a live openconnect is not, so the raw read that
    /// used to do exactly that must be gone.
    func testThePidFileIsNeverReadAsAPidOnItsOwn() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertFalse(code.contains("String(contentsOfFile: pidFilePath)"),
                       "a raw read of the pid file is how an unverified pid got adopted and signalled")
        XCTAssertFalse(code.contains("kill(pid, 0) == 0"),
                       "`kill(pid, 0)` reads EPERM as death: a root-owned tunnel looks gone")
        XCTAssertTrue(code.contains("OpenConnectPidFile.recordedPid()"),
                      "the recorded pid must come from the reader that refuses 0 and 1")
    }

    // MARK: - Verifying before signalling

    /// Every kill in the app goes through one function, and that function
    /// verifies first. A recorded pid that is not an openconnect is left alone.
    func testEverySignalGoesThroughTheVerifyingTerminator() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        let start = try XCTUnwrap(code.range(of: "private func terminateGracefully(pid: Int32"))
        let end = try XCTUnwrap(code.range(of: "private func forceTerminate()"))
        let body = code[start.lowerBound..<end.lowerBound]

        let verifyRange = try XCTUnwrap(body.range(of: "guard OpenConnectProcess.isOpenConnect(pid: pid) else"))
        let signalRange = try XCTUnwrap(body.range(of: "_ = kill(pid, SIGTERM)"))
        XCTAssertLessThan(verifyRange.lowerBound, signalRange.lowerBound,
                          "nothing may be signalled before `ps` says the pid is an openconnect")

        // The three paths that stop a tunnel all switch on the measured outcome,
        // so "exited cleanly" is never claimed for a process that was never
        // signalled (a root-owned one answers EPERM to every signal).
        let switches = code.components(separatedBy: "switch terminateGracefully(pid: pid").count - 1
        XCTAssertGreaterThanOrEqual(switches, 3,
                                    "expected disconnect, quit and pre-connect cleanup to check the outcome, found \(switches)")
        let rawSignals = code.components(separatedBy: "_ = kill(pid, SIGTERM)").count - 1
        XCTAssertEqual(rawSignals, 1, "SIGTERM to a recorded pid belongs in exactly one guarded place")
    }

    // MARK: - Verifying on the polling path

    /// The connect waits on this timer to decide the tunnel is up. Both tiers
    /// have to verify, and the fallback has to be the name-based scan: the plan
    /// passes `--pid-file` without `--background`, so openconnect never writes
    /// that file and the scan is the tier that actually finds the tunnel.
    func testThePollingTimerVerifiesBothTiers() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let start = try XCTUnwrap(code.range(of: "private func startConnectionPollingTimer"))
        let end = try XCTUnwrap(code.range(of: "private func startDurationTimer"))
        let body = code[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(body.contains("OpenConnectPidFile.recordedPid(), OpenConnectProcess.isOpenConnect(pid: pid)"),
                      "the PID-file tier must verify the pid it reads")
        XCTAssertTrue(body.contains("ExistingConnectionScanner.detect(pidFilePid: nil)"),
                      "the fallback tier must be the verified scan, not a command-line match")
        XCTAssertFalse(body.contains("waitUntilExit()"),
                       "the poll runs every 2 s; an unbounded wait there is a stuck timer")
    }

    // MARK: - Keeping the UI responsive

    /// The scan spawns `pgrep` and one `ps` per candidate, each bounded at 3 s.
    /// At launch and at connect that must not be the main thread.
    func testTheScanNeverBlocksTheMainThread() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let count = code.components(separatedBy: "ExistingConnectionScanner.detect(").count - 1
        XCTAssertGreaterThanOrEqual(count, 3, "expected detection at launch, at connect and in the poll")

        let launch = try XCTUnwrap(code.range(of: "private func checkForExistingConnection()"))
        let launchBody = code[launch.lowerBound...].prefix(600)
        XCTAssertTrue(launchBody.contains("DispatchQueue.global"),
                      "the launch scan must not run on the main thread")
        XCTAssertTrue(launchBody.contains("self.connectionGeneration == generation"),
                      "an adoption that arrives after a connect started must be dropped")

        let connect = try XCTUnwrap(code.range(of: "private func terminateExistingOpenConnect() async"))
        let connectBody = code[connect.lowerBound...].prefix(600)
        XCTAssertTrue(connectBody.contains("withCheckedContinuation"),
                      "the pre-connect scan must be awaited off the main thread")
    }

    // MARK: - No stale records

    /// A pid file that outlives the process it named is the same stale state one
    /// step later: the number can be recycled by anything. Once the app knows the
    /// process is gone, the record goes with it.
    func testThePidRecordIsClearedOnceTheProcessIsGone() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        for function in ["func disconnect()", "func cleanupOnTermination()", "func forceTerminate()"] {
            let body = try body(of: function, in: code)
            // And the slice really is this one function: a helper that ran to the
            // end of the file would satisfy the assertions below for free.
            XCTAssertLessThan(body.count, 4_000, "the body of \(function) looks unbounded: \(body.count) characters")

            // Only the branch that ends a *live* tunnel has to clear the record,
            // so the assertion is over that branch and not the rest of the method
            // (which has discards of its own).
            let clean = try branch(".exitedCleanly", in: body)
            XCTAssertTrue(clean.contains("OpenConnectPidFile.discard()"),
                          "\(function) must clear the record once the process is gone")
            XCTAssertFalse(clean.contains("break"),
                           "\(function) must not leave a finished process's pid on record")
        }
    }

    // MARK: - No unbounded waits on the adoption path

    /// The duration read runs on the main thread while a tunnel is being
    /// adopted, i.e. on the launch path. It used to spawn `ps` and wait on it
    /// with no deadline, asking for `lstart` — a formatted date whose day and
    /// month names follow the machine's `LC_TIME`.
    func testTheDurationReadIsBoundedAndLocaleProof() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let body = try body(of: "func processStartTime(pid:", in: code)

        XCTAssertFalse(body.contains("waitUntilExit()"), "the duration read needs a deadline")
        XCTAssertFalse(body.contains("Process()"), "the duration read must go through the bounded reader")
        XCTAssertFalse(body.contains("lstart"), "lstart is a formatted date: its names follow LC_TIME")
        XCTAssertTrue(body.contains("processStartTimeReader.startTime(pid: pid)"),
                      "the duration read must go through ProcessStartTimeReader")
        XCTAssertTrue(code.contains("private let processStartTimeReader = ProcessStartTimeReader()"),
                      "and the reader must be a property, so it can be replaced in a test")
    }

    // MARK: - The adopted tunnel's duration

    /// An adopted tunnel's duration must count from when that process started,
    /// not from when we noticed it.
    ///
    /// This is a separate defect from the detection one and outlived it: the
    /// adopter read the real start time correctly and then assigned it, and the
    /// duration timer's first statement — inside a `DispatchQueue.main.async`
    /// block, one runloop later — overwrote it with `Date()`. The reader was
    /// right, the wiring threw the answer away, and the only visible symptom was
    /// a duration that quietly restarted from zero (the history row, built
    /// before the async block ran, still held the true start, so the app's own
    /// two records disagreed).
    func testTheAdoptedStartTimeSurvivesTheDurationTimer() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        let timer = try body(of: "private func startDurationTimer", in: code)
        XCTAssertLessThan(timer.count, 4_000)
        XCTAssertFalse(timer.contains("connectionStartTime = Date()"),
                       "the timer must not recompute the start time; that is what discarded the adopted one")
        XCTAssertTrue(timer.contains("connectionStartTime = start"),
                      "the timer must seed the display from the start it was given")
        XCTAssertFalse(timer.contains("startingAt start: Date ="),
                       "a default would let a caller silently mean `now` again")

        // Every call site must say which instant it means: no bare calls, and no
        // call that passes `Date()` where an adopted start time is in hand.
        let calls = code.components(separatedBy: "startDurationTimer(").count - 1
        let explicitCalls = code.components(separatedBy: "startDurationTimer(startingAt").count - 1
        XCTAssertEqual(calls, explicitCalls, "every call site must pass its start instant")
        XCTAssertFalse(code.contains("startDurationTimer()"),
                       "the bare call is the shape that silently meant `now`")

        let adoption = try body(of: "private func adoptExistingConnection", in: code)
        XCTAssertLessThan(adoption.count, 4_000)
        XCTAssertTrue(adoption.contains("startDurationTimer(startingAt: start)"),
                      "the adopter must seed the timer with the process's own start time")
        XCTAssertFalse(adoption.contains("startDurationTimer(startingAt: Date())"),
                       "the adopter must not fall back to `now`")
        XCTAssertTrue(adoption.contains("let start = startTime ?? Date()"),
                      "one local feeds both the timer and the history row")
        XCTAssertTrue(adoption.contains("timestamp: start,"),
                      "the history row must use the same instant as the duration")
    }

    /// The reader itself is pinned in `ProcessStartTimeTests`; this pins that the
    /// adopter still goes through it rather than inventing a time.
    func testTheAdopterAsksTheProcessWhenItStarted() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let adoption = try body(of: "private func adoptExistingConnection", in: code)
        XCTAssertTrue(adoption.contains("let startTime = processStartTime(pid: pid)"))
    }

    // MARK: - Helpers

    /// The statements of one `case` in a switch, from its label to the next one.
    private func branch(_ label: String, in body: Substring) throws -> Substring {
        let start = try XCTUnwrap(body.range(of: "case \(label)"), "\(label) not found")
        let rest = body[start.upperBound...]
        guard let end = rest.range(of: "\n            case ") ?? rest.range(of: "\n            }") else { return rest }
        return rest[..<end.lowerBound]
    }

    /// The text of one function, from its declaration to the next declaration at
    /// the same indentation. The nearest one, not the first pattern that matches:
    /// taking `"\n    func "` alone would silently slice past the end of a method
    /// whose body is followed by a `private func`, and an assertion over that
    /// slice would pass for the wrong reason.
    private func body(of function: String, in code: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: function), "\(function) not found")
        let rest = code[start.upperBound...]
        let anchors = ["\n    func ", "\n    private func ", "\n    static func ", "\n    public func "]
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
