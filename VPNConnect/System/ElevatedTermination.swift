import Foundation

// MARK: - The signal

/// Which signal to send, spelled the way `kill` spells it.
public enum ElevatedSignal: String, Equatable, Sendable, CaseIterable {
    /// The graceful one: `openconnect` and vpn-slice restore routes, DNS and
    /// `/etc/hosts` on the way out.
    case terminate = "-TERM"
    /// For a process that ignored `SIGTERM`.
    case kill = "-KILL"
}

/// One `sudo` invocation that sends one signal and does nothing else.
///
/// The plan is a value rather than a closure so the two properties that make it
/// safe are assertable without spawning anything: the administrator password
/// travels on standard input and **never in `argv`** (arguments are readable by
/// every process on the machine), and `-S` appears only for the machine whose
/// `sudo` cannot answer with a dialog the pipe would not be read for.
public struct ElevatedKillPlan: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    /// What to write to `sudo`'s standard input. `nil` means `sudo` gets no
    /// input at all: it either authenticates through the system's own prompt
    /// (`pam_tid` shows its dialog from inside the PAM stack, with no terminal)
    /// or it fails fast.
    public let stdin: String?

    public init(executable: URL, arguments: [String], stdin: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
    }

    /// True when this plan hands the stored password to `sudo`. Exactly one
    /// strategy is allowed to do that, and this is how a test says so.
    public var pipesTheStoredPassword: Bool { stdin != nil }
}

// MARK: - The decision

/// Ending a tunnel this app started with `sudo`.
///
/// The connect path elevates: `sudo` runs `openconnect` as root, so the process
/// that owns the tunnel belongs to root, and every signal this user sends is
/// refused with `EPERM` — for `SIGTERM` and for `SIGKILL` alike. For a long time
/// "Disconnect" tried once as the user, failed, and then reported the tunnel as
/// disconnected anyway: the process stayed up, the tunnel stayed up, and the
/// window said otherwise. The only thing that can end a root-owned tunnel is the
/// same elevation that started it.
///
/// Nothing here decides *whether* to ask: that is `strategy` (what the connect
/// learned about this Mac's `sudo`) and `mayPrompt` (whether the caller is even
/// allowed to put a dialog in front of somebody). The quit path is not.
public enum ElevatedTermination {
    /// Both by absolute path: `PATH` is not trusted for a command that runs as
    /// root, and `sudo`'s own resolution rules are not either.
    public static let sudo = URL(fileURLWithPath: "/usr/bin/sudo")
    public static let kill = URL(fileURLWithPath: "/bin/kill")

    /// The bound on one elevated signal. `kill` itself answers immediately; the
    /// time is there for the wait for `sudo`'s authentication, which can be a
    /// dialog a person has to notice and answer.
    public static let timeout: TimeInterval = 20

    /// The plan for one signal, or `nil` when this app must not build one.
    ///
    /// - Parameters:
    ///   - pid: the target: a process id, or a process group id.
    ///   - isProcessGroup: true to signal `pid`'s whole group (`kill -TERM
    ///     -<pgid>`), which is what ends a launch: the wrapper shell, the
    ///     `sudo`, and `openconnect` are one group.
    ///   - strategy: what the connect resolved for this Mac.
    ///   - adminPassword: the stored administrator password, if any.
    ///   - ownProcessGroup: this app's group, so a bogus record can never make
    ///     the app signal itself as root.
    public static func plan(
        pid: Int32,
        isProcessGroup: Bool,
        signal: ElevatedSignal,
        strategy: ElevationStrategy,
        adminPassword: String?,
        ownProcessGroup: Int32
    ) -> ElevatedKillPlan? {
        guard pid > 1 else { return nil }
        if isProcessGroup, pid == ownProcessGroup { return nil }
        let target = isProcessGroup ? "-\(pid)" : "\(pid)"
        let password = adminPassword ?? ""

        switch strategy {
        case .neverPrompt:
            // Nothing is asked: never prompting is the whole point of this
            // strategy, and `-n` fails in milliseconds when the timestamp has
            // gone cold. The caller adds a prompting attempt after it.
            return ElevatedKillPlan(
                executable: sudo,
                arguments: ["-n", kill.path, signal.rawValue, target]
            )

        case .storedPassword where !password.isEmpty:
            // The unattended route, safe only where `pam_tid` is absent — which
            // is exactly what this strategy means. The password goes down the
            // pipe, never into `argv`.
            return ElevatedKillPlan(
                executable: sudo,
                arguments: ["-S", kill.path, signal.rawValue, target],
                stdin: password + "\n"
            )

        case .storedPassword, .systemPrompt:
            // No stored password, or a Mac whose `sudo` authenticates through
            // `pam_tid`: this is the form that asks. Whether asking is allowed
            // is the caller's decision — at quit it is not, because a dialog
            // nothing answers would hold the quit open and leave a blocked
            // `sudo` behind, which is the failure this app was built to avoid.
            return ElevatedKillPlan(
                executable: sudo,
                arguments: [kill.path, signal.rawValue, target]
            )
        }
    }
}

// MARK: - Who owns the process

/// Whether a pid belongs to somebody else, and so cannot be signalled from here.
///
/// Checked *before* signalling rather than inferred from a failed `kill`: a
/// `SIGTERM` and a `SIGKILL` that were never going to land cost three seconds of
/// the user's time and end in a report that was never in doubt.
public enum ProcessOwner {
    public static let ps = URL(fileURLWithPath: "/bin/ps")
    /// Bounded, because this runs on the disconnect path.
    public static let timeout: TimeInterval = 3

    /// The owning user's *name*, from `ps -o user=`.
    ///
    /// The name, not the uid: "root" in a log line is checkable by the person
    /// reading it, and user names are not localised. `nil` means the answer
    /// could not be read, which is not the same as "somebody else".
    public static func name(
        of pid: Int32,
        using runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) -> String? {
        guard pid > 1 else { return nil }
        guard let result = try? runner.run(
            executable: ps,
            arguments: ["-o", "user=", "-p", "\(pid)"],
            timeout: timeout
        ), !result.timedOut else { return nil }

        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// True only when the answer is positive. A pid whose owner cannot be read
    /// is not assumed to be root — the caller's own signal is tried instead.
    public static func belongsToAnotherUser(
        _ pid: Int32,
        ownUserName: String = NSUserName(),
        using runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) -> Bool {
        guard let name = name(of: pid, using: runner) else { return false }
        return name != ownUserName
    }
}

// MARK: - Running the elevated command

/// Runs one `ElevatedKillPlan`, bounded.
public protocol ElevatedCommandRunning: Sendable {
    func run(_ plan: ElevatedKillPlan, timeout: TimeInterval) throws -> BoundedProcessResult
}

/// The real one. Bounded exactly like `SystemBoundedProcessRunner`, plus the
/// standard-input pipe that `sudo -S` needs.
public struct SystemElevatedCommandRunner: ElevatedCommandRunning {
    /// How long a killed child is given to be reaped before `SIGKILL`.
    public static let reapGrace: TimeInterval = 2

    public init() {}

    public func run(_ plan: ElevatedKillPlan, timeout: TimeInterval) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let input = Pipe()
        // A plan with no password gets no input at all: nothing can be typed
        // into a pipe this app does not own, and `sudo` must not wait on one.
        process.standardInput = plan.stdin == nil ? FileHandle.nullDevice : input

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed(error.localizedDescription)
        }

        // The child holds its own descriptors; closing ours is what lets the
        // reads below see EOF rather than block on a pipe we still hold.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        if let stdin = plan.stdin {
            try? input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8))
        }
        try? input.fileHandleForWriting.close()

        var timedOut = false
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + Self.reapGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + Self.reapGrace)
            }
        }

        return BoundedProcessResult(
            terminationStatus: process.terminationStatus,
            timedOut: timedOut,
            stdout: String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}

// MARK: - The terminator

/// Sends the signal, and then *looks* rather than trusting `kill`.
///
/// Everything it touches is injected, so the safety property — nothing is
/// signalled as root until the target is verified to still be this app's launch
/// — is testable without going anywhere near the user's VPN or their password.
public struct ElevatedTerminator: Sendable {
    /// What to signal.
    public enum Target: Equatable, Sendable {
        /// The process group the connect recorded: the wrapper shell, the
        /// `sudo`, and `openconnect`.
        case group(Int32)
        /// The `openconnect` itself, for a tunnel whose group record is gone.
        case pid(Int32)

        public var number: Int32 {
            switch self {
            case .group(let value), .pid(let value): return value
            }
        }

        public var isProcessGroup: Bool {
            if case .group = self { return true }
            return false
        }
    }

    public enum Outcome: Equatable, Sendable {
        /// The openconnect is gone.
        case ended
        /// A signal was sent — or could not be — and the process is still there,
        /// with the detail.
        case stillRunning(String)
        /// Nothing was sent, deliberately, with the reason.
        case refused(String)
    }

    /// How long `openconnect` gets after each elevated signal. Long enough for
    /// the graceful path (routes, DNS, `/etc/hosts`) to run.
    public static let settleSeconds: TimeInterval = 3
    public static let pollSeconds: TimeInterval = 0.1

    private let runner: any ElevatedCommandRunning
    private let isRunning: @Sendable (Int32) -> Bool
    private let isOpenConnect: @Sendable (Int32) -> Bool
    private let groupPids: @Sendable (Int32) -> [Int32]
    private let ownProcessGroup: Int32
    private let sleep: @Sendable (TimeInterval) -> Void

    public init(
        runner: any ElevatedCommandRunning = SystemElevatedCommandRunner(),
        isRunning: @escaping @Sendable (Int32) -> Bool = { OpenConnectProcess.isRunning(pid: $0) },
        isOpenConnect: @escaping @Sendable (Int32) -> Bool = { OpenConnectProcess.isOpenConnect(pid: $0) },
        groupPids: @escaping @Sendable (Int32) -> [Int32] = ElevatedTerminator.processGroupPids,
        ownProcessGroup: Int32 = getpgrp(),
        sleep: @escaping @Sendable (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) }
    ) {
        self.runner = runner
        self.isRunning = isRunning
        self.isOpenConnect = isOpenConnect
        self.groupPids = groupPids
        self.ownProcessGroup = ownProcessGroup
        self.sleep = sleep
    }

    /// The pids in a process group, from a bounded `ps`.
    public static func processGroupPids(_ pgid: Int32) -> [Int32] {
        guard pgid > 1, let result = try? SystemBoundedProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-o", "pid=", "-g", "\(pgid)"],
            timeout: 3
        ), !result.timedOut else { return [] }

        return result.stdout
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Ends the tunnel, or says why it did not.
    ///
    /// - Parameters:
    ///   - target: the group to signal, or the pid when there is no record.
    ///   - openConnectPid: the pid that must be verified and must be gone at the
    ///     end. Never inferred from `target` — a group kill is judged by whether
    ///     the tunnel died, not by whether the signal was accepted.
    ///   - strategy: what the connect resolved for this Mac.
    ///   - adminPassword: the stored administrator password, if any.
    ///   - mayPrompt: false on the quit path, where a dialog would hold the quit
    ///     open. Such a caller may only use `sudo -n` or a piped password.
    public func end(
        _ target: Target,
        openConnectPid: Int32,
        strategy: ElevationStrategy,
        adminPassword: String?,
        mayPrompt: Bool
    ) -> Outcome {
        guard openConnectPid > 1 else {
            return .refused("the recorded pid (\(openConnectPid)) is not a process")
        }
        // Already gone: whatever was recorded, the tunnel is not up and there is
        // nothing here worth a root privilege.
        guard isRunning(openConnectPid) else { return .ended }
        guard isOpenConnect(openConnectPid) else {
            return .refused("pid \(openConnectPid) is not an \(OpenConnectProcess.name), so nothing was signalled")
        }

        switch target {
        case .group(let pgid):
            guard pgid > 1 else {
                return .refused("the recorded process group (\(pgid)) is not a group")
            }
            guard pgid != ownProcessGroup else {
                return .refused("the recorded process group is this app's own")
            }
            let members = groupPids(pgid)
            guard members.contains(openConnectPid) else {
                return .refused(
                    "process group \(pgid) no longer holds pid \(openConnectPid) (members: "
                        + members.map(String.init).joined(separator: ", ") + ")"
                )
            }
        case .pid(let pid):
            guard pid > 1 else {
                return .refused("pid \(pid) is not a process")
            }
        }

        var sent = 0
        var failures: [String] = []

        let terminate = send(attempts(
            for: .terminate,
            target: target,
            strategy: strategy,
            adminPassword: adminPassword,
            mayPrompt: mayPrompt
        ), pid: openConnectPid)
        sent += terminate.sent
        failures += terminate.failures
        if waitForExit(openConnectPid) { return .ended }

        // Escalation, not a retry: a `-TERM` to a root `sudo` wrapper can be
        // consumed while `openconnect` keeps the tunnel up.
        let escalated = send(attempts(
            for: .kill,
            target: target,
            strategy: strategy,
            adminPassword: adminPassword,
            mayPrompt: mayPrompt
        ), pid: openConnectPid)
        sent += escalated.sent
        failures += escalated.failures
        if waitForExit(openConnectPid) { return .ended }

        var detail: String
        if !failures.isEmpty {
            detail = failures.joined(separator: "; ")
        } else if sent > 0 {
            detail = "the elevated signal was accepted and ignored"
        } else {
            detail = "no elevated signal was available to try"
        }
        if !mayPrompt, strategy.waitsForTheSystem {
            // Say which door was left shut, so the log does not read as an
            // unexplained failure: this caller could not raise the dialog.
            detail += " — this path may not ask for administrator approval"
        }
        return .stillRunning("\(OpenConnectProcess.name) \(openConnectPid) survived an elevated SIGTERM and SIGKILL — \(detail)")
    }

    // MARK: Internals

    /// The plans to try, in order, for one signal.
    ///
    /// `sudo -n` is always first: it never prompts, it fails in milliseconds
    /// when the timestamp is cold, and a tunnel that was just connected has a
    /// warm one. Only then does the strategy's own form get a turn, so a
    /// password is not fed to `sudo` when nothing needed it.
    private func attempts(
        for signal: ElevatedSignal,
        target: Target,
        strategy: ElevationStrategy,
        adminPassword: String?,
        mayPrompt: Bool
    ) -> [ElevatedKillPlan] {
        var plans: [ElevatedKillPlan] = []
        if let silent = ElevatedTermination.plan(
            pid: target.number,
            isProcessGroup: target.isProcessGroup,
            signal: signal,
            strategy: .neverPrompt,
            adminPassword: nil,
            ownProcessGroup: ownProcessGroup
        ) {
            plans.append(silent)
        }
        if mayPrompt, let asking = ElevatedTermination.plan(
            pid: target.number,
            isProcessGroup: target.isProcessGroup,
            signal: signal,
            strategy: strategy,
            adminPassword: adminPassword,
            ownProcessGroup: ownProcessGroup
        ), asking != plans.first {
            plans.append(asking)
        }
        return plans
    }

    /// Runs the plans for one signal in order, stopping as soon as the tunnel is
    /// gone. Only the arguments are ever quoted — a plan's standard input is
    /// where a stored password lives and it must not reach a log.
    ///
    /// What comes back is only ever *detail*: the verdict is the liveness check,
    /// never `sudo`'s exit status.
    private func send(_ plans: [ElevatedKillPlan], pid: Int32) -> (sent: Int, failures: [String]) {
        var sent = 0
        var failures: [String] = []
        for plan in plans {
            sent += 1
            do {
                let result = try runner.run(plan, timeout: ElevatedTermination.timeout)
                if result.timedOut {
                    failures.append("\(plan.arguments.joined(separator: " ")) timed out")
                } else if result.terminationStatus != 0 {
                    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    failures.append(
                        "\(plan.arguments.joined(separator: " ")) exited \(result.terminationStatus)"
                            + (stderr.isEmpty ? "" : ": \(stderr)")
                    )
                }
            } catch {
                failures.append(error.localizedDescription)
            }
            // Stop at the first form that worked — the next plan is a stronger
            // privilege (a password, or a dialog), and it is only worth spending
            // while there is still something to kill.
            if !isRunning(pid) { break }
        }
        return (sent, failures)
    }

    private func waitForExit(_ pid: Int32) -> Bool {
        let steps = max(1, Int((Self.settleSeconds / Self.pollSeconds).rounded()))
        for _ in 0 ..< steps {
            if !isRunning(pid) { return true }
            sleep(Self.pollSeconds)
        }
        return !isRunning(pid)
    }
}
