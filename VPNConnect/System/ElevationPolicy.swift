import Foundation

/// How this Mac answers `sudo`'s authentication.
///
/// The distinction exists because of one failure: `/etc/pam.d/sudo_local` on a
/// Mac with Touch ID for sudo enabled contains `auth sufficient pam_tid.so`, and
/// `pam_tid` raises its own dialog from inside the PAM stack. A process that
/// pipes a password into `sudo -S` therefore feeds a pipe nobody reads: sudo is
/// blocked in the dialog, the connect stalls until its timeout, and the blocked
/// `sudo` survives as a root-owned process the app cannot signal. The app has to
/// know which of the two situations it is in *before* it builds the command.
public enum SudoAuthenticationMode: Equatable, Sendable {
    /// A `pam_tid` `auth` line is present: a cold timestamp is answered by the
    /// system's Touch ID / password dialog, which the app must not try to feed.
    case systemPrompt
    /// No `pam_tid`: `sudo -S` with the stored administrator password is the
    /// only unattended route (stock macOS, and any Mac without Touch ID).
    case storedPassword
}

/// How a supplied administrator password reaches `sudo`.
///
/// A second axis, deliberately separate from `ElevationStrategy`. The strategy
/// says what this Mac *asks for* — a system dialog, or a password nobody can be
/// asked for — and the delivery says which door a password goes through. They
/// were one thing until `sudo -A` was measured: `pam_tid` raises its dialog from
/// inside the PAM stack, which is why a piped password is never read, but its own
/// strings (`askpass-enabled`, `sudo askpass mode, not showing UI`) say it stands
/// that dialog down in askpass mode. So a Mac with Touch ID for `sudo` can take a
/// password after all — down the askpass door, not the pipe — and "the machine
/// prompts" no longer settles how a password can travel, or whether it can.
public enum SudoPasswordDelivery: Equatable, Sendable, CaseIterable {
    /// `sudo -S`: the password is the first line of the child's standard input.
    /// The door for a machine whose PAM stack reads that pipe, and the one the
    /// app has used since the unattended route existed.
    case standardInput
    /// `sudo -A`: `sudo` runs the program named by `SUDO_ASKPASS` and reads the
    /// password from *that program's* standard output. The password therefore
    /// never enters the calling process at all — the helper is a separate
    /// process, started by `sudo` as the invoking user.
    case askpass

    /// True when the password travels inside the child's own standard input.
    ///
    /// The one property the app's credential block depends on: a plan whose
    /// standard input carries the tunnel's credentials may add an administrator
    /// password line only on this route, and on the askpass route the same pipe
    /// is left to the agent's credentials alone.
    public var writesThePasswordToStandardInput: Bool { self == .standardInput }

    /// Which door a password goes through on a machine that behaves as
    /// `strategy` says, or nil when no password can travel at all.
    ///
    /// The decision the app and the tool must make the same way, so it is a
    /// function of the strategy rather than a setting:
    ///
    /// * Where the pipe is read — no module in front of it — `-S` is used. It is
    ///   one process fewer and needs no helper installed, and asking the Keychain
    ///   for a password to hand a program that will not read it would be theatre.
    /// * Where `pam_tid` answers, the pipe is dead, and the helper is the only
    ///   door left: `-A` with the prepared helper's path. Without a helper there is
    ///   no door, and the honest answer is nil — the connect then waits for the
    ///   system dialog, which is what it did before this existed.
    /// * Where nothing is asked at all there is nothing to deliver, so nil.
    ///
    /// A nil here is not a failure. It is the statement "no stored password is
    /// used by this connect", which is the correct state on a Mac whose sudo
    /// stack answers with Touch ID and whose user has not prepared a helper.
    public static func resolve(
        strategy: ElevationStrategy,
        askpassHelper: String? = nil
    ) -> SudoPasswordDelivery? {
        if strategy.pipesTheStoredPassword { return .standardInput }
        guard strategy.waitsForTheSystem else { return nil }
        return askpassHelper == nil ? nil : .askpass
    }
}

/// What the connect path does about elevation, decided before anything runs.
///
/// One strategy per connect, chosen from the machine's state. There is
/// deliberately no automatic fallback *during* a connect: a silent fallback from
/// "the system will ask" to "pipe the stored password" is what re-creates the
/// blocked-dialog hang this type exists to avoid.
public enum ElevationStrategy: Equatable, Sendable, CaseIterable {
    /// `sudo -n` throughout: nothing is asked, and a cold timestamp fails fast
    /// with a marker instead of raising a dialog.
    ///
    /// The name is a statement about the *plan*, not about the machine, which is
    /// why nothing resolves a connect to it. `sudo` keys its timestamp to the
    /// parent process when there is no terminal (`man sudoers`, `timestamp_type`
    /// defaults to `tty`), so a "is it warm?" probe taken by the app says nothing
    /// about a `sudo` that runs under the connect's wrapper shell — the two have
    /// different parents. A connect that trusted the probe died with
    /// `Failed - Elevation Expired` while the timestamp it had measured was
    /// still perfectly warm, in the other process's context. Both strategies a
    /// connect may choose probe warmth *inside* the plan, where it is used.
    case neverPrompt
    /// `pam_tid` is enabled: run `sudo` normally and let the system show its
    /// Touch ID / password dialog if the refresh needs one, bounded by the
    /// connect timeout.
    case systemPrompt
    /// No `pam_tid`: pipe the stored administrator password to `sudo -S`, which
    /// is the only way to elevate with nobody at the keyboard.
    case storedPassword

    /// The decision, as a pure function of what was detected.
    ///
    /// There is deliberately no "and is the timestamp already warm?" input. The
    /// only strategy that would answer yes to it is `.neverPrompt`, and choosing
    /// that for a connect from the app's own probe is the defect described above.
    public static func resolve(mode: SudoAuthenticationMode) -> ElevationStrategy {
        switch mode {
        case .systemPrompt: return .systemPrompt
        case .storedPassword: return .storedPassword
        }
    }

    /// True when the plan may send the administrator password down a pipe.
    /// Only the mode that cannot raise a dialog may do so.
    public var pipesTheStoredPassword: Bool { self == .storedPassword }

    /// True when the connect is expected to wait for a system dialog, which is
    /// the case whose timeout has a cause worth naming.
    public var waitsForTheSystem: Bool { self == .systemPrompt }

    /// How many credential lines the plan's standard input carries: the admin
    /// password is only needed — and only safe — in the `sudo -S` mode.
    public var credentialLineCount: Int {
        switch self {
        case .storedPassword: return OpenConnectCommand.credentialLineCount
        case .neverPrompt, .systemPrompt: return OpenConnectCommand.credentialLineCount - 1
        }
    }

    /// The History status for a connect that timed out under this strategy.
    public var timeoutHistoryStatus: String {
        waitsForTheSystem ? ElevationFailure.touchIDStatus : "Connection timeout"
    }

    /// The message shown for a connect that timed out under this strategy.
    public func timeoutDetail(timeoutSeconds: Int) -> String {
        switch self {
        case .systemPrompt:
            return "macOS asked for Touch ID or your administrator password before openconnect could run,"
                + " and nothing answered within \(timeoutSeconds)s. Connect again with the app in front"
                + " (and the lid open) so the dialog can be answered."
        case .neverPrompt, .storedPassword:
            return "Connection timeout"
        }
    }

    /// Says, before the launch, which way elevation will go. This is the
    /// "diagnose before the wait" half: if the answer is a system dialog, the
    /// user is told to expect one while there is still time to answer it.
    public func debugLines(timeoutSeconds: Int) -> [String] {
        switch self {
        case .neverPrompt:
            return ["Elevation: no dialog will be shown; sudo -n fails fast if the timestamp has gone cold."]
        case .systemPrompt:
            return [
                "Elevation: Touch ID for sudo is enabled (pam_tid).",
                "Elevation: the refresh checks sudo non-interactively first; if that is refused, macOS"
                    + " asks for Touch ID or your administrator password, and the connect waits up to"
                    + " \(timeoutSeconds)s for that dialog.",
            ]
        case .storedPassword:
            return ["Elevation: using the stored administrator password (sudo -S); no system dialog is expected."]
        }
    }
}

/// What was detected about elevation, and the strategy it implies.
public struct ElevationSnapshot: Equatable, Sendable {
    public let mode: SudoAuthenticationMode
    /// The PAM files that were read, in order, for the log.
    public let pamFilesInspected: [String]

    public init(mode: SudoAuthenticationMode, pamFilesInspected: [String] = []) {
        self.mode = mode
        self.pamFilesInspected = pamFilesInspected
    }

    public var strategy: ElevationStrategy {
        ElevationStrategy.resolve(mode: mode)
    }
}

/// Reads the one fact the strategy needs: what the sudo PAM stack does.
public enum ElevationProbe {
    /// `sudo_local` is the file the Touch ID recipe edits; `sudo` itself is
    /// checked too because the older recipe edited it directly, and because a
    /// stock `sudo` merely `@include`s the local file (which the parser ignores).
    ///
    /// Both are world-readable, which is what makes detection possible without
    /// elevation. The app only ever reads them — see `docs/ELEVATION.md`.
    public static let pamFilePaths = ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"]

    /// Substring that identifies the module (`pam_tid.so`, or a full path such
    /// as `/usr/lib/pam/pam_tid.so.2`).
    public static let touchIDModuleName = "pam_tid"

    /// The snapshot, with the read injected so the decision is testable without
    /// reading `/etc`.
    ///
    /// Nothing here asks `sudo` anything: whether its timestamp is warm is a
    /// question only the plan's own process can answer for itself.
    public static func live(readFile: (String) -> String?) -> ElevationSnapshot {
        let contents = pamFilePaths.map(readFile)
        return ElevationSnapshot(
            mode: mode(pamFileContents: contents),
            pamFilesInspected: pamFilePaths
        )
    }

    /// `.systemPrompt` if any inspected file enables `pam_tid` for `auth`.
    public static func mode(pamFileContents: [String?]) -> SudoAuthenticationMode {
        pamFileContents.contains(where: fileEnablesTouchID) ? .systemPrompt : .storedPassword
    }

    /// True if this file has an `auth` line that consults `pam_tid`.
    ///
    /// The control flag is deliberately not required to be `sufficient`: with
    /// `required` the dialog is still raised (and the whole authentication then
    /// fails if it is not answered), so the "do not pipe a password" conclusion
    /// is the same. Commented-out lines and `@include`/`include` directives are
    /// not evidence of anything.
    public static func fileEnablesTouchID(_ contents: String?) -> Bool {
        guard let contents else { return false }
        for rawLine in contents.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            // `type control module [args]`; `@include sudo_local` has only two.
            guard fields.count >= 3 else { continue }
            guard fields[0] == "auth" else { continue }
            guard !fields[1].hasPrefix("@"), fields[1] != "include" else { continue }
            guard fields[2].contains(touchIDModuleName) else { continue }
            return true
        }
        return false
    }
}

/// The classified reasons an elevation can fail, and the one-line markers the
/// launch script writes to stderr so the app can name the cause instead of
/// reporting a bare exit status.
///
/// The marker travels through the log the same way openconnect's output does.
/// It contains no credential material — only which branch failed.
public enum ElevationBlockReason: String, CaseIterable, Sendable {
    case timestampExpired = "sudo timestamp expired before openconnect could use it"
    case systemPromptUnanswered = "the system Touch ID or password dialog was not answered"
    case storedPasswordRejected = "sudo could not authenticate with the stored administrator password"
    case askpassRefused = "the askpass helper did not supply an administrator password"

    /// Prefix that makes a marker line recognisable (and un-ignorable) in the log.
    public static let markerPrefix = "turtlediver: elevation "

    /// The exact line the script writes. Single-quoted by the builder.
    public var markerLine: String { Self.markerPrefix + rawValue }

    /// The History status this cause deserves.
    public var historyStatus: String {
        switch self {
        case .timestampExpired: return "Failed - Elevation Expired"
        case .systemPromptUnanswered: return ElevationFailure.touchIDStatus
        case .storedPasswordRejected, .askpassRefused: return "Failed - Admin Password"
        }
    }

    /// What to tell the user, in the second person and with the remedy.
    public var detail: String {
        switch self {
        case .timestampExpired:
            return "Elevation was lost between starting the connect and using it. Connect again."
        case .systemPromptUnanswered:
            return "macOS asked for Touch ID or your administrator password and the request went unanswered."
                + " Connect again with the app in front so the dialog can be answered."
        case .storedPasswordRejected:
            return "The stored administrator password was not accepted. Update it in Settings ▸ VPN."
        case .askpassRefused:
            return "sudo asked the helper for the stored administrator password and got nothing back."
                + " Check the password in Settings ▸ VPN, and allow the helper to read it when macOS asks."
        }
    }

    /// Exact-match lookup for a line of the connection log. Deliberately not a
    /// substring search: a fuzzy match would classify openconnect's own output.
    public static func match(markerLine line: String) -> ElevationBlockReason? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(markerPrefix) else { return nil }
        return allCases.first { trimmed == $0.markerLine }
    }
}

/// Names shared by the elevation failure paths.
public enum ElevationFailure {
    /// A distinct History status, in the same spirit as `Failed - Missing Tool`.
    public static let touchIDStatus = "Failed - Elevation Blocked (Touch ID)"
}

/// Where the running connect records the process group of its elevation
/// wrapper, so a wrapper that outlives the app can be found and signalled.
///
/// The recorded value is a *process group* rather than a pid because that is
/// the only handle that survives the wrapper being reparented to `launchd` when
/// its parent dies — which is exactly what happened to the orphaned `sudo` this
/// mechanism is meant to prevent creating.
public enum ElevationRecord {
    public static let fileName = "elevation.pgid"

    /// `…/TurtleDiver/run/elevation.pgid` — the same owner-only directory as
    /// the PID file, so it cannot be squatted either.
    public static func path(inApplicationSupport directory: URL) -> URL {
        directory
            .appendingPathComponent(OpenConnectPidFile.directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static var path: URL {
        path(inApplicationSupport: OpenConnectPidFile.applicationSupportDirectory)
    }

    /// Accepts the `ps -o pgid=` output, rejects anything that is not a usable
    /// group: pgid 0 and 1 are the kernel and `launchd`, and killing either is
    /// never what anybody meant.
    public static func parse(_ contents: String?) -> Int32? {
        guard let trimmed = contents?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.allSatisfy(\.isNumber),
              let value = Int32(trimmed),
              value > 1
        else { return nil }
        return value
    }

    public static func read(from url: URL = ElevationRecord.path) -> Int32? {
        parse(try? String(contentsOf: url, encoding: .utf8))
    }

    @discardableResult
    public static func write(_ pgid: Int32, to url: URL = ElevationRecord.path) -> Bool {
        guard pgid > 1 else { return false }
        do {
            try "\(pgid)\n".write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    public static func remove(at url: URL = ElevationRecord.path) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Decides what to do about a recorded process group left behind by an earlier
/// run. Pure, so the dangerous cases can be pinned by tests: the point is that
/// it must *never* be worth killing a group that might still be tunneling.
///
/// A group that is left alive keeps its record: it is the only handle on a
/// wrapper whose `Process` the app no longer has.
public enum ElevationSweep {
    public enum Decision: Equatable, Sendable {
        case nothingToDo
        /// Safe to signal: no connection is attached to this group.
        case reap(Int32)
        /// Left alone, with the reason, which is logged.
        case leaveAlive(Int32, reason: String)
    }

    /// The process name that makes a group untouchable.
    public static let connectionProcessName = "openconnect"

    /// - Parameters:
    ///   - recordedPgid: the group recorded by a previous run, if any.
    ///   - liveConnectionPid: a pid from the PID file that is *still running*,
    ///     or nil. The caller resolves liveness; a pid that is gone must be
    ///     passed as nil.
    ///   - ownProcessGroup: this app's own group, so a bogus record can never
    ///     make the app signal itself.
    ///   - groupMembers: `comm` names of the group's current members.
    public static func decide(
        recordedPgid: Int32?,
        liveConnectionPid: Int32?,
        ownProcessGroup: Int32,
        groupMembers: [String]
    ) -> Decision {
        guard let pgid = recordedPgid, pgid > 1 else { return .nothingToDo }
        if pgid == ownProcessGroup {
            return .leaveAlive(pgid, reason: "it is this app's own process group")
        }
        if let pid = liveConnectionPid {
            return .leaveAlive(pgid, reason: "the connection recorded in the PID file (\(pid)) is still running")
        }
        if groupMembers.contains(where: { $0.lowercased().contains(connectionProcessName) }) {
            return .leaveAlive(pgid, reason: "the group still contains an \(connectionProcessName) process")
        }
        return .reap(pgid)
    }
}

/// The I/O half of the sweep: reads the record, asks whether a connection is
/// attached, and signals the group only when `ElevationSweep` says it is safe.
///
/// Everything it touches is injected, so the safety property can be tested
/// against real processes without going anywhere near the user's VPN.
public enum ElevationReaper {
    /// How long a reaped group gets to exit on `SIGTERM` before `SIGKILL`.
    public static let reapGraceSeconds: TimeInterval = 0.5

    /// Reaps a group left behind by a **previous** run.
    ///
    /// It is called at launch, before any connect, so anything in the record is
    /// by definition a leftover. A group that still has a connection attached —
    /// a live PID file, or an `openconnect` member — is reported and left alone.
    @discardableResult
    public static func reapStaleGroup(
        recordURL: URL = ElevationRecord.path,
        pidFileURL: URL = OpenConnectPidFile.path,
        ownProcessGroup: Int32 = getpgrp(),
        isRunning: (Int32) -> Bool = { kill($0, 0) == 0 },
        groupMembers: (Int32) -> [String] = defaultGroupMembers,
        signalGroup: (Int32, Int32) -> Void = { killpg($0, $1) },
        log: (String) -> Void = { _ in }
    ) -> ElevationSweep.Decision {
        let recorded = ElevationRecord.read(from: recordURL)
        let liveConnectionPid = readLivePid(pidFileURL, isRunning: isRunning)
        let members = recorded.map(groupMembers) ?? []

        let decision = ElevationSweep.decide(
            recordedPgid: recorded,
            liveConnectionPid: liveConnectionPid,
            ownProcessGroup: ownProcessGroup,
            groupMembers: members
        )

        switch decision {
        case .nothingToDo:
            discardStalePidFile(pidFileURL, liveConnectionPid: liveConnectionPid, isRunning: isRunning, log: log)
            ElevationRecord.remove(at: recordURL)

        case .leaveAlive(let pgid, let reason):
            log("Elevation: leaving process group \(pgid) alone — \(reason)")
            // The record stays: it is how a later teardown can still reach the wrapper.

        case .reap(let pgid):
            log("Elevation: reaping stale process group \(pgid) from a previous run")
            signalGroup(pgid, SIGTERM)
            usleep(useconds_t(reapGraceSeconds * 1_000_000))
            // Escalating only reaches members this user may signal; a root-owned
            // descendant ignores us either way, which is why the record is not
            // treated as proof that the group died.
            if killpg(pgid, 0) == 0 {
                signalGroup(pgid, SIGKILL)
                log("Elevation: process group \(pgid) did not exit on SIGTERM; sent SIGKILL")
            }
            discardStalePidFile(pidFileURL, liveConnectionPid: liveConnectionPid, isRunning: isRunning, log: log)
            ElevationRecord.remove(at: recordURL)
        }

        return decision
    }

    /// The pid in the PID file, but only while it is still running.
    public static func readLivePid(_ url: URL, isRunning: (Int32) -> Bool) -> Int32? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1,
              isRunning(pid)
        else { return nil }
        return pid
    }

    /// `comm` names of a process group's members, from a bounded `ps`.
    public static func defaultGroupMembers(_ pgid: Int32) -> [String] {
        guard let result = try? SystemBoundedProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-o", "comm=", "-g", "\(pgid)"],
            timeout: 3
        ), !result.timedOut else { return [] }

        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func discardStalePidFile(
        _ url: URL,
        liveConnectionPid: Int32?,
        isRunning: (Int32) -> Bool,
        log: (String) -> Void
    ) {
        guard liveConnectionPid == nil, FileManager.default.fileExists(atPath: url.path) else { return }
        guard readRawPid(url).map(isRunning) != true else { return }
        log("Elevation: removed the stale PID file at \(url.path)")
        try? FileManager.default.removeItem(at: url)
    }

    private static func readRawPid(_ url: URL) -> Int32? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
