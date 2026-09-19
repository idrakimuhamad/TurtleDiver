import Darwin
import Foundation
import TurtleDiverSystem

/// The tunnel agent's entry point. All the rules live in
/// `TunnelAgentProtocol.swift`; this file only turns argv into them and supplies
/// the real process handling.
///
/// ```
/// turtlediver-agent --credential-lines N [--path <search path>] /absolute/path/openconnect [args…]
/// ```
///
/// Everything after the options is the tunnel's own command line, passed through
/// unchanged. Nothing secret is ever in argv — the credentials arrive on the
/// channel and go straight to the child's standard input — because argv is
/// readable by every other process running as the same user.
///
/// `--path` is how the tunnel gets a usable `PATH`. The agent is started through
/// `sudo`, which resets the environment, so an inherited `PATH` is not the
/// caller's. `openconnect` runs `vpn-slice` as its script and vpn-slice runs
/// helpers by name, so the Homebrew directories have to be put back explicitly.
/// Without the option the child inherits the agent's own environment.
///
/// The exit code is `TunnelAgent.ExitCode`: `0` the tunnel is gone, `2` unusable
/// arguments, `3` end of input inside the credential block, `4` the tunnel would
/// not stop, `5` the command was refused or could not be started.

// A channel the app has already closed must not kill the agent: writing the
// greeting to a closed pipe would otherwise raise SIGPIPE, and the agent would
// die before it read the end of its input — leaving the tunnel running, which is
// the exact outcome the EOF rule exists to prevent.
signal(SIGPIPE, SIG_IGN)

/// Exit codes are the only way out, so a word is written and then the process
/// ends without unwinding anything that could print to the channel.
func fail(_ word: String, _ code: TunnelAgent.ExitCode) -> Never {
    FileHandle.standardOutput.write(Data((word + "\n").utf8))
    exit(code.rawValue)
}

let arguments = Array(CommandLine.arguments.dropFirst())

// The agent runs as root and has no business holding a working directory in
// someone's home. Nothing it starts needs one.
_ = FileManager.default.changeCurrentDirectoryPath("/")

// Options first, then the command. An option is only accepted when it has its
// value, so a truncated line is a usage refusal rather than a command the agent
// reads past the end of the array for.
var index = 0
var credentialLines: Int?
var searchPath: String?
while index < arguments.count, arguments[index].hasPrefix("--") {
    let (option, value) = (arguments[index], index + 1 < arguments.count ? arguments[index + 1] : nil)
    switch option {
    case "--credential-lines":
        guard let value, let lines = Int(value) else {
            fail(TunnelAgentWord.refusedUsage, .usage)
        }
        credentialLines = lines
    case "--path":
        guard let value else {
            fail(TunnelAgentWord.refusedUsage, .usage)
        }
        searchPath = value
    default:
        fail(TunnelAgentWord.refusedUsage, .usage)
    }
    index += 2
}

// Options and nothing else is a truncated line, not a tunnel the agent should
// try to start: `refused-usage` says the caller's argv was malformed, which is
// the opposite of `refused-command`.
guard index < arguments.count else {
    fail(TunnelAgentWord.refusedUsage, .usage)
}
let command = arguments[index]
let tunnelArguments = Array(arguments.dropFirst(index + 1))

// The agent must never become a general way to run something as root. It starts
// one program, and `mayStart` is the whole of that rule.
guard TunnelAgent.mayStart(command: command) else {
    fail(TunnelAgentWord.refusedCommand, .cannotStart)
}

let session: TunnelAgentSession
do {
    session = try TunnelAgentSession(credentialLines: credentialLines ?? 0)
} catch {
    fail(TunnelAgentWord.refusedUsage, .usage)
}

let runtime = AgentRuntime(command: command, arguments: tunnelArguments, searchPath: searchPath)
exit(TunnelAgentLoop.run(session: session, runtime: runtime))
