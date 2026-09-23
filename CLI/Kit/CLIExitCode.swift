import Foundation

/// The process exit status, which is part of the CLI's interface: a caller
/// matches on it, so a code never changes meaning to mean something else.
///
/// The numbers are grouped so that the common distinction — "you asked wrong",
/// "this machine is not ready", "the tunnel did something you did not ask for" —
/// is visible without a lookup table. `docs/CLI.md` documents them for people
/// who do not read Swift.
public enum CLIExitCode: Int32, Equatable, CaseIterable {
    /// The command did what it said.
    case ok = 0
    /// It did not, and the detail was printed.
    case failure = 1
    /// The arguments are not a command line this CLI accepts.
    case usage = 2
    /// Nothing is configured to connect to, or the agent is not installed.
    case notConfigured = 3
    /// `connect` found a tunnel already up.
    case alreadyConnected = 4
    /// Reserved for a command that needs a tunnel and there is none. `disconnect`
    /// deliberately does not use it: ending a tunnel that is not there is
    /// success with `"changed": false`, because a caller cannot know the state
    /// it is asking about.
    case noTunnel = 5
    /// A dialog would be needed and there is no terminal to show it in.
    case needsApproval = 6
    /// A program the connect needs is not installed.
    case missingTool = 7
    /// The tunnel is still there after everything this CLI may do.
    case tunnelNotStopped = 8
    /// A wait expired.
    case timedOut = 9

    /// The one-line meaning, for `--help` and for a JSON error body.
    public var meaning: String {
        switch self {
        case .ok: return "success"
        case .failure: return "failure"
        case .usage: return "usage error"
        case .notConfigured: return "not configured"
        case .alreadyConnected: return "already connected"
        case .noTunnel: return "no tunnel"
        case .needsApproval: return "approval required"
        case .missingTool: return "missing tool"
        case .tunnelNotStopped: return "the tunnel did not stop"
        case .timedOut: return "timed out"
        }
    }
}

/// A failure that already knows which exit code it deserves.
///
/// Commands throw this rather than printing and exiting so that `--json` gets a
/// structured body for the same condition a person sees as a sentence, and so
/// the exit code is chosen once, at the throw.
public struct CLIFailure: Error, Equatable {
    public let code: CLIExitCode
    public let message: String
    /// Extra machine-readable fields for `--json`, e.g. the remedy for a missing
    /// tool. Kept a `[String: String]` so it cannot smuggle a value the JSON
    /// writer would refuse.
    public let details: [String: String]

    public init(_ code: CLIExitCode, _ message: String, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// The failure that means "nothing here is worth a bug report": a missing
    /// profile, an unreadable plist, a host that was never set.
    public static func notConfigured(_ message: String) -> CLIFailure {
        CLIFailure(.notConfigured, message)
    }

    public static func usage(_ message: String) -> CLIFailure {
        CLIFailure(.usage, message)
    }

    public static func failure(_ message: String) -> CLIFailure {
        CLIFailure(.failure, message)
    }
}
