import Darwin
import Foundation
import TurtleDiverSystem

/// The tunnel agent's entry point. All the rules live in
/// `TunnelAgentProtocol.swift`; this file only turns argv into them and supplies
/// the real process handling.
///
/// ```
/// turtlediver-agent --credential-lines N /absolute/path/openconnect [args…]
/// ```
///
/// Everything after the option is the tunnel's own command line, passed through
/// unchanged. Nothing secret is ever in argv — the credentials arrive on the
/// channel and go straight to the child's standard input — because argv is
/// readable by every other process running as the same user.
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

guard arguments.count >= 3, arguments[0] == "--credential-lines" else {
    fail(TunnelAgentWord.refusedUsage, .usage)
}
guard let credentialLines = Int(arguments[1]) else {
    fail(TunnelAgentWord.refusedUsage, .usage)
}
let command = arguments[2]
let tunnelArguments = Array(arguments.dropFirst(3))

// The agent must never become a general way to run something as root. It starts
// one program, and `mayStart` is the whole of that rule.
guard TunnelAgent.mayStart(command: command) else {
    fail(TunnelAgentWord.refusedCommand, .cannotStart)
}

let session: TunnelAgentSession
do {
    session = try TunnelAgentSession(credentialLines: credentialLines)
} catch {
    fail(TunnelAgentWord.refusedUsage, .usage)
}

let runtime = AgentRuntime(command: command, arguments: tunnelArguments)
exit(TunnelAgentLoop.run(session: session, runtime: runtime))
