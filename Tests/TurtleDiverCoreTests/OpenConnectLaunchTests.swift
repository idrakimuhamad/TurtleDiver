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

    // Distinctive values so a containment check cannot pass by accident — and
    // deliberately fictitious, so a fixture can never be mistaken for a real
    // credential (or become one as the placeholder is edited).
    private let admin = "ADMIN-pw-placeholder"
    private let pin = "PIN-placeholder"
    private let password = "VPN-pw-placeholder"

    private func makePlan(host: String = "vpn.example.com",
                          arguments: [String]? = nil,
                          openconnectPath: String = "/opt/homebrew/bin/openconnect",
                          searchPath: String = OpenConnectCommand.defaultSearchPath,
                          elevation: ElevationStrategy = .storedPassword,
                          pgidFile: String = "/tmp/turtlediver-test-elevation.pgid") -> OpenConnectLaunchPlan {
        OpenConnectCommand.launchPlan(
            openconnectPath: openconnectPath,
            arguments: arguments ?? ["--force-dpd=10", "--user=10001", "--pid-file", "/tmp/pid", host],
            adminPassword: admin,
            pin: pin,
            vpnPassword: password,
            searchPath: searchPath,
            elevation: elevation,
            pgidFile: pgidFile
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
        XCTAssertTrue(script.contains("'--user=10001'"))
        // The host stays last, after the options, and the launch is the last
        // thing in the group's body.
        XCTAssertTrue(script.contains("'vpn.example.com'; } & job=$!"),
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

    // MARK: - sudo timestamp

    /// `sudo -v` authenticates unconditionally, so it raised a Touch ID prompt
    /// of its own even when the timestamp was already valid. The probe must be
    /// non-interactive, or the refresh keeps costing a dialog it does not need.
    func testTheTimestampRefreshProbesNonInteractivelyFirst() {
        let script = makePlan().script

        XCTAssertTrue(script.contains("if ! sudo -n -v >/dev/null 2>&1; then"),
                      "the refresh must not authenticate when the timestamp is warm")
        XCTAssertTrue(script.contains("| sudo -S -v || { printf '%s\\n' 'turtlediver: elevation"),
                      "a refused password must be reported, not left as a bare exit status")
        XCTAssertTrue(script.contains("exit 1; }; fi"))
    }

    /// A cold timestamp still has to end up authenticated — `-n` alone would
    /// simply fail and stop every connect on a machine that has not run sudo
    /// recently.
    func testAColdTimestampStillFallsBackToTheStoredPassword() {
        let script = makePlan().script

        XCTAssertTrue(script.contains("printf '%s\\n' \"$\(OpenConnectCommand.adminVariable)\" | sudo -S -v"),
                      "the admin password fallback must survive the probe")
    }

    /// The refresh has to happen before anything else needs sudo, so the
    /// cleanup and openconnect inherit a warm timestamp instead of each raising
    /// their own dialog.
    func testTheTimestampIsRefreshedBeforeTheCleanupAndOpenconnect() throws {
        let script = makePlan().script
        let refresh = try XCTUnwrap(script.range(of: "sudo -n -v"))
        let cleanup = try XCTUnwrap(script.range(of: "sed -i"))
        let run = try XCTUnwrap(script.range(of: "/openconnect"))

        XCTAssertTrue(refresh.lowerBound < cleanup.lowerBound)
        XCTAssertTrue(cleanup.lowerBound < run.lowerBound)
    }

    /// Nothing was relaxed system-wide to get there: no `NOPASSWD`, no edit to
    /// sudoers, no passwordless `sudo` standing in for a password that is
    /// available. The default mode is the only one allowed to feed `-S`, and it
    /// feeds it only where the pipe carries the password.
    func testThePlanNeverAsksForPasswordlessSudo() {
        for elevation in ElevationStrategy.allCases {
            let script = makePlan(elevation: elevation).script
            XCTAssertFalse(script.contains("NOPASSWD"), "\(elevation) weakens sudo system-wide")
            XCTAssertFalse(script.contains("sudoers"), "\(elevation) touches sudoers")
        }
        XCTAssertFalse(makePlan().script.contains("sudo -n openconnect"))
        XCTAssertFalse(makePlan().script.contains("sudo -n sed"))
    }

    /// The default mode is the only one that may pipe a password, and it is the
    /// one whose `sudo` can never raise a dialog.
    func testOnlyTheStoredPasswordModeFeedsSudoAPassword() {
        let stored = makePlan(elevation: .storedPassword).script
        XCTAssertTrue(stored.contains("| sudo -S -v"))
        XCTAssertTrue(stored.contains("| sudo -S sed"))

        for elevation in [ElevationStrategy.systemPrompt, .warmTimestamp] {
            let script = makePlan(elevation: elevation).script
            XCTAssertFalse(script.contains("sudo -S"), "\(elevation) can still block on a dialog")
            XCTAssertFalse(script.contains(OpenConnectCommand.adminVariable),
                           "\(elevation) still references the administrator password")
        }
    }

    /// The Touch ID case: the dialog is the point, so stdin is closed and
    /// nothing is piped. Feeding `sudo` here is what produced the hang — the
    /// password was never read, and the `sudo` blocked forever.
    func testTheSystemPromptModeLetsSudoRaiseItsOwnDialogAndPipesNothing() {
        let plan = makePlan(elevation: .systemPrompt)

        XCTAssertTrue(plan.script.contains("sudo -v </dev/null"),
                      "sudo must be free to ask the system, with no pipe in the way")
        XCTAssertFalse(plan.script.contains("printf '%s\\n' \"$\(OpenConnectCommand.adminVariable)\""))
        XCTAssertEqual(plan.script.components(separatedBy: "IFS= read -r ").count - 1, 2)

        let lines = String(decoding: plan.standardInput, as: UTF8.self)
        XCTAssertEqual(lines, "\(pin)\n\(password)\n", "the admin password must not be on the pipe at all")
        XCTAssertFalse(lines.contains(admin))
    }

    /// The no-dialog case for a quit or a headless moment: never ask, and say so
    /// when the timestamp is cold.
    func testTheWarmTimestampModeRefusesToAskAndReportsWhy() {
        let plan = makePlan(elevation: .warmTimestamp)

        XCTAssertTrue(plan.script.contains("sudo -n '/opt/homebrew/bin/openconnect'"))
        XCTAssertFalse(plan.script.contains("sudo -S"))
        XCTAssertFalse(plan.script.contains("sudo -v"))
        XCTAssertTrue(plan.script.contains("exit 1"), "a cold timestamp must end the script, not wait")
        XCTAssertTrue(plan.script.contains(ElevationBlockReason.timestampExpired.markerLine))
        XCTAssertEqual(String(decoding: plan.standardInput, as: UTF8.self), "\(pin)\n\(password)\n")
    }

    /// The invariant the plain `sudo` launch relies on: by the time openconnect
    /// runs, a cold timestamp has already ended the script.
    func testTheWarmTimestampIsCheckedAgainImmediatelyBeforeTheLaunch() throws {
        let script = makePlan(elevation: .warmTimestamp).script
        let stillWarm = try XCTUnwrap(script.range(of: "sudo -n -v >/dev/null 2>&1 || {"))
        let launch = try XCTUnwrap(script.range(of: "sudo -n '/opt/homebrew/bin/openconnect'"))

        XCTAssertTrue(stillWarm.lowerBound < launch.lowerBound)
    }

    /// Quitting must never raise a dialog: nobody can answer one, and the app is
    /// on its way out.
    func testTheCleanupPlanOnQuitNeverAsksForAnything() {
        let plan = OpenConnectCommand.hostsCleanupPlan(adminPassword: admin, elevation: .warmTimestamp)

        XCTAssertTrue(plan.script.contains("sudo -n sed -i '' '/# vpn-slice-/d' /etc/hosts"))
        XCTAssertFalse(plan.script.contains("sudo -S"))
        XCTAssertFalse(plan.script.contains("sudo -v"))
        XCTAssertFalse(plan.script.contains(OpenConnectCommand.adminVariable))
        XCTAssertTrue(plan.script.contains(ElevationBlockReason.timestampExpired.markerLine))
        XCTAssertTrue(plan.standardInput.isEmpty)
        // It reports its own failure; the caller does not silence it.
        XCTAssertFalse(plan.script.contains("2>/dev/null"))
    }

    // MARK: - The process group

    func testThePrivilegedBodyRunsInItsOwnProcessGroup() {
        let script = makePlan(pgidFile: "/tmp/example.pgid").script

        XCTAssertTrue(script.contains("set -m; { set +m; "),
                      "job control must create the group, then be switched off inside it")
        XCTAssertTrue(script.contains("} & job=$!; set +m; "),
                      "job control must be off again before anything forks")
        XCTAssertTrue(script.contains("ps -o pgid= -p \"$job\" 2>/dev/null | tr -d ' ' > '/tmp/example.pgid'"))
        XCTAssertTrue(script.contains("wait \"$job\" 2>/dev/null; status=$?;"))
        XCTAssertTrue(script.contains("rm -f '/tmp/example.pgid'"))
        XCTAssertTrue(script.hasSuffix("exit $status"), "the body's status must be the script's status")
    }

    func testTheCleanupPlanRunsInTheForeground() {
        // Quitting has no timer to fall back on, so that plan waits inline.
        let plan = OpenConnectCommand.hostsCleanupPlan(adminPassword: admin)

        XCTAssertFalse(plan.script.contains("set -m"))
        XCTAssertFalse(plan.script.contains("job=$!"))
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
    /// simply execs its arguments. The process-group record is redirected into
    /// the sandbox too, so a test can never write into the real run directory.
    private func run(
        makePlan: (String) -> OpenConnectLaunchPlan
    ) throws -> (stdin: String, argv: [String], sudoCalls: [String], recordedPgid: String, openconnectPgid: String, wrapperPid: Int32) {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oclaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let plan = makePlan(sandbox.path)

        let recorded = sandbox.appendingPathComponent("openconnect-received.txt")
        let argvFile = sandbox.appendingPathComponent("openconnect-argv.txt")
        let sudoLog = sandbox.appendingPathComponent("sudo-calls.txt")
        let pgidFile = sandbox.appendingPathComponent("elevation.pgid")
        let myPgidFile = sandbox.appendingPathComponent("openconnect.pgid")
        let seenPgidFile = sandbox.appendingPathComponent("pgid-file-seen.pgid")

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
            -n) ;;
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
        # Record which process group this ran in, and what the script had
        # written down for it. The script writes the record concurrently with
        # this process starting, so wait — briefly and with a bound — for it.
        printf '%s\\n' "$(ps -o pgid= -p $$ | tr -d ' ')" > '\(myPgidFile.path)'
        i=0
        while [ ! -s '\(pgidFile.path)' ] && [ "$i" -lt 40 ]; do
          sleep 0.05
          i=$((i + 1))
        done
        cat '\(pgidFile.path)' > '\(seenPgidFile.path)' 2>/dev/null
        cat > '\(recorded.path)'
        """
        _ = try write("openconnect", openconnectBody)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", plan.script]
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

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
        let recordedPgid = ((try? String(contentsOf: seenPgidFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openconnectPgid = ((try? String(contentsOf: myPgidFile, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(stderr.isEmpty, "the plan wrote to stderr, which the app parses as log output: \(stderr)")
        return (received, argv, calls, recordedPgid, openconnectPgid, process.processIdentifier)
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
        let result = try run { makePlan(openconnectPath: $0 + "/openconnect", searchPath: $0,
                                        pgidFile: $0 + "/elevation.pgid") }

        XCTAssertEqual(result.stdin, "\(pin)\n\(password)\n",
                       "openconnect's own stdin must be unchanged from the old pipeline")
        XCTAssertEqual(result.stdin, try runLegacyPipeline())
    }

    /// The group is the whole mechanism: a teardown signals that id, and a
    /// launch-time sweep decides from it whether a leftover can be killed. Both
    /// only work if the id really is the group openconnect runs in — and if it
    /// is *not* the app's own group, because signalling that would kill the app.
    func testTheRecordedGroupIsTheOneOpenconnectActuallyRunsIn() throws {
        let result = try run { makePlan(openconnectPath: $0 + "/openconnect", searchPath: $0,
                                        pgidFile: $0 + "/elevation.pgid") }

        let recorded = try XCTUnwrap(Int32(result.recordedPgid), "the script recorded no process group")
        let actual = try XCTUnwrap(Int32(result.openconnectPgid), "openconnect did not report its group")
        XCTAssertEqual(recorded, actual, "the recorded group is not the one openconnect ran in")
        XCTAssertNotEqual(recorded, result.wrapperPid,
                          "the record names the wrapper itself, not a group the body leads")
        XCTAssertNotEqual(recorded, getpgrp(),
                          "the recorded group is the caller's own — signalling it would kill the app")
    }

    func testTheAdminPasswordReachesSudoThroughItsStdinNotItsArguments() throws {
        let result = try run { makePlan(openconnectPath: $0 + "/openconnect", searchPath: $0,
                                        pgidFile: $0 + "/elevation.pgid") }

        XCTAssertFalse(result.sudoCalls.isEmpty, "the fake sudo was never called")
        for call in result.sudoCalls {
            XCTAssertFalse(call.contains(admin), "the admin password is in sudo's argv: \(call)")
        }
        // The admin password is piped into `sudo -S` (which the fake logs as a
        // `-S …` call) — proving the pipe reached it.
        XCTAssertTrue(result.sudoCalls.contains { $0.hasPrefix("-S") })
    }

    func testOpenconnectNeverSeesTheCredentialsInItsArguments() throws {
        let result = try run { makePlan(openconnectPath: $0 + "/openconnect", searchPath: $0,
                                        pgidFile: $0 + "/elevation.pgid") }

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
                            searchPath: sandbox.path,
                            pgidFile: sandbox.appendingPathComponent("elevation.pgid").path)
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
