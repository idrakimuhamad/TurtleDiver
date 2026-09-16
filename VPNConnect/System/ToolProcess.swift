import Foundation

// MARK: - Result

/// How a child process ended.
public struct ToolProcessResult: Equatable, Sendable {
    /// The exit status, or `-1` when the process could not be started at all.
    public let status: Int32
    /// Everything the process printed (stdout and stderr interleaved), capped.
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }

    public var succeeded: Bool { status == 0 }

    /// The last non-empty line — what a failed `brew install` puts its error on.
    public var lastLine: String {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}

// MARK: - Runner

/// Runs a child process. A protocol so the doctor and the installer can be
/// tested without spawning anything.
public protocol ToolProcessRunning: Sendable {
    /// Runs to completion. `onLine` receives complete output lines as they
    /// arrive (used to stream an install into the pane); `nil` collects only.
    func run(executable: String,
             arguments: [String],
             environment: [String: String]?,
             onLine: (@Sendable (String) -> Void)?) async -> ToolProcessResult
}

/// The real thing: `Process` with both pipes read as they arrive.
public struct SystemToolProcessRunner: ToolProcessRunning {

    public init() {}

    public func run(executable: String,
                    arguments: [String],
                    environment: [String: String]?,
                    onLine: (@Sendable (String) -> Void)?) async -> ToolProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return ToolProcessResult(status: -1, output: "\(executable) is not executable")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = ToolOutputCollector(onLine: onLine)

        return await withCheckedContinuation { continuation in
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                collector.append(handle.availableData)
            }
            process.terminationHandler = { finished in
                // Stop the handlers before the final drain, or the last chunk
                // can arrive twice.
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                collector.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                collector.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let text = collector.finish()
                continuation.resume(returning: ToolProcessResult(status: finished.terminationStatus,
                                                                 output: text))
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(returning: ToolProcessResult(status: -1,
                                                                 output: "could not run \(executable): \(error.localizedDescription)"))
            }
        }
    }
}

/// Splits a byte stream into lines as it arrives and keeps a bounded copy of
/// everything. Pure and synchronous; the runner's pipe handlers are the only
/// callers, from two queues at once, hence the lock.
final class ToolOutputCollector: @unchecked Sendable {

    /// Enough for a full `brew install` transcript; a pathological tool cannot
    /// grow the app's memory without bound.
    static let retainedLimit = 256 * 1024
    /// A single line, trimmed. Progress bars can emit megabytes on one "line".
    static let lineLimit = 4000

    private let lock = NSLock()
    private var buffer = ""
    private var retained = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        append(text)
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        buffer += text
        let lines = ToolLineSplitter.takeCompleteLines(&buffer)
        for line in lines { store(line) }
        // Emitted while the lock is held so the two pipe readers cannot deliver
        // a later line before an earlier one.
        for line in lines { onLine?(line) }
        lock.unlock()
    }

    /// Emits whatever is left and returns the collected output.
    func finish() -> String {
        lock.lock()
        defer { lock.unlock() }
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        if !rest.isEmpty {
            let line = String(rest.prefix(Self.lineLimit))
            store(line)
            onLine?(line)
        }
        return retained
    }

    private func store(_ line: String) {
        if !retained.isEmpty { retained += "\n" }
        retained += line
        if retained.count > Self.retainedLimit {
            retained = String(retained.suffix(Self.retainedLimit))
        }
    }
}

/// Turns a growing buffer into complete lines, tolerating `\r` and `\r\n`
/// (progress output uses carriage returns).
enum ToolLineSplitter {

    static func takeCompleteLines(_ buffer: inout String) -> [String] {
        var lines: [String] = []
        var current = ""
        var remainder = buffer.endIndex

        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)

            if character == "\n" || character == "\r\n" {
                lines.append(current)
                current = ""
                index = next
                continue
            }
            if character == "\r" {
                // Note: Swift folds a CRLF pair into one `Character`, so the
                // only ambiguity left is a CR at the very end of what has been
                // read — that may be the first half of a CRLF the next read
                // completes. Hold it back rather than emitting a line now and a
                // bogus empty one when the LF turns up.
                if next == buffer.endIndex {
                    remainder = index
                    break
                }
                lines.append(current)
                current = ""
                index = next
                continue
            }
            current.append(character)
            index = next
        }

        buffer = String(current) + (remainder == buffer.endIndex ? "" : String(buffer[remainder...]))
        return lines.map { String($0.prefix(ToolOutputCollector.lineLimit)) }
    }
}

// MARK: - Location

/// Finds an executable by name. A protocol so the doctor's answers can be
/// scripted in tests instead of depending on what this machine has installed.
public protocol ToolLocating: Sendable {
    func locate(_ name: String) -> String?
}

/// The real locator: `$PATH` first, then the known prefixes.
public struct SystemToolLocator: ToolLocating {

    public let environment: [String: String]
    public let home: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                home: String = NSHomeDirectory()) {
        self.environment = environment
        self.home = home
    }

    public func locate(_ name: String) -> String? {
        ToolResolver.locate(name, environment: environment, home: home)
    }
}

// MARK: - Doctor

/// Asks the machine what is installed.
public struct ToolDoctor: Sendable {

    public let requirements: [ToolRequirement]
    public let locator: ToolLocating
    public let runner: ToolProcessRunning

    public init(requirements: [ToolRequirement] = ToolRequirement.all,
                locator: ToolLocating = SystemToolLocator(),
                runner: ToolProcessRunning = SystemToolProcessRunner()) {
        self.requirements = requirements
        self.locator = locator
        self.runner = runner
    }

    public init(requirements: [ToolRequirement] = ToolRequirement.all,
                environment: [String: String],
                home: String = NSHomeDirectory(),
                runner: ToolProcessRunning = SystemToolProcessRunner()) {
        self.init(requirements: requirements,
                  locator: SystemToolLocator(environment: environment, home: home),
                  runner: runner)
    }

    public func inspect() async -> [ToolStatus] {
        var statuses: [ToolStatus] = []
        for requirement in requirements {
            statuses.append(await inspect(requirement))
        }
        return statuses
    }

    /// Resolves the tool, and — only if it was found — runs it for a version.
    public func inspect(_ requirement: ToolRequirement) async -> ToolStatus {
        guard let path = locator.locate(requirement.id) else {
            return ToolStatus(requirement: requirement, path: nil, version: nil)
        }
        let result = await runner.run(executable: path,
                                      arguments: requirement.versionArguments,
                                      environment: nil,
                                      onLine: nil)
        let version = result.succeeded ? ToolVersion.parse(result.output) : nil
        return ToolStatus(requirement: requirement, path: path, version: version)
    }

    /// Everything a connect needs that is not installed. Empty means ready.
    public func missing(forConnection splitTunneling: Bool) -> [ToolRequirement] {
        ToolPreflight.missing(splitTunneling: splitTunneling) { locator.locate($0) }
    }
}

// MARK: - Install

/// The exact command an install runs.
public struct ToolInstallCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    /// "brew install openconnect stoken" — what the pane offers to copy.
    public var commandLine: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

/// Builds and runs `brew install …`.
///
/// Always as the user, never through `sudo`: these formulae ship as bottles, and
/// an installer that escalates privileges to edit a user's toolchain is a worse
/// problem than the missing tool. Homebrew may itself ask for a password when a
/// formula needs it, which is Homebrew's business and not ours — we never pass
/// one along.
public struct ToolInstaller: Sendable {

    public let runner: ToolProcessRunning

    public init(runner: ToolProcessRunning = SystemToolProcessRunner()) {
        self.runner = runner
    }

    /// The pure part: which formulae, which binary, which environment.
    ///
    /// Returns `nil` when there is nothing to install (every requirement is
    /// Homebrew itself or already covered), so a no-op cannot accidentally
    /// become `brew install` with no arguments.
    public static func plan(for requirements: [ToolRequirement],
                            brewPath: String,
                            environment: [String: String]) -> ToolInstallCommand? {
        let formulas = requirements.compactMap(\.formula)
        guard !formulas.isEmpty else { return nil }

        // Homebrew's own directory goes on PATH for the tools it spawns while
        // building, and the hint block (which only ever tells the user to read
        // about environment variables) is noise in a pane.
        var child = environment
        let brewDirectory = ToolResolver.homebrewDirectory(brewPath: brewPath)
        let existing = child["PATH"] ?? ""
        child["PATH"] = existing.isEmpty ? brewDirectory : "\(brewDirectory):\(existing)"
        child["HOMEBREW_NO_ENV_HINTS"] = "1"

        return ToolInstallCommand(executable: brewPath,
                                  arguments: ["install"] + formulas,
                                  environment: child)
    }

    /// Runs the install, streaming output. Homebrew exits non-zero on failure
    /// and says why in its own output, which the caller shows.
    @discardableResult
    public func install(_ requirements: [ToolRequirement],
                        brewPath: String,
                        environment: [String: String] = ProcessInfo.processInfo.environment,
                        onLine: (@Sendable (String) -> Void)? = nil) async -> ToolProcessResult {
        guard let plan = Self.plan(for: requirements, brewPath: brewPath, environment: environment) else {
            return ToolProcessResult(status: 0, output: "nothing to install")
        }
        return await runner.run(executable: plan.executable,
                                arguments: plan.arguments,
                                environment: plan.environment,
                                onLine: onLine)
    }
}
