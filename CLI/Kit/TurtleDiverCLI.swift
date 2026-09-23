import Foundation
import TurtleDiverCore
import TurtleDiverSystem

/// The command dispatch.
///
/// Kept in the kit rather than in `main.swift` so the parser, the exit codes,
/// and every command's answer can be exercised by tests with no process started
/// and no terminal attached. `CLI/main.swift` is `exit(TurtleDiverCLI.main(...))`
/// and nothing else.
public enum TurtleDiverCLI {

    /// The entry point. Never throws: a failure has already been printed and its
    /// exit code chosen.
    public static func main(arguments: [String]) -> Int32 {
        // The output shape has to be known before anything can fail, so it is
        // read from the raw arguments rather than from the parsed result.
        let output = Output(
            json: arguments.contains("--json"),
            quiet: arguments.contains("--quiet")
        )
        do {
            let parsed = try ParsedCommandLine.parse(arguments)
            let parsedOutput = Output(json: parsed.wantsJSON, quiet: parsed.wantsQuiet)
            return try dispatch(parsed, output: parsedOutput).rawValue
        } catch let failure as CLIFailure {
            output.fail(failure)
            return failure.code.rawValue
        } catch {
            output.fail(.failure("\(error)"))
            return CLIExitCode.failure.rawValue
        }
    }

    static func dispatch(_ parsed: ParsedCommandLine, output: Output) throws -> CLIExitCode {
        if parsed.switches.contains("version") { return version(output) }
        guard let command = parsed.command else {
            output.note(usageText)
            return .usage
        }
        if parsed.wantsHelp && command != "help" {
            output.note(usageText)
            return .ok
        }

        switch command {
        case "version", "--version": return version(output)
        case "help": output.note(usageText); return .ok
        case "status": return try status(parsed, output: output)
        case "connect": return try connect(parsed, output: output)
        case "disconnect": return try disconnect(parsed, output: output)
        case "rules": return try rules(parsed, output: output)
        case "profile": return try profile(parsed, output: output)
        default:
            throw CLIFailure.usage("unknown command \"\(command)\" (try `turtlediver help`)")
        }
    }

    // MARK: - Commands

    static func version(_ output: Output) -> CLIExitCode {
        let app = CLIInfo.installedAppVersion()
        var body: [String: Any] = ["ok": true, "name": CLIInfo.name, "version": CLIInfo.version]
        if let app { body["appVersion"] = app }
        output.report(body, [
            "\(CLIInfo.name) \(CLIInfo.version)"
                + (app.map { " (app \($0))" } ?? " (app not found)"),
        ])
        return .ok
    }

    static func status(_ parsed: ParsedCommandLine, output: Output) throws -> CLIExitCode {
        let status = TunnelStatus.read()
        output.report(status.jsonObject, status.humanLines)
        return .ok
    }

    static func connect(_ parsed: ParsedCommandLine, output: Output) throws -> CLIExitCode {
        // The command line is checked before any state is: a caller that mistyped
        // the password source should be told so whether or not a tunnel happens
        // to be up, and nothing should be asked for on the strength of a flag
        // that is wrong.
        let passwordSource = try sudoPasswordSource(parsed)
        // Read here, before anything is asked for, because it decides whether a
        // supplied password can be read at all — and the answer must come before
        // a Keychain dialog or a Keychain read, not after both.
        let elevation = ElevationRoute.strategy()
        // Refuse to start a second tunnel. Not a safety property — the pid file
        // and the group record tolerate two — but two openconnects on one host
        // is never what the caller meant, and saying so is cheaper than letting
        // them find out from the routes.
        let existing = TunnelStatus.read()
        if let pid = existing.pid {
            throw CLIFailure(
                .alreadyConnected,
                "a tunnel is already up (openconnect pid \(pid), found via \(existing.source ?? "unknown"))"
            )
        }
        let settings = AppSettings.readFromAppDomains()
        let resolution = try ConnectCommand.resolve(settings: settings)
        output.note("openconnect: \(resolution.invocation.commandLinePreview())")

        // Whether the launch needs an authenticated sudo at all, asked before
        // anything is read or refused. A machine that exempts the agent command
        // (a sudoers rule — see Unattended connects in `usageText`) needs no
        // refresh, no dialog and no password, so a caller that offered one should
        // not be refused on a machine where nothing would read it.
        let authentication = ConnectCommand.launchAuthentication(agentPath: resolution.agentPath)
        // After the state, because "already up" is a complete answer of its own,
        // and after the probe, because the refusal is only true of a launch that
        // has to authenticate; before anything is read or run, because a machine
        // that raises its own sudo dialog would otherwise take the password and
        // hang on that dialog.
        if authentication == .required,
           let refusal = ElevationRoute.refusal(for: passwordSource, on: elevation) {
            throw refusal
        }

        // Credentials: the account password, and the passcode half of the PIN.
        // Read before elevation so a missing one is reported before a password
        // prompt, not after.
        guard let vpnPassword = KeychainSecret.vpnPassword.value else {
            let result = KeychainSecret.vpnPassword.read()
            throw CLIFailure.notConfigured(
                KeychainSecret.explain(result, account: .vpnPassword)
                    ?? "the stored VPN password could not be read"
            )
        }
        let passcode = KeychainSecret.vpnPasscode.value ?? ""

        let token = try TokenGenerator().generate(for: TokenGenerator.Plan(
            stokenPath: ToolResolver.locate("stoken"),
            tokenFilePath: settings.stokenTokenFilePath,
            rcPath: settings.stokenRCPath,
            homeRCPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".stokenrc").path,
            passcode: passcode
        ))
        let pin = TokenGenerator.combine(passcode: passcode, code: token)

        let hasTerminal = ConnectCommand.hasTerminal()
        if authentication == .required {
            // The administrator password, if the caller offered one. Read after the
            // credentials above so that a missing VPN password — the more common
            // failure — is reported before anything is asked for, and read here, not
            // earlier, so it is held for as little of the command's life as possible.
            let secret = try sudoPassword(passwordSource, output: output)
            for line in ConnectCommand.warmUpNotes(
                strategy: elevation,
                hasTerminal: hasTerminal,
                hasPassword: secret != nil
            ) {
                output.note(line)
            }
            let warmUp = ConnectCommand.warmUp(
                hasTerminal: hasTerminal,
                strategy: elevation,
                secret: secret
            )
            guard warmUp == .warmed else {
                throw CLIFailure(
                    .needsApproval,
                    ConnectCommand.failureDetail(warmUp, strategy: elevation, hasTerminal: hasTerminal)
                )
            }
        } else {
            // Nothing to authenticate, so nothing is read either: the launch is
            // still `sudo -n`, and it succeeds because the rule exempts it.
            for line in ConnectCommand.exemptionNotes(hasPassword: passwordSource != nil) {
                output.note(line)
            }
        }

        OpenConnectPidFile.prepareDirectory()
        OpenConnectPidFile.discardLegacyFile()

        let tunnel = ForegroundTunnel()
        var announced = false
        let timeout = TimeInterval(try parsed.int("timeout", default: 90))

        let result = tunnel.run(
            agentPath: resolution.agentPath,
            openconnectPath: resolution.invocation.openconnectPath,
            tunnelArguments: resolution.invocation.arguments,
            searchPath: resolution.invocation.searchPath,
            credentialLines: resolution.invocation.credentialLineCount,
            credentialBlock: TunnelAgentChannel.Launch.credentialBlock(pin: pin, vpnPassword: vpnPassword),
            waitUntilUp: timeout,
            onUp: { pid in
                announced = true
                // Recorded so `status` and `disconnect` can name this tunnel even
                // though the agent, not the app, owns it.
                OpenConnectPidFile.record(pid)
                output.report(
                    ["ok": true, "connected": true, "pid": Int(pid), "foreground": true],
                    ["connected: openconnect pid \(pid) — press Ctrl-C to end the tunnel"]
                )
            },
            onLog: { output.note($0) }
        )

        if result.stubborn {
            throw CLIFailure(.tunnelNotStopped, "the tunnel agent did not end the tunnel in time")
        }
        if let refused = result.refused {
            throw CLIFailure.failure("the tunnel agent refused the launch: \(refused)")
        }
        if !announced {
            throw CLIFailure(.timedOut,
                "no tunnel came up within \(Int(timeout))s; the agent's output on stderr says why")
        }
        output.note("tunnel ended.")
        return .ok
    }

    static func disconnect(
        _ parsed: ParsedCommandLine,
        output: Output,
        readStatus: () -> TunnelStatus = { TunnelStatus.read() },
        readPassword: (SudoPasswordSource) throws -> String = { try SudoPassword.read($0) }
    ) throws -> CLIExitCode {
        let passwordSource = try sudoPasswordSource(parsed)
        let strategy = ElevationRoute.strategy()
        let status = readStatus()
        // Only when there is something to stop. A password is needed to tear a
        // tunnel down, and nothing else; with nothing to do this command is
        // idempotent and says so, flag or no flag, which is the promise scripts
        // rely on when they run it unconditionally at the end.
        if status.connected, let refusal = ElevationRoute.refusal(for: passwordSource, on: strategy) {
            throw refusal
        }
        // Read only when it will be used, for the same reason: a no-op
        // disconnect must not raise a Keychain consent dialog for a password it
        // is about to throw away, and the caller must not have to answer one.
        let adminPassword = status.connected
            ? try sudoPassword(passwordSource, output: output, read: readPassword)
            : nil
        let result = try DisconnectCommand.run(
            status: status,
            mayPrompt: ConnectCommand.hasTerminal(),
            strategy: strategy,
            adminPassword: adminPassword
        )

        var body: [String: Any] = ["ok": true, "changed": result.changed, "connected": false]
        if let pid = status.pid { body["pid"] = Int(pid) }
        if let detail = result.detail { body["detail"] = detail }
        output.report(
            body,
            [result.changed
                ? "disconnected: openconnect pid \(status.pid.map(String.init) ?? "?") is gone."
                : "no tunnel was up; nothing to do."]
        )
        return .ok
    }

    static func rules(_ parsed: ParsedCommandLine, output: Output) throws -> CLIExitCode {
        guard let sub = parsed.positional.first, sub == "explain" else {
            throw CLIFailure.usage("usage: turtlediver rules explain <host> [--profile NAME] [--port N]")
        }
        guard parsed.positional.count >= 2 else {
            throw CLIFailure.usage("rules explain needs a host or IP address")
        }
        let host = parsed.positional[1]

        let settings = AppSettings.readFromAppDomains()
        let directory = ProfileDirectory()
        let profileName = try resolveProfileName(parsed, directory: directory, settings: settings)
        let explanation = try RulesExplanation.explain(
            host: host,
            port: try parsed.int("port"),
            profileName: profileName,
            directory: directory,
            defaults: AppSettings.appDefaults()
        )
        output.report(explanation.jsonObject, explanation.humanLines)
        return .ok
    }

    static func profile(_ parsed: ParsedCommandLine, output: Output) throws -> CLIExitCode {
        guard let sub = parsed.positional.first else {
            throw CLIFailure.usage("usage: turtlediver profile list|validate [name]")
        }
        let settings = AppSettings.readFromAppDomains()
        let directory = ProfileDirectory()

        switch sub {
        case "list":
            let listing = ProfileListing.read(directory: directory, activeName: settings.activeProfileName)
            output.report(listing.jsonObject, listing.humanLines)
            return .ok

        case "validate":
            let name = parsed.positional.count >= 2
                ? parsed.positional[1]
                : try resolveProfileName(parsed, directory: directory, settings: settings)
            let validation = try ProfileValidation.validate(name: name, directory: directory)
            output.report(validation.jsonObject, validation.humanLines)
            return validation.isValid ? .ok : .failure

        default:
            throw CLIFailure.usage("unknown profile subcommand \"\(sub)\" (expected list or validate)")
        }
    }

    // MARK: - Shared resolution

    /// The source the caller named for the administrator password, if any.
    ///
    /// Split from the read so it can be called before any state is consulted: a
    /// mistyped source is a usage error even when there is no tunnel to end or
    /// one already up, and nothing is asked for on the strength of a flag that is
    /// wrong. Nothing here touches the Keychain or the standard input.
    static func sudoPasswordSource(_ parsed: ParsedCommandLine) throws -> SudoPasswordSource? {
        guard let raw = parsed.options[SudoPasswordSource.optionName] else { return nil }
        return try SudoPasswordSource.parse(raw)
    }

    /// The administrator password itself, from the source already named, and
    /// `nil` when the caller named none.
    ///
    /// Read as late as the command allows: it is the one value in this tool that
    /// nobody may see, and holding it for less of the run is the only protection
    /// available here. The announcement is printed *before* the read on purpose —
    /// the Keychain read can raise macOS's own consent dialog, and a dialog with
    /// nothing above it reads as a crash. The value is returned to exactly one
    /// caller, which puts it on a pipe.
    static func sudoPassword(
        _ source: SudoPasswordSource?,
        output: Output,
        read: (SudoPasswordSource) throws -> String = { try SudoPassword.read($0) }
    ) throws -> String? {
        guard let source else { return nil }
        output.note(SudoPassword.announcement(for: source))
        return try read(source)
    }

    /// The profile to use when the caller did not name one, with a message that
    /// lists what is available rather than just refusing.
    static func resolveProfileName(
        _ parsed: ParsedCommandLine,
        directory: ProfileDirectory,
        settings: AppSettings
    ) throws -> String {
        if let named = parsed.options["profile"], !named.isEmpty {
            guard directory.exists(named) else {
                throw CLIFailure.notConfigured(
                    "no profile named \"\(named)\" in \(directory.directory.path)"
                )
            }
            return named
        }
        if let resolved = directory.resolveDefault(activeName: settings.activeProfileName) {
            return resolved
        }
        let available = directory.names()
        if available.isEmpty {
            throw CLIFailure.notConfigured("no profiles in \(directory.directory.path)")
        }
        throw CLIFailure.notConfigured(
            "which profile? the app's active profile is not set and there are several: "
                + available.joined(separator: ", ") + " — pass --profile NAME"
        )
    }

    // MARK: - Help

    static let usageText = """
    \(CLIInfo.name) \(CLIInfo.version) — the TurtleDiver engine from a shell.

    Usage:
      turtlediver status [--json]
      turtlediver connect [--timeout SECONDS] [--sudo-password SOURCE] [--json]
      turtlediver disconnect [--sudo-password SOURCE] [--json]
      turtlediver rules explain <host|ip> [--profile NAME] [--port N] [--json]
      turtlediver profile list [--json]
      turtlediver profile validate [name] [--json]
      turtlediver version

    Global options:
      --json     one JSON document on stdout; human notes go to stderr
      --quiet    suppress the human lines
      -h, --help this text
      -v, --version

    --sudo-password SOURCE
      hand over the administrator password, from `keychain` (the app's stored
      one) or `stdin` (one line on the pipe), so sudo never has to prompt. Left
      out — the default — sudo prompts on a terminal and a pipe gets `sudo -n`.
      The CLI never guesses a source and never falls back to another.
      This only works where sudo reads a piped password: on a Mac whose PAM
      stack runs pam_tid (Touch ID for sudo) its dialog comes first, nothing can
      read the pipe, and the option is refused with exit 6 rather than left to
      wait on a dialog nobody asked for. Without the option that Mac prompts as
      usual — and where the agent command is exempt from authentication (see
      Unattended connects) no refresh and no password are needed at all.

    Unattended connects
      connect starts the agent with `sudo -n`, so sudo has to be authenticated
      first. With nobody at the machine, only a stack that reads a piped password
      can do that, which is what --sudo-password is for. Two ways to get there,
      both of which you install yourself with the administrator password, and
      both of which undo by deleting what you added:

      1. Exempt the agent command, and nothing else. In
         /etc/sudoers.d/turtlediver (write it with `sudo visudo -f`):

           Defaults!/usr/local/libexec/turtlediver-agent !authenticate

         connect notices this (`sudo -n -l`), skips the refresh and needs no
         password at all, and Touch ID still guards every other use of sudo. The
         cost is that anything running as you can then start a root tunnel
         without authenticating.

      2. Or drop Touch ID for sudo machine-wide, by taking the pam_tid line out
         of /etc/pam.d/sudo_local, and keep --sudo-password keychain (or stdin)
         as the connect's credential.

      The CLI makes neither change and never relaxes sudo on its own; docs/CLI.md
      has the full note, including the Keychain prompts an unattended connect
      also has to get past.

    connect runs in the foreground: the tunnel lives as long as the command does,
    and Ctrl-C ends it. `disconnect` is for a tunnel whose driver is already gone.
    See docs/CLI.md for the exit codes.
    """
}
