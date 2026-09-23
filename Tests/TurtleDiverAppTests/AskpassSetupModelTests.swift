import XCTest
@testable import TurtleDiverAppGlue
@testable import TurtleDiverSystem

/// Covers the Settings ▸ VPN action that prepares the app's askpass helper.
///
/// The two things worth pinning are the shape of the command — `sudo -A -v` with
/// the helper named in its environment, which is the only thing that makes macOS
/// ask about *that* program — and what gets recorded afterwards: the helper's
/// designated requirement, never a bare "yes". Everything else here is about
/// telling the user the truth when it did not work.
///
/// No test runs `sudo`, reads the Keychain or raises a dialog: the step is
/// injected, and the fingerprints are supplied.
@MainActor
final class AskpassSetupModelTests: XCTestCase {

    private var defaults: UserDefaults!
    private var settings: SettingsManager!
    private var bundle: URL!

    /// A step that answers "the helper printed the password", recording what it
    /// was asked to run so the command itself can be asserted.
    private final class Recorder {
        var arguments: [String] = []
        var environment: [String: String] = [:]
        var stdin: Data?
        var timeouts: [TimeInterval] = []
        var result = TunnelAgentChannel.SudoStepRunner.Result(
            terminationStatus: 0, timedOut: false, launchError: nil, stderr: ""
        )

        func step(arguments: [String], stdin: Data?, timeout: TimeInterval,
                  environment: [String: String]) -> TunnelAgentChannel.SudoStepRunner.Result {
            self.arguments = arguments
            self.stdin = stdin
            self.timeouts.append(timeout)
            self.environment = environment
            return result
        }
    }

    override func setUpWithError() throws {
        let suite = "askpass-setup-model-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsManager(defaults: defaults!)
        bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askpass-model-\(UUID().uuidString)/TurtleDiver.app")
        try placeHelper()
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: try XCTUnwrap(defaults.volatileDomainNames.first))
        try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
        settings = nil
    }

    private func placeHelper() throws {
        let helper = AskpassProgram.bundledPath(bundleURL: bundle)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: helper).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: URL(fileURLWithPath: helper))
        // The model uses the real executable check, so the stand-in has to be
        // executable — a file that only exists is not a helper anyone could run.
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: helper)
    }

    private func model(recorded: String? = nil,
                       fingerprint: @escaping (String) -> String?,
                       recorder: Recorder = Recorder()) -> AskpassSetupModel {
        if let recorded { settings.askpassHelperRequirement = recorded }
        return AskpassSetupModel(settings: settings,
                                 bundleURL: bundle,
                                 step: recorder.step,
                                 fingerprint: fingerprint)
    }

    // MARK: - The state the row shows

    func testAFreshInstallIsNotPrepared() {
        let model = self.model(fingerprint: { _ in "req" })

        XCTAssertEqual(model.status, .notPrepared)
        XCTAssertTrue(model.canPrepare)
        XCTAssertFalse(model.canForget, "there is nothing to forget yet")
        XCTAssertTrue(AskpassSetupModel.caption(for: .notPrepared).contains("Not set up"))
    }

    func testABuildWithoutTheHelperCannotPrepare() throws {
        try FileManager.default.removeItem(at: bundle)

        let model = self.model(fingerprint: { _ in "req" })
        XCTAssertEqual(model.status, .unavailable)
        XCTAssertFalse(model.canPrepare, "a button that could never work must not be offered")
        XCTAssertNil(model.helperPathShown)
    }

    func testARecordThatStillMatchesTheHelperMeansReady() {
        let model = self.model(recorded: "identifier \"turtlediver-askpass\"",
                               fingerprint: { _ in "identifier \"turtlediver-askpass\"" })

        XCTAssertEqual(model.status, .ready)
        XCTAssertTrue(model.canForget)
        XCTAssertTrue(AskpassSetupModel.caption(for: .ready).contains("Ready"))
    }

    /// The whole reason the record is a requirement and not a flag: a rebuild
    /// puts a different program at the same path, and the row must say so
    /// instead of promising a connect nobody has to watch.
    func testAStaleRecordIsNotReady() {
        let model = self.model(recorded: "cdhash H\"the build before this one\"",
                               fingerprint: { _ in "cdhash H\"this build\"" })

        XCTAssertEqual(model.status, .notPrepared)
        XCTAssertTrue(model.canPrepare, "a rebuild is exactly when preparing again is needed")
    }

    // MARK: - Preparing

    func testPreparingAsksSudoForTheTimestampThroughTheHelper() async throws {
        let recorder = Recorder()
        let model = self.model(fingerprint: { _ in "req" }, recorder: recorder)

        await model.prepare()

        XCTAssertEqual(recorder.arguments, ["-A", "-v"],
                       "`-A` is the form whose askpass program is the helper; `-v` starts nothing")
        XCTAssertEqual(recorder.environment,
                       ["SUDO_ASKPASS": try XCTUnwrap(model.helperPathShown)],
                       "the environment carries the helper's path and nothing else")
        XCTAssertNil(recorder.stdin, "/dev/null, not a pipe: there is nothing to write")
        XCTAssertEqual(recorder.timeouts, [AskpassSetupModel.preparationTimeout])
    }

    func testASuccessfulPreparationRecordsTheHelperAndSaysSo() async {
        let model = self.model(fingerprint: { _ in "identifier \"turtlediver-askpass\"" })

        await model.prepare()

        XCTAssertEqual(settings.askpassHelperRequirement, "identifier \"turtlediver-askpass\"")
        XCTAssertEqual(model.status, .ready)
        XCTAssertNotNil(model.outcome)
        XCTAssertTrue(try XCTUnwrap(model.outcome).contains(AskpassProgram.installedName))
        XCTAssertFalse(model.isPreparing)
    }

    /// An unsigned build is approved by the Keychain but cannot be named
    /// afterwards. Recording a blank would be worse than recording nothing: the
    /// next connect would trust whatever is at the path.
    func testAHelperThatCannotBeFingerprintedIsNotRecorded() async {
        let model = self.model(fingerprint: { _ in nil })

        await model.prepare()

        XCTAssertEqual(settings.askpassHelperRequirement, "")
        XCTAssertEqual(model.status, .notPrepared)
        XCTAssertTrue(try XCTUnwrap(model.outcome).contains("signature"))
    }

    /// `sudo`'s own words are kept: they name a wrong password or a refused
    /// Keychain read better than a sentence written here could.
    func testARefusalKeepsWhatSudoSaid() async {
        let recorder = Recorder()
        recorder.result = TunnelAgentChannel.SudoStepRunner.Result(
            terminationStatus: 1, timedOut: false, launchError: nil,
            stderr: "sudo: 1 incorrect password attempt\n"
        )
        let model = self.model(fingerprint: { _ in "req" }, recorder: recorder)

        await model.prepare()

        XCTAssertEqual(model.status, .notPrepared, "nothing was approved, and the row must not claim otherwise")
        XCTAssertEqual(settings.askpassHelperRequirement, "")
        let outcome = try? XCTUnwrap(model.outcome)
        XCTAssertTrue(outcome?.contains("incorrect password") == true)
    }

    /// An unanswered dialog is the one refusal that is not the user's mistake,
    /// and it must not read like one.
    func testAnUnansweredDialogIsExplainedAsSuch() {
        let timedOut = TunnelAgentChannel.SudoStepRunner.Result(
            terminationStatus: -1, timedOut: true, launchError: nil, stderr: ""
        )
        let text = AskpassSetupModel.refusalText(timedOut)
        XCTAssertTrue(text.contains(AskpassProgram.installedName))
        XCTAssertTrue(text.lowercased().contains("macos asked"))
    }

    func testAHelperThatCouldNotStartNamesTheReasonItCouldNot() {
        let failed = TunnelAgentChannel.SudoStepRunner.Result(
            terminationStatus: -1, timedOut: false, launchError: "The file does not exist.", stderr: ""
        )
        XCTAssertTrue(AskpassSetupModel.refusalText(failed).contains("The file does not exist."))

        let silent = TunnelAgentChannel.SudoStepRunner.Result(
            terminationStatus: 1, timedOut: false, launchError: nil, stderr: "  \n"
        )
        let text = AskpassSetupModel.refusalText(silent)
        XCTAssertTrue(text.contains("exited 1"), "a silent failure still has to say something exact")
    }

    // MARK: - Forgetting

    func testForgettingOnlyStopsTheAppFromUsingTheHelper() {
        let model = self.model(recorded: "req", fingerprint: { _ in "req" })

        model.forget()

        XCTAssertEqual(settings.askpassHelperRequirement, "")
        XCTAssertEqual(model.status, .notPrepared, "the row must say what the next connect will do")
        XCTAssertTrue(model.canPrepare)
    }

    /// The pane's own state decides whether preparing is even meaningful: an
    /// empty Keychain or an unsaved password would make the helper print
    /// something the user never sees, and the refusal would look like a bug.
    func testPreparationUsesTheStoredPasswordWhichIsWhyThePaneGatesIt() throws {
        let view = try String(contentsOfFile: viewSourcePath, encoding: .utf8)

        XCTAssertTrue(view.contains("askpass.canPrepare && hasStoredAdminPassword && draft.adminPassword == loaded.adminPassword"),
                      "preparing must be gated on what the Keychain actually holds")
        XCTAssertTrue(view.contains("hasStoredAdminPassword = !settings.adminPassword.isEmpty"))
        XCTAssertTrue(view.contains("AskpassSetupModel.caption(for: askpass.status)"))
        XCTAssertTrue(view.contains("await askpass.prepare()"))
    }

    private var viewSourcePath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VPNConnect/SettingsView.swift")
            .path
    }
}
