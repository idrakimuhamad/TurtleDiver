import Foundation

// MARK: - Identifying an openconnect by name

/// Tells an `openconnect` apart from any other process.
///
/// The app used to identify a running tunnel by matching **command lines**
/// (`pgrep -f openconnect`). That matches every process that merely *mentions*
/// the word: a terminal running `grep openconnect`, an editor with the file
/// open, the shell that launched the app, a `pgrep -f openconnect` in flight.
/// One of those was adopted as the connection — its pid written to
/// `openconnect.pid`, the status flipped to "Connected", an entry added to the
/// history — with no tunnel running at all. The same argv match decided which
/// pids a cleanup path would signal.
///
/// Everything here therefore asks the kernel instead of the command line:
/// `pgrep -x` (an exact *name* match, never `-f`) to find candidates and
/// `ps -o comm=` to verify each one before it is adopted or signalled. A pid
/// that fails the check is reported, never touched, never recorded as a
/// connection.
public enum OpenConnectProcess {
    /// The name `pgrep -x` and `namesOpenConnect` both compare against.
    public static let name = "openconnect"

    public static let pgrepExecutable = URL(fileURLWithPath: "/usr/bin/pgrep")
    public static let psExecutable = URL(fileURLWithPath: "/bin/ps")

    /// `pgrep` and `ps` answer in milliseconds. The bound exists so that a
    /// wedged one cannot hold up a launch, a quit, or a connect.
    public static let timeout: TimeInterval = 3

    /// Pure: does this `comm` string name an `openconnect`?
    ///
    /// `ps -o comm=` reports an absolute path when the binary was started with
    /// one (`/opt/homebrew/bin/openconnect`) and a bare name otherwise, so both
    /// are accepted — but only the last path component is compared, so
    /// `/tmp/not-openconnect-at-all` does not pass. Nothing here looks at
    /// arguments, which is the whole point.
    public static func namesOpenConnect(_ comm: String) -> Bool {
        let trimmed = comm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (trimmed as NSString).lastPathComponent == name
    }

    /// Pure: is this pid alive?
    ///
    /// `kill(pid, 0)` answers `EPERM` — not 0 — for a process this user may not
    /// signal. An openconnect started through `sudo` is owned by root, so the
    /// naive `kill(pid, 0) == 0` test reports the app's *own* tunnel as dead.
    /// `EPERM` means "alive, not yours": count it as running.
    public static func isRunning(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The kernel's command name for `pid`, or nil when it is gone.
    public static func commandName(
        pid: Int32,
        using runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) -> String? {
        guard let result = try? runner.run(
            executable: psExecutable,
            arguments: ["-o", "comm=", "-p", "\(pid)"],
            timeout: timeout
        ), !result.timedOut, result.terminationStatus == 0 else { return nil }
        let comm = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return comm.isEmpty ? nil : comm
    }

    /// True only when `ps` says this pid is an openconnect. The check every
    /// signal and every adoption goes through.
    public static func isOpenConnect(
        pid: Int32,
        using runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) -> Bool {
        guard let comm = commandName(pid: pid, using: runner) else { return false }
        return namesOpenConnect(comm)
    }

    /// PIDs whose *name* is openconnect, in the order `pgrep` reported them.
    ///
    /// Deliberately not `-f`. This finds a root-owned openconnect as readily as
    /// one of ours (a name is not a permission), and it cannot find a process
    /// that merely talks about one.
    public static func pids(
        using runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) -> [Int32] {
        guard let result = try? runner.run(
            executable: pgrepExecutable,
            arguments: ["-x", name],
            timeout: timeout
        ), !result.timedOut, result.terminationStatus == 0 else { return [] }
        return result.stdout
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { Int32($0) }
    }
}

// MARK: - Deciding whether a connection already exists

/// What a scan found, and what it refused.
///
/// `pid` is the only value any caller may act on. `rejections` exists so that a
/// refused candidate is *visible* — a pid file naming something else used to be
/// adopted silently, which is how a false "Connected" reached the UI.
public struct ExistingConnectionDetection: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        /// The pid recorded in `…/run/openconnect.pid`.
        case pidFile
        /// A process whose name is openconnect, found by `pgrep -x`.
        case scanned
    }

    public struct Rejection: Equatable, Sendable {
        public enum Reason: String, Equatable, Sendable {
            case isNotOpenConnect
            case isNotRunning
            case isThisApp
        }

        public let pid: Int32
        public let reason: Reason

        public init(pid: Int32, reason: Reason) {
            self.pid = pid
            self.reason = reason
        }

        /// The sentence the app appends to its debug log. Pure, so it is tested.
        public var explanation: String {
            switch reason {
            case .isNotOpenConnect:
                return "Ignoring PID \(pid): it is not an openconnect (its command name is not \u{201C}\(OpenConnectProcess.name)\u{201D})"
            case .isNotRunning:
                return "Ignoring PID \(pid): it is no longer running"
            case .isThisApp:
                return "Ignoring PID \(pid): it is this app"
            }
        }
    }

    public let pid: Int32?
    public let source: Source?
    public let rejections: [Rejection]

    public init(pid: Int32?, source: Source?, rejections: [Rejection]) {
        self.pid = pid
        self.source = source
        self.rejections = rejections
    }

    public var adopted: Bool { pid != nil }

    public static let none = ExistingConnectionDetection(pid: nil, source: nil, rejections: [])
}

/// The decision table, with everything it touches injected.
public enum ExistingConnectionDetector {
    /// So the decision table below reads plainly.
    private typealias Rejection = ExistingConnectionDetection.Rejection
    /// Pure. Tier 1 is the pid file — how a tunnel this app started is found
    /// again; Tier 2 is a name-exact scan — how a tunnel started by an earlier
    /// build (openconnect only writes `--pid-file` with `--background`, which
    /// the launch plan does not use) or by hand is found.
    ///
    /// A candidate is adopted only when it is alive, is not this app, **and** is
    /// an openconnect. Every refusal of the pid file's pid is reported, because
    /// that file is the one thing on disk claiming a tunnel exists; a refused
    /// scanned pid is reported only when it is alive and simply not an
    /// openconnect (dead ones are ordinary races).
    public static func decide(
        pidFilePid: Int32?,
        scannedPids: [Int32],
        ownPid: Int32,
        isRunning: (Int32) -> Bool,
        isOpenConnect: (Int32) -> Bool
    ) -> ExistingConnectionDetection {
        var rejections: [Rejection] = []

        if let candidate = pidFilePid {
            if candidate == ownPid {
                rejections.append(Rejection(pid: candidate, reason: .isThisApp))
            } else if !isRunning(candidate) {
                rejections.append(Rejection(pid: candidate, reason: .isNotRunning))
            } else if !isOpenConnect(candidate) {
                rejections.append(Rejection(pid: candidate, reason: .isNotOpenConnect))
            } else {
                return ExistingConnectionDetection(pid: candidate, source: .pidFile, rejections: rejections)
            }
        }

        for candidate in scannedPids where candidate != ownPid {
            guard isRunning(candidate) else { continue }
            if isOpenConnect(candidate) {
                return ExistingConnectionDetection(pid: candidate, source: .scanned, rejections: rejections)
            }
            rejections.append(Rejection(pid: candidate, reason: .isNotOpenConnect))
        }

        return ExistingConnectionDetection(pid: nil, source: nil, rejections: rejections)
    }
}

/// The I/O half: runs the scan and hands the result to `ExistingConnectionDetector`.
public enum ExistingConnectionScanner {
    public static func detect(
        pidFilePid: Int32?,
        ownPid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        using runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) -> ExistingConnectionDetection {
        ExistingConnectionDetector.decide(
            pidFilePid: pidFilePid,
            scannedPids: OpenConnectProcess.pids(using: runner),
            ownPid: ownPid,
            isRunning: { OpenConnectProcess.isRunning(pid: $0) },
            isOpenConnect: { OpenConnectProcess.isOpenConnect(pid: $0, using: runner) }
        )
    }
}

// MARK: - Stopping one

/// What happened when the app tried to stop an openconnect.
///
/// The distinction matters because the outcome decides what the app *says*: an
/// openconnect launched through `sudo` is owned by root, and a normal user
/// process cannot signal it at all. Reporting that as "exited cleanly" — which
/// a bare `kill(pid, 0) == 0` liveness check did — is a claim about the network
/// that is not true.
public enum TerminationOutcome: Equatable, Sendable {
    /// Not an openconnect, or already gone. Nothing was signalled.
    case notAnOpenConnect
    case exitedCleanly
    case forceKilled
    /// Ended through the same elevation the launch used. Needed because an
    /// openconnect started through `sudo` is owned by root and no signal this
    /// user sends can reach it — for `SIGTERM` or for `SIGKILL`.
    case endedWithElevation
    /// Still alive after everything this app may do: the signal was refused
    /// (`EPERM` on a root-owned process) and the elevated attempt was not
    /// available or did not take. The process group record is only the handle on
    /// such a tunnel, not the thing that ends it.
    case notPermitted
}
