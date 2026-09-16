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
    public static func launchPlan(
        openconnectPath: String,
        arguments: [String],
        adminPassword: String,
        pin: String,
        vpnPassword: String,
        searchPath: String = defaultSearchPath
    ) -> OpenConnectLaunchPlan {
        let escapedArguments = arguments.map(shellEscape).joined(separator: " ")
        let body = [
            timestampRefreshStep,
            // `2>/dev/null` is kept from the old pipeline on purpose: a stale
            // entry that cannot be cleaned is not a connection failure, and its
            // stderr would otherwise be parsed as an error burst.
            hostsCleanupStep + " 2>/dev/null",
            "printf '%s\\n%s\\n' \"$\(pinVariable)\" \"$\(passwordVariable)\""
                + " | sudo \(shellEscape(openconnectPath)) \(escapedArguments)"
        ].joined(separator: "; ")

        return OpenConnectLaunchPlan(
            script: script(searchPath: searchPath, reading: 3, body: body),
            standardInput: credentialLines([adminPassword, pin, vpnPassword])
        )
    }

    /// The stale-`/etc/hosts` cleanup on its own — run on quit, when
    /// openconnect is already gone. Needs no openconnect stdin, so the plan
    /// reads one credential. Stderr is left connected on purpose: the caller
    /// reports it.
    public static func hostsCleanupPlan(
        adminPassword: String,
        searchPath: String = defaultSearchPath
    ) -> OpenConnectLaunchPlan {
        OpenConnectLaunchPlan(
            script: script(searchPath: searchPath, reading: 1, body: hostsCleanupStep),
            standardInput: credentialLines([adminPassword])
        )
    }

    /// Refreshes sudo's timestamp without a dialog whenever the timestamp is
    /// already valid, and only then falls back to an authenticated refresh.
    ///
    /// `sudo -v` on its own authenticates unconditionally, which raised a Touch
    /// ID (or password) dialog for the refresh itself even when the cleanup
    /// below had just authenticated — a prompt that proved nothing. `-n` never
    /// prompts, so it succeeds exactly when the timestamp is warm.
    ///
    /// The fallback keeps `sudo -S` and the stored admin password: `sudo_local`
    /// has pam_tid as `sufficient`, not `required`, so a cold timestamp uses
    /// Touch ID when it can and this password when it cannot — the clamshell or
    /// headless case, where nothing else can answer the prompt. The password is
    /// never in the script, only on stdin.
    private static let timestampRefreshStep =
        "if ! sudo -n -v >/dev/null 2>&1; then"
        + " printf '%s\\n' \"$\(adminVariable)\" | sudo -S -v || exit 1; fi"

    /// `sed -i` through sudo, fed by `printf` rather than `echo` so a password
    /// containing a backslash or a leading `-n` is not mangled.
    private static let hostsCleanupStep =
        "printf '%s\\n' \"$\(adminVariable)\""
        + " | sudo -S sed -i '' '/# vpn-slice-/d' /etc/hosts"

    /// `export PATH=…; read …; body; unset …`
    ///
    /// A failed `read` exits instead of continuing: an empty credential sent to
    /// `sudo -S` would fail anyway, and this way the failure is one line in the
    /// log rather than a confusing sudo prompt.
    private static func script(searchPath: String, reading count: Int, body: String) -> String {
        let variables = [adminVariable, pinVariable, passwordVariable].prefix(count)
        let reads = variables.map { "IFS= read -r \($0) || exit 1" }.joined(separator: "; ")
        let unset = "unset \(variables.joined(separator: " "))"
        return "export PATH=\(shellEscape(searchPath)):$PATH; \(reads); \(body); \(unset)"
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
