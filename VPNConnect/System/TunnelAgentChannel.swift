import Foundation

/// The app's half of the agent channel: what the agent says, whether the agent
/// can be trusted, and the argv that starts it.
///
/// The agent itself is `Agent/main.swift`; the rules are in
/// `TunnelAgentProtocol.swift`. This file is the app side — deliberately split
/// into three pure pieces so that the parts which decide *whether* to run
/// something as root are testable with no privilege and no running agent:
///
/// * `Decoder` turns the agent's stdout into events. It never echoes what it
///   read: the only text that can reach the app's log from this channel is a
///   word the protocol defines, because a channel that logs whatever arrives is
///   a channel someone else can write into.
/// * `Verifier` answers "is the file at that path ours, and is it root-owned?"
///   The agent is exec'd as root, so this is the check that decides whether the
///   app is willing to do that. It is the same check the installer makes before
///   and after it installs — see `packaging/install-agent.sh`.
/// * `Launch` builds the argv. Nothing here is secret: the credentials travel on
///   the channel, so argv carries paths and options only. That is the whole
///   reason the agent exists in this shape.
public enum TunnelAgentChannel {

    /// Something the agent said.
    ///
    /// Every case is a word from `TunnelAgentWord`. A pid is only accepted when
    /// it is a pid the app could act on (`> 1`) — a `supervising 0` would become
    /// a record that could later reach `kill`, and the app refuses those in two
    /// other places already.
    public enum Event: Equatable, Sendable {
        case supervising(Int32)
        case stopped(Int32)
        case killed(Int32)
        case stubborn(Int32)
        /// The agent saw end of input: the app is gone and the tunnel ends with
        /// it. Written by the agent as it shuts down, so the app may never read
        /// it at all.
        case peerGone
        /// The tunnel is gone and the channel is finished.
        case finished
        /// One of the `refused-*` words. The tunnel, if any, was left alone.
        case refused(String)
        /// A line that is not a word in this protocol, with how many bytes it
        /// was. The bytes themselves are not carried — an unrecognised line is
        /// the one thing on this channel the app cannot attribute to itself.
        case unrecognised(Int)
    }

    /// Decodes the agent's standard output, a chunk at a time.
    ///
    /// Line buffered rather than chunk buffered: a read can split a word in half,
    /// and matching on partial input would either miss a word or invent one.
    /// Matching is on the *whole* line with nothing stripped, so `stopped\r` is
    /// not a stop — the same discipline the agent applies to the verb it accepts,
    /// for the same reason.
    public struct Decoder {
        /// The most bytes kept for one line. A line longer than this cannot be a
        /// word (the longest is a prefix plus a pid), so the rest is discarded and
        /// the line is reported unrecognised.
        public static let lineLimit = TunnelAgent.maximumLineBytes

        private var current: [UInt8] = []
        private var discarding = false
        private var discarded = 0

        public init() {}

        public mutating func consume(_ data: Data) -> [Event] {
            var events: [Event] = []
            for byte in data {
                if discarding {
                    // Over the limit. The bytes are counted and dropped, not
                    // kept: the write end of this pipe is a process the app does
                    // not own, and a buffer that grows to whatever arrives lets
                    // it decide how much memory the app uses. Appending here
                    // would keep doing exactly that — the array is only cleared
                    // when the line ends.
                    if byte == 0x0A { events.append(finishLine()) } else { discarded += 1 }
                    continue
                }
                current.append(byte)
                if byte == 0x0A {
                    events.append(finishLine())
                    continue
                }
                if current.count > Self.lineLimit {
                    // Keep counting so the report is honest about how much
                    // arrived, and stop storing it.
                    discarding = true
                    current.removeAll()
                    discarded = Self.lineLimit + 1
                }
            }
            return events
        }

        /// A line that never got its newline is not delivered: end of input is
        /// the agent's exit, and the app reads the channel as a stream of
        /// newline-terminated words. `TunnelAgentProcessTests` pins the agent's
        /// half of that — it writes a newline with every word.
        private mutating func finishLine() -> Event {
            defer {
                current.removeAll()
                discarding = false
                discarded = 0
            }
            if discarding { return .unrecognised(discarded) }
            current.removeLast()
            let line = String(decoding: current, as: UTF8.self)
            return Self.decode(line)
        }

        static func decode(_ line: String) -> Event {
            switch line {
            case TunnelAgentWord.peerGone: return .peerGone
            case TunnelAgentWord.finished: return .finished
            case TunnelAgentWord.refused,
                 TunnelAgentWord.refusedStart,
                 TunnelAgentWord.refusedUsage,
                 TunnelAgentWord.refusedCommand,
                 TunnelAgentWord.credentialsTruncated:
                return .refused(line)
            default: break
            }
            if let pid = pid(after: TunnelAgentWord.supervisingPrefix, in: line) { return .supervising(pid) }
            if let pid = pid(after: TunnelAgentWord.stoppedPrefix, in: line) { return .stopped(pid) }
            if let pid = pid(after: TunnelAgentWord.killedPrefix, in: line) { return .killed(pid) }
            if let pid = pid(after: TunnelAgentWord.stubbornPrefix, in: line) { return .stubborn(pid) }
            return .unrecognised(line.utf8.count)
        }

        private static func pid(after prefix: String, in line: String) -> Int32? {
            guard line.hasPrefix(prefix) else { return nil }
            guard let pid = Int32(line.dropFirst(prefix.count)), pid > 1 else { return nil }
            return pid
        }
    }

    /// Whether the agent may be run as root.
    public enum Availability: Equatable, Sendable {
        case ready
        /// Nothing at the path. The drag-to-Applications case: not an error, and
        /// the app uses the elevation path it has always used.
        case notInstalled
        /// Something is there and the app will not run it as root. Carries a
        /// reason safe to show a user — no path from someone else's home, no
        /// secret, and never the contents of the file.
        case refused(String)

        public var isReady: Bool { self == .ready }
    }

    /// The check that stands between a path and running it as root.
    ///
    /// It is deliberately *not* a check that the file is the app's own build:
    /// any agent signed for this team is accepted, exactly as any app update
    /// signed for this team is. What it refuses is something else entirely
    /// sitting at a root-owned path.
    ///
    /// The path is root-owned and mode 0755, so the user cannot swap the file
    /// between this check and the exec; only root can, and root needs no help.
    public enum Verifier {
        /// `codesign` on a small binary takes milliseconds. The bound exists
        /// because "milliseconds" is a measurement, not a guarantee.
        public static let timeout: TimeInterval = 5

        public static func check(
            path: String = TunnelAgent.installedPath,
            expectedTeam: String = AppIdentity.updateTeamIdentifier,
            expectedOwner: String = "root",
            fileManager: FileManager = .default,
            runner: BoundedProcessRunning = SystemBoundedProcessRunner()
        ) -> Availability {
            guard fileManager.isExecutableFile(atPath: path) else { return .notInstalled }

            let owner = (try? fileManager.attributesOfItem(atPath: path))?[.ownerAccountName] as? String
            guard owner == expectedOwner else {
                return .refused("the agent at \(path) is owned by '\(owner ?? "nobody")', not \(expectedOwner)")
            }

            guard case .success = run(["--verify", "--strict", path], runner: runner) else {
                return .refused("the agent at \(path) does not have a valid code signature")
            }

            // Everything `-d` prints goes to stderr, including the fields below.
            let details = run(["-dv", "--verbose=2", path], runner: runner)
            guard case .success(let text) = details else {
                return .refused("the agent's code signature could not be read")
            }
            guard let team = field("TeamIdentifier", in: text), team == expectedTeam else {
                let found = field("TeamIdentifier", in: text) ?? "none"
                return .refused("the agent is signed for team '\(found)', not \(expectedTeam)")
            }
            guard field("Identifier", in: text) == TunnelAgent.executableName else {
                let found = field("Identifier", in: text) ?? "none"
                return .refused("the file at \(path) is signed as '\(found)', not \(TunnelAgent.executableName)")
            }
            return .ready
        }

        private static func run(_ arguments: [String], runner: BoundedProcessRunning)
            -> Result<String, BoundedProcessError> {
            do {
                let result = try runner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: arguments,
                    timeout: timeout
                )
                guard !result.timedOut, result.terminationStatus == 0 else {
                    return .failure(.launchFailed("codesign exited \(result.terminationStatus)"))
                }
                // stdout for `--verify`, stderr for `-d`; read both so the caller
                // does not have to know which.
                return .success(result.stdout + result.stderr)
            } catch let error as BoundedProcessError {
                return .failure(error)
            } catch {
                return .failure(.launchFailed(error.localizedDescription))
            }
        }

        private static func field(_ name: String, in text: String) -> String? {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let prefix = name + "="
                if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
            }
            return nil
        }
    }

    /// The argv that starts the agent, and the steps that must come first.
    ///
    /// There is no wrapper shell on this path, and that is the change that makes
    /// the prompt go away. `sudo` records its timestamp against the *parent*
    /// process when there is no terminal, so a connect that authenticates inside
    /// a per-connect shell warms that shell's record and never the app's. Here
    /// every `sudo` is a direct child of the app, so the one authentication at
    /// connect belongs to the app itself — and the agent it starts stays root for
    /// as long as the tunnel lasts.
    public enum Launch {
        /// What the agent forwards to openconnect's standard input. The PIN and
        /// the account password — the same two lines openconnect has always been
        /// given. The administrator password is *not* among them any more: on
        /// this path there is no `sudo -S` for openconnect to sit behind, so the
        /// connect stops carrying a credential it has no use for.
        public static let credentialLineCount = 2

        /// The agent, its own arguments, and then the tunnel's command line.
        ///
        /// The agent's path comes FIRST, before any of its flags, because this
        /// array is handed to `sudo` as its command line: `sudo` parses
        /// everything up to the command word as its own options, so an agent
        /// argument in that position is read as a `sudo` option and the whole
        /// launch dies with `sudo: unrecognized option '--credential-lines'`.
        /// That is what a live connect did before the path was put in front.
        ///
        /// The tunnel's arguments are passed through unchanged, including the
        /// `--pid-file` the agent path does not need: openconnect only writes
        /// that file when it backgrounds, which it never does, and keeping the
        /// two paths' arguments identical is worth more than removing an option
        /// that is already inert.
        public static func agentArguments(
            agentPath: String = TunnelAgent.installedPath,
            openconnectPath: String,
            tunnelArguments: [String],
            searchPath: String,
            credentialLines: Int = credentialLineCount
        ) -> [String] {
            [
                agentPath,
                "--credential-lines", String(credentialLines),
                "--path", searchPath,
                openconnectPath
            ] + tunnelArguments
        }

        /// The credential block the app writes down the channel, and the only
        /// thing it ever writes: the PIN and the account password, and no
        /// administrator password. That is what makes the channel safe to keep
        /// open for the life of a tunnel, and it is pinned by a test rather than
        /// by this comment.
        public static func credentialBlock(pin: String, vpnPassword: String) -> Data {
            Data((pin + "\n" + vpnPassword + "\n").utf8)
        }

        /// The one command the app ever writes after the credentials: the verb
        /// that ends the tunnel.
        ///
        /// Built here rather than spelled at the call site so the app and the
        /// agent's session agree on it by construction: the agent matches the
        /// line by exact equality, so a stray space or a `\r` would be a refusal,
        /// and a refusal leaves the tunnel running. A test pins the bytes.
        public static func stopRequest() -> Data {
            Data((TunnelAgent.stopVerb + "\n").utf8)
        }

        /// Marks one descriptor so that writing to a pipe whose far end has gone
        /// is an error the caller sees rather than a signal that kills the app.
        ///
        /// The channel is written to on a live tunnel's behalf, so its far end
        /// can be gone: the agent can exit between the check that it is running
        /// and the write. `EPIPE` is then a thrown error and a `.writeFailed` the
        /// log can explain; without this, it is `SIGPIPE` and the app dies with no
        /// message. It is a *descriptor* flag, not a process-wide one — the same
        /// thing `SO_NOSIGPIPE` does for the engine's sockets — so nothing else
        /// in the app changes behaviour. Returns whether the kernel accepted it.
        @discardableResult
        public static func ignoreBrokenPipe(on descriptor: Int32) -> Bool {
            fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0
        }

        /// `sudo -n` around the agent: the timestamp was warmed a moment ago, and
        /// `-n` means a cold one fails fast with an error instead of raising a
        /// dialog the user did not ask for. The agent's path must be the first
        /// element after those options — `sudo` reads what follows as its own
        /// flags until it meets a command word, so anything else here is refused
        /// by `sudo` before the agent ever runs.
        public static func sudoArguments(agentArguments: [String]) -> [String] {
            ["-n"] + agentArguments
        }

        /// `PATH` for the tunnel: the same directories the wrapper shell used to
        /// export, in front of whatever the app inherited.
        public static func searchPath(
            inherited: String?,
            defaults: String = OpenConnectCommand.defaultSearchPath
        ) -> String {
            guard let inherited, !inherited.isEmpty else { return defaults }
            return "\(defaults):\(inherited)"
        }

        /// The one authentication at connect, as a direct child of the app.
        ///
        /// * `.storedPassword` pipes the stored administrator password into
        ///   `sudo -S`, which is the unattended route on a Mac without `pam_tid`.
        /// * `.systemPrompt` runs `sudo -v` with its input set to `/dev/null`, so
        ///   the system's own Touch ID dialog answers it. Piping anything here is
        ///   the measured failure this branch exists to avoid: `pam_tid` never
        ///   reads the pipe, and the `sudo` blocks in the dialog forever.
        /// * `.neverPrompt` asks nobody and fails if the timestamp is cold.
        ///
        /// `delivery` overrides the pipe for the one door that does not use one:
        /// `.askpass` runs `sudo -A`, which starts the program named in
        /// `SUDO_ASKPASS` and reads the password from its standard output. That is
        /// how a password can reach a Mac whose `pam_tid` would swallow a pipe —
        /// the module stands its own dialog down in askpass mode — and the caller
        /// has to have a helper to point at, which is why the path travels with
        /// the arguments rather than being spelled here.
        public static func warmupArguments(
            _ strategy: ElevationStrategy,
            delivery: SudoPasswordDelivery = .standardInput
        ) -> [String] {
            if delivery == .askpass { return ["-A", "-v"] }
            switch strategy {
            case .storedPassword: return ["-S", "-v"]
            case .systemPrompt: return ["-v"]
            case .neverPrompt: return ["-n", "-v"]
            }
        }

        /// The variable `sudo` reads the askpass program's path from, spelled once
        /// for the whole project — the CLI, the app and the helper itself all name
        /// it through `AskpassProgram`.
        public static let askpassVariable = AskpassProgram.environmentVariable

        /// The environment for a child that authenticates through the askpass
        /// helper: the helper's *path*, and nothing else. The password is printed
        /// by the helper, so it is not in this child's environment either — a
        /// value there is readable by any process of this user (`ps -E`).
        public static func askpassEnvironment(helperPath: String) -> [String: String] {
            [askpassVariable: helperPath]
        }

        /// The bytes for the warm-up's standard input. Empty means the caller
        /// must connect it to `/dev/null` rather than to a pipe it never writes:
        /// an empty pipe is not the same thing as no input.
        public static func warmupInput(_ strategy: ElevationStrategy, adminPassword: String) -> Data {
            guard strategy.pipesTheStoredPassword else { return Data() }
            return Data((adminPassword + "\n").utf8)
        }

        /// The stale-route cleanup, as a direct child of the app now that the
        /// timestamp is warm — the same `sed` the launch script used to run
        /// inside its own process group. `-i` takes its suffix as a separate
        /// argument on BSD sed, which is why there is an empty one.
        ///
        /// Nothing here is fatal: a stale entry that cannot be cleaned is not a
        /// reason to refuse to connect, which is also why the script sent this
        /// step's stderr to `/dev/null`.
        public static let hostsCleanupArguments = [
            "-n", "/usr/bin/sed", "-i", "", "/# vpn-slice-/d", "/etc/hosts"
        ]
    }

    /// What an agent refusal means to the user.
    ///
    /// The agent's refusals are all "the app asked for something the protocol
    /// does not allow", which means a bug or a binary that is not this app's —
    /// either way the user gets a name and a remedy rather than `status 4`.
    public struct Diagnosis: Equatable, Sendable {
        public let historyStatus: String
        public let detail: String

        public init(historyStatus: String, detail: String) {
            self.historyStatus = historyStatus
            self.detail = detail
        }
    }

    /// The refusal word, as a diagnosis. An unrecognised refusal still gets one:
    /// the app never shows nothing when it has been told something.
    public static func diagnosis(forRefusal word: String) -> Diagnosis {
        switch word {
        case TunnelAgentWord.credentialsTruncated:
            return Diagnosis(
                historyStatus: "Failed - Agent Lost Credentials",
                detail: "The tunnel agent reached the end of its input before all of the credentials arrived,"
                    + " so it never started a tunnel. Connect again."
            )
        case TunnelAgentWord.refusedStart:
            return Diagnosis(
                historyStatus: "Failed - Agent Could Not Start Tunnel",
                detail: "The tunnel agent could not start openconnect. Check that openconnect is still installed."
            )
        case TunnelAgentWord.refusedUsage, TunnelAgentWord.refusedCommand:
            return Diagnosis(
                historyStatus: "Failed - Agent Rejected Launch",
                detail: "The tunnel agent refused the launch it was given, which means the installed agent and"
                    + " this app disagree about the protocol. Reinstall the agent."
            )
        default:
            return Diagnosis(
                historyStatus: "Failed - Agent Refused",
                detail: "The tunnel agent refused the launch it was given. Reinstall the agent."
            )
        }
    }

    /// Runs one `sudo` step as a direct child of the app, with a deadline.
    ///
    /// Deliberately not `SystemBoundedProcessRunner`. That type connects the
    /// child's standard input to `/dev/null` unconditionally, on the principle
    /// that a command which cannot prompt cannot hang on a prompt — and that is
    /// exactly right for a probe. The warm-up is not a probe: in
    /// `.storedPassword` mode the one thing it has to do is write a password into
    /// the child. Keeping the credential-carrying step in its own type is what
    /// lets it be tested on its own, including the bound on the case that waits
    /// for a dialog nobody answers.
    ///
    /// `stdin` is a parameter, not a property, so a caller cannot leave a
    /// password sitting in a runner that outlives the step.
    public struct SudoStepRunner: Sendable {
        public struct Result: Equatable, Sendable {
            public let terminationStatus: Int32
            /// True when the deadline expired and the child had to be signalled.
            /// The status is then meaningless — check this first.
            public let timedOut: Bool
            /// Set when the child could not be started at all.
            public let launchError: String?
            /// Whatever the child said. Small, and never a credential: `sudo`
            /// writes its prompts to the terminal, which a pipe is not.
            public let stderr: String

            public init(terminationStatus: Int32, timedOut: Bool, launchError: String?, stderr: String) {
                self.terminationStatus = terminationStatus
                self.timedOut = timedOut
                self.launchError = launchError
                self.stderr = stderr
            }

            public var succeeded: Bool { launchError == nil && !timedOut && terminationStatus == 0 }
        }

        public static let defaultExecutable = "/usr/bin/sudo"
        /// The program a step runs. `sudo` in production, and injectable because
        /// the property that makes this type worth having — that a step which
        /// never returns is signalled and reaped — is only worth having if it can
        /// be tested without a dialog.
        public let executable: String
        /// How long a signalled child is given to be reaped before `SIGKILL`.
        /// A `sudo` blocked in a dialog answers `SIGTERM`; this is for the one
        /// that does not.
        public static let reapGrace: TimeInterval = 2

        public init(executable: String = SudoStepRunner.defaultExecutable) {
            self.executable = executable
        }

        public func run(
            arguments: [String],
            stdin: Data?,
            timeout: TimeInterval,
            environment: [String: String] = [:]
        ) -> Result {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // Merged, never replaced: `sudo` is being given one extra fact (the
            // askpass helper's path) and must keep everything else it inherited,
            // `PATH` and the rest of `sudo`'s own inputs among them.
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(environment) { _, added in added }
            }

            let err = Pipe()
            process.standardError = err
            // No input means no pipe: `sudo -v` with a pipe that is never
            // written is not the same thing as `sudo -v </dev/null`, and the
            // measurement that matters is that the dialog still appears.
            let inputPipe: Pipe?
            if stdin != nil {
                inputPipe = Pipe()
                process.standardInput = inputPipe
            } else {
                inputPipe = nil
                process.standardInput = FileHandle.nullDevice
            }

            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }

            do {
                try process.run()
            } catch {
                return Result(terminationStatus: -1, timedOut: false,
                              launchError: error.localizedDescription, stderr: "")
            }
            try? err.fileHandleForWriting.close()

            if let stdin, let inputPipe {
                try? inputPipe.fileHandleForWriting.write(contentsOf: stdin)
                // Closed so `sudo -S` stops reading after the one line it wants,
                // and so a failed read fails instead of waiting on a writer that
                // will never write again.
                try? inputPipe.fileHandleForWriting.close()
            }

            var timedOut = false
            if finished.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if finished.wait(timeout: .now() + Self.reapGrace) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = finished.wait(timeout: .now() + Self.reapGrace)
                }
            }

            return Result(
                terminationStatus: timedOut ? -1 : process.terminationStatus,
                timedOut: timedOut,
                launchError: nil,
                stderr: String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            )
        }
    }
}
