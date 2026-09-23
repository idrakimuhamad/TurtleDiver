import XCTest

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Covers the decision "may a connect use the app's own askpass helper?".
///
/// The rule the type exists for: a *person* approves the helper once, in
/// Settings, and a *connect* uses it only while the recorded approval still names
/// the program that is actually in the bundle. A plain "prepared" flag would pass
/// the first half and fail the second — on an ad-hoc build the requirement embeds
/// the code hash, so a rebuild replaces the approved program with a different one
/// at the same path (`docs/ELEVATION.md` §11).
///
/// The fingerprints here are injected. The one thing worth exercising for real is
/// the Security framework call itself, and that is done against two programs this
/// Mac certainly has — `/bin/sh` and `/bin/ls` — rather than against the app's own
/// helper, which a `swift test` run has not built.
final class AskpassSetupTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askpass-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// Writes a file where the helper would be, so the bundle lookup has something
    /// to find. It is never executed: only its existence is consulted here.
    private func placeFakeHelper(in bundle: URL) throws -> String {
        let helper = AskpassProgram.bundledPath(bundleURL: bundle)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: helper).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: URL(fileURLWithPath: helper))
        return helper
    }

    // MARK: - The real fingerprint

    func testTheFingerprintOfARealProgramIsItsDesignatedRequirement() throws {
        let fingerprint = try XCTUnwrap(AskpassSetup.fingerprint(ofProgramAt: "/bin/sh"),
                                        "a signed system program must have a designated requirement")
        XCTAssertFalse(fingerprint.isEmpty)
        // Apple's binaries carry an identifier requirement; ad-hoc ones carry a
        // cdhash. Either is a genuine requirement — what must never happen is a
        // fingerprint that names nothing at all.
        XCTAssertTrue(fingerprint.contains("identifier") || fingerprint.contains("cdhash"),
                      "not a requirement text: \(fingerprint)")
    }

    func testTwoProgramsDoNotShareAFingerprint() throws {
        let shell = try XCTUnwrap(AskpassSetup.fingerprint(ofProgramAt: "/bin/sh"))
        let listing = try XCTUnwrap(AskpassSetup.fingerprint(ofProgramAt: "/bin/ls"))

        XCTAssertNotEqual(shell, listing,
                          "two different programs fingerprinted the same, which would approve either")
    }

    func testAProgramThatIsNotThereHasNoFingerprint() {
        XCTAssertNil(AskpassSetup.fingerprint(ofProgramAt: sandbox.appendingPathComponent("gone").path))
        XCTAssertNil(AskpassSetup.fingerprint(ofProgramAt: sandbox.path))
    }

    // MARK: - Prepared means "that program, still"

    func testAPreparedHelperMustMatchTheRecordedRequirement() {
        let helper = "/somewhere/turtlediver-askpass"
        let recorded = "identifier \"turtlediver-askpass\" and anchor apple generic"

        XCTAssertTrue(AskpassSetup.isPrepared(helperPath: helper, recorded: recorded,
                                              fingerprint: { _ in recorded }))
        XCTAssertFalse(AskpassSetup.isPrepared(helperPath: helper, recorded: nil,
                                               fingerprint: { _ in recorded }),
                       "a fresh install has not been set up")
        XCTAssertFalse(AskpassSetup.isPrepared(helperPath: helper, recorded: "",
                                               fingerprint: { _ in recorded }),
                       "an unset preference is not an approval")
        XCTAssertFalse(AskpassSetup.isPrepared(helperPath: helper, recorded: "cdhash H\"something else\"",
                                               fingerprint: { _ in recorded }),
                       "a rebuilt helper at the same path must not inherit the old approval")
        XCTAssertFalse(AskpassSetup.isPrepared(helperPath: helper, recorded: recorded,
                                               fingerprint: { _ in nil }),
                       "a helper the fingerprint cannot name must never be treated as approved")
    }

    // MARK: - Which helper a connect may use

    func testAConnectMayUseTheHelperOnlyWhenItIsThereAndUnchanged() throws {
        let bundle = sandbox.appendingPathComponent("TurtleDiver.app")
        let helper = try placeFakeHelper(in: bundle)
        let executable: (String) -> Bool = { $0 == helper }
        let recorded = "identifier \"turtlediver-askpass\""

        XCTAssertEqual(AskpassSetup.usableHelperPath(bundleURL: bundle, recorded: recorded,
                                                     isExecutable: executable,
                                                     fingerprint: { _ in recorded }),
                       helper)
        XCTAssertNil(AskpassSetup.usableHelperPath(bundleURL: bundle, recorded: nil,
                                                   isExecutable: executable,
                                                   fingerprint: { _ in recorded }),
                     "nothing was prepared, so the connect must ask the system as before")
        XCTAssertNil(AskpassSetup.usableHelperPath(bundleURL: bundle, recorded: recorded,
                                                   isExecutable: executable,
                                                   fingerprint: { _ in "cdhash H\"rebuilt\"" }),
                     "the bundle holds a different program than the one that was approved")
    }

    func testABundleWithoutTheHelperYieldsNothing() {
        let bundle = sandbox.appendingPathComponent("Empty.app")

        XCTAssertNil(AskpassSetup.usableHelperPath(bundleURL: bundle, recorded: "anything",
                                                   fingerprint: { _ in "anything" }),
                     "no helper in the bundle means no askpass route, whatever was recorded")
    }

    /// The path used for the lookup is the one the helper itself answers to, so a
    /// build that moves the helper cannot leave the setup pointing at the old
    /// place.
    func testTheSearchedPathIsTheHelpersOwnInstalledPath() throws {
        let bundle = sandbox.appendingPathComponent("TurtleDiver.app")
        let helper = try placeFakeHelper(in: bundle)

        XCTAssertEqual(AskpassSetup.bundledHelperPath(bundleURL: bundle, isExecutable: { _ in true }),
                       AskpassProgram.bundledPath(bundleURL: bundle))
        XCTAssertEqual(helper, AskpassProgram.bundledPath(bundleURL: bundle))
        XCTAssertTrue(helper.hasSuffix("/Contents/Library/HelperTools/\(AskpassProgram.installedName)"))
    }

    func testWhatIsRecordedIsTheFingerprintAndNothingElse() {
        XCTAssertEqual(AskpassSetup.recordToStore(helperPath: "/h", fingerprint: { _ in "req" }), "req")
        XCTAssertNil(AskpassSetup.recordToStore(helperPath: "/h", fingerprint: { _ in nil }),
                     "an unnameable helper must not be recorded as prepared")
    }

    /// The preference is a name for a program, not a secret, and it is spelled
    /// once. A test rather than a comment because the key is read by Settings and
    /// by the connect, and a rename that touched one of them would silently mean
    /// "never prepared".
    func testThePreferenceKeyIsSpelledOnce() {
        XCTAssertEqual(AskpassSetup.defaultsKey, "askpassHelperRequirement")
    }
}
