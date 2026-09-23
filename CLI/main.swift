import Foundation
import TurtleDiverCLIKit

// The whole of the entry point. Everything that decides anything lives in
// `TurtleDiverCLIKit` so it can be tested without a process.
exit(TurtleDiverCLI.main(arguments: Array(CommandLine.arguments.dropFirst())))
