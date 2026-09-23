import Foundation
import XCTest
import TurtleDiverSystem

/// The askpass program's *protocol* — the rules every copy of it obeys.
///
/// There are two copies on a machine that has both the app and the command line
/// tool installed: the tool installs itself under a second name, and the app
/// carries one inside its bundle at
/// `Contents/Library/HelperTools/turtlediver-askpass`. They are separate
/// binaries because the Keychain grant belongs to the program, and this type is
/// what keeps them one implementation: both print exactly the password, both
/// decide their mode from the name they were launched under, and both fail
/// without writing anything to standard output.
///
/// The tests below are written against the rules rather than against the call
/// sites, so a change of installation directory or of exit status fails here
/// first. The live end-to-end evidence (a real `sudo -A` run against a real
/// tunnel) is in `docs/ELEVATION.md`; nothing in this file touches a Keychain.
final class AskpassProgramTests: XCTestCase {

    // MARK: - Names

    func testTheProgramIsNamedForTheToolItBelongsTo() {
        // `sudo` prints this name in its own diagnostics and a person reads it in
        // Keychain Access, so it has to say which program is asking.
        XCTAssertEqual(AskpassProgram.installedName, "turtlediver-askpass")
        XCTAssertTrue(AskpassProgram.installedName.hasPrefix("turtlediver"))
    }

    func testTheEnvironmentVariableIsTheOneSudoReads() {
        // Spelled once for the whole project: `sudo` reads the helper's path from
        // this variable and from nowhere else.
        XCTAssertEqual(AskpassProgram.environmentVariable, "SUDO_ASKPASS")
    }

    func testTheAccountIsTheAppsAdministratorPassword() {
        XCTAssertEqual(AskpassProgram.administratorAccount, "adminPassword")
    }

    // MARK: - Where the helper lives in a bundle

    func testTheBundledPathIsTheConventionalHelperToolsDirectory() {
        let bundle = URL(fileURLWithPath: "/Applications/TurtleDiver.app")
        XCTAssertEqual(
            AskpassProgram.bundledPath(bundleURL: bundle),
            "/Applications/TurtleDiver.app/Contents/Library/HelperTools/turtlediver-askpass"
        )
        XCTAssertEqual(AskpassProgram.helperToolsDirectory, "Contents/Library/HelperTools")
    }

    func testABundledHelperThatIsNotExecutableIsNotAHelper() {
        // A file that is present but not runnable would make `sudo -A` fail with
        // its own generic sentence; answering `nil` lets the app say which
        // preparation step is missing instead.
        let bundle = URL(fileURLWithPath: "/Applications/TurtleDiver.app")
        XCTAssertNil(AskpassProgram.bundledHelper(in: bundle, isExecutable: { _ in false }))
        XCTAssertEqual(
            AskpassProgram.bundledHelper(in: bundle, isExecutable: { _ in true }),
            "/Applications/TurtleDiver.app/Contents/Library/HelperTools/turtlediver-askpass"
        )
    }

    func testTheBundledHelperIsOnlyLookedForInTheBundleGiven() {
        // The command line tool's copy is a different program to the Keychain, so
        // pointing the app at it would raise a second consent dialog and would
        // depend on an installation that need not exist.
        var asked: [String] = []
        _ = AskpassProgram.bundledHelper(
            in: URL(fileURLWithPath: "/Applications/TurtleDiver.app"),
            isExecutable: { asked.append($0); return false }
        )
        XCTAssertEqual(asked, ["/Applications/TurtleDiver.app/Contents/Library/HelperTools/turtlediver-askpass"])
    }

    // MARK: - How the helper knows it is the helper

    func testTheModeComesFromTheNameTheProgramWasStartedUnder() {
        for path in [
            "/Applications/TurtleDiver.app/Contents/Library/HelperTools/turtlediver-askpass",
            "/usr/local/bin/turtlediver-askpass",
            "turtlediver-askpass",   // a bare name, as `PATH` lookup would pass it
            "/private/tmp/dev/turtlediver-askpass",
        ] {
            XCTAssertTrue(AskpassProgram.isHelperInvocation(executablePath: path), path)
        }
    }

    func testNothingElseIsMistakenForTheHelper() {
        // A program that thought it was the helper would print the administrator
        // password to whoever ran it, so the neighbours matter as much as the
        // name: the tool itself, the tunnel agent, and near-misses.
        for path in [
            "/Applications/TurtleDiver.app/Contents/MacOS/TurtleDiver",
            "/usr/local/bin/turtlediver",
            "/usr/local/libexec/turtlediver-agent",
            "/usr/local/bin/turtlediver-askpass-helper",
            "/usr/local/bin/turtlediver-askpass2",
            "/usr/local/bin/askpass",
            "",
            "/",
        ] {
            XCTAssertFalse(AskpassProgram.isHelperInvocation(executablePath: path), path)
        }
        XCTAssertFalse(AskpassProgram.isHelperInvocation(executablePath: nil))
    }

    func testThePathIsWhateverTheCallerWrote() {
        // `argv[0]` is what decides the mode, so this must not be normalised into
        // an absolute path or resolved through the filesystem.
        XCTAssertEqual(AskpassProgram.ownPath(), CommandLine.arguments.first)
    }

    // MARK: - Printing the password

    func testTheOnlyOutputIsThePasswordAndANewline() {
        let captured = capture(read: { .value("hunter2") })
        XCTAssertEqual(captured.out, "hunter2\n")
        XCTAssertEqual(captured.err, "")
        XCTAssertEqual(captured.outcome, .printedPassword)
    }

    func testThePasswordIsPrintedVerbatim() {
        // No quoting, no trimming, no escaping: `sudo` reads this stream as the
        // password, so anything added to it is added to the password.
        let secret = "  p@ss word\twith spaces  "
        let captured = capture(read: { .value(secret) })
        XCTAssertEqual(captured.out, secret + "\n")
    }

    func testAMissingItemFailsWithoutPrintingAnything() {
        let captured = capture(read: { .missing })
        XCTAssertEqual(captured.out, "", "a failure must not put a line into sudo's password stream")
        XCTAssertEqual(captured.outcome, .failed)
        XCTAssertTrue(captured.err.contains(AskpassProgram.installedName), captured.err)
    }

    func testARefusedItemFailsWithoutPrintingAnything() {
        // The sentence is the one the shipped callers use: what matters here is
        // that a refusal never becomes output, and that the reason reaches the
        // person reading `sudo`'s diagnostics.
        let captured = capture(
            read: { .refused(-25293) },
            sentence: {
                StoredSecret.explain($0, noun: "administrator password",
                                     remedy: "save it in the app under Settings ▸ VPN")
            }
        )
        XCTAssertEqual(captured.out, "")
        XCTAssertEqual(captured.outcome, .failed)
        XCTAssertTrue(captured.err.contains("-25293"), captured.err)
        XCTAssertTrue(captured.err.contains("administrator password"), captured.err)
    }

    func testTheCallerSuppliesTheSentenceAndTheDefaultNeverQuotesAValue() {
        let said = capture(read: { .missing }, sentence: { _ in "no administrator password is saved" })
        XCTAssertTrue(said.err.contains("no administrator password is saved"), said.err)
        XCTAssertFalse(said.err.contains("hunter"), said.err)

        // Without a sentence the default still fails the same way rather than
        // printing an empty password.
        let silent = capture(read: { .missing })
        XCTAssertEqual(silent.out, "")
        XCTAssertEqual(silent.outcome, .failed)
        XCTAssertFalse(silent.err.isEmpty)
    }

    func testTheFailureSentenceNamesTheProgramSoSudoCanShowIt() {
        // `sudo` prints this on its own error path; an unattributed sentence would
        // read as sudo's own words.
        let captured = capture(read: { .refused(-128) })
        XCTAssertTrue(captured.err.hasPrefix("\(AskpassProgram.installedName): "), captured.err)
    }

    func testTheOutcomesAreTheTwoStatusesSudoUnderstands() {
        // Zero means "a password was printed" and nonzero means "none was";
        // `sudo` treats any other value the same as this one, so there is no third.
        XCTAssertEqual(AskpassProgram.Outcome.printedPassword.rawValue, 0)
        XCTAssertEqual(AskpassProgram.Outcome.failed.rawValue, 1)
    }

    // MARK: - Helpers

    private struct Captured {
        let out: String
        let err: String
        let outcome: AskpassProgram.Outcome
    }

    private func capture(
        read: @escaping () -> StoredSecret.ReadResult,
        sentence: @escaping (StoredSecret.ReadResult) -> String? = { _ in nil }
    ) -> Captured {
        let out = Pipe()
        let err = Pipe()
        let outcome = AskpassProgram.run(
            output: out.fileHandleForWriting,
            error: err.fileHandleForWriting,
            read: read,
            sentence: sentence
        )
        out.fileHandleForWriting.closeFile()
        err.fileHandleForWriting.closeFile()
        let outText = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        out.fileHandleForReading.closeFile()
        err.fileHandleForReading.closeFile()
        return Captured(out: outText, err: errText, outcome: outcome)
    }
}
