import Foundation

/// The tunnel agent: a small privileged process that *owns* the tunnel, so the
/// app can end it later without authenticating again.
///
/// ## Why it exists
///
/// `sudo` keys its credential timestamp to the parent process when there is no
/// terminal (see `docs/ELEVATION.md` §1a), so a connect that authenticates
/// inside a per-connect wrapper shell warms *that* shell's record, never the
/// app's. The teardown then runs `sudo` as a child of the app, finds a cold
/// timestamp, and raises the system Touch ID dialog — for a process the app
/// started itself, on a machine where the user has already answered once.
///
/// The fix is not another way to ask. It is to ask **once**, and leave behind
/// something that is already root and can act on that answer later. The agent is
/// that something: the connect starts it with the same single authentication it
/// needs anyway, the agent starts `openconnect` as its own child, and from then
/// on the app ends the tunnel by writing one word down a pipe.
///
/// ## What this file is
///
/// The protocol as *logic* — no processes, no signals, no IO — so the rules that
/// matter are testable without privilege:
///
/// * what counts as the one verb (exact line equality; `stop `, `STOP` and
///   `stop\r` are all refusals),
/// * what a line length limit does to an over-long line,
/// * what end-of-input means in each phase,
/// * and which words the agent is allowed to write.
///
/// `Agent/main.swift` supplies the real process handling through
/// `TunnelAgentRuntime`; `TunnelAgentProcessTests` drives the built agent as an
/// unprivileged child. Each half of the protocol was measured on this machine
/// against a stand-in for openconnect before any of it was wired to a VPN:
/// a stop took 21 ms with a provably cold sudo timestamp, ten hostile lines were
/// all refused with the target left alive, and EOF ended the tunnel.
public enum TunnelAgent {
    /// The name the agent is installed under. It is *not* inside the app bundle
    /// on purpose: a payload in a user-writable directory that the app execs as
    /// root is an escalation surface, and a platform-signed binary copied into a
    /// writable path is not even allowed to run — measured, `Killed: 9`. The
    /// installer puts it in a root-owned directory and the app verifies it
    /// before exec'ing it.
    public static let executableName = "turtlediver-agent"

    /// The only verb the channel accepts, matched exactly.
    ///
    /// Exact equality is the whole safety property of the channel. A prefix rule
    /// would accept `stop now`; a whitespace-trimming rule would accept `stop `
    /// and `stop\r`; a case-folded rule would accept `STOP`. None of those are
    /// the verb, and a channel that guesses is a channel that can be made to do
    /// something the app did not ask for.
    public static let stopVerb = "stop"

    /// The largest line the channel will carry. Sized for the longest credential
    /// (a stored administrator password), not for a command as short as `stop`.
    public static let maximumLineBytes = 4096

    /// The most credential lines an agent will wait for. The app asks for two or
    /// three; the ceiling exists so a wrong argument cannot make the agent wait
    /// for input that will never come.
    public static let maximumCredentialLines = 8

    /// How long the agent waits after `SIGTERM` before escalating to `SIGKILL`,
    /// and how long it waits after that before calling the tunnel stubborn.
    /// `openconnect` unmounts vpn-slice routes on a clean `SIGTERM`, so the
    /// grace is generous and the escalation is the exception.
    public static let terminateGraceSeconds: TimeInterval = 10
    public static let killSettleSeconds: TimeInterval = 2
    /// How often the agent re-checks liveness while waiting.
    public static let pollSeconds: TimeInterval = 0.1

    /// May the agent start this command?
    ///
    /// The agent must never become a general way to run something as root. It
    /// starts one program, and this is the check that says so: an absolute path
    /// whose last component is `openconnect`. Nothing relative (a `PATH` lookup
    /// would let the caller's environment choose the program), and nothing that
    /// merely contains the name — `/tmp/not-openconnect-at-all` fails.
    ///
    /// The rule matches `OpenConnectProcess.namesOpenConnect`, which classifies a
    /// *running* pid by the same last-component test, so "what the agent started"
    /// and "what the app will accept as the tunnel" agree.
    public static func mayStart(command: String) -> Bool {
        guard command.hasPrefix("/") else { return false }
        let name = (command as NSString).lastPathComponent
        guard !name.isEmpty else { return false }
        return name == OpenConnectProcess.name
    }

    /// The exit codes the agent can finish with, so a caller can classify an exit
    /// without parsing the words.
    public enum ExitCode: Int32 {
        /// The tunnel ended, or there was never one to end.
        case ok = 0
        /// The arguments were not usable. Nothing was started.
        case usage = 2
        /// End of input arrived inside the credential block. Nothing was started.
        case credentialsTruncated = 3
        /// The tunnel did not stop. The app must not report a clean disconnect.
        case tunnelNotStopped = 4
        /// The command was refused, or could not be started at all.
        case cannotStart = 5
    }
}

/// The fixed words the agent writes, and the only things it ever writes.
///
/// Nothing that arrived on the channel is echoed back. An echo would put text
/// chosen by whoever wrote to the pipe into the app's log, which is the one
/// place this protocol must never become a formatting surface for. Every word
/// here is a compile-time constant plus a pid the agent observed itself.
public enum TunnelAgentWord {
    public static let supervisingPrefix = "supervising "
    public static let stoppedPrefix = "stopped "
    public static let killedPrefix = "killed "
    public static let stubbornPrefix = "stubborn "
    public static let refused = "refused"
    public static let refusedStart = "refused-start"
    public static let refusedUsage = "refused-usage"
    public static let refusedCommand = "refused-command"
    public static let credentialsTruncated = "refused-credentials-eof"
    public static let peerGone = "eof"
    public static let finished = "done"

    public static func supervising(_ pid: Int32) -> String { supervisingPrefix + String(pid) }
    public static func stopped(_ pid: Int32) -> String { stoppedPrefix + String(pid) }
    public static func killed(_ pid: Int32) -> String { killedPrefix + String(pid) }
    public static func stubborn(_ pid: Int32) -> String { stubbornPrefix + String(pid) }
}

/// Why the channel is ending.
public enum TunnelAgentEnd: Equatable, Sendable {
    /// The app asked, with the one verb.
    case stop
    /// End of input: the app is gone, so the tunnel ends with it.
    case peerGone
}

/// What actually happened to the tunnel, as observed rather than attempted.
///
/// The three cases exist because "asked it to stop" and "it stopped" are
/// different facts, and the app must be able to tell them apart — a disconnect
/// that reports success over a live process is exactly the defect this whole
/// path exists to remove.
public enum TunnelAgentOutcome: Equatable, Sendable {
    /// Gone after `SIGTERM`.
    case stopped
    /// Gone, but only after `SIGKILL`.
    case killed
    /// Still there. The caller must not report a disconnect.
    case stubborn
}

/// The agent's side of the channel, as a state machine with no IO.
///
/// Phases: the credential lines first, then commands. The tunnel starts when the
/// last credential line arrives, not before — openconnect needs those bytes on
/// its standard input, and an agent that started it early would have to buffer
/// them somewhere else.
public struct TunnelAgentSession: Equatable {
    public enum Phase: Equatable, Sendable {
        /// Still reading the credential block; `remaining` counts what is left.
        case credentials(remaining: Int)
        /// Credentials complete; commands from here.
        case commands
        /// Ended. Further input is refused, and the loop has already returned.
        case finished
    }

    public enum Action: Equatable, Sendable {
        /// One credential line consumed.
        case credential
        /// The last credential line arrived: start the tunnel.
        case start
        /// End the tunnel for this reason.
        case end(TunnelAgentEnd)
        /// Not a verb the channel understands. The tunnel is left alone.
        case refuse
        /// End of input inside the credential block.
        case credentialsTruncated
    }

    public let credentialLines: Int
    public private(set) var phase: Phase
    /// The credential lines received so far, in order. Bounded by
    /// `maximumCredentialLines` and `maximumLineBytes`, so this cannot grow with
    /// the input. It is retained rather than discarded because the tunnel cannot
    /// start until the block is complete, and openconnect needs these bytes on
    /// its standard input. Swift cannot promise the array is wiped after use, and
    /// nothing here claims it is.
    public private(set) var credentials: [String] = []

    /// - Parameter credentialLines: how many lines to read before starting the
    ///   tunnel. Rejected outside `1...maximumCredentialLines`: an agent asked
    ///   for no credentials would have nothing to hand the tunnel, and a
    ///   protocol that accepts a configuration it cannot honour is worse than
    ///   one that refuses it.
    public init(credentialLines: Int) throws {
        guard credentialLines >= 1,
              credentialLines <= TunnelAgent.maximumCredentialLines else {
            throw TunnelAgentError.credentialLineCountOutOfRange(credentialLines)
        }
        self.credentialLines = credentialLines
        self.phase = .credentials(remaining: credentialLines)
    }

    /// Feeds one line, or `nil` for end of input.
    ///
    /// The line must arrive with its newline removed and **nothing else
    /// stripped**: a carriage return is left in place, because `stop\r` is not
    /// the verb and a reader that quietly cleaned it up would be accepting input
    /// the protocol did not agree to.
    public mutating func receive(line: String?) -> Action {
        switch phase {
        case .finished:
            return .refuse

        case .credentials(let remaining):
            guard let line else {
                phase = .finished
                return .credentialsTruncated
            }
            guard line.utf8.count <= TunnelAgent.maximumLineBytes else {
                // Over-long in the credential block: an agent that kept reading
                // could be made to buffer without limit, and a credential this
                // long is a caller error. Nothing has been started, so nothing
                // is at risk.
                phase = .finished
                return .credentialsTruncated
            }
            let left = remaining - 1
            credentials.append(line)
            if left == 0 {
                phase = .commands
                return .start
            }
            phase = .credentials(remaining: left)
            return .credential

        case .commands:
            guard let line else {
                phase = .finished
                return .end(.peerGone)
            }
            // The comparison is on the line as received, before the length
            // check, so an over-long line can never be truncated into the verb:
            // a line longer than the limit is at least `maximumLineBytes + 1`
            // bytes, and the verb is four.
            guard line.utf8.count <= TunnelAgent.maximumLineBytes else { return .refuse }
            guard line == TunnelAgent.stopVerb else { return .refuse }
            phase = .finished
            return .end(.stop)
        }
    }
}

/// A configuration the agent refuses, rather than one it guesses at.
public enum TunnelAgentError: Error, Equatable {
    case credentialLineCountOutOfRange(Int)
}

/// Everything the loop needs from the outside world.
///
/// Injected so the loop can be driven — including through a stubborn or
/// unstartable tunnel — without a privileged process and without a VPN. The
/// real implementation is `Agent/AgentRuntime.swift`.
public protocol TunnelAgentRuntime: AnyObject {
    /// Starts the validated command in a process group of its own, handing it
    /// the credential lines on its standard input, and returns its pid.
    func startTunnel(credentials: [String]) throws -> Int32
    /// Ends the tunnel this agent started, escalating only as far as it must,
    /// and reports what was observed.
    func endTunnel(pid: Int32) -> TunnelAgentOutcome
    /// The next line with its newline removed, or `nil` at end of input.
    func nextLine() -> String?
    /// Writes one protocol word, newline-terminated.
    func write(_ word: String)
}

/// Drives a `TunnelAgentSession` against a runtime until the channel ends.
///
/// The loop's obligations, all of which the spike measured:
///
/// * a refused line leaves the tunnel running and the channel open — the one
///   verb still works afterwards,
/// * the tunnel is only ever ended by the exact verb or by end of input,
/// * every word written is a fixed constant plus a pid the agent observed,
///   never anything that arrived on the channel,
/// * and the tunnel's real fate is what decides the exit code, not the fact that
///   a stop was requested.
public enum TunnelAgentLoop {
    public static func run(session: TunnelAgentSession, runtime: TunnelAgentRuntime) -> Int32 {
        var session = session
        var tunnelPid: Int32?

        while true {
            let action = session.receive(line: runtime.nextLine())
            switch action {
            case .credential:
                continue

            case .credentialsTruncated:
                runtime.write(TunnelAgentWord.credentialsTruncated)
                return TunnelAgent.ExitCode.credentialsTruncated.rawValue

            case .refuse:
                runtime.write(TunnelAgentWord.refused)
                continue

            case .start:
                // The block the session consumed, bounded by construction.
                let credentials = session.credentials
                do {
                    let pid = try runtime.startTunnel(credentials: credentials)
                    tunnelPid = pid
                    runtime.write(TunnelAgentWord.supervising(pid))
                } catch {
                    runtime.write(TunnelAgentWord.refusedStart)
                    return TunnelAgent.ExitCode.cannotStart.rawValue
                }

            case .end(let reason):
                guard let pid = tunnelPid else {
                    // Unreachable: `.end` is only produced from `.commands`,
                    // which is only entered by `.start`.
                    runtime.write(TunnelAgentWord.refused)
                    return TunnelAgent.ExitCode.usage.rawValue
                }
                if reason == .peerGone {
                    // The app is gone, so nobody is reading the rest. The word
                    // is written anyway; the app's log may already have it.
                    runtime.write(TunnelAgentWord.peerGone)
                }
                let outcome = runtime.endTunnel(pid: pid)
                switch outcome {
                case .stopped:
                    runtime.write(reason == .stop
                                  ? TunnelAgentWord.stopped(pid)
                                  : TunnelAgentWord.finished)
                case .killed:
                    runtime.write(reason == .stop
                                  ? TunnelAgentWord.killed(pid)
                                  : TunnelAgentWord.finished)
                case .stubborn:
                    runtime.write(TunnelAgentWord.stubborn(pid))
                }
                return outcome == .stubborn
                    ? TunnelAgent.ExitCode.tunnelNotStopped.rawValue
                    : TunnelAgent.ExitCode.ok.rawValue
            }
        }
    }
}
