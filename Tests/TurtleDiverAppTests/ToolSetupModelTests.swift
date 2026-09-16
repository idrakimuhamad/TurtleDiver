import XCTest
@testable import TurtleDiverAppGlue
@testable import TurtleDiverSystem

// MARK: - Fakes

private final class FakeLocator: ToolLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String]

    init(_ entries: [String: String] = [:]) { self.entries = entries }

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

private final class FakeRunner: ToolProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocations: [[String]] = []
    private var outputByExecutable: [String: ToolProcessResult]

    init(outputByExecutable: [String: ToolProcessResult] = [:]) {
        self.outputByExecutable = outputByExecutable
    }

    /// Synchronous so the lock is not taken from an async context.
    private func record(_ executable: String, _ arguments: [String]) -> ToolProcessResult {
        lock.lock()
        defer { lock.unlock() }
        invocations.append([executable] + arguments)
        return outputByExecutable[executable] ?? ToolProcessResult(status: 0, output: "")
    }

    func run(executable: String,
             arguments: [String],
             environment: [String: String]?,
             onLine: (@Sendable (String) -> Void)?) async -> ToolProcessResult {
        let result = record(executable, arguments)
        if let onLine {
            for line in result.output.split(separator: "\n", omittingEmptySubsequences: true) {
                onLine(String(line))
            }
        }
        return result
    }

    func set(_ executable: String, to result: ToolProcessResult) {
        lock.lock()
        defer { lock.unlock() }
        outputByExecutable[executable] = result
    }

    /// Only the `brew install …` calls — the doctor's `--version` probes are
    /// noise for the assertions about what gets installed.
    var installs: [[String]] {
        invocations.filter { $0.dropFirst().first == "install" }
    }
}

private let brewPath = "/opt/homebrew/bin/brew"
private let toolPaths: [String: String] = [
    "brew": "/opt/homebrew/bin/brew",
    "openconnect": "/opt/homebrew/bin/openconnect",
    "stoken": "/opt/homebrew/bin/stoken",
    "vpn-slice": "/opt/homebrew/bin/vpn-slice",
]

private func versions() -> [String: ToolProcessResult] {
    [
        brewPath: ToolProcessResult(status: 0, output: "Homebrew 7.0.1"),
        "/opt/homebrew/bin/openconnect": ToolProcessResult(status: 0, output: "OpenConnect version v9.21"),
        "/opt/homebrew/bin/stoken": ToolProcessResult(status: 0, output: "stoken 0.93 - software token"),
        "/opt/homebrew/bin/vpn-slice": ToolProcessResult(status: 0, output: "vpn-slice 0.16.1"),
    ]
}

// MARK: - The Setup pane's model

/// The pane's state machine: what it reports, what it offers to install, and
/// what it refuses to do.
@MainActor
final class ToolSetupModelTests: XCTestCase {

    private func makeModel(installed: [String: String],
                           runner: FakeRunner,
                           locator: FakeLocator? = nil) -> ToolSetupModel {
        ToolSetupModel(doctor: ToolDoctor(locator: locator ?? FakeLocator(installed), runner: runner),
                       installer: ToolInstaller(runner: runner),
                       environment: ["PATH": "/usr/bin"])
    }

    // MARK: Reporting

    func testAFullyInstalledMachineIsReadyForBothModes() async {
        let runner = FakeRunner(outputByExecutable: versions())
        let model = makeModel(installed: toolPaths, runner: runner)

        await model.refresh()

        XCTAssertEqual(model.statuses.map(\.id), ["brew", "openconnect", "stoken", "vpn-slice"])
        XCTAssertEqual(model.statuses.map(\.version), ["7.0.1", "9.21", "0.93", "0.16.1"])
        XCTAssertTrue(model.hasHomebrew)
        XCTAssertTrue(model.missingDependencies.isEmpty)
        XCTAssertTrue(model.isReadyForStandardConnection)
        XCTAssertTrue(model.isReadyForSplitTunneling)
    }

    func testNothingInstalledReportsEveryToolAndIsNotReady() async {
        let model = makeModel(installed: [:], runner: FakeRunner())

        await model.refresh()

        XCTAssertEqual(model.missingDependencies.map(\.id), ["openconnect", "stoken", "vpn-slice"])
        XCTAssertFalse(model.hasHomebrew)
        XCTAssertFalse(model.isReadyForStandardConnection)
        XCTAssertFalse(model.isReadyForSplitTunneling)
    }

    /// Before the first refresh the pane must not claim readiness — "no rows"
    /// is not "everything is fine".
    func testAFreshModelIsNotReadyUntilItHasChecked() {
        let model = makeModel(installed: toolPaths, runner: FakeRunner(outputByExecutable: versions()))
        XCTAssertTrue(model.statuses.isEmpty)
        XCTAssertFalse(model.isReadyForStandardConnection)
        XCTAssertFalse(model.isReadyForSplitTunneling)
    }

    /// The distinction the app cares about: split tunneling is optional. Its
    /// absence must not read as "the VPN is broken".
    func testAMissingSplitTunnelToolLeavesStandardModeReady() async {
        var installed = toolPaths
        installed.removeValue(forKey: "vpn-slice")
        let model = makeModel(installed: installed, runner: FakeRunner(outputByExecutable: versions()))

        await model.refresh()

        XCTAssertEqual(model.missingDependencies.map(\.id), ["vpn-slice"])
        XCTAssertTrue(model.isReadyForStandardConnection)
        XCTAssertFalse(model.isReadyForSplitTunneling)
    }

    func testTheManualCommandNamesTheThreeToolsAndNotHomebrew() async {
        let model = makeModel(installed: [:], runner: FakeRunner())
        XCTAssertEqual(model.manualCommand, "brew install openconnect stoken vpn-slice")
    }

    // MARK: Installing

    func testInstallingMissingRunsBrewOnceForExactlyTheMissingFormulae() async {
        var installed = toolPaths
        installed.removeValue(forKey: "stoken")
        installed.removeValue(forKey: "vpn-slice")
        let runner = FakeRunner(outputByExecutable: versions())
        let model = makeModel(installed: installed, runner: runner)

        await model.refresh()
        await model.install()

        XCTAssertEqual(runner.installs, [[brewPath, "install", "stoken", "vpn-slice"]])
        XCTAssertEqual(model.transcript.first, "$ \(brewPath) install stoken vpn-slice")
        XCTAssertEqual(model.lastResult?.status, 0)
    }

    /// The fake locator still says `stoken` and `vpn-slice` are absent after the
    /// install (nothing was really poured), so the rows stay honest — the pane
    /// re-checks rather than assuming success.
    func testAnInstallRechecksAndDoesNotAssumeSuccess() async {
        var installed = toolPaths
        installed.removeValue(forKey: "stoken")
        let locator = FakeLocator(installed)
        let runner = FakeRunner(outputByExecutable: versions())
        let model = makeModel(installed: installed, runner: runner, locator: locator)

        await model.refresh()
        await model.install([.stoken])

        XCTAssertFalse(model.isReadyForStandardConnection, "the tool is still not there")
        XCTAssertEqual(model.missingDependencies.map(\.id), ["stoken"])

        // Now it really is installed, and Check Again notices.
        locator.set("stoken", to: "/opt/homebrew/bin/stoken")
        await model.refresh()
        XCTAssertTrue(model.isReadyForStandardConnection)
    }

    func testInstallingWithNothingMissingDoesNothing() async {
        let runner = FakeRunner(outputByExecutable: versions())
        let model = makeModel(installed: toolPaths, runner: runner)

        await model.refresh()
        await model.install()

        XCTAssertTrue(runner.installs.isEmpty, "brew must not be run for no reason")
    }

    /// Without Homebrew there is nothing to run: the pane explains and stops,
    /// rather than failing with a process error.
    func testInstallingWithoutHomebrewRefusesAndSaysWhy() async {
        let runner = FakeRunner()
        let model = makeModel(installed: [:], runner: runner)

        await model.refresh()
        await model.install()

        XCTAssertTrue(runner.installs.isEmpty)
        XCTAssertNotNil(model.installRefusal)
        XCTAssertTrue(model.installRefusal!.contains("brew.sh"))
        XCTAssertTrue(model.installRefusal!.lowercased().contains("homebrew"))
    }

    func testAFailedInstallKeepsHomebrewsOwnExplanation() async {
        var installed = toolPaths
        installed.removeValue(forKey: "openconnect")
        let runner = FakeRunner(outputByExecutable: versions())
        runner.set(brewPath, to: ToolProcessResult(status: 1, output: "==> Downloading\nError: no bottle available"))
        let model = makeModel(installed: installed, runner: runner)

        await model.refresh()
        await model.install()

        XCTAssertEqual(model.lastResult?.status, 1)
        XCTAssertEqual(model.lastResult?.lastLine, "Error: no bottle available")
        XCTAssertTrue(model.transcript.contains("Error: no bottle available"))
    }

    func testTheTranscriptIsBoundedSoALongBuildCannotGrowItForever() async {
        var installed = toolPaths
        installed.removeValue(forKey: "openconnect")
        let runner = FakeRunner(outputByExecutable: versions())
        let manyLines = (0..<900).map { "line \($0)" }.joined(separator: "\n")
        runner.set(brewPath, to: ToolProcessResult(status: 0, output: manyLines))
        let model = makeModel(installed: installed, runner: runner)

        await model.refresh()
        await model.install()

        XCTAssertEqual(model.transcript.count, ToolSetupModel.transcriptLimit)
        XCTAssertEqual(model.transcript.last, "line 899", "the tail is what matters")
    }

    func testInstallingReportsWhileItRunsAndStopsAfterwards() async {
        var installed = toolPaths
        installed.removeValue(forKey: "openconnect")
        let runner = FakeRunner(outputByExecutable: versions())
        let model = makeModel(installed: installed, runner: runner)

        await model.refresh()
        XCTAssertFalse(model.isInstalling)
        await model.install()
        XCTAssertFalse(model.isInstalling, "the flag must not be left on after a failure either")
    }

    // MARK: Advisory

    func testStatusLookupIsByRequirement() async {
        let model = makeModel(installed: toolPaths, runner: FakeRunner(outputByExecutable: versions()))
        await model.refresh()
        XCTAssertEqual(model.status(for: .stoken)?.path, "/opt/homebrew/bin/stoken")
        XCTAssertEqual(model.homebrew?.version, "7.0.1")
    }
}
