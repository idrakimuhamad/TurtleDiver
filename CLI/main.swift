import Foundation
import TurtleDiverCLIKit

// The helper `sudo -A` runs is this same binary under a second name,
// `turtlediver-askpass` — so the one program that can print the stored
// administrator password is a named, signed grant rather than a general-purpose
// dispenser, and nothing else in the command line applies to it: it takes no
// arguments, prints one line, and exits.
if AskpassHelper.isHelperInvocation(executablePath: AskpassHelper.ownPath()) {
    exit(AskpassHelper.run().rawValue)
}

// The whole of the entry point. Everything that decides anything lives in
// `TurtleDiverCLIKit` so it can be tested without a process.
exit(TurtleDiverCLI.main(arguments: Array(CommandLine.arguments.dropFirst())))
