import Foundation

/// The result of a process that was given a deadline.
public struct BoundedProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    /// True when the deadline expired and the child had to be signalled. The
    /// status is then meaningless — say so by checking this first.
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String

    public init(terminationStatus: Int32, timedOut: Bool, stdout: String, stderr: String) {
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum BoundedProcessError: LocalizedError, Equatable {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail): return "Could not run the command: \(detail)"
        }
    }
}

/// Runs a short-lived command with a deadline.
///
/// Every elevation path in the app needs this. `sudo` and `networksetup` can
/// both block on a system dialog, and the previous code waited for them with no
/// bound at all: `waitUntilExit()` in one place and a bare `semaphore.wait()` in
/// another. Unbounded waits turn "the user stepped away" into "the app is hung
/// and there is a root process nobody can signal".
public protocol BoundedProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult
}

/// `Process`-backed runner. Meant for commands whose output is small (a probe,
/// `ps`): it collects the pipes after the child exits, so a command that fills a
/// pipe buffer would deadlock. Nothing here is asked to.
public struct SystemBoundedProcessRunner: BoundedProcessRunning {
    /// How long a killed child is given to be reaped before `SIGKILL`.
    public static let reapGrace: TimeInterval = 2

    public init() {}

    public func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Never let the child wait on a read that will not come: a command that
        // cannot prompt is a command that cannot hang on a prompt.
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed(error.localizedDescription)
        }
        // The child holds its own descriptors; closing ours is what lets the
        // reads below see EOF rather than block forever on a pipe we still hold.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

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

/// Asks `sudo` whether its timestamp is already valid, without ever prompting.
///
/// `sudo -n -v` succeeds exactly when a previous authentication is still within
/// its timeout, and fails immediately (no dialog, no read) when it is not. That
/// makes it the one safe way to find out whether the connect will need to ask
/// for anything — which decides `ElevationStrategy`.
public enum SudoProbe {
    public static let executable = URL(fileURLWithPath: "/usr/bin/sudo")
    public static let arguments = ["-n", "-v"]
    /// A warm timestamp answers in milliseconds; a cold one fails immediately.
    /// The bound only exists so a wedged `sudo` cannot hold up the connect.
    public static let timeout: TimeInterval = 3

    public static func isTimestampWarm(
        using runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) -> Bool {
        guard let result = try? runner.run(executable: executable, arguments: arguments, timeout: timeout) else {
            return false
        }
        return !result.timedOut && result.terminationStatus == 0
    }
}
