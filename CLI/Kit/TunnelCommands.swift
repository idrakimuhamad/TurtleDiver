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

    /// Refuses `--sudo-password` where the password would never be read.
    ///
    /// Refusing is the only honest answer available. Continuing would raise the
    /// very dialog the caller asked to avoid and then blame the password for the
    /// timeout; taking the password and quietly running the no-password route
    /// would ignore what the caller said. Both are worse than naming what this
    /// machine does and what the caller can do about it.
    public static func refusal(
        for source: SudoPasswordSource?,
        on strategy: ElevationStrategy
    ) -> CLIFailure? {
        guard source != nil, !strategy.pipesTheStoredPassword else { return nil }
        return CLIFailure(
            .needsApproval,
            "\(ElevationProbe.touchIDModuleName) answers sudo on this Mac, so its own Touch ID or"
                + " administrator-password dialog appears before anything can read a piped password,"
                + " and --sudo-password cannot skip it; nothing was started."
                + " Run the same command without the option and answer the prompt, or take the"
                + " \(ElevationProbe.touchIDModuleName) line out of /etc/pam.d/sudo_local if a connect has"
                + " to run with nobody at the machine."
        )
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

    /// What to say *before* authenticating, so a caller learns whether a dialog
    /// is coming while there is still time to answer it — the same "diagnose
    /// before the wait" the app's own log does. Pure, so all four combinations
    /// are pinned by tests instead of being discovered at a prompt.
    public static func warmUpNotes(
        strategy: ElevationStrategy,
        hasTerminal: Bool,
        hasPassword: Bool
    ) -> [String] {
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
        hasTerminal: Bool
    ) -> String {
        switch outcome {
        case .warmed:
            return "sudo is authenticated"
        case .passwordRefused:
            return "sudo did not accept the administrator password that was supplied; nothing was started."
                + " Check the item behind --sudo-password keychain (Settings ▸ Advanced is where the app"
                + " stores it), or leave the option out and answer the prompt yourself."
        case .timedOut:
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
    /// Three routes, and offering a password is what picks between them:
    ///
    /// * **A supplied password** (`--sudo-password`) goes into `sudo -S -v`,
    ///   which never prompts and never waits on a dialog — on a machine whose
    ///   PAM stack can read the pipe. `pam_tid` sits *ahead* of the module that
    ///   reads it and raises its own dialog first, so a password may only be
    ///   piped where `strategy.pipesTheStoredPassword` says it will be read.
    /// * **No password, terminal**: `sudo -v` prompts on `/dev/tty` — its
    ///   standard input being `/dev/null` does not stop it — so Touch ID and a
    ///   typed password both work.
    /// * **No password, no terminal**: `sudo -n -v` asks nobody. It succeeds
    ///   when the caller already warmed `sudo` *for this process*, and fails in
    ///   milliseconds when it did not, which is the case exit 6 exists for.
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
        runner: TunnelAgentChannel.SudoStepRunner = TunnelAgentChannel.SudoStepRunner(),
        timeout: TimeInterval = ConnectCommand.warmUpTimeoutSeconds
    ) -> WarmUpOutcome {
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

        let chosen = elevation(strategy: strategy, hasTerminal: mayPrompt, adminPassword: adminPassword)
        let outcome = terminator.end(
            target,
            openConnectPid: pid,
            strategy: chosen.strategy,
            adminPassword: chosen.adminPassword,
            mayPrompt: chosen.mayPrompt
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

    /// The strategy, the prompt permission and the password a teardown runs
    /// with, resolved in one place so the command holds no opinion of its own.
    ///
    /// With a password offered, the teardown authenticates the way the connect's
    /// warm-up did — `sudo -S` with those bytes — so the two halves of a scripted
    /// session agree instead of one of them raising a dialog the other avoided.
    ///
    /// `mayPrompt` is then true, which needs saying out loud: that is not a claim
    /// that a dialog may appear, it is what lets the strategy's own plan onto
    /// `ElevatedTerminator`'s list at all. `.storedPassword` asks nobody — the
    /// password is already on the pipe — so nothing is raised. The `sudo -n`
    /// attempt still comes first in every case, so a tunnel connected moments ago
    /// is signalled without the password being fed to `sudo` at all.
    public static func elevation(
        strategy: ElevationStrategy,
        hasTerminal: Bool,
        adminPassword: String? = nil
    ) -> (strategy: ElevationStrategy, mayPrompt: Bool, adminPassword: String?) {
        guard let adminPassword, !adminPassword.isEmpty else {
            return (strategy, hasTerminal, nil)
        }
        return (.storedPassword, true, adminPassword)
    }
}
