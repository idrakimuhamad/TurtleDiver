import Foundation
import Cocoa
import Combine
#if canImport(TurtleDiverSystem)
// The openconnect launch plan and PID-file paths live in the System module in
// the SPM test harness (VPNConnect/System/OpenConnectLaunch.swift). In the app
// target everything is one module, so the import is guarded away.
import TurtleDiverSystem
#endif

// MARK: - Subprocess support

/// A reference type wrapper around Data that is explicitly Sendable, allowing
/// it to be captured in `@Sendable` closures for Swift 6 concurrency checking.
final class SendableDataBuffer: @unchecked Sendable {
    var data = Data()
    func append(_ other: Data) { data.append(other) }
}

/// Failure of an `openconnect`/`stoken` subprocess.
enum ProcessError: LocalizedError {
    case exitStatus(Int32, String)

    var errorDescription: String? {
        switch self {
        case .exitStatus(let code, let stderr):
            return "Process exited with code \(code): \(stderr)"
        }
    }
}

// MARK: - Connection Log File

/// Writes a detailed, timestamped trace of the VPN connection I/O to a file.
/// Use this to debug credential flow issues that are not visible in the UI debug panel.
final class VpnConnectionLogger: @unchecked Sendable {
    /// Connection log. Under `~/Library/Logs` (where Console.app picks it up)
    /// rather than a predictable `/tmp` name, and created owner-only: it holds
    /// the (redacted) credential lines and raw openconnect output.
    static var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TurtleDiver", isDirectory: true)
            .appendingPathComponent("vpn.log")
            .path
    }
    
    private let path: String
    private let queue = DispatchQueue(label: "com.turtlediver.vpn-log", qos: .utility)
    private var fileHandle: FileHandle?
    
    init(path: String = VpnConnectionLogger.logPath) {
        self.path = path
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Truncate the log file on each connection
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)
        // ...and tighten the mode even if an older build left it world-readable.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        if let handle = FileHandle(forWritingAtPath: path) {
            fileHandle = handle
        }
        write("=== VPN Connection Log ===")
    }
    
    deinit {
        fileHandle?.closeFile()
    }
    
    func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async { [weak self] in
            guard let handle = self?.fileHandle else { return }
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
        }
    }
    
    /// Logs raw data from an openconnect stream (stdout or stderr).
    func logStream(_ stream: String, data: Data) {
        guard !data.isEmpty else { return }
        if let text = String(data: data, encoding: .utf8) {
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                write("[\(stream)] \(line)")
            }
        } else {
            write("[\(stream)] <binary data: \(data.count) bytes>")
        }
    }
    
    /// Logs a credential being written to the input pipe (redacted for security).
    func logSend(_ label: String, value: String? = nil) {
        if let val = value, !val.isEmpty {
            write("[SEND] \(label): \(String(repeating: "•", count: val.count)) (\(val.count) chars)")
        } else if let val = value {
            write("[SEND] \(label): <empty>")
        } else {
            write("[SEND] \(label)")
        }
    }
    
    func logHandler(_ handler: String, action: String) {
        write("[HANDLER] \(handler): \(action)")
    }
    
    func flush() {
        queue.sync {
            fileHandle?.synchronizeFile()
        }
    }
}

// Import the connection history types
struct ConnectionAttempt: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let host: String
    let status: String
    let duration: TimeInterval?
    let logOutput: String
    
    init(id: UUID = UUID(), timestamp: Date = Date(), host: String, status: String, duration: TimeInterval? = nil, logOutput: String) {
        self.id = id
        self.timestamp = timestamp
        self.host = host
        self.status = status
        self.duration = duration
        self.logOutput = logOutput
    }
}

class ConnectionHistoryManager {
    static let shared = ConnectionHistoryManager()
    
    private let historyKey = "VPNConnectConnectionHistory"
    private let maxHistoryItems = 100
    
    private init() {}
    
    func getHistory() -> [ConnectionAttempt] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let history = try? JSONDecoder().decode([ConnectionAttempt].self, from: data) else {
            return []
        }
        return history.sorted { $0.timestamp > $1.timestamp }
    }
    
    func addAttempt(_ attempt: ConnectionAttempt) {
        var history = getHistory()
        history.insert(attempt, at: 0)
        
        if history.count > maxHistoryItems {
            history = Array(history.prefix(maxHistoryItems))
        }
        
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: historyKey)
            UserDefaults.standard.synchronize()
        }
    }
    
    func updateAttempt(_ attempt: ConnectionAttempt) {
        var history = getHistory()
        if let index = history.firstIndex(where: { $0.id == attempt.id }) {
            history[index] = attempt
            
            if let encoded = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(encoded, forKey: historyKey)
                UserDefaults.standard.synchronize()
            }
        } else {
            addAttempt(attempt)
        }
    }
    
    func deleteAttempt(id: UUID) {
        var history = getHistory()
        history.removeAll { $0.id == id }
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: historyKey)
            UserDefaults.standard.synchronize()
        }
    }
    
    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
}

enum VPNStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error(String)

    /// Whether a connect may start from here.
    ///
    /// `.error` is deliberately included. The main window labels its action
    /// button "Reconnect" in that state and the menu bar item calls `connect()`
    /// too, so both affordances promise a retry — and the guard this replaces
    /// (`case .disconnected` only) accepted neither, returning silently and
    /// adding no log line and no history row. One failed connect therefore
    /// wedged the app until it was quit and relaunched: the state a failure
    /// leaves behind has to be a state a retry can start from.
    var isConnectable: Bool {
        switch self {
        case .disconnected, .error: return true
        case .connecting, .connected, .disconnecting: return false
        }
    }
}

class VPNManager: ObservableObject {
    static let shared = VPNManager()

    /// Whether this process adopts a tunnel it did not start, the first time the
    /// manager is created.
    ///
    /// False in a test host. Adoption is not a read: it records the pid, writes
    /// the user's own pid file and publishes `.connected`. From a test process
    /// that meant the suite adopted whatever `openconnect` happened to be
    /// running on the machine — writing the real run directory, and running the
    /// rule-set tests down a different path depending on it. The app adopts; a
    /// test does not.
    static let adoptsExistingConnectionsAtLaunch = !isTestHost

    /// XCTest sets `XCTestConfigurationFilePath` for the process it runs, and the
    /// XCTest framework is only linked into a test bundle. Either signal is
    /// enough; a test host is a test host.
    private static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
    
    @Published var status: VPNStatus = .disconnected
    @Published var debugOutput: String = ""
    @Published var durationString: String = "00:00:00"
    
    var onChallenge: ((String, @escaping (String) -> Void) -> Void)?
    
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var inputPipe: Pipe?
    private var connectionTimer: DispatchSourceTimer?

    /// How long a connect may stay in `.connecting` before it is treated as
    /// stuck. Named because the preflight message quotes it back to the user.
    private static let connectionTimeoutSeconds = 90

    /// How this attempt asks for privilege. Decided *before* the launch, from
    /// what `/etc/pam.d` and a bounded `sudo -n -v` say — this is what stops a
    /// password being piped into a `sudo` that will never read it, which is the
    /// whole bug: `pam_tid` answers first, the pipe is left full, and the
    /// `sudo` sits on a dialog nobody was told about.
    private var elevation: ElevationStrategy = .storedPassword
    /// Ends a tunnel this app raised as root. The connect path elevates, so the
    /// teardown has to be able to as well; see `ElevatedTermination`.
    let elevatedTerminator = ElevatedTerminator()

    /// Set when the launch script reported a named elevation failure. Matched
    /// exactly, so openconnect's own output cannot pass for one.
    private var elevationBlock: ElevationBlockReason?
    private var durationTimer: Timer?
    private var connectionStartTime: Date?
    private var errorBurst: Int = 0
    private var challengePending = false
    /// Tracks whether we have already sent credentials for the current
    /// prompt round, preventing duplicate writes when the server sends
    /// multiple "PASSCODE:" lines in the same batch.
    private var passcodePromptCount = 0
    /// Where openconnect records its PID. Computed rather than stored because
    /// it now depends on the user's Application Support directory — see
    /// `OpenConnectPidFile` for why it left `/tmp`.
    private var pidFilePath: String { OpenConnectPidFile.path.path }

    /// Reads a process's start time for the duration display. Bounded, because
    /// it means spawning `ps` on the main thread while adopting a tunnel.
    private let processStartTimeReader = ProcessStartTimeReader()
    private var currentAttemptId: UUID?
    
    /// Incremented on each `connect()` call so stale termination handlers
    /// from a previous connection can detect they should not act on state.
    private var connectionGeneration: UInt64 = 0
    
    /// Timer that polls for openconnect connection success via the PID file and
    /// a name-exact process scan.
    private var connectionPollTimer: DispatchSourceTimer?
    
    /// Flag set when the pipe write-end has been closed, preventing
    /// readability handlers from attempting writes after forceTerminate().
    private var pipeClosed = false
    
    private init() {
        // Check for existing openconnect process on launch — except from a test,
        // which would otherwise adopt the machine's own tunnel and write the
        // user's pid file. See `adoptsExistingConnectionsAtLaunch`.
        guard Self.adoptsExistingConnectionsAtLaunch else { return }
        DispatchQueue.main.async { [weak self] in
            self?.checkForExistingConnection()
        }
    }
    
    func connect() {
        guard status.isConnectable else { return }
        
        connectionGeneration += 1
        status = .connecting
        debugOutput = "Starting VPN connection...\n"
        errorBurst = 0
        challengePending = false
        passcodePromptCount = 0
        elevationBlock = nil
        
        let settings = SettingsManager.shared
        
        // Log attempt start
        let attemptId = UUID()
        currentAttemptId = attemptId
        connectionStartTime = Date()
        let attempt = ConnectionAttempt(
            id: attemptId,
            timestamp: connectionStartTime ?? Date(),
            host: settings.vpnHost.isEmpty ? "Unknown" : settings.vpnHost,
            status: "Connecting",
            logOutput: debugOutput
        )
        ConnectionHistoryManager.shared.addAttempt(attempt)
        
        // Validate settings
        guard !settings.vpnHost.isEmpty,
              !settings.vpnPassword.isEmpty,
              !settings.vpnID.isEmpty else {
            status = .error("Please configure all VPN settings")
            // Update attempt with failure
            if let id = currentAttemptId {
                let failedAttempt = ConnectionAttempt(
                    id: id,
                    timestamp: connectionStartTime ?? Date(),
                    host: settings.vpnHost.isEmpty ? "Unknown" : settings.vpnHost,
                    status: "Failed - Missing Settings",
                    logOutput: debugOutput
                )
                ConnectionHistoryManager.shared.updateAttempt(failedAttempt)
            }
            return
        }
        
        Task {
            await self.executeVPNConnection()
        }
    }
    
    func cleanupOnTermination() {
        // Log termination attempt first to ensure it's saved
        if let id = currentAttemptId {
            let attempt = ConnectionAttempt(
                id: id,
                timestamp: connectionStartTime ?? Date(),
                host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                status: "Terminated by App Exit",
                duration: connectionStartTime.map { Date().timeIntervalSince($0) },
                logOutput: debugOutput
            )
            ConnectionHistoryManager.shared.updateAttempt(attempt)
        }
        
        // Synchronous cleanup to ensure no processes are left behind
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        if let proc = process {
            if proc.isRunning {
                proc.terminate()
            }
        }
        
        // Gracefully terminate openconnect via the PID file (allows clean
        // network teardown) — but only when that pid is *verified* to be an
        // openconnect. The file is plain text in Application Support: a stale or
        // recycled pid in it used to be signalled here, and a missing file used
        // to fall back to a name-wide `pkill openconnect`.
        //
        // What this path deliberately does NOT do is resolve a missing record the
        // way `disconnect()` does (own process group, then a scan). It runs on the
        // main thread inside `applicationWillTerminate`, with a budget of seconds,
        // and it may not raise a dialog; a scan there could cost three seconds per
        // candidate and still end in a prompt. It does not have to: the launch and
        // adoption paths both record the pid, so a tunnel this app raised in this
        // run *has* a record by the time a quit can happen. A tunnel with no
        // record at all was launched by another build — the launch sweep of the
        // next run reaps its own group, and `disconnect()` can still be asked.
        if let pid = OpenConnectPidFile.recordedPid() {
            // Blocking call — this is called from applicationWillTerminate on the main thread,
            // but it's essential to give openconnect time to restore network settings before exit.
            // `mayPrompt: false` is the quit path's rule: a dialog that nothing
            // answers would hold the quit open and leave a blocked `sudo`
            // behind. Only `sudo -n` and a piped stored password are allowed.
            switch terminateGracefully(pid: pid, timeoutSeconds: 3, mayPrompt: false) {
            case .exitedCleanly:
                debugOutput += "openconnect exited cleanly on quit\n"
                OpenConnectPidFile.discard()
            case .forceKilled:
                debugOutput += "openconnect force-killed on quit (network may need manual restore)\n"
                OpenConnectPidFile.discard()
            case .endedWithElevation:
                debugOutput += "openconnect ended with elevation on quit\n"
                OpenConnectPidFile.discard()
            case .notPermitted:
                // An openconnect started through sudo is root-owned, so this user
                // cannot signal it, and the quit path may not put a dialog in
                // front of anybody. The process-group record is the handle on
                // that tunnel — it is *not* what ends it; the launch sweep
                // deliberately leaves a group that still holds an openconnect
                // alone. The next Disconnect (or connect) can still end it.
                // The record stays: it is the only handle on a live tunnel.
                debugOutput += "PID \(pid) is root-owned and the quit cannot ask — leaving the process-group record\n"
            case .notAnOpenConnect:
                debugOutput += "PID \(pid) is not an openconnect — left alone\n"
                OpenConnectPidFile.discard()
            }
        }

        // Best effort before the process goes away. It is asynchronous, so it may
        // not finish — in which case the record stays and the next launch sweeps it.
        reapLaunchProcessGroupInBackground()
    }
    
    /// Ends the tunnel, at the user's request.
    ///
    /// The status flips to `.disconnecting` here so the window responds at once;
    /// the teardown itself is asynchronous because finding the tunnel can need a
    /// look at the process table, which does not belong on the main thread. Use
    /// `disconnectAndWait()` where the *completion* matters — the update flow
    /// installs and quits, and must not begin before the tunnel is down.
    func disconnect() {
        let settings = SettingsManager.shared
        guard beginDisconnect() else { return }
        Task { [weak self] in
            guard let self else { return }
            let detection = await self.detectTunnelForTeardown()
            await MainActor.run {
                _ = self.performTunnelShutdown(detection: detection, settings: settings)
            }
        }
    }

    /// The same teardown, awaited. Answers whether the tunnel is *gone*.
    ///
    /// `false` also covers "there was nothing left to do", which is the honest
    /// answer for a caller that is about to install over this app.
    @discardableResult
    func disconnectAndWait() async -> Bool {
        let settings = SettingsManager.shared
        let started = await MainActor.run { self.beginDisconnect() }
        guard started else { return await MainActor.run { self.status == .disconnected } }
        let detection = await detectTunnelForTeardown()
        return await MainActor.run {
            self.performTunnelShutdown(detection: detection, settings: settings)
        }
    }

    /// The entry state both callers share: the status flip, the log line, and the
    /// guard against two teardowns at once.
    ///
    /// That guard is needed *because* the teardown became asynchronous: while
    /// this whole path blocked the main thread, a second press could not be
    /// delivered until the first had finished, so re-entry was impossible by
    /// accident. It is not any more.
    private func beginDisconnect() -> Bool {
        if case .disconnected = status { return false }
        if case .disconnecting = status { return false }

        // Use appropriate log message depending on current state
        let wasConnecting = if case .connecting = status { true } else { false }

        status = .disconnecting
        if wasConnecting {
            debugOutput += "Cancelling connection...\n"
        } else {
            debugOutput += "Disconnecting VPN...\n"
        }
        return true
    }

    /// Resolves the tunnel to stop: the record, then this app's own process
    /// group, then a verified scan of the machine.
    ///
    /// `pid == nil` in the result means *no verified openconnect is running*,
    /// which is not the same as "no record on disk". Reading a missing record as
    /// a missing tunnel is what produced a "Disconnected" over the live
    /// root-owned tunnel this app had launched moments earlier: openconnect
    /// writes no `--pid-file` of its own (it only does that when it backgrounds,
    /// and the launch plan does not pass `--background`) and the record's other
    /// writer is the *adoption* path, which by definition does not run for a
    /// tunnel started by this run.
    ///
    /// `ps`/`pgrep` get up to 3 s each; the UI must not wait on them.
    private func detectTunnelForTeardown() async -> ExistingConnectionDetection {
        let pidFilePid = OpenConnectPidFile.recordedPid()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ExistingConnectionScanner.detect(pidFilePid: pidFilePid))
            }
        }
    }

    /// Ends what the resolution found, and reports what is true. Returns whether
    /// the tunnel is gone.
    private func performTunnelShutdown(
        detection: ExistingConnectionDetection,
        settings: SettingsManager
    ) -> Bool {
        // A record that named something else is reported and dropped, exactly as
        // the adoption and connect paths do: that file is the one thing on disk
        // claiming a tunnel is out there, so a wrong entry in it has to be
        // visible rather than quietly acted upon.
        for rejection in detection.rejections {
            debugOutput += rejection.explanation + "\n"
        }
        if detection.pid == nil, !detection.rejections.isEmpty {
            OpenConnectPidFile.discard()
            debugOutput += "Discarded a PID file that named no openconnect\n"
        }

        // STEP 1: Gracefully terminate openconnect (allows clean network teardown)
        //
        // The elevation in this call is what makes a disconnect work at all. The
        // tunnel this app raised through `sudo` is owned by root, so no signal
        // this user sends reaches it; the app asks for the same elevation that
        // started it. `mayPrompt` is true because a person is here and asked.
        var tunnelEnded = true
        if let pid = detection.pid {
            debugOutput += "Terminating openconnect (PID: \(pid)) gracefully...\n"
            switch terminateGracefully(pid: pid, mayPrompt: true) {
            case .exitedCleanly:
                debugOutput += "openconnect exited cleanly, network restored\n"
                OpenConnectPidFile.discard()
            case .forceKilled:
                debugOutput += "openconnect force-killed (network may need manual restore)\n"
                OpenConnectPidFile.discard()
            case .endedWithElevation:
                debugOutput += "openconnect ended with elevation, network restored\n"
                OpenConnectPidFile.discard()
            case .notPermitted:
                // The tunnel is still up. The record is the handle on it, so it
                // stays — and the status below says so, because "Disconnected"
                // over a live tunnel is the report that hid this bug.
                tunnelEnded = false
                debugOutput += "openconnect (PID: \(pid)) is still running — the tunnel is still up\n"
            case .notAnOpenConnect:
                debugOutput += "PID \(pid) is not an openconnect — left alone\n"
                OpenConnectPidFile.discard()
            }
        } else {
            // Nothing verified is tunnelling. Saying so is not decoration: the
            // silent version of this branch is what made "Disconnected" and a
            // live root openconnect indistinguishable in this log.
            debugOutput += "No openconnect to stop\n"
        }
        
        // No pkill -9 backup — it races with graceful SIGTERM and prevents
        // openconnect from restoring network routes/DNS, causing internet loss.
        //
        // NOTE: We do NOT clean up stale vpn-slice /etc/hosts entries here.
        // vpn-slice's atexit handlers clean up on graceful SIGTERM. If they fail
        // (e.g. sudo cache expired), the next connection's shell command pipeline
        // handles the cleanup before connecting.
        
        // STEP 2: Clean up the PID file — but only when the tunnel is actually
        // gone. The record is how a later disconnect, or the next connect, finds
        // a surviving process again.
        if tunnelEnded {
            OpenConnectPidFile.discard()
        }
        
        // STEP 3: Gracefully terminate the bash/sudo wrapper process
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process {
            if proc.isRunning {
                let pid = proc.processIdentifier
                proc.terminate() // SIGTERM
                // Bash/sudo will exit once openconnect is gone — give it a moment
                let deadline = DispatchTime.now() + .seconds(2)
                while DispatchTime.now() < deadline {
                    usleep(100_000)
                    if !proc.isRunning { break }
                }
                if proc.isRunning {
                    _ = kill(pid, SIGKILL)
                    debugOutput += "Shell process force-killed\n"
                }
            }
        }
        process = nil
        cancelConnectionTimer()
        
        // The history row and the status both come *after* the attempt, and both
        // say what is true. "Disconnected" written before the signal was even
        // sent is what made a live tunnel look like a finished one.
        if let id = currentAttemptId {
            let duration = connectionStartTime.map { Date().timeIntervalSince($0) }
            let attempt = ConnectionAttempt(
                id: id,
                timestamp: connectionStartTime ?? Date(),
                host: settings.vpnHost.isEmpty ? "Unknown" : settings.vpnHost,
                status: tunnelEnded ? "Disconnected" : "Failed - Still Connected",
                duration: duration,
                logOutput: debugOutput
            )
            ConnectionHistoryManager.shared.updateAttempt(attempt)
        }
        
        if tunnelEnded {
            status = .disconnected
            debugOutput += "VPN disconnected\n"
            stopDurationTimer()
        } else {
            // `.connected` is the honest state: the tunnel really is up. It is
            // also the only state that keeps the button saying "Disconnect" —
            // `.error` would rename it "Reconnect" and invite a second tunnel on
            // top of the one that is still running.
            status = .connected
            debugOutput += "VPN NOT disconnected — openconnect is still running\n"
        }
        reapLaunchProcessGroupInBackground()
        return tunnelEnded
    }
    
    private func executeVPNConnection() async {
        // Check for existing openconnect processes
        await terminateExistingOpenConnect()
        
        let settings = SettingsManager.shared
        let withTunneling = settings.useTunneling

        // A missing command-line tool is a setup problem, not a token problem.
        // Asking stoken for a code when stoken is not installed produced
        // "Failed to generate token", which points at the PIN and the token
        // file — the one place the fault is not. Say which tool is absent (and
        // where), before anything is attempted.
        let missingTools = ToolPreflight.missing(splitTunneling: withTunneling)
        if let message = ToolPreflight.message(for: missingTools) {
            let paths = missingTools.map { "\($0.id): not found" }.joined(separator: ", ")
            await MainActor.run {
                self.status = .error(message)
                self.debugOutput += "Missing tool(s) — \(paths)\n"
                self.debugOutput += "Install them with: brew install \(missingTools.compactMap(\.formula).joined(separator: " "))\n"
            }
            logFailedAttempt(status: "Failed - Missing Tool")
            return
        }

        // Decide the elevation path before anything is launched, so the user can
        // be told what to expect while there is still time to answer it. The
        // probe shells out to `sudo -n -v` and reads two world-readable PAM
        // files; it authenticates nothing and changes nothing.
        let snapshot = await Self.elevationSnapshot()
        elevation = snapshot.strategy
        elevationBlock = nil
        await MainActor.run {
            for line in snapshot.strategy.debugLines(timeoutSeconds: Self.connectionTimeoutSeconds) {
                self.debugOutput += line + "\n"
            }
        }

        // Generate token using stoken
        let token = await generateToken(passcode: settings.vpnPasscode)
        guard !token.isEmpty else {
            await MainActor.run {
                self.status = .error("Failed to generate token")
                self.debugOutput += "Error: Failed to generate token using stoken\n"
            }
            return
        }
        
        // The server expects the PIN (static) prepended to the TOTP tokencode.
        // stoken tokencode -p returns just the 6-digit TOTP, not the combined value.
        // So we manually combine: passcode + token.
        let pin = settings.vpnPasscode + token

        // Build the command: options first, then host
        // Auto-reconnect for up to 7 days when the server disconnects
        // (e.g. idle timeout, network interruption). openconnect caches the
        // session cookie internally so reconnection doesn't need stdin.
        var arguments: [String] = ["--force-dpd=10", "--reconnect-timeout=604800", "--user=\(settings.vpnID)", "--pid-file", pidFilePath]
        if withTunneling {
            let slicePath = binaryPath("vpn-slice") ?? "vpn-slice"
            let sliceArg = "\(slicePath) \(settings.vpnSliceURLs.joined(separator: " "))"
            arguments.append(contentsOf: ["-s", sliceArg])
        }
        arguments.append(settings.vpnHost)
        
        DispatchQueue.main.async {
            self.debugOutput += "Connecting to \(settings.vpnHost)...\n"
            if withTunneling {
                self.debugOutput += "Using tunneling with URLs: \(settings.vpnSliceURLs.joined(separator: ", "))\n"
            }
        }
        
        // The stored password is only *needed* when it is the one being piped.
        // With Touch ID enabled the system answers, and demanding a password
        // first would be asking for a credential the connect has no use for.
        if elevation.pipesTheStoredPassword && settings.adminPassword.isEmpty {
            await MainActor.run {
                self.debugOutput += "Admin password required for VPN connection.\n"
            }
            // promptForAdminPasswordAndRetry is @MainActor — Swift auto-hops to main actor
            let retry = await self.promptForAdminPasswordAndRetry()
            guard retry else {
                await MainActor.run {
                    self.status = .error("Admin password required")
                    self.debugOutput += "Connection cancelled - admin password is needed to configure network settings.\n"
                }
                return
            }
        }
        
        let openconnectPath = binaryPath("openconnect") ?? "openconnect"
        // The three credentials are *not* interpolated into this string. A
        // process's argv is readable by any process running as the same user
        // (`ps`, `pgrep -f`) and is copied into crash reports; the previous
        // `echo <password> | sudo …` pipeline therefore leaked the admin
        // password, the PIN and the VPN password to every process on the
        // machine. They now travel down a pipe that the script reads into
        // unexported shell variables — see `OpenConnectLaunchPlan`.
        OpenConnectPidFile.prepareDirectory()
        OpenConnectPidFile.discardLegacyFile()
        let plan = OpenConnectCommand.launchPlan(
            openconnectPath: openconnectPath,
            arguments: arguments,
            adminPassword: settings.adminPassword,
            pin: pin,
            vpnPassword: settings.vpnPassword,
            elevation: elevation
        )
        // Shape, for the log and for debugging — it is the same script every
        // time, and it contains nothing secret.
        let shellCommand = plan.script
        
        // Connection file logger
        let log = VpnConnectionLogger()
        log.write("Host: \(settings.vpnHost)")
        log.write("User: \(settings.vpnID)")
        log.write("Tunneling: \(withTunneling)")
        log.write("openconnect path: \(openconnectPath)")
        log.write("Arguments: \(arguments)")
        // The pipeline's *shape* is logged, never its credential bytes: they
        // are not in the command line at all any more, they are written to
        // openconnect's stdin from `plan.standardInput`. Individual
        // credentials are recorded below in redacted form by `logSend`.
        log.write("Pipeline: \(shellCommand)")
        log.write("Credential stdin: \(plan.standardInput.count) bytes, \(elevation.credentialLineCount) lines")
        log.write("Elevation: \(elevation)")
        log.logSend("Admin password (for sudo)", value: settings.adminPassword)
        log.logSend("PIN (passcode+tokencode)", value: pin)
        log.logSend("VPN password", value: settings.vpnPassword)
        log.flush()
        
        DispatchQueue.main.async {
            self.debugOutput += "Connection log: \(VpnConnectionLogger.logPath)\n"
            self.debugOutput += "Launching openconnect via sudo...\n"
        }
        
        // Run via bash -c (direct, unbuffered — no osascript intermediary)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", shellCommand]
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        // The credentials' route into the process. Three short lines fit in the
        // pipe buffer, so the write below cannot block even if the script is
        // slow to reach its first `read`.
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe
        
        // Reset flags
        self.passcodePromptCount = 0
        self.pipeClosed = false
        
        // Handle output — now unbuffered since we run bash directly, not via osascript
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            log.logStream("STDOUT", data: data)
            if let output = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.debugOutput += output
                    let lowerOut = output.lowercased()
                    
                    // "Please enter your username and password." is a WebVPN banner, not a prompt.
                    if lowerOut.contains("please enter your username and password") {
                        log.logHandler("STDOUT", action: "banner text, no input sent")
                    }
                    
                    // Check connection success signals
                    if output.contains("Established DTLS")
                        || output.contains("ESP session established")
                        || output.contains("Connected as")
                        || output.contains("CSTP connected")
                        || output.contains("Configured as")
                        || output.contains("Got CONNECT response") {
                        log.logHandler("STDOUT", action: "detected successful connection signal")
                        if case .connecting = self.status {
                            self.status = .connected
                            self.startDurationTimer(startingAt: Date())
                            self.cancelConnectionTimer()
                            // Cancelling the connect timer cancels the *poller*
                            // too, so this is the last chance to write down what
                            // was just launched. Without the record, the next
                            // disconnect has no pid to signal — see
                            // `recordOwnTunnelPid`.
                            self.recordOwnTunnelPid()
                            if let id = self.currentAttemptId {
                                let attempt = ConnectionAttempt(
                                    id: id,
                                    timestamp: self.connectionStartTime ?? Date(),
                                    host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                                    status: "Connected",
                                    logOutput: self.debugOutput
                                )
                                ConnectionHistoryManager.shared.updateAttempt(attempt)
                            }
                        }
                    }
                }
            }
        }
        
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            log.logStream("STDERR", data: data)
            
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanLine.isEmpty { continue }
                DispatchQueue.main.async {
                    let lower = cleanLine.lowercased()

                    // A named elevation failure, before the keyword checks below:
                    // the marker contains "sudo", and would otherwise be logged
                    // as an administrator-password problem, which it is not.
                    if let reason = ElevationBlockReason.match(markerLine: cleanLine) {
                        log.logHandler("STDERR", action: "elevation blocked: \(reason.historyStatus)")
                        self.elevationBlock = reason
                        self.debugOutput += "ERROR: \(reason.detail)\n"
                        return
                    }
                    
                    // Handle potential login failure messages from openconnect.
                    // NOTE: Do NOT force-terminate here — the VPN may have successfully
                    // connected (routes configured, vpn-slice running) even when openconnect
                    // outputs "login failed" as part of a multi-step auth flow or secondary
                    // challenge. If it's a real failure, openconnect will exit on its own
                    // and the termination handler will report the error.
                    if lower.contains("login failed") {
                        log.logHandler("STDERR", action: "LOGIN FAILED reported by openconnect — may be part of multi-step auth")
                        self.debugOutput += "WARN: \(cleanLine) (openconnect may still continue)\n"
                    }
                    
                    // Authentication errors
                    if lower.contains("authentication failed") || lower.contains("authorization failed") {
                        log.logHandler("STDERR", action: "Auth failed")
                        self.debugOutput += "ERROR: \(cleanLine)\n"
                        return
                    }
                    
                    // Sudo / admin password issues
                    if lower.contains("sudo") || lower.contains("permission denied") || lower.contains("incorrect") {
                        log.logHandler("STDERR", action: "admin password issue")
                        self.debugOutput += "ERROR: \(cleanLine)\n"
                        return
                    }
                }
            }
        }
        
        self.process = proc
        self.outputPipe = outPipe
        self.errorPipe = errPipe
        self.inputPipe = nil
        
        let gen = connectionGeneration
        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                guard let self = self, self.connectionGeneration == gen else { return }
                log.write("[TERM] VPN process terminated (status: \(p.terminationStatus))")
                log.flush()
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.errorPipe?.fileHandleForReading.readabilityHandler = nil
                self.debugOutput += "VPN process exited (status: \(p.terminationStatus))\n"
                // A named cause beats a bare exit status: the script ended
                // itself because elevation could not be obtained, and saying
                // which branch failed is the difference between a fixable
                // message and "Connection failed (status: 1)".
                if let reason = self.elevationBlock {
                    self.debugOutput += "\(reason.detail)\n"
                    self.status = .error(reason.historyStatus)
                    self.logFailedAttempt(status: reason.historyStatus)
                    self.cancelConnectionTimer()
                    return
                }
                // Only update status if we weren't already connected
                if case .connected = self.status {
                    self.status = .disconnected
                } else if case .connecting = self.status {
                    self.status = .error("Connection failed (status: \(p.terminationStatus))")
                }
                self.cancelConnectionTimer()
            }
        }
        
        do {
            try proc.run()
            log.write("[INIT] bash process started with PID \(proc.processIdentifier)")
            log.flush()
            
            DispatchQueue.main.async {
                self.debugOutput += "VPN process launched. Awaiting connection...\n"
            }
            
            self.startConnectionTimer(timeoutSeconds: Self.connectionTimeoutSeconds)
            
            // Feed the credentials. Written after `run()` so the child cannot
            // miss them, and closed so a failed `read` fails fast instead of
            // waiting on a pipe nobody will write to.
            do {
                try inPipe.fileHandleForWriting.write(contentsOf: plan.standardInput)
            } catch {
                log.write("[TERM] writing credentials to stdin failed: \(error.localizedDescription)")
            }
            try? inPipe.fileHandleForWriting.close()
            
            // Start polling for connection success via PID file.
            // Since we now run bash directly (not through osascript),
            // stdout/stderr arrive in real-time via the readability handlers.
            // The PID file polling is a secondary fallback.
            self.startConnectionPollingTimer(log: log, gen: gen)
        } catch {
            log.write("[TERM] bash process failed to start: \(error.localizedDescription)")
            log.flush()
            self.pipeClosed = true
            DispatchQueue.main.async {
                self.status = .error("Failed to launch: \(error.localizedDescription)")
                self.debugOutput += "Error: \(error.localizedDescription)\n"
                self.cancelConnectionTimer()
            }
        }
    }
    
    /// Stops a tunnel that is already running, before starting one.
    ///
    /// The pid is verified before anything is signalled. `openconnect.pid` has
    /// named a process that was not an openconnect, and the name-wide
    /// `pkill -15 -f openconnect` this used to fall back to could signal any
    /// process of the user's whose command line merely mentioned the word.
    private func terminateExistingOpenConnect() async {
        let pidFilePid = await MainActor.run { OpenConnectPidFile.recordedPid() }
        // The scan spawns processes (up to 3 s each, bounded); keep it off the
        // main thread.
        let detection = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ExistingConnectionScanner.detect(pidFilePid: pidFilePid))
            }
        }

        guard let pid = detection.pid else {
            // Nothing verified to stop. No hosts cleanup here either: stale
            // vpn-slice entries are removed by the launch plan's own step, whose
            // `sudo` runs in the context that just authenticated. An attempt from
            // this process would be a child of the app — a different parent, so a
            // different timestamp record — and could only fail.
            await MainActor.run {
                for rejection in detection.rejections {
                    self.debugOutput += rejection.explanation + "\n"
                }
                if !detection.rejections.isEmpty {
                    OpenConnectPidFile.discard()
                    self.debugOutput += "Discarded a PID file that named no openconnect\n"
                }
            }
            return
        }

        await MainActor.run {
            let source = detection.source?.rawValue ?? "unknown"
            self.debugOutput += "Found existing openconnect (PID: \(pid), \(source)). Terminating...\n"
        }

        // `mayPrompt: true`: the user just asked to connect, so a dialog is
        // expected in this flow (the launch itself may raise one) — and a
        // leftover root-owned tunnel from a previous attempt has to be ended
        // before a second one is raised on top of it.
        let outcome = terminateGracefully(pid: pid, mayPrompt: true)

        await MainActor.run {
            switch outcome {
            case .exitedCleanly:
                self.debugOutput += "Existing openconnect exited cleanly\n"
            case .forceKilled:
                self.debugOutput += "Existing openconnect force-killed\n"
            case .notPermitted:
                self.debugOutput += "Existing openconnect (PID: \(pid)) is root-owned and could not be ended\n"
            case .endedWithElevation:
                self.debugOutput += "Existing openconnect ended with elevation\n"
            case .notAnOpenConnect:
                self.debugOutput += "PID \(pid) is not an openconnect — left alone\n"
            }
            if outcome != .notPermitted {
                OpenConnectPidFile.discard()
            }
        }

        // Wait for cleanup to complete before the plan starts.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func generateToken(passcode: String, isNext: Bool = false) async -> String {
        let stokenPath = binaryPath("stoken")
        
        // Ensure PATH includes Homebrew locations
        let defaultPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        var envBuilder = ProcessInfo.processInfo.environment
        envBuilder["PATH"] = "\(defaultPaths):\(envBuilder["PATH"] ?? "")"
        
        var startedAccess = false
        var usingTokenFile = false
        var tokenFilePath: String?
        
        // Determine executable and arguments
        func makeArguments(baseArgs: [String] = ["tokencode"]) -> [String] {
            var args = baseArgs
            if isNext { args.append("--next") }
            if !passcode.isEmpty { args.append(contentsOf: ["-p", passcode]) }
            return args
        }
        
        let executable: URL
        var arguments: [String]
        
        if let tokenURL = SettingsManager.shared.resolvedStokenTokenURL() {
            if tokenURL.startAccessingSecurityScopedResource() {
                startedAccess = true
                usingTokenFile = true
                tokenFilePath = tokenURL.path
                executable = stokenPath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/env")
                arguments = stokenPath != nil ? makeArguments(baseArgs: ["tokencode", "--file", tokenURL.path]) : ["stoken", "tokencode", "--file", tokenURL.path] + (passcode.isEmpty ? [] : ["-p", passcode])
            } else {
                // Fallback: use default approach
                executable = stokenPath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/env")
                arguments = stokenPath != nil ? makeArguments() : ["stoken"] + makeArguments()
            }
        } else {
            let tokenPath = SettingsManager.shared.stokenTokenFilePath
            if !tokenPath.isEmpty {
                usingTokenFile = true
                tokenFilePath = tokenPath
                executable = stokenPath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/env")
                arguments = stokenPath != nil ? makeArguments(baseArgs: ["tokencode", "--file", tokenPath]) : ["stoken", "tokencode", "--file", tokenPath] + (passcode.isEmpty ? [] : ["-p", passcode])
            } else {
                executable = stokenPath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/env")
                arguments = stokenPath != nil ? makeArguments() : ["stoken"] + makeArguments()
                
                if let stokenURL = SettingsManager.shared.resolvedStokenURL() {
                    if stokenURL.startAccessingSecurityScopedResource() {
                        startedAccess = true
                        envBuilder["STOKEN_RC"] = stokenURL.path
                    }
                } else {
                    let rcPath = SettingsManager.shared.stokenRCPath
                    if !rcPath.isEmpty {
                        envBuilder["STOKEN_RC"] = rcPath
                    } else {
                        // Fallback: check if ~/.stokenrc exists (stoken's default path)
                        let homeRC = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".stokenrc").path
                        if FileManager.default.isReadableFile(atPath: homeRC) {
                            envBuilder["STOKEN_RC"] = homeRC
                        }
                    }
                }
            }
        }
        
        // Capture the final env as a constant to satisfy Swift 6 concurrency checking
        let env = envBuilder
        
        // Helper to stop security-scoped access
        func stopAccess() {
            guard startedAccess else { return }
            if usingTokenFile, let url = SettingsManager.shared.resolvedStokenTokenURL() {
                url.stopAccessingSecurityScopedResource()
            } else if let url = SettingsManager.shared.resolvedStokenURL() {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        // Helper to log token info
        func logTokenInfo() async {
            await MainActor.run {
                self.debugOutput += "stoken path: \(stokenPath ?? "/usr/bin/env stoken")\n"
                if usingTokenFile {
                    self.debugOutput += "Using --file\n"
                } else if let rc = env["STOKEN_RC"] {
                    self.debugOutput += "Using STOKEN_RC: \(rc)\n"
                }
            }
        }
        
        do {
            let (stdout, stderr) = try await runProcess(
                executable: executable,
                arguments: arguments,
                environment: env
            )
            
            let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if output.isEmpty {
                // Retry with explicit --file if using a token file
                if usingTokenFile, let filePath = tokenFilePath {
                    let retryExec = stokenPath.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: "/usr/bin/env")
                    let retryArgs = stokenPath != nil
                        ? makeArguments(baseArgs: ["tokencode", "--file", filePath])
                        : ["stoken"] + makeArguments(baseArgs: ["tokencode", "--file", filePath])
                    
                    if let retryResult = try? await runProcess(executable: retryExec, arguments: retryArgs, environment: env) {
                        let retryOutput = retryResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !retryOutput.isEmpty {
                            stopAccess()
                            return retryOutput
                        }
                    }
                }
                
                await MainActor.run {
                    self.debugOutput += "stoken error: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                    self.debugOutput += "Tried path: \(stokenPath ?? "/usr/bin/env stoken")\n"
                    if usingTokenFile {
                        self.debugOutput += "Using --file\n"
                    } else {
                        if let rc = env["STOKEN_RC"] {
                            self.debugOutput += "STOKEN_RC: \(rc)\n"
                        } else {
                            self.debugOutput += "STOKEN_RC not set\n"
                        }
                    }
                    self.logTokenErrorAttempt()
                }
            } else {
                await logTokenInfo()
            }
            
            stopAccess()
            return output
        } catch {
            await MainActor.run {
                self.debugOutput += "Error generating token: \(error.localizedDescription)\n"
                self.debugOutput += "Tried path: \(stokenPath ?? "/usr/bin/env stoken")\n"
                if usingTokenFile {
                    self.debugOutput += "Using --file\n"
                } else if let rc = env["STOKEN_RC"] {
                    self.debugOutput += "STOKEN_RC: \(rc)\n"
                }
                self.logTokenErrorAttempt()
            }
            stopAccess()
            return ""
        }
    }
    
    /// Records a failed attempt under a status the History pane can name. The
    /// status has to describe *why*: a missing `stoken` is not a token error.
    private func logFailedAttempt(status: String) {
        if let id = currentAttemptId {
            let attempt = ConnectionAttempt(
                id: id,
                timestamp: connectionStartTime ?? Date(),
                host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                status: status,
                logOutput: debugOutput
            )
            ConnectionHistoryManager.shared.updateAttempt(attempt)
        }
    }

    private func logTokenErrorAttempt() {
        logFailedAttempt(status: "Failed - Token Error")
    }
    
    /// The elevation snapshot, taken off the main thread: it reads two files.
    /// Neither the window nor the cooperative pool should be waiting on that.
    ///
    /// It deliberately does not ask `sudo` anything. Whether sudo's timestamp is
    /// warm is keyed to the process that warmed it (`timestamp_type` defaults to
    /// `tty`, which means `ppid` when there is no terminal), so the app's own
    /// answer would not apply to the plan's wrapper shell — measuring it here is
    /// what produced `Failed - Elevation Expired` on a connect whose timestamp
    /// was, in that other context, perfectly warm.
    private static func elevationSnapshot() async -> ElevationSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ElevationProbe.live(
                    readFile: { try? String(contentsOfFile: $0, encoding: .utf8) }
                ))
            }
        }
    }

    /// Signals the process group the launch recorded, once the connection and the
    /// wrapper are done with it.
    ///
    /// One id covers every user-owned member of the privileged subtree, which is
    /// how a blocked `sudo` stops being *created*: with the body in a group of its
    /// own, the group is what gets signalled. Three things it deliberately does
    /// not do — it does not make the root members killable (the kernel refuses a
    /// signal from a non-root sender), it does not touch a group that still holds
    /// a live `openconnect` (that process restores routes and DNS on its way out),
    /// and it does not pretend the group died: a group that is left alone keeps
    /// its record, so a later launch can still find it.
    ///
    /// Runs off the main thread: it shells out to `ps`, bounded, but the UI must
    /// not wait on it. If the app is quitting before that finishes, the record
    /// survives and the next launch's sweep picks it up.
    private func reapLaunchProcessGroup(log: VpnConnectionLogger? = nil) {
        ElevationReaper.reapStaleGroup(log: { message in
            if let log {
                log.write("[ELEV] \(message)")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.debugOutput += message + "\n"
                }
            }
        })
    }

    private func reapLaunchProcessGroupInBackground() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.reapLaunchProcessGroup()
        }
    }

    private func binaryPath(_ name: String) -> String? {
        // Delegates to the shared resolver, which searches `$PATH` as well as
        // the prefixes: the four directories this used to try missed MacPorts
        // (`/opt/local/bin`) and `~/.local/bin`, so a tool the user had
        // installed looked absent and the connect failed with a message about
        // the *token*.
        ToolResolver.locate(name)
    }
    
    private func startConnectionTimer(timeoutSeconds: Int) {
        cancelConnectionTimer()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if case .connecting = self.status {
                    self.debugOutput += "Connection timeout reached. Terminating VPN process.\n"
                    self.forceTerminate()
                    // With a system dialog up, the timeout means the dialog was
                    // not answered — which is something the user can act on, and
                    // is not the same as a network that did not come up.
                    if let reason = self.elevationBlock {
                        self.debugOutput += "\(reason.detail)\n"
                        self.status = .error(reason.historyStatus)
                    } else if self.elevation.waitsForTheSystem {
                        self.debugOutput += self.elevation.timeoutDetail(timeoutSeconds: timeoutSeconds) + "\n"
                        self.status = .error(self.elevation.timeoutHistoryStatus)
                    } else {
                        self.status = .error("Connection timeout")
                    }
                    self.logFailedAttempt(status: self.elevationBlock?.historyStatus
                                          ?? self.elevation.timeoutHistoryStatus)
                }
            }
        }
        connectionTimer = timer
        timer.resume()
    }
    
    private func cancelConnectionTimer() {
        connectionTimer?.cancel()
        connectionTimer = nil
        connectionPollTimer?.cancel()
        connectionPollTimer = nil
    }
    
    /// Polls every 2 seconds to detect when openconnect has successfully
    /// started. Since we now run bash directly (not through osascript),
    /// stdout/stderr arrive in real-time via readability handlers; this timer is
    /// the secondary path.
    ///
    /// Detection strategy (tiered):
    /// 1. The PID file openconnect was asked to write with `--pid-file`.
    /// 2. After 10 seconds without one, a scan for a process *named*
    ///    openconnect.
    ///
    /// Both tiers verify the pid before it counts — see `ExistingConnection`.
    /// The scan is a name match (`pgrep -x` plus `ps -o comm=`), never a
    /// command-line match: matching command lines is what once made this app
    /// adopt a process that merely mentioned openconnect, and it is why the
    /// previous version had to guess which pids to leave out.
    private func startConnectionPollingTimer(log: VpnConnectionLogger, gen: UInt64) {
        // Cancel any previous polling timer
        connectionPollTimer?.cancel()
        
        // The bash process that launched this connection, kept for the log only:
        // the verification already excludes it, because its command name is
        // bash, not openconnect.
        let bashPid: Int32? = self.process?.processIdentifier
        
        // Track how many polls have elapsed. After 5 (10 seconds), fall back to a
        // process-name scan if the PID file hasn't appeared.
        var pollCount = 0
        
        let pollTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .background))
        pollTimer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        pollTimer.setEventHandler { [weak self] in
            guard let self = self else { return }
            pollCount += 1
            
            // Quick check on generation to avoid unnecessary work
            var shouldContinue = false
            let genCheck = DispatchGroup()
            genCheck.enter()
            DispatchQueue.main.async {
                if case .connecting = self.status, self.connectionGeneration == gen {
                    shouldContinue = true
                } else {
                    pollTimer.cancel()
                }
                genCheck.leave()
            }
            genCheck.wait()
            guard shouldContinue else { return }
            
            var detectedPid: Int32?
            
            // Tier 1: the PID file, verified before it counts. This tier used to
            // accept *any* live pid from that file, and the file held a pid that
            // was not an openconnect — enough to report a connection that did not
            // exist.
            if let pid = OpenConnectPidFile.recordedPid(), OpenConnectProcess.isOpenConnect(pid: pid) {
                detectedPid = pid
                log.write("[POLL] PID file found — PID \(pid) is openconnect")
            }
            
            // Tier 2: after 10 seconds, scan for a process *named* openconnect.
            // The verification excludes the bash wrapper and any process that
            // merely mentions the word, so no pid needs to be guessed at. This is
            // the tier that finds the tunnel in practice: openconnect only writes
            // `--pid-file` together with `--background`, which the plan does not
            // use.
            if detectedPid == nil && pollCount >= 5 {
                let detection = ExistingConnectionScanner.detect(pidFilePid: nil)
                if let pid = detection.pid {
                    detectedPid = pid
                    log.write("[POLL] scan found openconnect PID \(pid) (bash PID: \(bashPid ?? -1))")
                }
            }
            
            guard let pid = detectedPid else { return }

            // Record it before the status flips, and off the main thread: the
            // write is what a later disconnect, connect timeout, or quit reads to
            // *name* this tunnel, and this poller stops the moment the status
            // changes. The pid is already verified — the detector only returns
            // candidates it has checked.
            recordOwnTunnelPid(pid)

            // Connection detected! Update status.
            log.flush()
            pollTimer.cancel()
            self.connectionPollTimer = nil
            
            DispatchQueue.main.async {
                guard case .connecting = self.status, self.connectionGeneration == gen else { return }
                self.debugOutput += "VPN connection established (PID: \(pid))\n"
                self.status = .connected
                self.startDurationTimer(startingAt: Date())
                self.cancelConnectionTimer()
                if let id = self.currentAttemptId {
                    let attempt = ConnectionAttempt(
                        id: id,
                        timestamp: self.connectionStartTime ?? Date(),
                        host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                        status: "Connected",
                        logOutput: self.debugOutput
                    )
                    ConnectionHistoryManager.shared.updateAttempt(attempt)
                }
            }
        }
        pollTimer.resume()
        connectionPollTimer = pollTimer
    }
    
    /// Seeds the duration display from a known start instant.
    ///
    /// The start is a parameter rather than a default, because the callers mean
    /// different things by it: a fresh connect means "now", an adopted tunnel
    /// means "when that process actually started". Passing the value in — rather
    /// than recomputing it inside the block below — is what makes the adopted
    /// case honest. An earlier version assigned `Date()` in the block and so
    /// discarded the adopter's real start time one runloop after it was read,
    /// which is why an adopted tunnel's duration always restarted from zero.
    private func startDurationTimer(startingAt start: Date) {
        DispatchQueue.main.async {
            self.connectionStartTime = start
            self.durationString = "00:00:00"
            self.durationTimer?.invalidate()
            self.durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, let startTime = self.connectionStartTime else { return }
                let duration = Date().timeIntervalSince(startTime)
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = [.hour, .minute, .second]
                formatter.zeroFormattingBehavior = .pad
                self.durationString = formatter.string(from: duration) ?? "00:00:00"
            }
        }
    }
    
    private func stopDurationTimer() {
        DispatchQueue.main.async {
            self.durationTimer?.invalidate()
            self.durationTimer = nil
            self.connectionStartTime = nil
            self.durationString = "00:00:00"
        }
    }
    
    /// Send SIGTERM and wait up to `timeoutSeconds` for the process to exit.
    /// Returns true if the process exited cleanly, false if force-kill was required.
    /// This is critical — SIGKILL prevents openconnect from restoring network
    /// configuration (routes, DNS, utun interface), causing total internet loss.
    @discardableResult
    /// Stops an openconnect, and says truthfully what happened.
    ///
    /// Three things are deliberately different from the version this replaces.
    /// First, the pid is verified: `openconnect.pid` is a plain file, and a
    /// stale or recycled pid in it names somebody else's process. Nothing is
    /// signalled until `ps` says the pid is an openconnect.
    ///
    /// Second, the outcome is *measured* rather than assumed. Liveness used to
    /// be `kill(pid, 0) == 0`, which answers `EPERM` — not 0 — for a process this
    /// user may not signal. An openconnect started through `sudo` is owned by
    /// root, so that test reported the app's own tunnel as "exited cleanly"
    /// without ever having signalled it.
    ///
    /// Third, a root-owned tunnel is actually *ended* rather than only named:
    /// the signal is sent through the same elevation the connect used. Naming
    /// the failure was honest but useless — the user pressed Disconnect and the
    /// tunnel stayed up.
    /// - Parameter mayPrompt: whether this caller may put a system dialog in
    ///   front of the user. There is deliberately no default: at quit a dialog
    ///   that nothing answers would hold the quit open and leave a blocked root
    ///   `sudo` behind, so every call site has to say which path it is.
    private func terminateGracefully(
        pid: Int32,
        timeoutSeconds: TimeInterval = 3.0,
        mayPrompt: Bool
    ) -> TerminationOutcome {
        guard OpenConnectProcess.isOpenConnect(pid: pid) else { return .notAnOpenConnect }
        guard OpenConnectProcess.isRunning(pid: pid) else { return .exitedCleanly }

        // The owner is read before anything is sent. A root-owned process
        // refuses both signals, so asking costs the timeout and then reports a
        // failure that was never in doubt.
        if ProcessOwner.belongsToAnotherUser(pid) {
            debugOutput += "openconnect (PID: \(pid)) belongs to another user — the signal needs elevation\n"
            return terminateWithElevation(pid: pid, mayPrompt: mayPrompt)
        }

        _ = kill(pid, SIGTERM)

        let deadline = DispatchTime.now() + .seconds(Int(timeoutSeconds))
        while DispatchTime.now() < deadline {
            usleep(200_000) // 200ms
            if !OpenConnectProcess.isRunning(pid: pid) { return .exitedCleanly }
        }

        // Only force-kill as last resort — this may leave network in a bad state
        _ = kill(pid, SIGKILL)
        usleep(200_000)
        if !OpenConnectProcess.isRunning(pid: pid) { return .forceKilled }

        // Still there after signals this user *may* send. It may simply hold
        // privileges the owner check could not see, so elevation gets one turn
        // before the app calls the tunnel unkillable.
        return terminateWithElevation(pid: pid, mayPrompt: mayPrompt)
    }

    /// Ends a tunnel through the same elevation that started it.
    ///
    /// The group recorded by the connect is preferred to the pid: the launch is
    /// one group — the wrapper shell, the `sudo`, and `openconnect` — and
    /// signalling only the pid leaves the other two to be orphaned. The group is
    /// used only while it verifiably still holds this tunnel's pid.
    private func terminateWithElevation(pid: Int32, mayPrompt: Bool) -> TerminationOutcome {
        let target: ElevatedTerminator.Target = ElevationRecord.read().map { .group($0) } ?? .pid(pid)
        let outcome = elevatedTerminator.end(
            target,
            openConnectPid: pid,
            strategy: elevation,
            adminPassword: SettingsManager.shared.adminPassword,
            mayPrompt: mayPrompt
        )
        switch outcome {
        case .ended:
            debugOutput += "openconnect (PID: \(pid)) ended with elevation\n"
            return .endedWithElevation
        case .stillRunning(let detail), .refused(let detail):
            debugOutput += "Elevation: \(detail)\n"
            return .notPermitted
        }
    }
    
    private func forceTerminate() {
        // Mark the pipe as closed so readability handlers skip writes
        pipeClosed = true
        
        // Clear readability handlers FIRST to prevent any new callbacks
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        // Gracefully terminate openconnect (allows clean network teardown) — but
        // only a pid that is verified to be an openconnect.
        //
        // This is the connect *timeout* path, so it cannot resolve a missing
        // record the way `disconnect()` does (`mayPrompt: false`, and the timeout
        // may itself be the sign that something is stuck). It does not need to:
        // this runs 90 s after the launch and only while the status is still
        // `.connecting`, and the connect poller has by then read the pid off the
        // process table and recorded it — or nothing verifiable is running and
        // this is the honest no-op it looks like.
        if let pid = OpenConnectPidFile.recordedPid() {
            // `mayPrompt: false`: the connect just timed out — very possibly
            // because a dialog went unanswered — so this path must not put up
            // another one. `sudo -n` and a piped stored password still apply.
            switch terminateGracefully(pid: pid, mayPrompt: false) {
            case .notPermitted:
                debugOutput += "openconnect (PID: \(pid)) is root-owned and could not be ended\n"
            case .endedWithElevation:
                debugOutput += "openconnect ended with elevation\n"
                OpenConnectPidFile.discard()
            case .notAnOpenConnect:
                debugOutput += "PID \(pid) is not an openconnect — left alone\n"
                OpenConnectPidFile.discard()
            case .exitedCleanly, .forceKilled:
                // The process is gone, so the record is stale — and a pid that no
                // longer belongs to openconnect can be recycled by something else.
                OpenConnectPidFile.discard()
            }
        }
        
        // Then handle the shell wrapper
        if let proc = process {
            if proc.isRunning {
                let pid = proc.processIdentifier
                proc.terminate()
                // Give it up to 2 seconds to exit after openconnect is gone
                let deadline = DispatchTime.now() + .seconds(2)
                while DispatchTime.now() < deadline {
                    usleep(100_000)
                    if !proc.isRunning { break }
                }
                if proc.isRunning {
                    _ = kill(pid, SIGKILL)
                }
            }
        }
        process = nil
        inputPipe = nil
        stopDurationTimer()
        reapLaunchProcessGroupInBackground()
    }
    
    /// Shows an on-demand alert asking for the local admin password when sudo fails,
    /// stores it via Keychain, and signals whether to retry the connection.
    @MainActor
    private func promptForAdminPasswordAndRetry() async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Admin Password Required"
        alert.informativeText = "VPN requires administrator privileges to configure network settings. Please enter your local Mac login password."
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let password = input.stringValue
            guard !password.isEmpty else {
                // Empty password = cancel
                self.debugOutput += "Admin password prompt cancelled (empty password)\n"
                return false
            }
            SettingsManager.shared.adminPassword = password
            self.debugOutput += "Admin password updated. Retrying connection...\n"
            return true
        }
        self.debugOutput += "Admin password prompt dismissed\n"
        return false
    }
    
    // MARK: - Async Process Helper
    
    private func runProcess(
        executable: URL,
        arguments: [String] = [],
        input: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> (stdout: String, stderr: String) {
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            
            if let env = environment {
                var merged = ProcessInfo.processInfo.environment
                merged.merge(env) { (_, new) in new }
                process.environment = merged
            }
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            if input != nil {
                let inputPipe = Pipe()
                process.standardInput = inputPipe
            }
            
            let stdoutData = SendableDataBuffer()
            let stderrData = SendableDataBuffer()
            
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stdoutData.append(data)
                }
            }
            
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stderrData.append(data)
                }
            }
            
            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                
                stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                
                let stdout = String(data: stdoutData.data, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData.data, encoding: .utf8) ?? ""
                
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: (stdout, stderr))
                } else {
                    continuation.resume(throwing: ProcessError.exitStatus(proc.terminationStatus, stderr))
                }
            }
            
            do {
                try process.run()
                
                if let inputString = input, let inputPipe = process.standardInput as? Pipe {
                    if let data = "\(inputString)\n".data(using: .utf8) {
                        try? inputPipe.fileHandleForWriting.write(contentsOf: data)
                    }
                    inputPipe.fileHandleForWriting.closeFile()
                }
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
    
    /// Records the pid of the tunnel *this run* launched, so a later disconnect,
    /// connect timeout, or quit can name it again.
    ///
    /// `knownPid` is a pid the caller has already seen verified (the connect
    /// poller). `nil` means "find it", which costs a bounded scan of the process
    /// table and therefore never runs on the main thread.
    ///
    /// Either way the value is checked before it is written. This record is what
    /// three teardown paths will later *signal*, and the rest of this file is
    /// full of comments about what a record naming the wrong process once did.
    private func recordOwnTunnelPid(_ knownPid: Int32? = nil) {
        let store: (Int32) -> Void = { [weak self] pid in
            guard OpenConnectPidFile.record(pid) else { return }
            DispatchQueue.main.async {
                self?.debugOutput += "Recorded the tunnel's PID (\(pid)) so it can be ended later\n"
            }
        }

        if let knownPid {
            guard OpenConnectProcess.isOpenConnect(pid: knownPid) else { return }
            store(knownPid)
            return
        }

        DispatchQueue.global(qos: .utility).async {
            // No pid file: the question is only "which of these is mine", and the
            // detector answers it from this app's own recorded process group
            // first, so the name-wide scan is the last resort it always was.
            let detection = ExistingConnectionScanner.detect(pidFilePid: nil)
            guard let pid = detection.pid else { return }
            store(pid)
        }
    }

    // MARK: - Existing Connection Detection
    
    /// Checks if openconnect is already running (from a previous session)
    /// and updates the app status accordingly. Called on launch.
    /// Looks for a tunnel that is already running and adopts it, so relaunching
    /// the app does not orphan an openconnect it started itself.
    ///
    /// Adoption is a claim about the network, so it is gated on verification:
    /// the pid must be alive, must not be this app, and `ps` must say it is an
    /// openconnect. A PID file naming anything else is reported and discarded
    /// instead of adopted — the previous version adopted whatever pid that file
    /// held, or the first live pid from a command-line `pgrep`, and drew
    /// "Connected" over a tunnel that did not exist.
    private func checkForExistingConnection() {
        let pidFilePid = OpenConnectPidFile.recordedPid()
        let generation = connectionGeneration
        // `ps`/`pgrep` get up to 3 s each; the UI must not wait on them.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let detection = ExistingConnectionScanner.detect(pidFilePid: pidFilePid)
            DispatchQueue.main.async {
                guard let self, self.connectionGeneration == generation else { return }
                self.adoptExistingConnection(ifVerified: detection)
            }
        }
    }

    /// Adopts an existing tunnel, and *only* one that was verified.
    private func adoptExistingConnection(ifVerified detection: ExistingConnectionDetection) {
        for rejection in detection.rejections {
            debugOutput += rejection.explanation + "\n"
        }

        guard let pid = detection.pid else {
            if !detection.rejections.isEmpty {
                OpenConnectPidFile.discard()
                debugOutput += "Discarded a PID file that named no openconnect\n"
            }
            return
        }
        
        // Get the process start time for the duration display
        let startTime = processStartTime(pid: pid)
        // One start instant, used for both the timer and the history row, so
        // the two can never disagree about when this connection began.
        let start = startTime ?? Date()
        
        // Write the PID to the PID file so disconnect(), forceTerminate(),
        // and cleanupOnTermination() can find and gracefully kill openconnect.
        // The same call the launch path uses: one writer, one shape.
        if !OpenConnectPidFile.record(pid) {
            debugOutput += "Warning: could not record the tunnel's PID — the next disconnect will have to find it again\n"
        }
        
        debugOutput += "Found existing VPN connection (PID: \(pid), verified openconnect)\n"
        status = .connected
        connectionStartTime = start
        startDurationTimer(startingAt: start)
        
        // Also log to connection history
        let attemptId = UUID()
        currentAttemptId = attemptId
        let attempt = ConnectionAttempt(
            id: attemptId,
            timestamp: start,
            host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
            status: "Connected (adopted from existing process)",
            logOutput: debugOutput
        )
        ConnectionHistoryManager.shared.addAttempt(attempt)
    }
    
    /// Gets the process start time for the duration display.
    ///
    /// Returns nil if the process is gone, the read failed, or it ran out of
    /// time. Deliberately a *bounded* read of the elapsed field: this runs on the
    /// main thread on the launch path, and the previous version both waited on
    /// `ps` with no deadline at all and asked for `lstart`, a formatted date
    /// whose day and month names follow the machine's `LC_TIME`. See
    /// `ProcessStartTime`.
    private func processStartTime(pid: Int32) -> Date? {
        processStartTimeReader.startTime(pid: pid)
    }
}
