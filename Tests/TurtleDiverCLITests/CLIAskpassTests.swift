import XCTest
@testable import TurtleDiverCLIKit
import TurtleDiverCore
import TurtleDiverSystem

/// `turtlediver-askpass` is the program `sudo -A` runs, and the only thing in
/// this tool that ever prints the administrator password.
///
/// It is worth being blunt about what is being tested, because the shape of the
/// type is a security decision rather than a convenience:
///
/// * the helper is **this same binary** under a second installed name, and it is
///   chosen by `argv[0]` and by nothing else — not by an argument a caller could
///   add, not by an environment variable a caller could set, and not by an
///   environment variable pointing at some other program;
/// * its *only* output is the password and a newline, because `sudo` reads that
///   standard output as the password itself, and a stray line would become part
///   of it;
/// * a caller that can run it can obtain the password, which is stated in
///   `docs/CLI.md` rather than hidden, and the reason the grant is worth having
///   on a `pam_tid` machine is that the alternative there is a sudoers rule that
///   hands out passwordless root.
final class CLIAskpassTests: XCTestCase {

    // MARK: - Structure

    func testTheHelperIsInstalledAsASecondNameOfTheSameProgram() {
        // A person reading Keychain Access or `ps` has to be able to tell the two
        // names apart from unrelated tools, so the helper's name is the CLI's own
        // name plus a suffix rather than something generic.
        XCTAssertEqual(AskpassHelper.installedName, "turtlediver-askpass")
        XCTAssertTrue(AskpassHelper.installedName.hasPrefix("turtlediver"))
    }

    func testTheVariableIsSudosOwn() {
        XCTAssertEqual(AskpassHelper.environmentVariable, "SUDO_ASKPASS")
    }

    // MARK: - How the helper knows it is the helper

    func testTheHelperIsRecognisedByName() {
        XCTAssertTrue(AskpassHelper.isHelperInvocation(executablePath: "/usr/local/bin/turtlediver-askpass"))
        XCTAssertTrue(AskpassHelper.isHelperInvocation(executablePath: "turtlediver-askpass"))
        XCTAssertTrue(AskpassHelper.isHelperInvocation(executablePath: "/private/tmp/build/turtlediver-askpass"))
    }

    func testNothingElseIsMistakenForTheHelper() {
        // The neighbour names matter as much as the helper's: a CLI that thought
        // it was the helper would print the password to whoever ran it, and an
        // agent that did would print it into a tunnel's credentials.
        for path in [
            "/usr/local/bin/turtlediver",
            "/usr/local/libexec/turtlediver-agent",
            "/usr/local/bin/turtlediver-askpass2",
            "/usr/local/bin/askpass",
            "/usr/local/bin/turtlediver-askpass-helper",
            "",
            "/",
        ] {
            XCTAssertFalse(AskpassHelper.isHelperInvocation(executablePath: path), path)
        }
        XCTAssertFalse(AskpassHelper.isHelperInvocation(executablePath: nil))
    }

    /// An askpass invocation must never reach the command line. `sudo` passes the
    /// prompt it would have shown as `argv[1]`, so a helper that parsed arguments
    /// would be one that could be talked into something else by whoever wrote
    /// `SUDO_ASKPASS`. The check is in `main.swift` above the parser, which is a
    /// structural fact a test can read.
    func testTheHelperBranchComesBeforeTheParserReadsAnything() throws {
        let source = try repoSource("CLI/main.swift")
        let branch = try XCTUnwrap(
            source.range(of: "AskpassHelper.isHelperInvocation"),
            "main.swift no longer decides whether it is the helper"
        )
        let parser = try XCTUnwrap(
            source.range(of: "TurtleDiverCLI.main(arguments:"),
            "main.swift no longer calls the command line parser"
        )
        XCTAssertTrue(
            branch.lowerBound < parser.lowerBound,
            "the helper branch runs after the parser, so an askpass invocation is parsed as a command"
        )
        // And it exits with what the helper decided, rather than falling through
        // into the CLI's own work.
        XCTAssertTrue(source.contains("exit(AskpassHelper.run().rawValue)"), source)
    }

    // MARK: - Where the helper is

    func testTheHelperBesideTheRunningBinaryIsPreferred() {
        let sibling = AskpassHelper.path(
            invokedAs: "/tmp/build/turtlediver",
            runningAt: "/tmp/build/turtlediver",
            isExecutable: { $0 == "/tmp/build/turtlediver-askpass" }
        )
        // No install and no sudo: a development build works with one symlink
        // beside it, which is what makes this testable at all.
        XCTAssertEqual(sibling, "/tmp/build/turtlediver-askpass")
    }

    func testABareNameFallsBackToTheRunningBinarysDirectory() {
        // Started as `turtlediver` from a directory on `PATH`: the name on the
        // command line carries no directory, so the running binary's own path is
        // consulted too.
        let found = AskpassHelper.path(
            invokedAs: "turtlediver",
            runningAt: "/opt/tools/turtlediver",
            isExecutable: { $0 == "/opt/tools/turtlediver-askpass" }
        )
        XCTAssertEqual(found, "/opt/tools/turtlediver-askpass")
    }

    func testTheInstalledHelperIsTheLastCandidate() {
        let found = AskpassHelper.path(
            invokedAs: "/tmp/build/turtlediver",
            runningAt: "/tmp/build/turtlediver",
            isExecutable: { $0 == "/usr/local/bin/turtlediver-askpass" }
        )
        XCTAssertEqual(found, "/usr/local/bin/turtlediver-askpass")
    }

    func testNoHelperAnywhereIsNothingRatherThanAGuess() {
        XCTAssertNil(AskpassHelper.path(
            invokedAs: "/tmp/build/turtlediver",
            runningAt: "/tmp/build/turtlediver",
            isExecutable: { _ in false }
        ))
    }

    func testAnInstalledPathIsNamedEvenWhenTheHelperIsMissing() {
        // The refusal has to be able to say where to look.
        XCTAssertEqual(
            AskpassHelper.expectedPath(invokedAs: "turtlediver", runningAt: nil),
            "/usr/local/bin/turtlediver-askpass"
        )
        XCTAssertEqual(
            AskpassHelper.expectedPath(invokedAs: "/tmp/build/turtlediver", runningAt: "/tmp/build/turtlediver"),
            "/tmp/build/turtlediver-askpass"
        )
    }

    func testTheSearchOrderIsDedupedAndTheInstalledDirectoryIsLast() {
        XCTAssertEqual(
            AskpassHelper.searchDirectories(invokedAs: "/tmp/build/turtlediver", runningAt: "/tmp/build/turtlediver"),
            ["/tmp/build", "/usr/local/bin"]
        )
        XCTAssertEqual(
            AskpassHelper.searchDirectories(invokedAs: "turtlediver", runningAt: "/opt/tools/turtlediver"),
            ["/opt/tools", "/usr/local/bin"]
        )
        XCTAssertEqual(AskpassHelper.searchDirectories(invokedAs: nil, runningAt: nil), ["/usr/local/bin"])
    }

    /// Which program is handed the administrator password is not a caller's
    /// choice. `SUDO_ASKPASS` in this process's environment is the variable the
    /// *helper* is pointed at by, so honouring it here would let a caller set it
    /// and watch the CLI read the password out of a program of their choosing.
    func testTheEnvironmentCannotNameTheHelper() {
        setenv(AskpassHelper.environmentVariable, "/tmp/someone-elses-program", 1)
        defer { unsetenv(AskpassHelper.environmentVariable) }
        XCTAssertNil(AskpassHelper.path(
            invokedAs: "/tmp/build/turtlediver",
            runningAt: "/tmp/build/turtlediver",
            isExecutable: { $0 == "/tmp/someone-elses-program" }
        ))
    }

    // MARK: - What the helper prints

    func testTheHelperPrintsThePasswordAndNothingElse() throws {
        let out = Pipe()
        let err = Pipe()
        let code = AskpassHelper.run(
            output: out.fileHandleForWriting,
            error: err.fileHandleForWriting,
            readStored: { account in
                XCTAssertEqual(account, .adminPassword)
                return .value("hunter2")
            }
        )
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()

        XCTAssertEqual(code, .ok)
        // `sudo` reads this as the password: one value, one newline. A progress
        // line or a JSON document here would become part of the password and show
        // up as a failed authentication with no explanation.
        XCTAssertEqual(
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "hunter2\n"
        )
        XCTAssertEqual(err.fileHandleForReading.readDataToEndOfFile(), Data())
    }

    func testAMissingItemFailsWithNoPasswordAtAll() throws {
        let out = Pipe()
        let err = Pipe()
        let code = AskpassHelper.run(
            output: out.fileHandleForWriting,
            error: err.fileHandleForWriting,
            readStored: { _ in .missing }
        )
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()

        XCTAssertEqual(code, .failure)
        XCTAssertEqual(
            out.fileHandleForReading.readDataToEndOfFile(),
            Data(),
            "a failed helper wrote something on the channel sudo reads as the password"
        )
        let said = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(said.contains(AskpassHelper.installedName), said)
        XCTAssertTrue(said.contains("administrator password"), said)
    }

    func testARefusedItemFailsWithItsReasonAndNoPassword() throws {
        // `errSecUserCanceled` is what a person clicking Deny looks like, and it
        // is the one failure here that a person caused — so the reason matters.
        let out = Pipe()
        let err = Pipe()
        let code = AskpassHelper.run(
            output: out.fileHandleForWriting,
            error: err.fileHandleForWriting,
            readStored: { _ in .refused(errSecUserCanceled) }
        )
        try out.fileHandleForWriting.close()
        try err.fileHandleForWriting.close()

        XCTAssertEqual(code, .failure)
        XCTAssertEqual(out.fileHandleForReading.readDataToEndOfFile(), Data())
        let said = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(said.contains("\(errSecUserCanceled)"), said)
    }

    /// The password is printed as stored. A helper that trimmed it or quoted it
    /// would turn a correct password into a failing authentication, and — unlike
    /// a refusal — there would be nothing on screen to say why.
    func testThePasswordIsPrintedVerbatim() throws {
        let out = Pipe()
        let code = AskpassHelper.run(
            output: out.fileHandleForWriting,
            error: .nullDevice,
            readStored: { _ in .value("  hunter 2 ") }
        )
        try out.fileHandleForWriting.close()
        XCTAssertEqual(code, .ok)
        XCTAssertEqual(
            String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            "  hunter 2 \n"
        )
    }

    /// A caller that can run the helper can obtain the password, which is the
    /// exposure this design accepts in exchange for not writing a sudoers rule.
    /// `docs/CLI.md` has to say so: it is the sentence a reader needs to decide
    /// whether to install the helper at all.
    func testTheDocsStateTheExposure() throws {
        let docs = try repoSource("docs/CLI.md")
        let start = try XCTUnwrap(
            docs.range(of: "#### Unattended connects"),
            "docs/CLI.md no longer has an Unattended connects section"
        )
        let rest = docs[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "#### What happens to the password"))
        let section = String(rest[..<end.lowerBound])

        XCTAssertTrue(section.contains(AskpassHelper.installedName), "the helper is not named")
        XCTAssertTrue(
            section.contains(AskpassHelper.environmentVariable),
            "the section does not say what sudo reads the helper's path from"
        )
        XCTAssertTrue(
            section.contains("can obtain the") || section.contains("can read the item")
                    || section.contains("anything running as you"),
            "the section does not state what a caller of the helper can get"
        )
        XCTAssertTrue(
            section.contains("Always Allow"),
            "the section does not say how to make the Keychain grant stick"
        )
        XCTAssertTrue(
            section.contains("sudo -A"),
            "the section does not show the form of sudo that is run"
        )
    }

    /// The route is only real if the installer installs the helper: a package
    /// that shipped the CLI without the second name would send every unattended
    /// connect into the exit-7 refusal, and the refusal is only useful if the
    /// remedy it names is true.
    func testTheInstallerInstallsTheHelperAsALink() throws {
        let publisher = try repoSource("publish.sh")
        XCTAssertTrue(
            publisher.contains("CLI_ASKPASS_NAME=\"\(AskpassHelper.installedName)\""),
            "publish.sh names the helper something other than what the CLI looks for"
        )
        // A link, not a copy: one file, one signature, one Keychain grant.
        XCTAssertTrue(
            publisher.contains("ln -s \"$CLI_INSTALL_NAME\" \"$pkgroot/$CLI_INSTALL_DIR/$CLI_ASKPASS_NAME\""),
            "publish.sh does not stage the helper beside the command line tool"
        )
        XCTAssertTrue(
            publisher.contains("[ -L \"$cli_askpass\" ]"),
            "publish.sh never checks that the packaged helper is a link"
        )
        XCTAssertTrue(
            publisher.contains("readlink \"$cli_askpass\""),
            "publish.sh never checks what the link points at"
        )
    }

    /// Neither installer may run the helper, because running it prints the
    /// password: `argv[0]` is what decides the mode, so `turtlediver-askpass
    /// version` is not a version check, it is a Keychain read on the machine
    /// doing the packaging.
    func testNoScriptRunsTheHelper() throws {
        for path in ["publish.sh", "packaging/install-agent.sh"] {
            let source = try repoSource(path)
            for suffix in ["version", "help", "status", "--json"] {
                for variable in ["$cli_askpass", "$CLI_ASKPASS_NAME"] {
                    XCTAssertFalse(
                        source.contains("\(variable)\" \(suffix)"),
                        "\(path) runs the helper through `\(variable) \(suffix)`, which prints the password"
                    )
                }
            }
        }
    }

    func testTheInstallerNoteNamesTheHelperAndItsRoute() throws {
        let notes = try repoSource("packaging/README_INSTALL.txt")
        XCTAssertTrue(notes.contains(AskpassHelper.installedName), "the note does not name the helper")
        XCTAssertTrue(notes.contains("sudo"), notes)
        XCTAssertTrue(notes.contains("Always Allow"), "the note does not say how to stop the prompts")
    }

    // MARK: - Source

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func repoSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
