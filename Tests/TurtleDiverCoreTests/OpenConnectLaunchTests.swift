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
                          askpassHelper: String? = nil,
                          pgidFile: String = "/tmp/turtlediver-test-elevation.pgid") -> OpenConnectLaunchPlan {
        OpenConnectCommand.launchPlan(
            openconnectPath: openconnectPath,
            arguments: arguments ?? ["--force-dpd=10", "--user=10001", "--pid-file", "/tmp/pid", host],
            adminPassword: admin,
            pin: pin,
            vpnPassword: password,
            searchPath: searchPath,
            elevation: elevation,
            askpassHelper: askpassHelper,
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

    func testTheCleanupStepIsPartOfTheLaunchPlan() {
        // Stale `/etc/hosts` entries are cleaned by the plan's own step, in the
        // `sudo` context that just authenticated. There is no standalone cleanup
        // plan any more: the only thing that ever called one ran `sudo` as a
        // child of the app, whose timestamp is keyed to a different parent — so
        // it could only ever report "a password is required".
        XCTAssertTrue(makePlan().script.contains("sed -i '' '/# vpn-slice-/d' /etc/hosts"))
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

        for elevation in [ElevationStrategy.systemPrompt, .neverPrompt] {
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

    /// The no-dialog case for a headless moment: never ask, and say so when the
    /// timestamp is cold.
    func testTheNeverPromptModeRefusesToAskAndReportsWhy() {
        let plan = makePlan(elevation: .neverPrompt)

        XCTAssertTrue(plan.script.contains("sudo -n '/opt/homebrew/bin/openconnect'"))
        XCTAssertFalse(plan.script.contains("sudo -S"))
        XCTAssertFalse(plan.script.contains("sudo -v"))
        XCTAssertTrue(plan.script.contains("exit 1"), "a cold timestamp must end the script, not wait")
        XCTAssertTrue(plan.script.contains(ElevationBlockReason.timestampExpired.markerLine))
        XCTAssertEqual(String(decoding: plan.standardInput, as: UTF8.self), "\(pin)\n\(password)\n")
    }

    /// The invariant the plain `sudo` launch relies on: by the time openconnect
    /// runs, a cold timestamp has already ended the script.
    func testTheTimestampIsCheckedAgainImmediatelyBeforeANoPromptLaunch() throws {
        let script = makePlan(elevation: .neverPrompt).script
        let stillWarm = try XCTUnwrap(script.range(of: "sudo -n -v >/dev/null 2>&1 || {"))
        let launch = try XCTUnwrap(script.range(of: "sudo -n '/opt/homebrew/bin/openconnect'"))

        XCTAssertTrue(stillWarm.lowerBound < launch.lowerBound)
    }

    // MARK: - The askpass door

    /// The door that lets a Mac with Touch ID for `sudo` connect with nobody at
    /// the keyboard: every privileged step names `-A`, and the helper's path — a
    /// path, never a password — is exported before the first `sudo`, because
    /// `sudo` reads that variable from its own environment.
    func testTheAskpassPlanNamesTheHelperAndUsesDashAEverywhere() {
        let helper = "/Applications/TurtleDiver.app/Contents/Library/HelperTools/turtlediver-askpass"
        let script = makePlan(elevation: .systemPrompt, askpassHelper: helper).script

        XCTAssertTrue(script.contains("export SUDO_ASKPASS='\(helper)'; "),
                      "the helper's path must be in sudo's own environment")
        XCTAssertTrue(script.contains("sudo -A -v </dev/null"),
                      "the refresh must authenticate through the helper, not a dialog")
        XCTAssertTrue(script.contains("sudo -A sed -i '' '/# vpn-slice-/d' /etc/hosts"))
        XCTAssertTrue(script.contains("| sudo -A '/opt/homebrew/bin/openconnect'"))
        XCTAssertFalse(script.contains("sudo -S"), "the pipe is dead on this machine")
        XCTAssertFalse(script.contains("sudo -v </dev/null"),
                       "a bare -v is the dialog this route exists to avoid")
    }

    /// The helper replaces the *password*, not the pipe: openconnect still gets
    /// its PIN and account password, and the administrator password is nowhere —
    /// not in the script, not in the pipe, not in any variable the script reads.
    func testTheAskpassPlanKeepsTheAdministratorPasswordOutOfEverything() {
        let plan = makePlan(elevation: .systemPrompt, askpassHelper: "/tmp/helper")

        XCTAssertFalse(plan.script.contains(admin))
        XCTAssertFalse(plan.script.contains(OpenConnectCommand.adminVariable))
        XCTAssertEqual(plan.script.components(separatedBy: "IFS= read -r ").count - 1, 2)

        let lines = String(decoding: plan.standardInput, as: UTF8.self)
        XCTAssertEqual(lines, "\(pin)\n\(password)\n")
        XCTAssertFalse(lines.contains(admin))
    }

    /// Without a prepared helper, a machine whose sudo stack asks a person still
    /// asks a person. That is the behaviour that shipped before this existed, and
    /// it has to survive: a connect must not silently pretend to be unattended.
    func testWithoutAHelperTheSystemPromptPlanStillWaitsForAPerson() {
        let script = makePlan(elevation: .systemPrompt).script

        XCTAssertFalse(script.contains("SUDO_ASKPASS"))
        XCTAssertFalse(script.contains("sudo -A"))
        XCTAssertTrue(script.contains("sudo -v </dev/null"))
        XCTAssertTrue(script.contains(ElevationBlockReason.systemPromptUnanswered.markerLine))
    }

    /// A helper that runs but supplies nothing is a different failure from a
    /// dialog nobody answered, and the log has to say which one happened.
    func testAnAskpassFailureIsReportedAsItsOwnCause() {
        let script = makePlan(elevation: .systemPrompt, askpassHelper: "/tmp/helper").script

        XCTAssertTrue(script.contains(ElevationBlockReason.askpassRefused.markerLine))
        XCTAssertFalse(script.contains(ElevationBlockReason.systemPromptUnanswered.markerLine))
        XCTAssertEqual(ElevationBlockReason.askpassRefused.historyStatus, "Failed - Admin Password")
        XCTAssertTrue(ElevationBlockReason.askpassRefused.detail.contains("Settings ▸ VPN"))
    }

    /// Where the pipe is read, a helper is dead weight and the plan says so: the
    /// mode that cannot raise a dialog names its own door, and a stray helper
    /// cannot turn `-S` into `-A` behind the caller's back.
    func testAHelperIsIgnoredWhereThePipeIsRead() {
        for elevation in [ElevationStrategy.storedPassword, .neverPrompt] {
            let script = makePlan(elevation: elevation, askpassHelper: "/tmp/helper").script
            XCTAssertFalse(script.contains("SUDO_ASKPASS"), "\(elevation) exported a helper path")
            XCTAssertFalse(script.contains("sudo -A"), "\(elevation) used the askpass door")
        }

        XCTAssertEqual(OpenConnectCommand.askpassPath(.systemPrompt, "/tmp/helper"), "/tmp/helper")
        XCTAssertNil(OpenConnectCommand.askpassPath(.systemPrompt, nil))
        XCTAssertNil(OpenConnectCommand.askpassPath(.systemPrompt, ""), "an empty path is not a helper")
        XCTAssertNil(OpenConnectCommand.askpassPath(.storedPassword, "/tmp/helper"))
        XCTAssertNil(OpenConnectCommand.askpassPath(.neverPrompt, "/tmp/helper"))
    }

    /// The path is escaped like any other interpolated value, because it is the
    /// one thing on this route that does come from outside the script.
    func testAHelperPathWithAQuoteSurvivesEscaping() {
        let script = makePlan(elevation: .systemPrompt, askpassHelper: "/tmp/it's here/helper").script

        XCTAssertTrue(script.contains(#"export SUDO_ASKPASS='/tmp/it'\''s here/helper'; "#))
    }

    /// The same decision, stated once for both callers: the app and the command
    /// line must not be able to disagree about which door a password takes.
    func testTheDeliveryFollowsTheStrategyAndTheHelper() {
        XCTAssertEqual(SudoPasswordDelivery.resolve(strategy: .storedPassword), .standardInput)
        XCTAssertEqual(SudoPasswordDelivery.resolve(strategy: .systemPrompt, askpassHelper: "/tmp/helper"),
                       .askpass)
        XCTAssertNil(SudoPasswordDelivery.resolve(strategy: .systemPrompt),
                     "no helper, no door: the dialog answers instead")
        XCTAssertNil(SudoPasswordDelivery.resolve(strategy: .neverPrompt, askpassHelper: "/tmp/helper"))
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

    func testTheConnectPlanKeepsTheCleanupStepQuiet() {
        // The old pipeline sent the /etc/hosts cleanup's stderr to /dev/null:
        // a stale entry it cannot remove is not a connection failure, and the
        // app parses stderr for error bursts.
        XCTAssertTrue(makePlan().script.contains("| sudo -S sed -i '' '/# vpn-slice-/d' /etc/hosts 2>/dev/null"))
        // The Touch ID mode cleans through the same `sudo` it has just warmed,
        // and asks nothing of its own.
        let touchID = makePlan(elevation: .systemPrompt).script
        XCTAssertTrue(touchID.contains("sudo sed -i '' '/# vpn-slice-/d' /etc/hosts 2>/dev/null"))
        XCTAssertFalse(touchID.contains("sudo -S sed"))
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
    ) throws -> (stdin: String, argv: [String], sudoCalls: [String], recordedPgid: String, openconnectPgid: String, wrapperPid: Int32, askpassCalls: [String], askpassOutput: String) {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oclaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let plan = makePlan(sandbox.path)

        let recorded = sandbox.appendingPathComponent("openconnect-received.txt")
        let argvFile = sandbox.appendingPathComponent("openconnect-argv.txt")
        let sudoLog = sandbox.appendingPathComponent("sudo-calls.txt")
        let pgidFile = sandbox.appendingPathComponent("elevation.pgid")
        let askpassLog = sandbox.appendingPathComponent("askpass-calls.txt")
        let askpassOut = sandbox.appendingPathComponent("askpass-output.txt")
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
        # flags, then run the rest of the command for real. `-A` is honoured the
        # way sudo honours it: run the program named by SUDO_ASKPASS and read the
        # password from *its* output — which is how a test can see that the
        # helper really ran and that the calling script never held a password.
        printf '%s\\n' "$*" >> '\(sudoLog.path)'
        password=0
        args=()
        for arg in "$@"; do
          case "$arg" in
            -S) password=1 ;;
            -v) exit 0 ;;
            -n) ;;
            -A)
              printf '%s\n' "$SUDO_ASKPASS" >> '\(askpassLog.path)'
              "$SUDO_ASKPASS" > '\(askpassOut.path)' 2>/dev/null || exit 1
              ;;
            *) args+=("$arg") ;;
          esac
        done
        [ "$password" = 1 ] && cat > /dev/null
        exec "${args[@]}"
        """
        _ = try write("sudo", sudoBody)
        _ = try write("sed", "#!/bin/bash\nexit 0\n")
        _ = try write("helper", "#!/bin/bash\nprintf '%s\\n' 'askpass-helper-ran'\n")
        _ = try write("helper-that-refuses", "#!/bin/bash\nexit 1\n")
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
        let askpassCalls = ((try? String(contentsOf: askpassLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        let askpassOutput = (try? String(contentsOf: askpassOut, encoding: .utf8)) ?? ""
        return (received, argv, calls, recordedPgid, openconnectPgid, process.processIdentifier,
                askpassCalls, askpassOutput)
    }

    /// The askpass plan, run for real against a fake `sudo` that honours `-A`
    /// the way sudo does: it runs `$SUDO_ASKPASS` and reads that program's
    /// output. Three things are being checked at once, and each is a claim the
    /// design rests on — that the path really reaches sudo's environment, that
    /// the helper really is what ran instead of a dialog, and that the connect's
    /// own pipe still carries only the two tunnel credentials.
    func testTheAskpassPlanRunsTheHelperAndKeepsTheConnectPipeClean() throws {
        var helperPath = ""
        let result = try run { sandbox in
            helperPath = sandbox + "/helper"
            return makePlan(openconnectPath: sandbox + "/openconnect", searchPath: sandbox,
                            elevation: .systemPrompt, askpassHelper: helperPath,
                            pgidFile: sandbox + "/elevation.pgid")
        }

        XCTAssertEqual(Set(result.askpassCalls), [helperPath],
                       "the path that reached sudo was not the helper's — or it never ran")
        XCTAssertEqual(result.askpassOutput, "askpass-helper-ran\n",
                       "sudo did not get output from the helper, so nothing could authenticate")
        // The first call is the warmth probe, which is `-n` by design: it must
        // never authenticate. Every call *after* it goes through the helper.
        XCTAssertFalse(result.sudoCalls.isEmpty)
        XCTAssertEqual(result.sudoCalls.first, "-n -v", "the probe must not authenticate")
        XCTAssertTrue(result.sudoCalls.dropFirst().allSatisfy { $0.hasPrefix("-A") },
                      "a privileged step ran without the askpass door: \(result.sudoCalls)")
        // The warmth probe succeeded, so the refresh never had to authenticate:
        // the two remaining privileged steps are the ones that did.
        XCTAssertEqual(result.sudoCalls.filter { $0.hasPrefix("-A") }.count, 2,
                       "the hosts cleanup and the launch both need the helper")
        XCTAssertFalse(result.sudoCalls.contains { $0.hasPrefix("-S") },
                       "a piped password appeared on the askpass route")
        XCTAssertEqual(result.stdin, "\(pin)\n\(password)\n")
        XCTAssertTrue(result.argv.contains { $0.hasPrefix("--user=") }, "openconnect never ran")
    }

    /// A helper that cannot deliver ends the connect with its own marker rather
    /// than hanging: that is the difference between a reported cause and the
    /// blocked-`sudo` wait this whole route exists to remove.
    func testARefusingHelperStopsTheConnectInsteadOfWaiting() throws {
        let result = try runWithColdTimestamp { sandbox in
            makePlan(openconnectPath: sandbox + "/openconnect", searchPath: sandbox,
                     elevation: .systemPrompt, askpassHelper: sandbox + "/helper-that-refuses",
                     pgidFile: sandbox + "/elevation.pgid")
        }

        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(result.launched, "the privileged body ran without authenticating")
        XCTAssertTrue(result.stderr.contains(ElevationBlockReason.askpassRefused.markerLine),
                      "the cause was not named: \(result.stderr)")
    }

    /// The same cold timestamp, with a helper that works: the connect proceeds
    /// and the helper — not a dialog — is what answered.
    func testAColdTimestampOnTheAskpassRouteIsAnsweredByTheHelper() throws {
        let result = try runWithColdTimestamp { sandbox in
            makePlan(openconnectPath: sandbox + "/openconnect", searchPath: sandbox,
                     elevation: .systemPrompt, askpassHelper: sandbox + "/helper",
                     pgidFile: sandbox + "/elevation.pgid")
        }

        XCTAssertTrue(result.launched, "a prepared helper must be enough to authenticate")
        XCTAssertFalse(result.askpassCalls.isEmpty, "the helper was never asked")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)
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

    // MARK: - A cold sudo timestamp

    private struct ColdTimestampRun {
        let status: Int32
        let stderr: String
        let sudoCalls: [String]
        let launched: Bool
        let askpassCalls: [String]
    }

    /// The regression that produced `Failed - Elevation Expired`, driven through
    /// the plan itself.
    ///
    /// Both plans run against the same fake tools, whose `sudo -n -v` **fails** —
    /// a cold timestamp, which is the normal state of the connect wrapper's own
    /// process context. Only the strategy differs, and that is the whole point:
    /// the one a connect resolves to (`.systemPrompt` on a Mac with `pam_tid`)
    /// recovers by letting the system ask for Touch ID or a password, while
    /// `.neverPrompt` — the strategy the app used to choose from a warmth probe
    /// taken in a *different* process — ends the connect with a classified marker.
    func testAColdTimestampIsRecoveredByAskingAndRefusedByNeverPrompt() throws {
        let asking = try runWithColdTimestamp { path in
            makePlan(openconnectPath: path + "/openconnect", searchPath: path,
                     elevation: .systemPrompt, pgidFile: path + "/elevation.pgid")
        }
        XCTAssertEqual(asking.status, 0, "a connect that may ask must survive a cold timestamp: \(asking.stderr)")
        XCTAssertTrue(asking.launched, "openconnect must have been reached")
        XCTAssertFalse(asking.stderr.contains(ElevationBlockReason.timestampExpired.markerLine))
        XCTAssertTrue(asking.sudoCalls.contains { $0.contains("sed") },
                      "the plan's own /etc/hosts cleanup must run in the context that just authenticated")

        let refusing = try runWithColdTimestamp { path in
            makePlan(openconnectPath: path + "/openconnect", searchPath: path,
                     elevation: .neverPrompt, pgidFile: path + "/elevation.pgid")
        }
        XCTAssertNotEqual(refusing.status, 0, "a no-prompt launch must not proceed on a cold timestamp")
        XCTAssertFalse(refusing.launched, "nothing privileged may run without a warm timestamp")
        XCTAssertTrue(refusing.stderr.contains(ElevationBlockReason.timestampExpired.markerLine),
                      "the refusal must be classified, not left as a bare exit status")
    }

    /// Runs a plan against fake `sudo`/`sed`/`openconnect` tools on a private PATH
    /// where the timestamp is cold: `sudo -n` always fails, while the forms that
    /// may ask (`-v`, `-S`) succeed. No password is read and no real tool runs —
    /// in particular `sed` is a stub, so `/etc/hosts` is never touched.
    private func runWithColdTimestamp(
        makePlan: (String) -> OpenConnectLaunchPlan
    ) throws -> ColdTimestampRun {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let plan = makePlan(sandbox.path)

        let sudoLog = sandbox.appendingPathComponent("sudo-calls.txt")
        let launched = sandbox.appendingPathComponent("openconnect-ran")
        let askpassSeen = sandbox.appendingPathComponent("askpass-path.txt")

        func write(_ name: String, _ body: String) throws {
            let url = sandbox.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        _ = try write("sudo", """
        #!/bin/bash
        # A cold timestamp, modelled: the non-interactive form fails outright,
        # the forms that are allowed to ask succeed. Nothing authenticates for
        # real, and the password pipe is swallowed rather than read. `-A` runs
        # the helper, as sudo would: that is the evidence a dialog was *not*
        # what answered.
        printf '%s\\n' "$*" >> '\(sudoLog.path)'
        args=()
        for arg in "$@"; do
          if [ "$arg" = "-n" ]; then exit 1; fi
          case "$arg" in
            -S) cat > /dev/null ;;
            -A)
              printf '%s\n' "$SUDO_ASKPASS" >> '\(askpassSeen.path)'
              "$SUDO_ASKPASS" > /dev/null 2>&1 || exit 1
              ;;
            -v) ;;
            *) args+=("$arg") ;;
          esac
        done
        if [ "${#args[@]}" -eq 0 ]; then exit 0; fi
        exec "${args[@]}"
        """)
        _ = try write("sed", "#!/bin/bash\nexit 0\n")
        _ = try write("openconnect", "#!/bin/bash\ntouch '\(launched.path)'\ncat > /dev/null\n")
        _ = try write("helper", "#!/bin/bash\nprintf '%s\\n' 'askpass-helper-ran'\n")
        _ = try write("helper-that-refuses", "#!/bin/bash\nexit 1\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", plan.script]
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        try stdinPipe.fileHandleForWriting.write(contentsOf: plan.standardInput)
        try? stdinPipe.fileHandleForWriting.close()
        let stderr = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        return ColdTimestampRun(
            status: process.terminationStatus,
            stderr: stderr,
            sudoCalls: ((try? String(contentsOf: sudoLog, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init),
            launched: FileManager.default.fileExists(atPath: launched.path),
            askpassCalls: ((try? String(contentsOf: askpassSeen, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        )
    }
}
