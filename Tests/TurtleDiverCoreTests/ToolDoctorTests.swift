import XCTest
@testable import TurtleDiverSystem

// MARK: - Fakes

/// A scripted `ToolLocating`: only the listed tools exist, at made-up paths.
final class FakeToolLocator: ToolLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String]

    init(_ entries: [String: String] = [:]) {
        self.entries = entries
    }

    func locate(_ name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[name]
    }

    func set(_ name: String, to path: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let path { entries[name] = path } else { entries.removeValue(forKey: name) }
    }
}

/// A scripted runner. Records every invocation so a test can assert on the
/// exact argv — which is how "never sudo" is pinned.
final class RecordingToolRunner: ToolProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private var responses: [(executable: String, result: ToolProcessResult)]

    init(responses: [(executable: String, result: ToolProcessResult)] = []) {
        self.responses = responses
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Synchronous so the lock is not taken from an async context.
    private func record(_ executable: String, _ arguments: [String], _ environment: [String: String]?) -> ToolProcessResult? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Invocation(executable: executable, arguments: arguments, environment: environment))
        return responses.first { $0.executable == executable }?.result
    }

    func run(executable: String,
             arguments: [String],
             environment: [String: String]?,
             onLine: (@Sendable (String) -> Void)?) async -> ToolProcessResult {
        let result = record(executable, arguments, environment) ?? ToolProcessResult(status: 0, output: "")
        if let onLine {
            for line in result.output.split(separator: "\n", omittingEmptySubsequences: true) {
                onLine(String(line))
            }
        }
        return result
    }
}

/// Collects the lines a runner streams. A class (not a captured `var`) so the
/// `@Sendable` line closures stay warning-free.
final class LineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(line)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - Doctor

/// What the pane shows: which tools exist, where, and at what version.
final class ToolDoctorTests: XCTestCase {

    private let openconnectOutput = "OpenConnect version v9.21\nUsing GnuTLS 3.8.13"

    func testAMissingToolIsAbsentWithNoPathAndNoVersion() async {
        let doctor = ToolDoctor(requirements: [.stoken],
                                locator: FakeToolLocator([:]),
                                runner: RecordingToolRunner())

        let statuses = await doctor.inspect()
        XCTAssertEqual(statuses.count, 1)
        XCTAssertFalse(statuses[0].isInstalled)
        XCTAssertNil(statuses[0].path)
        XCTAssertNil(statuses[0].version)
        XCTAssertEqual(statuses[0].versionSummary, "not installed")
    }

    func testAnInstalledToolReportsItsPathAndVersion() async {
        let runner = RecordingToolRunner(responses: [
            ("/opt/local/bin/openconnect", ToolProcessResult(status: 0, output: openconnectOutput))
        ])
        let doctor = ToolDoctor(requirements: [.openconnect],
                                locator: FakeToolLocator(["openconnect": "/opt/local/bin/openconnect"]),
                                runner: runner)

        let status = (await doctor.inspect())[0]
        XCTAssertEqual(status.path, "/opt/local/bin/openconnect")
        XCTAssertEqual(status.version, "9.21")
        XCTAssertEqual(status.versionSummary, "9.21")
        // The version came from the resolved path, not from PATH.
        XCTAssertEqual(runner.invocations.map(\.executable), ["/opt/local/bin/openconnect"])
        XCTAssertEqual(runner.invocations.first?.arguments, ["--version"])
    }

    /// A tool that exists but cannot answer is *installed* — the pane must not
    /// claim it is missing, and must not invent a version.
    func testAToolThatExistsButFailsToAnswerIsStillInstalled() async {
        let runner = RecordingToolRunner(responses: [
            ("/usr/bin/stoken", ToolProcessResult(status: 1, output: "dyld: library not loaded"))
        ])
        let doctor = ToolDoctor(requirements: [.stoken],
                                locator: FakeToolLocator(["stoken": "/usr/bin/stoken"]),
                                runner: runner)

        let status = (await doctor.inspect())[0]
        XCTAssertTrue(status.isInstalled)
        XCTAssertNil(status.version)
        XCTAssertEqual(status.versionSummary, "version unknown")
    }

    func testNothingIsRunForAToolThatIsNotThere() async {
        let runner = RecordingToolRunner()
        let doctor = ToolDoctor(requirements: [.openconnect, .stoken], locator: FakeToolLocator([:]), runner: runner)

        _ = await doctor.inspect()
        XCTAssertTrue(runner.invocations.isEmpty, "a missing binary must not be executed")
    }

    func testInspectWalksTheWholeTableInOrder() async {
        let doctor = ToolDoctor(requirements: ToolRequirement.all,
                                locator: FakeToolLocator([:]),
                                runner: RecordingToolRunner())

        let ids = await doctor.inspect().map(\.id)
        XCTAssertEqual(ids, ["brew", "openconnect", "stoken", "vpn-slice"])
    }

    func testMissingForConnectionUsesTheLocatorNotTheRealMachine() async {
        let doctor = ToolDoctor(locator: FakeToolLocator(["openconnect": "/usr/bin/openconnect"]),
                                runner: RecordingToolRunner())

        XCTAssertEqual(doctor.missing(forConnection: false).map(\.id), ["stoken"])
        XCTAssertEqual(doctor.missing(forConnection: true).map(\.id), ["stoken", "vpn-slice"])
    }
}

// MARK: - Install

/// The install command, which is the one thing here that changes a user's
/// machine — so it is pinned exactly.
final class ToolInstallerTests: XCTestCase {

    func testThePlanIsABareBrewInstall() {
        let plan = ToolInstaller.plan(for: [.openconnect, .stoken, .vpnSlice],
                                      brewPath: "/opt/homebrew/bin/brew",
                                      environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(plan?.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(plan?.arguments, ["install", "openconnect", "stoken", "vpn-slice"])
        XCTAssertEqual(plan?.commandLine, "/opt/homebrew/bin/brew install openconnect stoken vpn-slice")
    }

    /// The rule this whole type exists to keep: the app never escalates. No
    /// `sudo` in the binary, the arguments or the environment.
    func testThePlanNeverMentionsSudo() {
        let plan = ToolInstaller.plan(for: ToolRequirement.installable,
                                      brewPath: "/opt/homebrew/bin/brew",
                                      environment: ["PATH": "/usr/bin", "LANG": "en_US.UTF-8"])!
        let argv = [plan.executable] + plan.arguments
        XCTAssertFalse(argv.contains { $0.contains("sudo") }, argv.joined(separator: " "))
        XCTAssertFalse(plan.commandLine.contains("sudo"))
        // It is the resolved brew binary that runs — never a shell that could
        // be handed a different command.
        XCTAssertFalse(plan.executable.hasSuffix("sh"), plan.executable)
    }

    func testTheEnvironmentPutsHomebrewOnThePathAndQuietsTheHints() {
        let plan = ToolInstaller.plan(for: [.openconnect],
                                      brewPath: "/opt/homebrew/bin/brew",
                                      environment: ["PATH": "/usr/bin", "HOME": "/Users/tester"])!

        XCTAssertEqual(plan.environment["PATH"], "/opt/homebrew/bin:/usr/bin")
        XCTAssertEqual(plan.environment["HOMEBREW_NO_ENV_HINTS"], "1")
        XCTAssertEqual(plan.environment["HOME"], "/Users/tester", "the user's own environment is preserved")
    }

    func testAnEmptyPathInTheEnvironmentStillGetsHomebrew() {
        let plan = ToolInstaller.plan(for: [.openconnect],
                                      brewPath: "/usr/local/bin/brew",
                                      environment: [:])!
        XCTAssertEqual(plan.environment["PATH"], "/usr/local/bin")
    }

    /// Homebrew itself has no formula, so a request to "install" it is a no-op
    /// rather than `brew install` with nothing after it.
    func testThereIsNoPlanWhenThereIsNothingToInstall() {
        XCTAssertNil(ToolInstaller.plan(for: [.homebrew],
                                        brewPath: "/opt/homebrew/bin/brew",
                                        environment: [:]))
        XCTAssertNil(ToolInstaller.plan(for: [],
                                        brewPath: "/opt/homebrew/bin/brew",
                                        environment: [:]))
    }

    func testInstallingRunsThePlannedCommandAndStreamsItsOutput() async {
        let runner = RecordingToolRunner(responses: [
            ("/opt/homebrew/bin/brew",
             ToolProcessResult(status: 0, output: "==> Downloading openconnect\n==> Pouring openconnect"))
        ])
        let installer = ToolInstaller(runner: runner)

        let streamed = LineRecorder()
        let result = await installer.install([.openconnect],
                                            brewPath: "/opt/homebrew/bin/brew",
                                            environment: ["PATH": "/usr/bin"]) { line in
            streamed.append(line)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations[0].arguments, ["install", "openconnect"])
        XCTAssertEqual(streamed.lines, ["==> Downloading openconnect", "==> Pouring openconnect"])
    }

    func testAFailedInstallIsReportedWithHomebrewsOwnLastLine() async {
        let runner = RecordingToolRunner(responses: [
            ("/opt/homebrew/bin/brew",
             ToolProcessResult(status: 1, output: "==> Downloading\nError: openconnect: no bottle available"))
        ])
        let result = await ToolInstaller(runner: runner).install([.openconnect],
                                                                 brewPath: "/opt/homebrew/bin/brew",
                                                                 environment: [:])
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.lastLine, "Error: openconnect: no bottle available")
    }

    func testInstallingNothingRunsNothing() async {
        let runner = RecordingToolRunner()
        let result = await ToolInstaller(runner: runner).install([.homebrew],
                                                                 brewPath: "/opt/homebrew/bin/brew",
                                                                 environment: [:])
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(runner.invocations.isEmpty)
    }
}

// MARK: - Output plumbing

/// Streaming matters: a `brew install` can take a minute, and the pane has to
/// show it moving. These are the parsing pieces, tested without a process.
final class ToolOutputTests: XCTestCase {

    func testLinesAreEmittedAsTheyCompleteAndTheTailIsHeld() {
        var buffer = "one\ntwo\nthree"
        XCTAssertEqual(ToolLineSplitter.takeCompleteLines(&buffer), ["one", "two"])
        XCTAssertEqual(buffer, "three", "an unterminated line waits for more input")
    }

    func testCarriageReturnsAreTerminatorsAndCarriageReturnNewlineIsOne() {
        var buffer = "progress 10%\rprogress 20%\r\ndone\n"
        XCTAssertEqual(ToolLineSplitter.takeCompleteLines(&buffer),
                       ["progress 10%", "progress 20%", "done"])
        XCTAssertEqual(buffer, "")
    }

    /// A read can end between the CR and the LF. The line is only complete once
    /// the LF arrives, and no empty line may be invented for the pending CR.
    func testACarriageReturnAtTheEndOfAReadWaitsForTheNextByte() {
        var buffer = "progress 10%\r"
        XCTAssertEqual(ToolLineSplitter.takeCompleteLines(&buffer), [])
        XCTAssertEqual(buffer, "progress 10%\r", "the CR is held for the next read")

        buffer += "\nnext"
        XCTAssertEqual(ToolLineSplitter.takeCompleteLines(&buffer), ["progress 10%"])
        XCTAssertEqual(buffer, "next")
    }

    /// A lone CR followed by real text still ends its line.
    func testAStandaloneCarriageReturnEndsItsLine() {
        var buffer = "progress 10%\rdone\n"
        XCTAssertEqual(ToolLineSplitter.takeCompleteLines(&buffer), ["progress 10%", "done"])
        XCTAssertEqual(buffer, "")
    }

    func testBlankLinesBetweenOutputAreKept() {
        var buffer = "a\n\nb\n"
        XCTAssertEqual(ToolLineSplitter.takeCompleteLines(&buffer), ["a", "", "b"])
    }

    func testAPathologicalLineIsTrimmed() {
        var buffer = String(repeating: "x", count: ToolOutputCollector.lineLimit + 50) + "\n"
        let lines = ToolLineSplitter.takeCompleteLines(&buffer)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].count, ToolOutputCollector.lineLimit)
    }

    func testTheCollectedOutputIsBoundedToItsTail() {
        let collector = ToolOutputCollector(onLine: nil)
        // Each line is trimmed to the per-line limit first, so this is ~80 ×
        // 4000 chars — well past the retained cap.
        for index in 0..<80 {
            let line = "\(index)".padding(toLength: ToolOutputCollector.lineLimit,
                                          withPad: "x",
                                          startingAt: 0)
            collector.append(line + "\n")
        }
        let output = collector.finish()
        XCTAssertEqual(output.count, ToolOutputCollector.retainedLimit)
        XCTAssertTrue(output.hasSuffix("x"), "the tail is what a failure is reported from")
    }

    func testTheRemainderIsFlushedWhenTheProcessEnds() {
        let streamed = LineRecorder()
        let collector = ToolOutputCollector(onLine: { streamed.append($0) })
        collector.append("no trailing newline")
        let output = collector.finish()
        XCTAssertEqual(streamed.lines, ["no trailing newline"])
        XCTAssertEqual(output, "no trailing newline")
    }

    func testOutputIsSplitIntoLinesInOrder() {
        let streamed = LineRecorder()
        let collector = ToolOutputCollector(onLine: { streamed.append($0) })
        collector.append("==> Downloading\n==> Pouring\n")
        collector.append("==> Caveats\n")
        _ = collector.finish()
        XCTAssertEqual(streamed.lines, ["==> Downloading", "==> Pouring", "==> Caveats"])
    }

    func testAResultKnowsWhetherItSucceededAndItsLastLine() {
        XCTAssertTrue(ToolProcessResult(status: 0, output: "done").succeeded)
        XCTAssertFalse(ToolProcessResult(status: 1, output: "Error: nope").succeeded)
        XCTAssertEqual(ToolProcessResult(status: 1, output: "a\n\n  Error: nope  \n").lastLine, "Error: nope")
        XCTAssertEqual(ToolProcessResult(status: 1, output: "").lastLine, "")
    }
}
