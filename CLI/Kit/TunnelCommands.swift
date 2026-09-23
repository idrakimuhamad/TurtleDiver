import Foundation
import TurtleDiverCore
import TurtleDiverSystem

#if canImport(Darwin)
import Darwin
#endif

/// What this machine does when `sudo` needs to authenticate.
///
/// The one fact that decides whether `--sudo-password` can work at all, read
/// from the machine rather than assumed. `ElevationProbe` is the app's own
/// detector — two world-readable PAM files, and no question asked of `sudo` —
/// and the CLI asks it for the reason it exists: `pam_tid` sits *ahead* of the
/// module that reads a piped password, so a connect that pipes one into such a
/// stack feeds a pipe nobody reads, waits on a dialog, and then blames the
/// password for the timeout. `docs/CLI.md` records that failure.
public enum ElevationRoute {

    /// This machine's strategy. Both files the probe reads are world-readable,
    /// so this needs no privilege and asks nobody anything.
    public static func strategy(
        readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
    ) -> ElevationStrategy {
        ElevationProbe.live(readFile: readFile).strategy
    }

    /// Which door a supplied password goes through on this machine, or nil when
    /// the caller supplied none.
    ///
    /// Two doors, and the machine picks between them. Where nothing precedes the
    /// module that reads a pipe, `sudo -S` is used: it is one process fewer and
    /// no helper has to be installed. Where `pam_tid` answers, the pipe is dead —
    /// the module raises its own dialog ahead of the reader — and `sudo -A` is
    /// the door that works, because `pam_tid` stands that dialog down in askpass
    /// mode. `--sudo-password` therefore goes on working on a Mac with Touch ID
    /// for `sudo`; it just travels a different way.
    ///
    /// `.neverPrompt` is not a machine this can be called on — `strategy()`
    /// never returns it — and `refusal` rejects it before this is consulted.
    public static func delivery(
        for source: SudoPasswordSource?,
        on strategy: ElevationStrategy
    ) -> SudoPasswordDelivery? {
        guard source != nil else { return nil }
        return strategy.pipesTheStoredPassword ? .standardInput : .askpass
    }

    /// Refuses a source this machine cannot deliver, naming the door that can.
    ///
    /// Refusing is the only honest answer available for a combination that
    /// cannot work. Continuing would raise the very dialog the caller asked to
    /// avoid and then blame the password for the timeout; taking the password and
    /// quietly running the no-password route would ignore what the caller said.
    /// Both are worse than naming what this machine does and what to do about it
    /// — and the second is worse than the first, because a caller that believes
    /// its password was used has no reason to look again.
    ///
    /// The two refusals are the two ways a named source can miss: `stdin` on a
    /// Mac where a pipe is never read, and `keychain` on one where the helper
    /// that could carry it is not installed. Neither falls back to the other.
    public static func refusal(
        for source: SudoPasswordSource?,
        on strategy: ElevationStrategy,
        askpassHelper: String?,
        expectedHelperPath: String = AskpassHelper.expectedPath()
    ) -> CLIFailure? {
        guard let source else { return nil }
        // The pipe is read here: the source works as offered.
        if strategy.pipesTheStoredPassword { return nil }

        guard strategy.waitsForTheSystem else {
            // Nothing is ever asked on this machine, so there is nothing for a
            // password to answer.
            return CLIFailure(
                .needsApproval,
                "this machine runs sudo without prompting, so there is nothing for a password to"
                    + " answer; nothing was started. Run the same command without the option."
            )
        }

        switch (source, askpassHelper) {
        case (.keychain, .some):
            // The one combination that works here, and the reason the old
            // refusal is gone: --sudo-password keychain is deliverable on a Mac
            // with Touch ID for sudo, through sudo's askpass helper.
            return nil

        case (.keychain, .none):
            return CLIFailure(
                .missingTool,
                "\(ElevationProbe.touchIDModuleName) answers sudo on this Mac, so a password can only"
                    + " arrive through sudo's askpass helper, which is not installed at"
                    + " \(expectedHelperPath); nothing was started. Install the command line tool that"
                    + " carries it (the .pkg installs both), or run the same command without the option"
                    + " and answer the prompt.",
                details: ["helper": expectedHelperPath]
            )

        case (.stdin, _):
            return CLIFailure(
                .needsApproval,
                "\(ElevationProbe.touchIDModuleName) answers sudo on this Mac, so a password piped to"
                    + " standard input is never read; nothing was started."
                    + " \(SudoPasswordSource.keychain.syntax) is the source that works here — sudo's"
                    + " askpass helper prints the stored password — or run the same command without the"
                    + " option and answer the prompt.",
                details: ["source": SudoPasswordSource.keychain.rawValue]
            )
        }
    }
}

/// `connect`: resolve, warm `sudo`, start the agent, and stay in the foreground
/// while the tunnel lasts.
///
/// The shape is forced by the agent: it owns the tunnel for as long as its
/// standard input is open, so the process holding that pipe *is* the tunnel's
/// lifetime. A `connect` that returned after reporting success would close the
/// pipe and end the tunnel it had just announced. Ctrl-C is therefore the way to
/// stop, and ending the command is the same thing as ending the tunnel.
///
/// See `docs/CLI.md` for when this command may be handed an administrator
/// password, and what it then does with it.
public enum ConnectCommand {

    /// How long the one authentication may take before it is called unanswered.
    /// The same 60s the app allows a dialog, named here because the timeout is
    /// also what the failure message reports.
    public static let warmUpTimeoutSeconds: TimeInterval = 60

    /// What the one authentication came back with.
    ///
    /// Four outcomes rather than a `Bool`, because the sentences differ and the
    /// difference is not guessable from the outside: a password that was not
    /// accepted, a prompt nobody answered and a `sudo -n` that asked nobody all
    /// want their own remedy, and the caller is being told what to do next.
    public enum WarmUpOutcome: Equatable {
        case warmed
        /// A supplied password went to `sudo -S -v` and sudo would not take it.
        case passwordRefused
        /// The dialog or the terminal prompt went unanswered until the timeout.
        case timedOut
        /// `sudo` refused without asking: the `-n` route, where there was
        /// nothing warm to find.
        case refused

        init(_ result: TunnelAgentChannel.SudoStepRunner.Result, passwordWasSupplied: Bool) {
            if result.succeeded { self = .warmed; return }
            if result.timedOut { self = .timedOut; return }
            self = passwordWasSupplied ? .passwordRefused : .refused
        }
    }

    /// Whether the launch will need an authenticated `sudo` at all.
    ///
    /// The ordinary answer is yes: the agent is started with `sudo -n`, whose
    /// timestamp has to be warmed by this same process, and the three routes in
    /// `warmUp` are about how. But a machine can be set up so that the *agent
    /// command alone* needs no authentication — a sudoers rule naming the
    /// installed agent, which is the way to let a connect run with nobody at the
    /// machine without turning Touch ID off for everything else (`docs/CLI.md`
    /// has the file, and what it costs). Where that rule exists there is nothing
    /// to warm and nobody to ask, and a caller that offered a password should not
    /// be refused, or prompted for one, on a machine where nothing would read it.
    public enum LaunchAuthentication: Equatable {
        /// `sudo -n <agent>` runs with no refresh, no prompt and no password.
        case notRequired
        /// The launch needs a warm timestamp: see `warmUp` for the three routes.
        case required
    }

    /// How long the one *question* may take. `sudo -l` reads policy files and
    /// authenticates nobody, so it cannot be waiting on a dialog that has to be
    /// answered; a machine slower than this is treated as the ordinary case.
    public static let authenticationProbeTimeout: TimeInterval = 5

    /// Asks sudo whether the launch itself needs a password, without asking
    /// anybody anything.
    ///
    /// `sudo -n -l <command>` is a question about policy, and `-n` turns "a
    /// password would be required" into a failure rather than a prompt — measured
    /// on this Mac, for a user with no exemption: exit 1 and `sudo: a password is
    /// required`. Exit 0 means the command may run without a password, and the
    /// command's path has to appear in the answer as well, so a `sudo` that exits
    /// 0 for some other reason cannot be read as permission.
    ///
    /// Every other answer — refused, unanswered, unreadable — is `.required`,
    /// which is the direction that cannot hurt: an unnecessary refresh costs a
    /// prompt, a missing one costs a failed launch. The runner is the app's
    /// bounded one, which gives the child no standard input at all, so a `sudo`
    /// that would find a way to prompt cannot.
    public static func launchAuthentication(
        agentPath: String,
        runner: BoundedProcessRunning = SystemBoundedProcessRunner(),
        timeout: TimeInterval = authenticationProbeTimeout
    ) -> LaunchAuthentication {
        let answer = try? runner.run(
            executable: ElevatedTermination.sudo,
            arguments: ["-n", "-l", agentPath],
            timeout: timeout
        )
        guard let answer, !answer.timedOut, answer.terminationStatus == 0,
              answer.stdout.contains(agentPath) else { return .required }
        return .notRequired
    }

    /// What to say when there is nothing to authenticate: the refresh is skipped
    /// because there is nothing to refresh, and a password the caller offered is
    /// left unread rather than prompted for with no reader waiting.
    public static func exemptionNotes(hasPassword: Bool) -> [String] {
        var lines = [
            "sudo -n -l: the agent command needs no authentication on this machine, so sudo is not"
                + " refreshed and no prompt or dialog can appear.",
        ]
        if hasPassword {
            lines.append("nothing to warm: the administrator password that was supplied was not read.")
        }
        return lines
    }

    /// What to say *before* authenticating, so a caller learns whether a dialog
    /// is coming while there is still time to answer it — the same "diagnose
    /// before the wait" the app's own log does. Pure, so all the combinations
    /// are pinned by tests instead of being discovered at a prompt.
    ///
    /// `delivery` is checked first because on the askpass route it is the whole
    /// answer: the password is read by another process, and the note has to say
    /// which one, because that is where macOS's one-time consent dialog will
    /// appear.
    public static func warmUpNotes(
        strategy: ElevationStrategy,
        hasTerminal: Bool,
        hasPassword: Bool,
        delivery: SudoPasswordDelivery = .standardInput
    ) -> [String] {
        if delivery == .askpass {
            return [
                "sudo: authenticating through sudo's askpass helper (\(AskpassHelper.installedName)), which"
                    + " prints the stored administrator password; \(ElevationProbe.touchIDModuleName) stands"
                    + " its own dialog down in askpass mode, so there is no Touch ID prompt and nothing to"
                    + " type. macOS may ask once, the first time that helper reads the item.",
            ]
        }
        if hasPassword {
            return [
                "sudo: authenticating with the supplied administrator password (sudo -S -v);"
                    + " no dialog will be shown.",
            ]
        }
        guard hasTerminal else {
            return ["sudo -n: no prompt and no dialog; if the timestamp is cold this exits 6."]
        }
        if strategy.waitsForTheSystem {
            return [
                "sudo: \(ElevationProbe.touchIDModuleName) answers on this Mac, so Touch ID or an"
                    + " administrator-password dialog is used if the timestamp is cold.",
            ]
        }
        return ["sudo: this terminal's own prompt is used if the timestamp is cold."]
    }

    /// The sentence for an authentication that did not come back warm, and the
    /// remedy for the reason it did not. Pure, and pinned by tests, because in
    /// the failing case this sentence is the whole interface the caller has.
    public static func failureDetail(
        _ outcome: WarmUpOutcome,
        strategy: ElevationStrategy,
        hasTerminal: Bool,
        delivery: SudoPasswordDelivery = .standardInput
    ) -> String {
        switch outcome {
        case .warmed:
            return "sudo is authenticated"
        case .passwordRefused:
            guard delivery != .askpass else {
                return "sudo did not accept the password its askpass helper printed; nothing was started."
                    + " Check the item behind --sudo-password keychain (Settings ▸ VPN is where the app"
                    + " stores it, and \(AskpassHelper.installedName) is what reads it), or leave the option"
                    + " out and answer the prompt yourself."
            }
            return "sudo did not accept the administrator password that was supplied; nothing was started."
                + " Check the item behind --sudo-password keychain (Settings ▸ VPN is where the app"
                + " stores it), or leave the option out and answer the prompt yourself."
        case .timedOut:
            if delivery == .askpass {
                return "sudo's askpass helper did not come back within \(Int(warmUpTimeoutSeconds))s; nothing"
                    + " was started. If macOS asked for consent to read the stored administrator password,"
                    + " that dialog was not answered — connect again with somebody at the machine, and click"
                    + " Always Allow so the next run needs nobody."
            }
            guard strategy.waitsForTheSystem else {
                return "the sudo prompt went unanswered for \(Int(warmUpTimeoutSeconds))s; nothing was started"
            }
            return "\(ElevationProbe.touchIDModuleName) asked for Touch ID or an administrator password and"
                + " nothing answered within \(Int(warmUpTimeoutSeconds))s; nothing was started."
                + " Run connect again with somebody at the machine to answer the dialog"
        case .refused:
            guard hasTerminal else {
                return "no terminal is attached and sudo is not already authenticated;"
                    + " run `sudo -v` first, run connect from a terminal, or supply --sudo-password"
            }
            return "sudo did not authenticate; nothing was started"
        }
    }

    /// Everything the connect resolved before it may run anything. Returned for
    /// `--json` preflight errors so a caller can print the remedy.
    public struct Resolution {
        public let settings: AppSettings
        public let invocation: OpenConnectInvocation
        public let agentPath: String
    }

    /// Resolves tools and settings; throws a `CLIFailure` naming the first thing
    /// that is missing.
    public static func resolve(
        settings: AppSettings,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        locate: (String) -> String? = { ToolResolver.locate($0) },
        verifyAgent: () -> TunnelAgentChannel.Availability = { TunnelAgentChannel.Verifier.check() }
    ) throws -> Resolution {
        guard settings.canConnect else {
            throw CLIFailure.notConfigured("no VPN server is configured; set it in the app under Settings ▸ VPN")
        }
        let availability = verifyAgent()
        if case .ready = availability {} else {
            let detail: String
            if case .refused(let reason) = availability {
                detail = reason
            } else {
                detail = "the tunnel agent is not installed at \(TunnelAgent.installedPath)"
            }
            throw CLIFailure(
                .notConfigured,
                detail + " — reinstall the app, which installs the agent"
            )
        }
        guard let openconnect = locate("openconnect") else {
            throw CLIFailure(.missingTool, "openconnect is not installed",
                             details: ["tool": "openconnect", "formula": "openconnect"])
        }
        let slice = settings.useTunneling ? locate("vpn-slice") : nil
        let invocation = try OpenConnectInvocation.build(
            settings: settings,
            openconnectPath: openconnect,
            slicePath: slice,
            pidFilePath: OpenConnectPidFile.path.path,
            searchPath: TunnelAgentChannel.Launch.searchPath(inherited: environment["PATH"])
        )
        return Resolution(settings: settings, invocation: invocation, agentPath: TunnelAgent.installedPath)
    }

    /// The one authentication at connect, as a direct child of this process.
    ///
    /// Four routes, and what the caller offered is what picks between them:
    ///
    /// * **A supplied password, askpass** (`--sudo-password keychain` on a Mac
    ///   whose `pam_tid` answers): `sudo -A` starts the helper named in
    ///   `SUDO_ASKPASS`, which prints the stored password. `pam_tid` stands its
    ///   own dialog down in askpass mode, so this is the route that reaches the
    ///   module that reads a password where nothing else can.
    /// * **A supplied password, piped** (`--sudo-password` on a machine without
    ///   `pam_tid`): `sudo -S -v`, which never prompts. `pam_tid` sits *ahead* of
    ///   the module that reads the pipe and raises its own dialog first, so a
    ///   password may only be piped where `strategy.pipesTheStoredPassword` says
    ///   it will be read; `ElevationRoute` refuses the combination otherwise.
    /// * **No password, terminal**: `sudo -v` prompts on `/dev/tty` — its
    ///   standard input being `/dev/null` does not stop it — so Touch ID and a
    ///   typed password both work.
    /// * **No password, no terminal**: `sudo -n -v` asks nobody. It succeeds
    ///   when the caller already warmed `sudo` *for this process*, and fails in
    ///   milliseconds when it did not, which is the case exit 6 exists for.
    ///
    /// A machine that exempts the agent command needs none of this, and
    /// `launchAuthentication` answers that before a route is chosen at all.
    ///
    /// Whichever route runs, the timestamp it warms belongs to this process,
    /// which is the one the later `sudo -n` around the agent runs under, and
    /// that is why the warm-up is a step of its own rather than a flag on the
    /// launch. The agent's standard input carries the PIN and the account
    /// password and stays open for the stop verb, so `sudo -S` must never be
    /// pointed at it: it would read the PIN as its own password and hand
    /// openconnect half a credential.
    public static func warmUp(
        hasTerminal: Bool,
        strategy: ElevationStrategy = .storedPassword,
        secret: String? = nil,
        delivery: SudoPasswordDelivery = .standardInput,
        askpassHelper: String? = nil,
        runner: TunnelAgentChannel.SudoStepRunner = TunnelAgentChannel.SudoStepRunner(),
        timeout: TimeInterval = ConnectCommand.warmUpTimeoutSeconds
    ) -> WarmUpOutcome {
        // The askpass route first, and `delivery` alone is what selects it: on
        // this door the password is printed by the helper, so this process has
        // no `secret` to pass and `secret` is deliberately not consulted. A
        // missing helper is a refusal rather than a quiet downgrade — the caller
        // said *here is the password*, and a route that ignores it is the one
        // failure this whole path exists to avoid.
        if delivery == .askpass {
            guard let askpassHelper else { return .refused }
            let result = runner.run(
                arguments: TunnelAgentChannel.Launch.warmupArguments(strategy, delivery: .askpass),
                // Nothing is piped: `sudo` reads the password from the helper's
                // standard output, not from this child's standard input.
                stdin: nil,
                timeout: timeout,
                environment: TunnelAgentChannel.Launch.askpassEnvironment(helperPath: askpassHelper)
            )
            return WarmUpOutcome(result, passwordWasSupplied: true)
        }
        if let secret, !secret.isEmpty, strategy.pipesTheStoredPassword {
            // The bytes go to the child, never into the arguments: argv is
            // readable by any process running as this user (`ps`, `pgrep -f`),
            // and it is copied into crash reports.
            let result = runner.run(
                arguments: TunnelAgentChannel.Launch.warmupArguments(.storedPassword),
                stdin: TunnelAgentChannel.Launch.warmupInput(.storedPassword, adminPassword: secret),
                timeout: timeout
            )
            return WarmUpOutcome(result, passwordWasSupplied: true)
        }
        // Everything below asks the *machine* to authenticate rather than a
        // pipe: `sudo -v` where a person can see the prompt, `sudo -n -v` where
        // nobody can. A password handed over on a machine whose stack answers
        // with its own dialog lands here deliberately — it would never be read,
        // and `ElevationRoute.refusal` stops that combination before this step.
        // With a terminal, the form that may raise a dialog. `sudo -v` reads no
        // standard input: `pam_tid` raises its own dialog, and on a Mac without
        // it `sudo` prompts on `/dev/tty` — either way a person can answer, and
        // the timestamp is warmed for the parent that will run `sudo -n`.
        // Without a terminal, the form that asks nobody. A caller that wants the
        // password route says so with `--sudo-password`; the CLI never takes it
        // on its own initiative.
        let arguments = hasTerminal
            ? TunnelAgentChannel.Launch.warmupArguments(.systemPrompt)
            : TunnelAgentChannel.Launch.warmupArguments(.neverPrompt)
        // No stdin: `sudo -v` with a pipe that is never written is not the same
        // thing as `</dev/null`, and the dialog the terminal case depends on
        // does not read a pipe anyway.
        let result = runner.run(arguments: arguments, stdin: nil, timeout: timeout)
        return WarmUpOutcome(result, passwordWasSupplied: false)
    }

    /// True when a prompt could be shown somewhere a person can see it. Checks
    /// standard error as well as standard input because `--json` sends the JSON
    /// to a pipe while the terminal is still there for a `sudo` prompt.
    public static func hasTerminal() -> Bool {
        isatty(STDIN_FILENO) != 0 || isatty(STDERR_FILENO) != 0
    }
}

// MARK: - The foreground tunnel

/// The tunnel while it lasts.
///
/// One process (`sudo -n turtlediver-agent …`), one pipe to its standard input,
/// and a decoder on its standard output. The agent's words are decoded with the
/// app's own `TunnelAgentChannel.Decoder`, so the CLI cannot invent a state the
/// app would not.
public final class ForegroundTunnel {
    public struct Result: Equatable {
        public let up: Bool
        public let pid: Int32?
        /// True when the tunnel ended because this command asked it to.
        public let stoppedByRequest: Bool
        /// A refusal word from the agent, if it refused.
        public let refused: String?
        /// Set when the tunnel did not end within its grace period.
        public let stubborn: Bool
    }

    private let queue = DispatchQueue(label: "com.xvii.kurakura.turtlediver.cli.tunnel")
    private let lock = NSLock()

    private var process: Process?
    private var input: FileHandle?
    private var decoder = TunnelAgentChannel.Decoder()
    private var upPid: Int32?
    private var refused: String?
    private var stopSent = false
    private var stopRequested = false

    private let upSemaphore = DispatchSemaphore(value: 0)
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private var signalSources: [DispatchSourceSignal] = []

    public init() {}

    /// Runs until the tunnel ends. `onUp` is called once, when the agent reports
    /// the openconnect pid. Returns when the process is gone.
    ///
    /// - Parameters:
    ///   - waitUntilUp: how long the agent gets to report a running openconnect.
    ///   - onUp: called on the caller's thread.
    ///   - onLog: the tunnel's own output, line by line, for forwarding.
    public func run(
        agentPath: String,
        openconnectPath: String,
        tunnelArguments: [String],
        searchPath: String,
        credentialLines: Int,
        credentialBlock: Data,
        waitUntilUp: TimeInterval,
        onUp: (Int32) -> Void,
        onLog: @escaping (String) -> Void
    ) -> Result {
        let arguments = TunnelAgentChannel.Launch.agentArguments(
            agentPath: agentPath,
            openconnectPath: openconnectPath,
            tunnelArguments: tunnelArguments,
            searchPath: searchPath,
            credentialLines: credentialLines
        )
        return run(
            sudoArguments: TunnelAgentChannel.Launch.sudoArguments(agentArguments: arguments),
            credentialBlock: credentialBlock,
            waitUntilUp: waitUntilUp,
            onUp: onUp,
            onLog: onLog
        )
    }

    func run(
        sudoArguments: [String],
        credentialBlock: Data,
        waitUntilUp: TimeInterval,
        onUp: (Int32) -> Void,
        onLog: @escaping (String) -> Void
    ) -> Result {
        let process = Process()
        process.executableURL = ElevatedTermination.sudo
        process.arguments = sudoArguments

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.process = process
        let stdinHandle = inputPipe.fileHandleForWriting
        self.input = stdinHandle
        // A write to a pipe whose far end is gone must be an error this code
        // sees, not a SIGPIPE that kills the command mid-sentence.
        TunnelAgentChannel.Launch.ignoreBrokenPipe(on: stdinHandle.fileDescriptor)

        let stdoutHandle = outputPipe.fileHandleForReading
        stdoutHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            let events = self.queue.sync { () -> [TunnelAgentChannel.Event] in
                self.lock.lock(); defer { self.lock.unlock() }
                return self.decoder.consume(data)
            }
            for event in events { self.handle(event, onLog: onLog) }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                onLog(String(line))
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.exitSemaphore.signal()
        }

        let sources = installSignalHandlers()
        signalSources = sources

        do {
            try process.run()
        } catch {
            uninstallSignalHandlers()
            return Result(up: false, pid: nil, stoppedByRequest: false,
                          refused: "could not start sudo: \(error.localizedDescription)", stubborn: false)
        }

        // The credentials go down the pipe and the pipe stays open: the agent
        // reads them, then reads the verb that ends the tunnel. Closing it here
        // would be the end of the tunnel.
        do {
            try stdinHandle.write(contentsOf: credentialBlock)
        } catch {
            requestStop(force: true)
            return Result(up: false, pid: nil, stoppedByRequest: true,
                          refused: "the credentials could not be written to the agent", stubborn: false)
        }

        // Wait for the agent's first word.
        if upSemaphore.wait(timeout: .now() + waitUntilUp) == .timedOut {
            requestStop(force: false)
            _ = exitSemaphore.wait(timeout: .now() + TunnelAgent.terminateGraceSeconds)
            uninstallSignalHandlers()
            return Result(up: false, pid: nil, stoppedByRequest: true,
                          refused: lock.withLock { refused }, stubborn: !exited)
        }

        let pid = lock.withLock { upPid }
        if let pid { onUp(pid) }

        // Stay alive while the tunnel lives. The stop request is written from the
        // signal source; here we only wait, and bound the wait after it is made.
        var stopDeadline: Date?
        var stubborn = false
        while true {
            if exitSemaphore.wait(timeout: .now() + 0.05) == .success { break }
            let requested = lock.withLock { stopRequested }
            guard requested else { continue }
            if stopDeadline == nil {
                stopDeadline = Date().addingTimeInterval(
                    TunnelAgent.terminateGraceSeconds + TunnelAgent.killSettleSeconds
                )
            } else if Date() > (stopDeadline ?? .distantPast) {
                // The agent is not answering. Close the pipe — the agent treats
                // end of input as the app being gone — and give it its grace.
                try? stdinHandle.close()
                if exitSemaphore.wait(timeout: .now() + TunnelAgent.killSettleSeconds) == .success { break }
                process.terminate()
                _ = exitSemaphore.wait(timeout: .now() + 2)
                stubborn = true
                break
            }
        }

        uninstallSignalHandlers()
        stdoutHandle.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        return Result(
            up: pid != nil,
            pid: pid,
            stoppedByRequest: lock.withLock { stopRequested },
            refused: lock.withLock { refused },
            stubborn: stubborn
        )
    }

    /// Writes the one verb that ends the tunnel. Idempotent: a second Ctrl-C
    /// while the first stop is in flight must not write a second `stop`, and it
    /// must not close the pipe and turn a graceful stop into an EOF.
    private func requestStop(force: Bool) {
        lock.lock()
        let shouldWrite = !stopSent || force
        stopRequested = true
        if shouldWrite { stopSent = true }
        let handle = input
        lock.unlock()

        guard shouldWrite, let handle else { return }
        try? handle.write(contentsOf: TunnelAgentChannel.Launch.stopRequest())
    }

    private func handle(_ event: TunnelAgentChannel.Event, onLog: (String) -> Void) {
        switch event {
        case .supervising(let pid):
            lock.lock()
            let first = upPid == nil
            if first { upPid = pid }
            lock.unlock()
            if first { upSemaphore.signal() }
        case .refused(let word):
            lock.withLock { refused = word }
            upSemaphore.signal()
        case .stopped(let pid):
            onLog("openconnect \(pid) stopped")
        case .killed(let pid):
            onLog("openconnect \(pid) killed")
        case .stubborn(let pid):
            lock.withLock { refused = "the agent could not end openconnect \(pid)" }
        case .peerGone, .finished:
            break
        case .unrecognised(let count):
            // The agent's word list is fixed; anything else is counted, never
            // echoed, for the same reason the app does not echo it.
            onLog("agent: \(count) unrecognised bytes")
        }
    }

    private var exited: Bool { process?.isRunning == false }

    private func installSignalHandlers() -> [DispatchSourceSignal] {
        var sources: [DispatchSourceSignal] = []
        for number in [SIGINT, SIGTERM] {
            // A dispatch source only sees the signal if the default action is
            // suppressed first, or the process dies before the handler runs.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in
                self?.requestStop(force: false)
            }
            source.resume()
            sources.append(source)
        }
        return sources
    }

    private func uninstallSignalHandlers() {
        for source in signalSources { source.cancel() }
        signalSources = []
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}

// MARK: - Disconnect

/// `disconnect`: end a tunnel nobody is holding any more, idempotently.
///
/// It never talks to the agent, because it cannot: a tunnel the app is driving
/// belongs to the app's agent, whose pipe this process does not hold, and a
/// tunnel a `connect` of our own is driving belongs to *that* process, which
/// ends it when it goes away — Ctrl-C, `kill`, or the shell dying. What this
/// command is for is the tunnel whose driver is gone: a `connect` killed so
/// hard the agent could not outlive it, a session that ended with its shell, or
/// the app's tunnel while the app is not running. It signals the process by the
/// same elevated path the app's own teardown uses, so the two cannot disagree
/// about what "stopped" means — and so a `disconnect` that finds nothing to do
/// is a success, not an error: the caller cannot know the state it asks about.
public enum DisconnectCommand {
    public struct Result: Equatable {
        public let changed: Bool
        public let status: TunnelStatus
        public let detail: String?
    }

    public static func run(
        status: TunnelStatus,
        mayPrompt: Bool,
        strategy: ElevationStrategy,
        adminPassword: String? = nil,
        delivery: SudoPasswordDelivery? = nil,
        askpassHelper: String? = nil,
        terminator: ElevatedTerminator = ElevatedTerminator(),
        elevationRecord: URL = ElevationRecord.path
    ) throws -> Result {
        guard let pid = status.pid else {
            return Result(changed: false, status: status, detail: nil)
        }

        // Prefer the wrapper's group when the record names one that still holds
        // this openconnect: signalling the group also reaps the `sudo` around it.
        // Otherwise signal the pid alone, which is what a tunnel found by scan or
        // by pid file needs.
        var target = ElevatedTerminator.Target.pid(pid)
        if status.source == ExistingConnectionDetection.Source.ownProcessGroup.rawValue,
           let pgid = ElevationRecord.read(from: elevationRecord),
           ElevatedTerminator.processGroupPids(pgid).contains(pid) {
            target = .group(pgid)
        }

        let chosen = elevation(
            strategy: strategy,
            hasTerminal: mayPrompt,
            adminPassword: adminPassword,
            delivery: delivery,
            askpassHelper: askpassHelper
        )
        let outcome = terminator.end(
            target,
            openConnectPid: pid,
            strategy: chosen.strategy,
            adminPassword: chosen.adminPassword,
            mayPrompt: chosen.mayPrompt,
            askpass: chosen.askpass
        )

        switch outcome {
        case .ended:
            return Result(changed: true, status: status, detail: nil)
        case .stillRunning(let detail):
            throw CLIFailure(.tunnelNotStopped, detail)
        case .refused(let reason):
            // A tunnel that vanished between the scan and the signal is the
            // idempotent case, not a failure.
            if !OpenConnectProcess.isRunning(pid: pid) {
                return Result(changed: true, status: status, detail: "it ended before the signal was sent")
            }
            throw CLIFailure.failure(reason)
        }
    }

    /// The strategy, the prompt permission, the password and the askpass helper a
    /// teardown runs with, resolved in one place so the command holds no opinion
    /// of its own.
    ///
    /// With a password offered, the teardown authenticates the way the connect's
    /// warm-up did, so the two halves of a scripted session agree instead of one
    /// of them raising a dialog the other avoided: `sudo -S` with those bytes on a
    /// machine that reads the pipe, and `sudo -A` with the helper on one whose
    /// `pam_tid` would swallow it.
    ///
    /// `mayPrompt` is then true, which needs saying out loud: that is not a claim
    /// that a dialog may appear, it is what lets the strategy's own plan onto
    /// `ElevatedTerminator`'s list at all. Neither password route asks a person
    /// anything — the password is on a pipe, or printed by the helper — so nothing
    /// is raised. The `sudo -n` attempt still comes first in every case, so a
    /// tunnel connected moments ago is signalled without a password being fed to
    /// `sudo` at all.
    ///
    /// On the askpass route `adminPassword` stays nil deliberately: the helper
    /// reads the item itself, so the only thing this process contributes is the
    /// helper's path. `.systemPrompt` is kept as the strategy for the same reason
    /// — it is what this machine does, and the askpass plan is the one form of it
    /// that can carry a password.
    public static func elevation(
        strategy: ElevationStrategy,
        hasTerminal: Bool,
        adminPassword: String? = nil,
        delivery: SudoPasswordDelivery? = nil,
        askpassHelper: String? = nil
    ) -> (strategy: ElevationStrategy, mayPrompt: Bool, adminPassword: String?, askpass: String?) {
        if delivery == .askpass, let askpassHelper {
            return (strategy, true, nil, askpassHelper)
        }
        guard let adminPassword, !adminPassword.isEmpty else {
            return (strategy, hasTerminal, nil, nil)
        }
        return (.storedPassword, true, adminPassword, nil)
    }
}
