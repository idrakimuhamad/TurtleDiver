import XCTest

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Covers the launch plan that replaced `echo <password> | sudo …`.
///
/// The regression: the three credentials used to be interpolated into the
/// `/bin/bash -c` string, so they were part of that process's argv — readable
/// with `ps`/`pgrep -f` by any process running as the same user, and copied
/// into crash reports. The plan keeps the script constant and sends the
/// credentials down a pipe instead.
///
/// The interesting assertions are the end-to-end ones at the bottom: they run
/// both plans against a fake `sudo`/`sed`/`openconnect` trio on a private PATH
/// and check what openconnect actually receives. That covers the credential
/// path without needing a VPN.
final class OpenConnectLaunchTests: XCTestCase {

    // Distinctive values so a containment check cannot pass by accident.
    private let admin = "ADMIN-pw-1q2w3e4r"
    private let pin = "PIN-1qa2ws309418"
    private let password = "VPN-vymTip-vedju1"

    private func makePlan(host: String = "vpn.example.com",
                          arguments: [String]? = nil,
                          openconnectPath: String = "/opt/homebrew/bin/openconnect",
                          searchPath: String = OpenConnectCommand.defaultSearchPath) -> OpenConnectLaunchPlan {
        OpenConnectCommand.launchPlan(
            openconnectPath: openconnectPath,
            arguments: arguments ?? ["--force-dpd=10", "--user=451799", "--pid-file", "/tmp/pid", host],
            adminPassword: admin,
            pin: pin,
            vpnPassword: password,
            searchPath: searchPath
        )
    }

    // MARK: - The point of the exercise

    func testNoCredentialAppearsInTheScript() {
        let script = makePlan().script

        for secret in [admin, pin, password] {
            XCTAssertFalse(script.contains(secret), "\(secret.prefix(6))… leaked into the command line")
        }
    }

    func testTheScriptDoesNotChangeWithTheCredentials() {
        // If any credential were interpolated, these two would differ. This is
        // the cheapest possible guard against a future edit reintroducing it.
        let first = OpenConnectCommand.launchPlan(
            openconnectPath: "/opt/homebrew/bin/openconnect",
            arguments: ["vpn.example.com"],
            adminPassword: "one", pin: "two", vpnPassword: "three"
        )
        let second = OpenConnectCommand.launchPlan(
            openconnectPath: "/opt/homebrew/bin/openconnect",
            arguments: ["vpn.example.com"],
            adminPassword: "different", pin: "also different", vpnPassword: "and this"
        )

        XCTAssertEqual(first.script, second.script)
        XCTAssertNotEqual(first.standardInput, second.standardInput)
    }

    func testCredentialsArriveOnStandardInputInOrder() {
        let lines = String(decoding: makePlan().standardInput, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()

        XCTAssertEqual(lines.map(String.init), [admin, pin, password])
        XCTAssertEqual(lines.count, OpenConnectCommand.credentialLineCount)
    }

    func testTheScriptReadsExactlyAsManyLinesAsItIsFed() {
        let script = makePlan().script
        let reads = script.components(separatedBy: "IFS= read -r ").count - 1

        XCTAssertEqual(reads, OpenConnectCommand.credentialLineCount)
        XCTAssertTrue(script.contains("read -r \(OpenConnectCommand.adminVariable)"))
        XCTAssertTrue(script.contains("read -r \(OpenConnectCommand.pinVariable)"))
        XCTAssertTrue(script.contains("read -r \(OpenConnectCommand.passwordVariable)"))
        // A failed read must not continue into a pipeline with an empty secret.
        XCTAssertTrue(script.contains("|| exit 1"))
    }

    func testTheCleanupPlanCarriesOnlyTheAdminPassword() {
        let plan = OpenConnectCommand.hostsCleanupPlan(adminPassword: admin)

        XCTAssertEqual(String(decoding: plan.standardInput, as: UTF8.self), admin + "\n")
        XCTAssertEqual(plan.script.components(separatedBy: "IFS= read -r ").count - 1, 1)
        XCTAssertFalse(plan.script.contains(admin))
        XCTAssertFalse(plan.script.contains("openconnect"))
        XCTAssertTrue(plan.script.contains("vpn-slice-"))
    }

    func testTheVariablesAreNotExported() {
        // An exported variable shows up in a child's environment (`ps -E`),
        // which would just move the leak one step sideways.
        let script = makePlan().script

        for name in [OpenConnectCommand.adminVariable, OpenConnectCommand.pinVariable, OpenConnectCommand.passwordVariable] {
            XCTAssertFalse(script.contains("export \(name)"), "\(name) is exported")
        }
        XCTAssertTrue(script.contains("unset \(OpenConnectCommand.adminVariable)"))
    }

    func testShellMetacharactersInACredentialStayOnStdin() {
        // Nothing about a credential is interpreted any more — it is bytes in a
        // pipe. `$(…)`, backticks and quotes must survive verbatim.
        let nasty = "$(touch /tmp/pwned) `id` '; rm -rf /; \" '"
        let plan = OpenConnectCommand.launchPlan(
            openconnectPath: "/opt/homebrew/bin/openconnect",
            arguments: ["vpn.example.com"],
            adminPassword: nasty, pin: "123456", vpnPassword: "pw"
        )

        XCTAssertFalse(plan.script.contains("pwned"))
        XCTAssertFalse(plan.script.contains("/tmp/pwned"))
        XCTAssertTrue(String(decoding: plan.standardInput, as: UTF8.self).hasPrefix(nasty + "\n"))
    }

    // MARK: - The non-secret half still has to be escaped

    func testTheOpenconnectArgumentsAreEscapedAndOrdered() {
        let script = makePlan(host: "vpn.example.com").script

        XCTAssertTrue(script.contains("sudo '/opt/homebrew/bin/openconnect'"))
        XCTAssertTrue(script.contains("'--force-dpd=10'"))
        XCTAssertTrue(script.contains("'--user=451799'"))
        XCTAssertTrue(script.hasSuffix("'vpn.example.com'; unset oc_admin oc_pin oc_pass"),
                      "the host must stay last, after the options: \(script)")
    }

    func testAnEmptyValueEscapesToAnEmptyQuotedString() {
        XCTAssertEqual(OpenConnectCommand.shellEscape(""), "''")
    }

    func testAQuoteIsClosedReopenedAndEscaped() {
        XCTAssertEqual(OpenConnectCommand.shellEscape("it's"), "'it'\\''s'")
    }

    func testASearchPathWithSpacesSurvives() {
        let script = makePlan(searchPath: "/tmp/a b:/usr/bin").script

        XCTAssertTrue(script.hasPrefix("export PATH='/tmp/a b:/usr/bin':$PATH; "))
    }

    func testThePasswordIsPassedWithPrintfNotEcho() {
        // `echo` mangles backslashes and a leading `-n`; `printf '%s\n'` cannot.
        let plan = OpenConnectCommand.launchPlan(
            openconnectPath: "openconnect",
            arguments: ["vpn.example.com"],
            adminPassword: "-n \\c", pin: "1", vpnPassword: "2"
        )

        XCTAssertFalse(plan.script.contains("echo "))
        XCTAssertTrue(plan.script.contains("printf '%s\\n' \"$\(OpenConnectCommand.adminVariable)\""))
    }

    func testTheConnectPlanKeepsTheCleanupStepQuiet() {
        // The old pipeline sent the /etc/hosts cleanup's stderr to /dev/null:
        // a stale entry it cannot remove is not a connection failure, and the
        // app parses stderr for error bursts.
        XCTAssertTrue(makePlan().script.contains("| sudo -S sed -i '' '/# vpn-slice-/d' /etc/hosts 2>/dev/null"))
        // The standalone cleanup wants that stderr, because it reports it.
        XCTAssertFalse(OpenConnectCommand.hostsCleanupPlan(adminPassword: admin).script.contains("2>/dev/null"))
    }

    // MARK: - PID file

    func testThePidFileLivesInTheRunDirectoryOfTheBaseDirectory() {
        let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support/TurtleDiver")

        let path = OpenConnectPidFile.path(inApplicationSupport: base)

        XCTAssertEqual(path.path,
                       "/Users/someone/Library/Application Support/TurtleDiver/run/openconnect.pid")
    }

    func testTheLegacyPathIsTheOldWorldWritableOne() {
        XCTAssertEqual(OpenConnectPidFile.legacyPath, "/tmp/turtlediver.pid")
        XCTAssertFalse(OpenConnectPidFile.path.path.hasPrefix("/tmp/"))
    }

    func testPreparingTheDirectoryCreatesItOwnerOnly() throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocpid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let pidFile = OpenConnectPidFile.path(inApplicationSupport: sandbox)

        XCTAssertTrue(OpenConnectPidFile.prepareDirectory(for: pidFile))

        let directory = pidFile.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o700, "another local user must not be able to pre-create the pid file")
    }

    func testPreparingItTwiceIsHarmless() {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocpid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let pidFile = OpenConnectPidFile.path(inApplicationSupport: sandbox)

        XCTAssertTrue(OpenConnectPidFile.prepareDirectory(for: pidFile))
        XCTAssertTrue(OpenConnectPidFile.prepareDirectory(for: pidFile))
    }

    // MARK: - End to end, against a fake sudo/openconnect

    /// Runs a plan built around a private `PATH` whose first entry holds fakes
    /// for `sudo`, `sed` and `openconnect`, and returns what the fake
    /// openconnect saw.
    ///
    /// Nothing here touches the real `sudo`, `/etc/hosts` or a network: the
    /// plan is composed with `searchPath` pointing at the sandbox, so the
    /// script's own `export PATH=…` finds the fakes first, and the fake `sudo`
    /// simply execs its arguments.
    private func run(
        makePlan: (String) -> OpenConnectLaunchPlan
    ) throws -> (stdin: String, argv: [String], sudoCalls: [String]) {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oclaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let plan = makePlan(sandbox.path)

        let recorded = sandbox.appendingPathComponent("openconnect-received.txt")
        let argvFile = sandbox.appendingPathComponent("openconnect-argv.txt")
        let sudoLog = sandbox.appendingPathComponent("sudo-calls.txt")

        func write(_ name: String, _ body: String) throws -> String {
            let url = sandbox.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        let sudoBody = """
        #!/bin/bash
        # Log the call, swallow the password `-S` expects, drop sudo's own
        # flags, then run the rest of the command for real.
        printf '%s\\n' "$*" >> '\(sudoLog.path)'
        password=0
        args=()
        for arg in "$@"; do
          case "$arg" in
            -S) password=1 ;;
            -v) exit 0 ;;
            *) args+=("$arg") ;;
          esac
        done
        [ "$password" = 1 ] && cat > /dev/null
        exec "${args[@]}"
        """
        _ = try write("sudo", sudoBody)
        _ = try write("sed", "#!/bin/bash\nexit 0\n")
        let openconnectBody = """
        #!/bin/bash
        printf '%s\\n' "$@" > '\(argvFile.path)'
        cat > '\(recorded.path)'
        """
        _ = try write("openconnect", openconnectBody)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", plan.script]
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let finished = expectation(description: "plan finished")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        try stdinPipe.fileHandleForWriting.write(contentsOf: plan.standardInput)
        try? stdinPipe.fileHandleForWriting.close()

        wait(for: [finished], timeout: 15)

        let received = (try? String(contentsOf: recorded, encoding: .utf8)) ?? ""
        let argv = ((try? String(contentsOf: argvFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let calls = ((try? String(contentsOf: sudoLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        return (received, argv, calls)
    }

    /// What the old `printf '<pin>\n<password>' | sudo openconnect …` pipeline
    /// handed openconnect. The new plan must be byte-identical.
    private func runLegacyPipeline() throws -> String {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oclegacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorded = sandbox.appendingPathComponent("received.txt")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c",
            "printf '%s\\n%s\\n' '\(pin)' '\(password)' | tee '\(recorded.path)' > /dev/null"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return (try? String(contentsOf: recorded, encoding: .utf8)) ?? ""
    }

    func testOpenconnectReceivesTheSameStdinAsTheOldPipeline() throws {
        let result = try run { makePlan(openconnectPath: $0 + "/openconnect", searchPath: $0) }

        XCTAssertEqual(result.stdin, "\(pin)\n\(password)\n",
                       "openconnect's own stdin must be unchanged from the old pipeline")
        XCTAssertEqual(result.stdin, try runLegacyPipeline())
    }

    func testTheAdminPasswordReachesSudoThroughItsStdinNotItsArguments() throws {
        let result = try run { makePlan(openconnectPath: $0 + "/openconnect", searchPath: $0) }

        XCTAssertFalse(result.sudoCalls.isEmpty, "the fake sudo was never called")
        for call in result.sudoCalls {
            XCTAssertFalse(call.contains(admin), "the admin password is in sudo's argv: \(call)")
        }
        // The admin password is piped into `sudo -S` (which the fake logs as a
        // `-S …` call) — proving the pipe reached it.
        XCTAssertTrue(result.sudoCalls.contains { $0.hasPrefix("-S") })
    }

    func testOpenconnectNeverSeesTheCredentialsInItsArguments() throws {
        let result = try run { makePlan(openconnectPath: $0 + "/openconnect", searchPath: $0) }

        XCTAssertTrue(result.argv.contains("vpn.example.com"))
        XCTAssertTrue(result.argv.contains("--force-dpd=10"))
        for secret in [admin, pin, password] {
            XCTAssertFalse(result.argv.contains(secret))
            XCTAssertFalse(result.argv.joined(separator: " ").contains(secret))
        }
    }

    func testTheCleanupPlanReallyWritesTheAdminPasswordIntoSudostdin() throws {
        let result = try run { path in
            OpenConnectCommand.hostsCleanupPlan(adminPassword: admin, searchPath: path)
        }

        // The fake `sed` swallows stdin without recording it, so the observable
        // fact is that the pipeline ran at all and stayed out of argv.
        XCTAssertTrue(result.sudoCalls.contains { $0.contains("sed") })
        for call in result.sudoCalls {
            XCTAssertFalse(call.contains(admin))
        }
    }

    func testAReadThatCannotBeSatisfiedExitsInsteadOfRunningWithAnEmptySecret() throws {
        // Simulates the failure mode the `|| exit 1` guards: stdin is closed
        // with nothing in it (e.g. the app died between run() and the write).
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocfail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let marker = sandbox.appendingPathComponent("ran")
        let sudoLog = sandbox.appendingPathComponent("sudo.txt")

        for (name, body) in [
            ("sudo", "#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(sudoLog.path)'\nexec \"$@\"\n"),
            ("sed", "#!/bin/bash\ntouch '\(marker.path)'\n"),
            ("openconnect", "#!/bin/bash\ntouch '\(marker.path)'\n")
        ] {
            let url = sandbox.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let plan = makePlan(openconnectPath: sandbox.appendingPathComponent("openconnect").path,
                            searchPath: sandbox.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", plan.script]
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? stdinPipe.fileHandleForWriting.close()   // EOF immediately
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "nothing may run with an empty credential")
    }
}
