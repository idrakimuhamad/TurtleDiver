import XCTest

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Covers the check that decides whether a running process is an openconnect.
///
/// The defect this pins: the app identified a tunnel by matching *command lines*
/// (`pgrep -f openconnect`), adopted the first pid whose arguments mentioned the
/// word as the connection, wrote it to `openconnect.pid`, drew "Connected" over
/// a tunnel that did not exist, and had a cleanup path that signalled any
/// process whose command line merely mentioned it.
///
/// So the tests that matter most here start real processes — one whose arguments
/// mention openconnect and one that is genuinely *named* openconnect — and
/// assert which of them the detector will and will not touch. The rest of the
/// decision table is driven through injected runners.
final class ExistingConnectionTests: XCTestCase {

    // MARK: - A scripted `pgrep` / `ps`

    /// Answers process invocations from a script. The keys are whole command
    /// lines, because `ps -o comm= -p <pid>` differs per pid.
    final class FakeBoundedProcessRunner: BoundedProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var scripted: [String: BoundedProcessResult] = [:]
        private var recorded: [String] = []

        func script(executable: URL, arguments: [String], result: BoundedProcessResult) {
            lock.lock()
            scripted[Self.key(executable: executable, arguments: arguments)] = result
            lock.unlock()
        }

        var calls: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        static func key(executable: URL, arguments: [String]) -> String {
            ([executable.lastPathComponent] + arguments).joined(separator: " ")
        }

        func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult {
            let key = Self.key(executable: executable, arguments: arguments)
            lock.lock()
            recorded.append(key)
            let result = scripted[key]
            lock.unlock()
            guard let result else {
                throw BoundedProcessError.launchFailed("not scripted: \(key)")
            }
            return result
        }
    }

    private func psSays(_ comm: String) -> BoundedProcessResult {
        BoundedProcessResult(terminationStatus: 0, timedOut: false, stdout: comm + "\n", stderr: "")
    }

    private func pgrepSays(_ pids: [Int32]) -> BoundedProcessResult {
        BoundedProcessResult(
            terminationStatus: pids.isEmpty ? 1 : 0,
            timedOut: false,
            stdout: pids.map(String.init).joined(separator: "\n"),
            stderr: ""
        )
    }

    private func failed() -> BoundedProcessResult {
        BoundedProcessResult(terminationStatus: 1, timedOut: false, stdout: "", stderr: "")
    }

    private func timedOut() -> BoundedProcessResult {
        BoundedProcessResult(terminationStatus: 0, timedOut: true, stdout: "4242\n", stderr: "")
    }

    // MARK: - The name check

    func testNamesOpenConnectAcceptsABareNameAndAFullPath() {
        XCTAssertTrue(OpenConnectProcess.namesOpenConnect("openconnect"))
        XCTAssertTrue(OpenConnectProcess.namesOpenConnect("/opt/homebrew/bin/openconnect"))
        XCTAssertTrue(OpenConnectProcess.namesOpenConnect("/opt/homebrew/Cellar/openconnect/9.12/bin/openconnect"))
        XCTAssertTrue(OpenConnectProcess.namesOpenConnect("  /usr/local/bin/openconnect\n"))
    }

    func testNamesOpenConnectRejectsAnythingElse() {
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect(""))
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect("   \n"))
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect("/bin/bash"))
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect("sudo"))
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect("/tmp/not-openconnect-at-all"))
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect("/tmp/openconnect-lookalike"))
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect("openconnect9"))
        // A name that merely starts with the word is not the word. Strictness is
        // the safe direction: the cost of a false negative is that the app does
        // not adopt a tunnel, and the cost of a false positive is a signalled
        // process that was never openconnect.
        XCTAssertFalse(OpenConnectProcess.namesOpenConnect("/tmp/openconnectx"))
    }

    // MARK: - Reading the processes

    func testPgrepOutputIsParsedWhateverTheSpacing() {
        let runner = FakeBoundedProcessRunner()
        runner.script(
            executable: OpenConnectProcess.pgrepExecutable,
            arguments: ["-x", "openconnect"],
            result: BoundedProcessResult(
                terminationStatus: 0, timedOut: false, stdout: " 8510 \n8511\r\n\n", stderr: ""
            )
        )
        // `\r\n` is one `Character` in Swift, so splitting on "\n" or "\r"
        // individually would leave "8511\r\n" unparsed. Splitting on whitespace
        // is what makes a CRLF-terminated line an answer.
        XCTAssertEqual(OpenConnectProcess.pids(using: runner), [8510, 8511])
    }

    /// `pgrep -x` exits 1 when nothing matches. That is an answer, not a failure.
    func testPgrepExitingOneMeansNoProcesses() {
        let runner = FakeBoundedProcessRunner()
        runner.script(
            executable: OpenConnectProcess.pgrepExecutable,
            arguments: ["-x", "openconnect"],
            result: failed()
        )
        XCTAssertEqual(OpenConnectProcess.pids(using: runner), [])
    }

    func testATimedOutOrEmptyPsYieldsNoCommandName() {
        let runner = FakeBoundedProcessRunner()
        runner.script(executable: OpenConnectProcess.psExecutable, arguments: ["-o", "comm=", "-p", "42"], result: timedOut())
        XCTAssertNil(OpenConnectProcess.commandName(pid: 42, using: runner))
        XCTAssertFalse(OpenConnectProcess.isOpenConnect(pid: 42, using: runner))

        let empty = FakeBoundedProcessRunner()
        empty.script(
            executable: OpenConnectProcess.psExecutable,
            arguments: ["-o", "comm=", "-p", "43"],
            result: BoundedProcessResult(terminationStatus: 0, timedOut: false, stdout: "\n", stderr: "")
        )
        XCTAssertNil(OpenConnectProcess.commandName(pid: 43, using: empty))
    }

    /// A pid that no longer exists is a race, not a finding: `ps` fails, and the
    /// scan simply does not report it.
    func testADeadPidYieldsNoCommandName() {
        let runner = FakeBoundedProcessRunner()
        runner.script(executable: OpenConnectProcess.psExecutable, arguments: ["-o", "comm=", "-p", "999999"], result: failed())
        XCTAssertFalse(OpenConnectProcess.isOpenConnect(pid: 999999, using: runner))
    }

    // MARK: - Liveness

    /// A root-owned process is alive even though this user may not signal it:
    /// `kill(pid, 0)` answers `EPERM`. Reading `EPERM` as death is how the app
    /// reported its own root-owned openconnect as "exited cleanly" without ever
    /// having signalled it.
    func testARootOwnedProcessCountsAsRunning() {
        XCTAssertTrue(OpenConnectProcess.isRunning(pid: 1)) // launchd
        XCTAssertFalse(OpenConnectProcess.isOpenConnect(pid: 1)) // but not an openconnect
        XCTAssertFalse(OpenConnectProcess.isRunning(pid: 999_999))
    }

    // MARK: - The decision table

    func testThePidFileIsPreferredWhenItNamesAnOpenconnect() {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: 8510,
            scannedPids: [8600],
            ownPid: 999,
            isRunning: { _ in true },
            isOpenConnect: { _ in true }
        )
        XCTAssertEqual(detection.pid, 8510)
        XCTAssertEqual(detection.source, .pidFile)
        XCTAssertTrue(detection.adopted)
        XCTAssertTrue(detection.rejections.isEmpty)
    }

    /// The observed defect, in the decision table: a pid file naming a process
    /// that is not an openconnect must never be adopted.
    func testAPidFileNamingSomethingElseIsRejectedAndExplained() throws {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: 15817,
            scannedPids: [],
            ownPid: 999,
            isRunning: { _ in true },
            isOpenConnect: { _ in false }
        )
        XCTAssertNil(detection.pid)
        XCTAssertNil(detection.source)
        XCTAssertFalse(detection.adopted)
        XCTAssertEqual(detection.rejections, [
            ExistingConnectionDetection.Rejection(pid: 15817, reason: .isNotOpenConnect)
        ])

        // The rejection is what reaches the debug log — and it names the pid, so
        // the next false positive is visible instead of silent.
        let explanation = try XCTUnwrap(detection.rejections.first?.explanation)
        XCTAssertTrue(explanation.contains("Ignoring"))
        XCTAssertTrue(explanation.contains("15817"))
        XCTAssertTrue(explanation.contains("openconnect"))
    }

    func testAPidFileNamingADeadProcessIsRejected() {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: 15817,
            scannedPids: [],
            ownPid: 999,
            isRunning: { _ in false },
            isOpenConnect: { _ in true }
        )
        XCTAssertNil(detection.pid)
        XCTAssertEqual(detection.rejections.map(\.reason), [.isNotRunning])
    }

    func testTheAppNeverAdoptsItself() {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: 999,
            scannedPids: [999],
            ownPid: 999,
            isRunning: { _ in true },
            isOpenConnect: { _ in true }
        )
        XCTAssertNil(detection.pid)
        XCTAssertEqual(detection.rejections.map(\.reason), [.isThisApp])
    }

    /// Tier 2 is not dead code reached through a rejected Tier 1: when the pid
    /// file is wrong, the scan still runs and its verified pid is adopted.
    func testARejectedPidFileStopsNothingTheScanCanFind() {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: 15817,
            scannedPids: [8510],
            ownPid: 999,
            isRunning: { _ in true },
            isOpenConnect: { $0 == 8510 }
        )
        XCTAssertEqual(detection.pid, 8510)
        XCTAssertEqual(detection.source, .scanned)
        // The refused candidate is still reported: it is why adoption happened
        // after a fallback, and the file it came from needs discarding.
        XCTAssertEqual(detection.rejections.map(\.reason), [.isNotOpenConnect])
    }

    /// A scanned pid is verified too — `pgrep -x` is a name match, but the pid
    /// can still have exited and been recycled between the scan and the check.
    func testAScannedPidThatIsNotAnOpenconnectIsRejectedRatherThanAdopted() {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: nil,
            scannedPids: [4242],
            ownPid: 999,
            isRunning: { _ in true },
            isOpenConnect: { _ in false }
        )
        XCTAssertNil(detection.pid)
        XCTAssertEqual(detection.rejections, [
            ExistingConnectionDetection.Rejection(pid: 4242, reason: .isNotOpenConnect)
        ])
    }

    /// Dead candidates from the scan are ordinary races and are not reported as
    /// findings — otherwise every connect would log noise for a pid that exited.
    func testADeadScannedPidIsSkippedSilently() {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: nil,
            scannedPids: [4242],
            ownPid: 999,
            isRunning: { _ in false },
            isOpenConnect: { _ in true }
        )
        XCTAssertNil(detection.pid)
        XCTAssertTrue(detection.rejections.isEmpty)
    }

    func testNothingQualifiesMeansNothingIsAdopted() {
        let detection = ExistingConnectionDetector.decide(
            pidFilePid: nil,
            scannedPids: [],
            ownPid: 999,
            isRunning: { _ in true },
            isOpenConnect: { _ in true }
        )
        XCTAssertNil(detection.pid)
        XCTAssertEqual(detection, .none)
    }

    func testTheScannerAsksForNamesNotCommandLines() {
        let runner = FakeBoundedProcessRunner()
        // Liveness is real here by design — the seam is the *name*, not whether a
        // process exists. pid 1 is always alive (and root-owned, so it also
        // covers the `EPERM` case), while the name it answers to comes from the
        // scripted `ps`.
        runner.script(executable: OpenConnectProcess.pgrepExecutable, arguments: ["-x", "openconnect"], result: pgrepSays([1]))
        runner.script(executable: OpenConnectProcess.psExecutable, arguments: ["-o", "comm=", "-p", "1"], result: psSays("/opt/homebrew/bin/openconnect"))

        let detection = ExistingConnectionScanner.detect(pidFilePid: nil, ownPid: 999, using: runner)
        XCTAssertEqual(detection.pid, 1)
        XCTAssertEqual(detection.source, .scanned)
        XCTAssertEqual(runner.calls.first, "pgrep -x openconnect")
        XCTAssertTrue(runner.calls.contains("ps -o comm= -p 1"))
        XCTAssertFalse(runner.calls.contains { $0.contains("-f") })
    }

    // MARK: - Real processes

    /// The defect, end to end: a process whose *arguments* mention openconnect.
    ///
    /// The decoy has to be genuinely reachable by the old check, or this test
    /// proves nothing — so a raw `pgrep -f` is expected to find it, and that
    /// expectation is asserted first.
    func testAProcessWhoseArgumentsMentionOpenconnectIsNeverFound() throws {
        // Not `bash -c 'sleep 30 # openconnect'`: bash execs a lone simple
        // command, so the process *becomes* `sleep` and the decoy evaporates.
        // A list keeps the shell — with the word in its arguments — alive.
        let decoy = try spawn(executable: "/bin/bash", arguments: ["-c", "sleep 30; true # openconnect"])
        addTeardownBlock { kill(decoy.processIdentifier, SIGKILL) }
        try waitForCommandName(decoy.processIdentifier)

        XCTAssertTrue(
            commandLineMatches().contains(decoy.processIdentifier),
            "the decoy must be reachable by a command-line match, or this test cannot fail for the right reason"
        )

        XCTAssertFalse(OpenConnectProcess.pids().contains(decoy.processIdentifier))
        XCTAssertFalse(OpenConnectProcess.isOpenConnect(pid: decoy.processIdentifier))
        XCTAssertTrue(OpenConnectProcess.isRunning(pid: decoy.processIdentifier))

        // The exact shape of what was seen live: that pid sitting in the PID file.
        let detection = ExistingConnectionScanner.detect(pidFilePid: decoy.processIdentifier)
        XCTAssertNil(detection.pid)
        XCTAssertEqual(detection.rejections.map(\.reason), [.isNotOpenConnect])
    }

    /// The positive control for the test above: a process actually *named*
    /// openconnect is found and verified.
    ///
    /// A symlink is how Homebrew installs it (`/opt/homebrew/bin/openconnect`
    /// points into the Cellar) and, as measured on this machine, the kernel's
    /// record is the path it was exec'd with — the symlink, not its target.
    func testAProcessActuallyNamedOpenconnectIsFoundAndVerified() throws {
        let directory = try makeTemporaryDirectory()
        let binary = directory.appendingPathComponent(OpenConnectProcess.name)
        try FileManager.default.createSymbolicLink(
            at: binary,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )

        let process = try spawn(executable: binary.path, arguments: ["-c", "sleep 30; true"])
        addTeardownBlock { kill(process.processIdentifier, SIGKILL) }
        try waitForCommandName(process.processIdentifier)

        let comm = try XCTUnwrap(OpenConnectProcess.commandName(pid: process.processIdentifier))
        XCTAssertTrue(OpenConnectProcess.namesOpenConnect(comm), "comm was \(comm)")
        XCTAssertTrue(OpenConnectProcess.pids().contains(process.processIdentifier))
        XCTAssertTrue(OpenConnectProcess.isOpenConnect(pid: process.processIdentifier))

        // Recorded in the PID file, this is the legitimate adoption — the one
        // the app is supposed to make after a relaunch.
        let detection = ExistingConnectionScanner.detect(pidFilePid: process.processIdentifier)
        XCTAssertEqual(detection.pid, process.processIdentifier)
        XCTAssertEqual(detection.source, .pidFile)
        XCTAssertNil(detection.rejections.first?.explanation.isEmpty)
    }

    // MARK: - The PID file

    func testTheRecordedPidIsReadWithTheUnsafeValuesRefused() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("openconnect.pid")

        try "8510\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(OpenConnectPidFile.recordedPid(at: file), 8510)

        try " 8510 ".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(OpenConnectPidFile.recordedPid(at: file), 8510)

        // `0` and `1` are refused: a record of them must never reach `kill`.
        for unsafe in ["0\n", "1\n", "-1\n", "\n", "not a pid\n"] {
            try unsafe.write(to: file, atomically: true, encoding: .utf8)
            XCTAssertNil(OpenConnectPidFile.recordedPid(at: file), "accepted \(unsafe.debugDescription)")
        }

        XCTAssertNil(OpenConnectPidFile.recordedPid(at: directory.appendingPathComponent("absent.pid")))
    }

    func testDiscardingRemovesTheRecord() throws {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("openconnect.pid")
        try "15817\n".write(to: file, atomically: true, encoding: .utf8)

        OpenConnectPidFile.discard(at: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(OpenConnectPidFile.recordedPid(at: file))
    }

    // MARK: - Helpers

    private func spawn(executable: String, arguments: [String]) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Waits for the child to have been exec'd, which is what `pgrep` and `ps`
    /// need. This is a bounded wait for the real condition, not a sleep: a child
    /// that is still pre-exec has no `comm` and no argv for either tool to see.
    private func waitForCommandName(_ pid: Int32, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if OpenConnectProcess.commandName(pid: pid) != nil { return }
            usleep(20_000)
        }
        XCTFail("process \(pid) never reported a command name")
    }

    /// `pgrep -f openconnect` — the match this fix removes. Used here only to
    /// prove the decoy really is reachable that way.
    private func commandLineMatches() -> [Int32] {
        let process = Process()
        process.executableURL = OpenConnectProcess.pgrepExecutable
        process.arguments = ["-f", OpenConnectProcess.name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { Int32($0) }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("existing-connection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
