import Foundation

/// What to hand to `/bin/bash -c` when openconnect is launched, plus the bytes
/// that script must receive on its standard input.
///
/// The two are separate on purpose. A process's argv is readable by any other
/// process running as the same user (`ps`, `pgrep -f`) and it is copied into
/// crash reports, so credentials must never appear in it. Here the script is a
/// *constant* — nothing secret is interpolated into it — and the credentials
/// travel down a pipe that `read` consumes into shell variables, which are not
/// exported and therefore not inherited by the children either. openconnect
/// itself still gets exactly the same standard input it always did (the PIN
/// and the account password, one per line); only sudo's own password moves
/// from an `echo` argument to the pipe.
///
/// `OpenConnectLaunchTests` runs both plans against a fake `sudo`/`openconnect`
/// pair and compares the bytes openconnect receives with the old pipeline's
/// output, so the credential path is covered without a VPN.
public struct OpenConnectLaunchPlan: Equatable, Sendable {
    /// The text for `bash -c`. Contains no credential material.
    public let script: String
    /// The credential lines the script reads, in order, newline-terminated.
    public let standardInput: Data

    public init(script: String, standardInput: Data) {
        self.script = script
        self.standardInput = standardInput
    }
}

/// Builds the shell plans that need a credential.
public enum OpenConnectCommand {
    /// Name of the shell variables the script fills from stdin. They are
    /// deliberately not exported: an exported variable is visible in a child's
    /// environment (`ps -E`), which would just move the leak.
    public static let adminVariable = "oc_admin"
    public static let pinVariable = "oc_pin"
    public static let passwordVariable = "oc_pass"

    /// How many credential lines the connect plan's stdin carries, in order:
    /// admin (sudo), PIN (passcode + tokencode), account password.
    public static let credentialLineCount = 3

    /// The default `openconnect` lookup path, prepended so a Homebrew install
    /// wins over anything else on the login shell's `PATH`.
    public static let defaultSearchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    /// The full connect pipeline: refresh sudo's timestamp if that can be done
    /// without asking, clear stale vpn-slice lines out of `/etc/hosts`, then
    /// hand the PIN and the account password to openconnect.
    ///
    /// The credential order (PIN, then password) and the shape of the pipelines
    /// are unchanged from the previous `echo`-based version; only the source of
    /// the bytes is.
    ///
    /// `elevation` decides what happens when the timestamp is cold, and with it
    /// whether the administrator password is on the pipe at all. In the default
    /// `.storedPassword` mode the script is byte-for-byte what it was; the other
    /// two modes exist because on a Mac with Touch ID for sudo a piped password
    /// is never read, and the connect then waits for a dialog nobody can answer
    /// while a root-owned `sudo` sits blocked.
    ///
    /// The privileged work runs in its own process group, whose id is written to
    /// `pgidFile` so a wrapper that outlives the app can be found again. See
    /// `groupedWrapper` for why that is the only handle that survives.
    public static func launchPlan(
        openconnectPath: String,
        arguments: [String],
        adminPassword: String,
        pin: String,
        vpnPassword: String,
        searchPath: String = defaultSearchPath,
        elevation: ElevationStrategy = .storedPassword,
        pgidFile: String = ElevationRecord.path.path
    ) -> OpenConnectLaunchPlan {
        let escapedArguments = arguments.map(shellEscape).joined(separator: " ")
        let body = [
            timestampRefreshStep(elevation),
            elevation == .warmTimestamp ? timestampStillWarmStep : nil,
            // `2>/dev/null` is kept from the old pipeline on purpose: a stale
            // entry that cannot be cleaned is not a connection failure, and its
            // stderr would otherwise be parsed as an error burst. The still-warm
            // check above runs first, so nothing it reports is lost here.
            hostsCleanupStep(elevation) + " 2>/dev/null",
            "printf '%s\\n%s\\n' \"$\(pinVariable)\" \"$\(passwordVariable)\""
                + " | \(launchInvocation(elevation)) \(shellEscape(openconnectPath)) \(escapedArguments)"
        ].compactMap { $0 }.joined(separator: "; ")

        let variables = credentialVariables(elevation)
        return OpenConnectLaunchPlan(
            script: script(searchPath: searchPath, variables: variables,
                          body: groupedWrapper(body: body, variables: variables, pgidFile: pgidFile)),
            standardInput: credentialLines(credentialValues(elevation, adminPassword: adminPassword,
                                                            pin: pin, vpnPassword: vpnPassword))
        )
    }

    /// The stale-`/etc/hosts` cleanup on its own — run on quit, when
    /// openconnect is already gone. Needs no openconnect stdin. Stderr is left
    /// connected on purpose: the caller reports it.
    ///
    /// The caller passes `.warmTimestamp` on quit: a `pam_tid` dialog raised
    /// while the app is quitting cannot be answered, so that path uses `sudo -n`
    /// and fails loudly instead of asking.
    public static func hostsCleanupPlan(
        adminPassword: String,
        searchPath: String = defaultSearchPath,
        elevation: ElevationStrategy = .storedPassword
    ) -> OpenConnectLaunchPlan {
        let variables = cleanupVariables(elevation)
        return OpenConnectLaunchPlan(
            script: script(searchPath: searchPath, variables: variables,
                          body: hostsCleanupStep(elevation)),
            standardInput: credentialLines(variables.isEmpty ? [] : [adminPassword])
        )
    }

    /// The `sudo` prefix for the launch itself. Deliberately never `-S`: stdin
    /// carries openconnect's PIN and account password, so a `-S` that decided it
    /// needed a password would consume the PIN as its own and hand openconnect
    /// half a credential. It does not need one — the refresh step above exits
    /// the script with a marker if it cannot warm the timestamp, so a plain
    /// `sudo` here cannot prompt. In `.warmTimestamp` mode `-n` states that
    /// outright.
    public static func launchInvocation(_ elevation: ElevationStrategy) -> String {
        elevation == .warmTimestamp ? "sudo -n" : "sudo"
    }

    /// The credential lines the connect script reads, in the order the pipe
    /// carries them. Only the mode that feeds `sudo -S` reads the admin line.
    public static func credentialVariables(_ elevation: ElevationStrategy) -> [String] {
        elevation.pipesTheStoredPassword
            ? [adminVariable, pinVariable, passwordVariable]
            : [pinVariable, passwordVariable]
    }

    /// The cleanup script's variables: the admin line, or nothing at all.
    private static func cleanupVariables(_ elevation: ElevationStrategy) -> [String] {
        elevation.pipesTheStoredPassword ? [adminVariable] : []
    }

    private static func credentialValues(
        _ elevation: ElevationStrategy,
        adminPassword: String,
        pin: String,
        vpnPassword: String
    ) -> [String] {
        elevation.pipesTheStoredPassword ? [adminPassword, pin, vpnPassword] : [pin, vpnPassword]
    }

    /// Refreshes sudo's timestamp without a dialog whenever the timestamp is
    /// already valid, and only then authenticates in the way the machine's PAM
    /// stack allows.
    ///
    /// `sudo -v` on its own authenticates unconditionally, which raised a Touch
    /// ID (or password) dialog for the refresh itself even when the cleanup
    /// below had just authenticated — a prompt that proved nothing. `-n` never
    /// prompts, so it succeeds exactly when the timestamp is warm.
    ///
    /// The fallback is the whole point of the three modes:
    ///
    /// * `.storedPassword` pipes the stored admin password into `sudo -S`. This
    ///   is the clamshell and no-Touch-ID case, and no dialog can appear because
    ///   `-S` never asks for one.
    /// * `.systemPrompt` deliberately pipes nothing and closes stdin. With
    ///   `pam_tid` as a `sufficient` module, `sudo -v` raises the system's own
    ///   Touch ID / password dialog and reads no pipe at all; feeding it one
    ///   means the dialog is never answered and the `sudo` blocks forever.
    /// * `.warmTimestamp` refuses to ask anyone: if the timestamp is not warm it
    ///   fails immediately, with a marker, so the connect reports a cause
    ///   instead of timing out.
    private static func timestampRefreshStep(_ elevation: ElevationStrategy) -> String {
        switch elevation {
        case .storedPassword:
            return "if ! sudo -n -v >/dev/null 2>&1; then"
                + " printf '%s\\n' \"$\(adminVariable)\" | sudo -S -v"
                + " || { \(marker(.storedPasswordRejected)); exit 1; }; fi"
        case .systemPrompt:
            return "if ! sudo -n -v >/dev/null 2>&1; then"
                + " sudo -v </dev/null"
                + " || { \(marker(.systemPromptUnanswered)); exit 1; }; fi"
        case .warmTimestamp:
            return "if ! sudo -n -v >/dev/null 2>&1; then"
                + " \(marker(.timestampExpired)); exit 1; fi"
        }
    }

    /// Rechecks immediately before the privileged launch, in the one mode that
    /// cannot re-authenticate. The window is milliseconds wide, but the failure
    /// it catches — `sudo -n` finding a cold timestamp — is silent otherwise.
    private static let timestampStillWarmStep =
        "sudo -n -v >/dev/null 2>&1 || { \(marker(.timestampExpired)); exit 1; }"

    /// `sed -i` through sudo. The password is fed by `printf` rather than `echo`
    /// so a password containing a backslash or a leading `-n` is not mangled,
    /// and it is only fed where a password is available to feed.
    private static func hostsCleanupStep(_ elevation: ElevationStrategy) -> String {
        switch elevation {
        case .storedPassword:
            return "printf '%s\\n' \"$\(adminVariable)\""
                + " | sudo -S sed -i '' '/# vpn-slice-/d' /etc/hosts"
        case .systemPrompt:
            return "sudo sed -i '' '/# vpn-slice-/d' /etc/hosts"
        case .warmTimestamp:
            // Used on quit, and at launch as `… 2>/dev/null`. Failing here is
            // reported rather than papered over with a dialog.
            return "sudo -n sed -i '' '/# vpn-slice-/d' /etc/hosts"
                + " || { \(marker(.timestampExpired)); exit 1; }"
        }
    }

    /// One stderr line naming the branch that failed, so the app can report a
    /// classified status instead of a bare exit code. Contains no credentials.
    private static func marker(_ reason: ElevationBlockReason) -> String {
        "printf '%s\\n' \(shellEscape(reason.markerLine)) >&2"
    }

    /// Runs the privileged body in its **own process group**, and records the
    /// group id before waiting for it.
    ///
    /// The record exists so that a group id survives the connection: `$!` and the
    /// `Process` object both die with the launch, but a group id stays valid for
    /// as long as any member of it is alive. That is what lets a *later* launch
    /// discover a `sudo` that was blocked on authentication and is still sitting
    /// there — `ps -g <pgid>` lists it — instead of the leftover being invisible.
    /// It is also what a teardown signals: one id, and every user-owned member of
    /// the privileged subtree goes with it, rather than only the one child whose
    /// pid the app happens to be holding.
    ///
    /// What this does *not* buy: the app still cannot signal a root-owned member
    /// (the kernel refuses a signal from a non-root sender). `killpg` delivers to
    /// whoever it may, and skips the rest — so the root `sudo` that caused the
    /// whole problem is findable and reportable, but not killable, and nothing
    /// here pretends otherwise.
    ///
    /// Two details are load-bearing, both measured against a real bash rather
    /// than reasoned about:
    ///
    /// * `set -m`, so the backgrounded subshell gets a group of its own. Without
    ///   it the subshell stays in the group of the `bash` this app spawns, and the
    ///   recorded id would name *the wrapper* — which happens to be harmless, since
    ///   openconnect is in that group too, but it makes the record mean "the whole
    ///   launch" instead of "the privileged body". (Foundation already spawns that
    ///   wrapper as a group leader, so neither variant can accidentally name the
    ///   app's own group; `set -m` is what narrows the record to the body.)
    /// * `set +m` in the outer shell immediately after `$!`, before anything that
    ///   forks. While job control is on, bash prints a job-status line (`[1]+ Done …`)
    ///   as soon as it runs a command that forks, and that line would land in the
    ///   connect log. As the next command it is silent even when the job has
    ///   already finished.
    ///
    /// `set +m` inside the braces is kept for the case where somebody runs the
    /// script from a terminal to debug it: there bash has a controlling terminal
    /// and *does* give a foreground pipeline a group of its own. With no
    /// controlling terminal — how the app runs it — the pipeline stays in the
    /// subshell's group either way.
    ///
    /// `2>/dev/null` on the `ps` probe: if the job is already gone, `ps` has
    /// nothing to say, and the file is left empty — which reads as "no group to
    /// signal", the safe answer.
    private static func groupedWrapper(body: String, variables: [String], pgidFile: String) -> String {
        "set -m; { set +m; \(body); } & job=$!; set +m;"
        + " ps -o pgid= -p \"$job\" 2>/dev/null | tr -d ' ' > \(shellEscape(pgidFile));"
        + " wait \"$job\" 2>/dev/null; status=$?;"
        + " rm -f \(shellEscape(pgidFile)); \(unsetStep(variables)); exit $status"
    }

    /// `export PATH=…; read …; body`
    ///
    /// A failed `read` exits instead of continuing: an empty credential sent to
    /// `sudo -S` would fail anyway, and this way the failure is one line in the
    /// log rather than a confusing sudo prompt.
    private static func script(searchPath: String, variables: [String], body: String) -> String {
        let reads = variables.map { "IFS= read -r \($0) || exit 1" }.joined(separator: "; ")
        let prefix = reads.isEmpty ? "" : "\(reads); "
        return "export PATH=\(shellEscape(searchPath)):$PATH; \(prefix)\(body)"
    }

    private static func unsetStep(_ variables: [String]) -> String {
        variables.isEmpty ? ":" : "unset \(variables.joined(separator: " "))"
    }

    private static func credentialLines(_ values: [String]) -> Data {
        Data(values.map { $0 + "\n" }.joined().utf8)
    }

    /// Single-quote escaping for POSIX shells.
    ///
    /// A credential never needs this any more (it is not in the script), but
    /// the paths, the search `PATH` and the openconnect arguments still do.
    public static func shellEscape(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where openconnect records the PID of the running process.
///
/// This used to be `/tmp/turtlediver.pid`. `/tmp` is world-writable, so another
/// local user could pre-create that name — as a plain file, or as a symlink
/// pointing at a file of their choosing, which the app would then delete or
/// openconnect (running as root) would write through. Application Support is
/// ours and owner-only, so the name cannot be squatted.
public enum OpenConnectPidFile {
    public static let fileName = "openconnect.pid"
    public static let directoryName = "run"
    /// The pre-migration location, still read once so an openconnect started by
    /// an older build can be adopted.
    public static let legacyPath = "/tmp/turtlediver.pid"

    /// `~/Library/Application Support/TurtleDiver`.
    public static var applicationSupportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("TurtleDiver", isDirectory: true)
    }

    /// `…/TurtleDiver/run/openconnect.pid`.
    public static func path(inApplicationSupport directory: URL) -> URL {
        directory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The path the app uses.
    public static var path: URL { path(inApplicationSupport: applicationSupportDirectory) }

    /// Creates `run/` with `0700` before openconnect is launched.
    ///
    /// openconnect runs as root through sudo, so it can write the file anywhere
    /// — but the directory has to exist first, and the modes are reapplied in
    /// case an earlier version created it differently.
    @discardableResult
    public static func prepareDirectory(for pidFile: URL = OpenConnectPidFile.path) -> Bool {
        let directory = pidFile.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return true
    }

    /// Deletes the pre-migration file once, so a stale PID from `/tmp` cannot
    /// outlive the change. `removeItem` unlinks a symlink rather than following
    /// it, which is exactly what is wanted here.
    public static func discardLegacyFile() {
        try? FileManager.default.removeItem(atPath: legacyPath)
    }
}
