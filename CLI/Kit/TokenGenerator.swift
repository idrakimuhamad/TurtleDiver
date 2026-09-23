import Foundation
import TurtleDiverSystem

/// Runs a command with a modified environment and a deadline.
///
/// `SystemBoundedProcessRunner` is the right runner for a probe, but it gives the
/// child no way to add `STOKEN_RC`, and stoken needs that variable to find its
/// configuration when no token file is configured. Keeping the environment-aware
/// runner here — and its protocol separate — means the token step can be tested
/// with a fake instead of a real `~/.stokenrc`.
public protocol EnvironmentProcessRunning: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> BoundedProcessResult
}

public struct SystemEnvironmentProcessRunner: EnvironmentProcessRunning {
    public static let reapGrace: TimeInterval = 2

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        timeout: TimeInterval
    ) throws -> BoundedProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            throw BoundedProcessError.launchFailed(error.localizedDescription)
        }
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

/// The one-time code, from `stoken`.
///
/// A copy of the app's step in `VPNManager.generateToken`, reduced to the two
/// shapes that matter here: a token file, or a `.stokenrc`. The combined PIN the
/// server expects is the static passcode prepended to the code — stoken returns
/// only the code — which is why the passcode is an input to `combine`, not
/// something this type invents.
public struct TokenGenerator {
    /// The resolved inputs, so `command` is pure and a test can pin the argv.
    public struct Plan: Equatable {
        /// The resolved `stoken`, or nil to run it through `/usr/bin/env`.
        public let stokenPath: String?
        public let tokenFilePath: String
        public let rcPath: String
        /// `~/.stokenrc`, read only when nothing else is configured. Empty means
        /// there is none to fall back to.
        public let homeRCPath: String
        public let passcode: String

        public init(
            stokenPath: String?,
            tokenFilePath: String,
            rcPath: String,
            homeRCPath: String,
            passcode: String
        ) {
            self.stokenPath = stokenPath
            self.tokenFilePath = tokenFilePath
            self.rcPath = rcPath
            self.homeRCPath = homeRCPath
            self.passcode = passcode
        }
    }

    public struct Command: Equatable {
        public let executable: String
        public let arguments: [String]
        public let environment: [String: String]?
    }

    private let runner: any EnvironmentProcessRunning
    public static let timeout: TimeInterval = 20

    public init(runner: any EnvironmentProcessRunning = SystemEnvironmentProcessRunner()) {
        self.runner = runner
    }

    /// The argv and environment, with no process started. This is the part worth
    /// a test: `--next`, `--file`, and `-p` interact, and getting the order wrong
    /// produces a code that is merely incorrect rather than obviously broken.
    public static func command(for plan: Plan) -> Command {
        var arguments = plan.stokenPath != nil ? ["tokencode"] : ["stoken", "tokencode"]
        if !plan.tokenFilePath.isEmpty {
            arguments.append(contentsOf: ["--file", plan.tokenFilePath])
        }
        if !plan.passcode.isEmpty {
            arguments.append(contentsOf: ["-p", plan.passcode])
        }

        // `STOKEN_RC` is only consulted when there is no token file: with one,
        // the file is the whole configuration, and setting the variable too
        // would let a stale `.stokenrc` override it.
        var environment: [String: String]?
        if plan.tokenFilePath.isEmpty {
            if !plan.rcPath.isEmpty {
                environment = ["STOKEN_RC": plan.rcPath]
            } else if !plan.homeRCPath.isEmpty {
                environment = ["STOKEN_RC": plan.homeRCPath]
            }
        }

        return Command(
            executable: plan.stokenPath ?? "/usr/bin/env",
            arguments: arguments,
            environment: environment
        )
    }

    /// The code, or a `CLIFailure` naming what went wrong.
    public func generate(for plan: Plan) throws -> String {
        let command = Self.command(for: plan)
        let result: BoundedProcessResult
        do {
            result = try runner.run(
                executable: URL(fileURLWithPath: command.executable),
                arguments: command.arguments,
                environment: command.environment,
                timeout: Self.timeout
            )
        } catch {
            throw CLIFailure(
                .missingTool,
                "could not run stoken: \(error.localizedDescription)",
                details: ["tool": "stoken"]
            )
        }

        guard !result.timedOut else {
            throw CLIFailure(.timedOut, "stoken did not produce a code within \(Int(Self.timeout))s")
        }
        let code = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // stoken writes diagnostics to stdout in some builds, so an empty or
        // multi-line answer is a refusal, not a code.
        guard result.terminationStatus == 0, !code.isEmpty, !code.contains("\n") else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIFailure(
                .failure,
                "stoken exited \(result.terminationStatus) without a code"
                    + (detail.isEmpty ? "" : ": \(detail)"),
                details: ["tool": "stoken"]
            )
        }
        return code
    }

    /// The PIN the server expects: the static passcode, then the code.
    public static func combine(passcode: String, code: String) -> String {
        passcode + code
    }
}
