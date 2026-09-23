import XCTest
@testable import TurtleDiverCLIKit
import TurtleDiverCore
import TurtleDiverSystem

/// The administrator password is the one value this tool may hold and must never
/// show, and `--sudo-password` is the only way it ever gets one. So what is
/// tested here is not "does the flag work" but the two properties that make it
/// safe to have at all:
///
/// * the password reaches `sudo` on the child's **standard input**, never in
///   `argv` (readable by any process of this user, and copied into crash
///   reports) and never in the environment (`ps -E`, and inherited by every
///   child);
/// * a source that does not deliver is refused rather than quietly replaced by a
///   different one — a scripted caller that asked for `stdin` and got a Touch ID
///   dialog hangs, and one that asked for `keychain` and got a prompt fails
///   somewhere it cannot see.
///
/// With no `--sudo-password` nothing here applies: the connect behaves exactly as
/// it did before the option existed, and two of these tests pin that.
final class CLISudoPasswordTests: XCTestCase {

    // MARK: - The option

    func testTheOptionTakesAValue() throws {
        let parsed = try ParsedCommandLine.parse(["connect", "--sudo-password", "keychain"])
        XCTAssertEqual(parsed.options["sudo-password"], "keychain")
        XCTAssertTrue(parsed.switches.isEmpty, "a valued option must not also be read as a switch")
    }

    func testTheOptionAcceptsTheInlineForm() throws {
        let parsed = try ParsedCommandLine.parse(["disconnect", "--sudo-password=stdin"])
        XCTAssertEqual(parsed.options["sudo-password"], "stdin")
    }

    func testTheOptionWithoutAValueIsAUsageError() {
        XCTAssertThrowsError(try ParsedCommandLine.parse(["connect", "--sudo-password"])) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .usage)
            XCTAssertTrue(failure.message.contains("--sudo-password"), failure.message)
        }
    }

    func testTheOptionIsUnparsedWhenTheCallerSaidNothing() throws {
        let parsed = try ParsedCommandLine.parse(["connect"])
        XCTAssertNil(try TurtleDiverCLI.sudoPasswordSource(parsed))
    }

    // MARK: - The sources

    func testTheSourcesAreExactlyTheTwoDocumented() {
        // A third source is a decision, not a detail: it needs a paragraph in
        // docs/CLI.md saying what it is for and who may see the password.
        XCTAssertEqual(SudoPasswordSource.allCases.map(\.rawValue), ["keychain", "stdin"])
    }

    func testBothSourcesParse() throws {
        XCTAssertEqual(try SudoPasswordSource.parse("keychain"), .keychain)
        XCTAssertEqual(try SudoPasswordSource.parse("stdin"), .stdin)
    }

    func testAnUnknownSourceIsRefusedWithBothChoices() {
        XCTAssertThrowsError(try SudoPasswordSource.parse("prompt")) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .usage)
            XCTAssertTrue(failure.message.contains("keychain"), failure.message)
            XCTAssertTrue(failure.message.contains("stdin"), failure.message)
            XCTAssertTrue(failure.message.contains("\"prompt\""), "the refused value is not echoed: \(failure.message)")
        }
    }

    func testTheSourceNameIsMatchedExactly() {
        // `keychain` is the spelling in the help text, in this file and in the
        // docs; accepting `Keychain` would make three spellings for one thing.
        XCTAssertThrowsError(try SudoPasswordSource.parse("Keychain"))
    }

    // MARK: - Standard input

    func testStdinRefusesATerminal() {
        XCTAssertThrowsError(
            try SudoPassword.read(.stdin, stdinIsTerminal: true, readLine: { "hunter2" })
        ) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .usage)
            // The remedy a person needs is the pipeline that does work.
            XCTAssertTrue(failure.message.contains("pipe"), failure.message)
            XCTAssertFalse(failure.message.contains("hunter2"), "the password reached a message")
        }
    }

    func testStdinRefusesNoInput() {
        XCTAssertThrowsError(try SudoPassword.read(.stdin, stdinIsTerminal: false, readLine: { nil })) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .usage)
            XCTAssertTrue(failure.message.contains("--sudo-password stdin"), failure.message)
        }
    }

    func testStdinRefusesAnEmptyLine() {
        // An empty line is what a caller gets from an unset shell variable, and
        // a blank password is not a password: `sudo -S` would fail after the
        // tunnel's credentials had already been read.
        XCTAssertThrowsError(try SudoPassword.read(.stdin, stdinIsTerminal: false, readLine: { "" })) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .usage)
        }
    }

    func testStdinReturnsTheLineUnchanged() throws {
        // Spaces are part of a password. Trimming one would turn a correct
        // password into a wrong one with nothing on screen to explain it.
        let secret = try SudoPassword.read(.stdin, stdinIsTerminal: false, readLine: { "  hunter 2  " })
        XCTAssertEqual(secret, "  hunter 2  ")
    }

    func testOnlyTheLineEndingIsRemoved() {
        XCTAssertEqual(SudoPassword.trimmingLineEnding("hunter2"), "hunter2")
        XCTAssertEqual(SudoPassword.trimmingLineEnding("hunter2\r"), "hunter2")
        XCTAssertEqual(SudoPassword.trimmingLineEnding("hunter2 "), "hunter2 ")
        XCTAssertEqual(SudoPassword.trimmingLineEnding(" hunter"), " hunter")
        XCTAssertEqual(SudoPassword.trimmingLineEnding(""), "")
    }

    // MARK: - The Keychain

    func testTheKeychainIsAskedForTheAdministratorPassword() throws {
        var asked: [KeychainSecret] = []
        let secret = try SudoPassword.read(.keychain, stdinIsTerminal: true, readStored: { account in
            asked.append(account)
            return .value("stored-admin")
        })
        XCTAssertEqual(secret, "stored-admin")
        XCTAssertEqual(asked, [.adminPassword])
    }

    func testAMissingKeychainItemNamesTheAdministratorPasswordAndItsDoor() {
        XCTAssertThrowsError(try SudoPassword.read(.keychain, readStored: { _ in .missing })) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .notConfigured)
            XCTAssertTrue(failure.message.contains("administrator password"), failure.message)
            // The VPN password lives in Settings ▸ VPN and this one does not, so
            // a shared remedy would send the reader to the wrong pane.
            XCTAssertTrue(failure.message.contains("Settings ▸ Advanced"), failure.message)
        }
    }

    func testARefusedKeychainItemQuotesTheStatus() {
        XCTAssertThrowsError(try SudoPassword.read(.keychain, readStored: { _ in .refused(-25293) })) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .notConfigured)
            XCTAssertTrue(failure.message.contains("-25293"), failure.message)
        }
    }

    func testANamedSourceIsNeverReplacedByAnother() {
        // The failure that matters: a caller that asked for the Keychain must not
        // be handed a prompt, and must not be handed a pipe. Neither other door
        // is even touched.
        var readLineCalls = 0
        XCTAssertThrowsError(
            try SudoPassword.read(
                .keychain,
                stdinIsTerminal: true,
                readStored: { _ in .missing },
                readLine: { readLineCalls += 1; return "leaked" }
            )
        ) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            XCTAssertEqual(failure.code, .notConfigured)
        }
        XCTAssertEqual(readLineCalls, 0, "a refused Keychain read fell through to standard input")
    }

    func testTheAnnouncementIsOneLineAndSaysWhereFrom() {
        // The note goes to stderr above the read, so a person watching sees what
        // a password was just asked for. It names the door, never the value.
        let expected: [SudoPasswordSource: String] = [.keychain: "Keychain", .stdin: "standard input"]
        for source in SudoPasswordSource.allCases {
            let line = SudoPassword.announcement(for: source)
            XCTAssertFalse(line.isEmpty)
            XCTAssertFalse(line.contains("\n"), "a note is printed as one stderr line: \(line)")
            guard let fragment = expected[source] else { return XCTFail("no expectation for \(source)") }
            XCTAssertTrue(line.contains(fragment), "\(line) does not say \(fragment)")
        }
    }

    // MARK: - What the connect does with it

    func testASuppliedPasswordGoesOnTheChildsStdinAndNotIntoArgv() throws {
        let sudo = try FakeSudo()
        XCTAssertTrue(
            ConnectCommand.warmUp(
                hasTerminal: false,
                secret: "hunter2",
                runner: TunnelAgentChannel.SudoStepRunner(executable: sudo.executable),
                timeout: 10
            )
        )
        // `-S -v`: read the password from standard input and refresh the
        // timestamp. The agent's own launch stays `sudo -n`, because the agent's
        // standard input carries the tunnel's credentials.
        XCTAssertEqual(sudo.argv, "-S\n-v\n")
        XCTAssertEqual(sudo.standardInput, "hunter2\n")
        XCTAssertFalse(sudo.argv.contains("hunter2"), "the password is in argv, where `ps` reads it")
        XCTAssertFalse(sudo.environment.contains("hunter2"), "the password is in the environment, where `ps -E` reads it")
    }

    func testASuppliedPasswordIsUsedEvenWithATerminal() throws {
        // A scripted caller sitting in a pseudo-terminal asked for no dialog. It
        // gets no dialog.
        let sudo = try FakeSudo()
        XCTAssertTrue(
            ConnectCommand.warmUp(
                hasTerminal: true,
                secret: "hunter2",
                runner: TunnelAgentChannel.SudoStepRunner(executable: sudo.executable),
                timeout: 10
            )
        )
        XCTAssertEqual(sudo.argv, "-S\n-v\n")
        XCTAssertEqual(sudo.standardInput, "hunter2\n")
    }

    func testWithoutAPasswordThePlainWarmupIsUsedAndGetsNoInput() throws {
        // The default, unchanged: no terminal, so the form that asks nobody.
        let sudo = try FakeSudo()
        XCTAssertTrue(
            ConnectCommand.warmUp(
                hasTerminal: false,
                runner: TunnelAgentChannel.SudoStepRunner(executable: sudo.executable),
                timeout: 10
            )
        )
        XCTAssertEqual(sudo.argv, "-n\n-v\n")
        XCTAssertEqual(sudo.standardInput, "", "the no-password form received bytes on standard input")
    }

    func testAnEmptyPasswordIsNotAPassword() throws {
        // What an empty shell variable looks like. It must not become a piped
        // empty line, which `sudo -S` would answer with a prompt.
        let sudo = try FakeSudo()
        XCTAssertTrue(
            ConnectCommand.warmUp(
                hasTerminal: false,
                secret: "",
                runner: TunnelAgentChannel.SudoStepRunner(executable: sudo.executable),
                timeout: 10
            )
        )
        XCTAssertEqual(sudo.argv, "-n\n-v\n")
        XCTAssertEqual(sudo.standardInput, "")
    }

    // MARK: - The teardown

    func testDisconnectElevationUsesTheStoredPasswordFormWhenGiven() {
        let chosen = DisconnectCommand.elevation(
            strategy: .systemPrompt,
            hasTerminal: false,
            adminPassword: "hunter2"
        )
        // The machine may prefer a dialog; a caller that handed over a password
        // asked for the pipe instead, and the two halves of a scripted session
        // then authenticate the same way.
        XCTAssertEqual(chosen.strategy, .storedPassword)
        XCTAssertEqual(chosen.adminPassword, "hunter2")
        XCTAssertTrue(chosen.mayPrompt, "the strategy's own plan must be allowed onto the list")
    }

    func testDisconnectElevationIsUnchangedWithoutAPassword() {
        let chosen = DisconnectCommand.elevation(strategy: .systemPrompt, hasTerminal: false)
        XCTAssertEqual(chosen.strategy, .systemPrompt)
        XCTAssertFalse(chosen.mayPrompt)
        XCTAssertNil(chosen.adminPassword)

        let empty = DisconnectCommand.elevation(strategy: .systemPrompt, hasTerminal: true, adminPassword: "")
        XCTAssertEqual(empty.strategy, .systemPrompt)
        XCTAssertTrue(empty.mayPrompt)
        XCTAssertNil(empty.adminPassword)
    }

    func testDisconnectFeedsThePasswordToSudosStdinAndNotItsArgv() throws {
        let runner = RecordingElevatedRunner()
        // A tunnel that outlives every signal, so every form gets its turn — the
        // `sudo -n` one first, and only then the one carrying the password.
        let terminator = ElevatedTerminator(
            runner: runner,
            isRunning: { _ in true },
            isOpenConnect: { _ in true },
            groupPids: { _ in [] },
            ownProcessGroup: 0,
            sleep: { _ in }
        )
        let status = TunnelStatus(
            pid: 4242,
            source: ExistingConnectionDetection.Source.pidFile.rawValue,
            pidFilePid: 4242,
            pidFilePath: "/tmp/does-not-matter",
            rejections: []
        )

        XCTAssertThrowsError(
            try DisconnectCommand.run(
                status: status,
                mayPrompt: false,
                strategy: .systemPrompt,
                adminPassword: "hunter2",
                terminator: terminator,
                elevationRecord: URL(fileURLWithPath: "/tmp/does-not-matter-either")
            )
        ) { error in
            guard let failure = error as? CLIFailure else { return XCTFail("not a CLIFailure: \(error)") }
            // The tunnel is still there and this CLI may not do anything else
            // about it; that verdict is unchanged by the password being supplied.
            XCTAssertEqual(failure.code, .tunnelNotStopped)
        }

        let plans = runner.recorded
        XCTAssertFalse(plans.isEmpty, "no elevated plan was run")
        XCTAssertNil(plans[0].stdin, "`sudo -n` must be tried first, without a password")
        let piped = plans.filter(\.pipesTheStoredPassword)
        XCTAssertFalse(piped.isEmpty, "the password never reached `sudo -S`")
        for plan in piped {
            XCTAssertEqual(plan.stdin, "hunter2\n")
        }
        for plan in plans {
            XCTAssertFalse(
                plan.arguments.joined(separator: " ").contains("hunter2"),
                "the password is in argv: \(plan.arguments)"
            )
        }
    }

    func testDisconnectWithoutAPasswordNeverPipesOne() throws {
        let runner = RecordingElevatedRunner()
        let terminator = ElevatedTerminator(
            runner: runner,
            isRunning: { _ in true },
            isOpenConnect: { _ in true },
            groupPids: { _ in [] },
            ownProcessGroup: 0,
            sleep: { _ in }
        )
        let status = TunnelStatus(
            pid: 4242,
            source: ExistingConnectionDetection.Source.pidFile.rawValue,
            pidFilePid: 4242,
            pidFilePath: "/tmp/does-not-matter",
            rejections: []
        )

        XCTAssertThrowsError(
            try DisconnectCommand.run(
                status: status,
                mayPrompt: false,
                strategy: .systemPrompt,
                terminator: terminator,
                elevationRecord: URL(fileURLWithPath: "/tmp/does-not-matter-either")
            )
        )

        let plans = runner.recorded
        XCTAssertFalse(plans.isEmpty)
        XCTAssertTrue(plans.allSatisfy { $0.stdin == nil }, "a password was piped that nobody supplied")
    }

    // MARK: - The documentation

    func testTheDocsDescribeBothSources() throws {
        // The option is the only way a password gets into this tool, so the file
        // that documents the interface has to name it and both of its doors.
        let docs = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/CLI.md"),
            encoding: .utf8
        )
        XCTAssertTrue(docs.contains("--sudo-password"), "docs/CLI.md does not mention the option")
        for source in SudoPasswordSource.allCases {
            XCTAssertTrue(docs.contains(source.rawValue), "docs/CLI.md does not mention \(source.rawValue)")
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

/// A `sudo` that records what it was handed and exits successfully.
///
/// The real one is never started: what is under test is the plan, and the plan is
/// the part that can leak a credential. Written to a temporary directory, so the
/// script sees exactly the arguments, environment and standard input the runner
/// would give `/usr/bin/sudo`.
private final class FakeSudo {
    let directory: URL
    let executable: String

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turtlediver-cli-sudo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("sudo").path
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(directory.path)/argv'
        env > '\(directory.path)/environment'
        cat > '\(directory.path)/stdin'
        exit 0
        """
        try script.write(toFile: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var argv: String { (try? String(contentsOfFile: directory.appendingPathComponent("argv").path, encoding: .utf8)) ?? "" }
    var standardInput: String { (try? String(contentsOfFile: directory.appendingPathComponent("stdin").path, encoding: .utf8)) ?? "" }
    var environment: String { (try? String(contentsOfFile: directory.appendingPathComponent("environment").path, encoding: .utf8)) ?? "" }
}

/// A witness for the teardown: it records every plan and reports success, while
/// the caller's own closures decide whether the tunnel is still alive.
private final class RecordingElevatedRunner: ElevatedCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [ElevatedKillPlan] = []

    var recorded: [ElevatedKillPlan] {
        lock.lock()
        defer { lock.unlock() }
        return plans
    }

    func run(_ plan: ElevatedKillPlan, timeout: TimeInterval) throws -> BoundedProcessResult {
        lock.lock()
        plans.append(plan)
        lock.unlock()
        return BoundedProcessResult(terminationStatus: 0, timedOut: false, stdout: "", stderr: "")
    }
}
