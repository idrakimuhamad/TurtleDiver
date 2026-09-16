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
}

class VPNManager: ObservableObject {
    static let shared = VPNManager()
    
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
    private var currentAttemptId: UUID?
    
    /// Incremented on each `connect()` call so stale termination handlers
    /// from a previous connection can detect they should not act on state.
    private var connectionGeneration: UInt64 = 0
    
    /// Timer that polls for openconnect connection success via PID file / pgrep.
    private var connectionPollTimer: DispatchSourceTimer?
    
    /// Flag set when the pipe write-end has been closed, preventing
    /// readability handlers from attempting writes after forceTerminate().
    private var pipeClosed = false
    
    private init() {
        // Check for existing openconnect process on launch
        DispatchQueue.main.async { [weak self] in
            self?.checkForExistingConnection()
        }
    }
    
    func connect() {
        guard case .disconnected = status else { return }
        
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
        
        // Gracefully terminate openconnect via PID file (allows clean network teardown)
        if let pidStr = try? String(contentsOfFile: pidFilePath).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), !pidStr.isEmpty, kill(pid, 0) == 0 {
            // Blocking call — this is called from applicationWillTerminate on the main thread,
            // but it's essential to give openconnect time to restore network settings before exit.
            kill(pid, SIGTERM)
            let deadline = DispatchTime.now() + .seconds(3)
            while DispatchTime.now() < deadline {
                usleep(200_000)
                if kill(pid, 0) != 0 { break }
            }
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL) // Last resort — app is quitting anyway
            }
        } else {
            // PID file missing — try pkill with SIGTERM (not SIGKILL)
            let pkillTask = Process()
            pkillTask.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            pkillTask.arguments = ["-15", "openconnect"]
            try? pkillTask.run()
            // Don't wait — the process may take time to clean up, but the app is exiting.
            // The network may briefly be in a bad state until the kernel cleans up.
        }

        // Best effort before the process goes away. It is asynchronous, so it may
        // not finish — in which case the record stays and the next launch sweeps it.
        reapLaunchProcessGroupInBackground()
    }
    
    func disconnect() {
        if case .disconnected = status { return }
        
        // Use appropriate log message depending on current state
        let wasConnecting = if case .connecting = status { true } else { false }
        
        status = .disconnecting
        if wasConnecting {
            debugOutput += "Cancelling connection...\n"
        } else {
            debugOutput += "Disconnecting VPN...\n"
        }
        
        let settings = SettingsManager.shared
        
        // Log disconnection attempt
        if let id = currentAttemptId {
            let duration = connectionStartTime.map { Date().timeIntervalSince($0) }
            let attempt = ConnectionAttempt(
                id: id,
                timestamp: connectionStartTime ?? Date(),
                host: settings.vpnHost.isEmpty ? "Unknown" : settings.vpnHost,
                status: "Disconnected",
                duration: duration,
                logOutput: debugOutput
            )
            ConnectionHistoryManager.shared.updateAttempt(attempt)
        }
        
        // STEP 1: Gracefully terminate openconnect (allows clean network teardown)
        if let pidStr = try? String(contentsOfFile: pidFilePath)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), !pidStr.isEmpty {
            debugOutput += "Terminating openconnect (PID: \(pid)) gracefully...\n"
            let cleanExit = terminateGracefully(pid: pid)
            if cleanExit {
                debugOutput += "openconnect exited cleanly, network restored\n"
            } else {
                debugOutput += "openconnect force-killed (network may need manual restore)\n"
            }
        }
        
        // No pkill -9 backup — it races with graceful SIGTERM and prevents
        // openconnect from restoring network routes/DNS, causing internet loss.
        //
        // NOTE: We do NOT clean up stale vpn-slice /etc/hosts entries here.
        // vpn-slice's atexit handlers clean up on graceful SIGTERM. If they fail
        // (e.g. sudo cache expired), the next connection's shell command pipeline
        // handles the cleanup before connecting.
        
        // STEP 2: Clean up PID file
        try? FileManager.default.removeItem(atPath: pidFilePath)
        
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
        
        status = .disconnected
        debugOutput += "VPN disconnected\n"
        stopDurationTimer()
        reapLaunchProcessGroupInBackground()
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
                            self.startDurationTimer()
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
    
    private func terminateExistingOpenConnect() async {
        let adminPwd = SettingsManager.shared.adminPassword
        var existingPid: Int32?
        
        // 1. Check PID file first — extract PID to avoid reading the file twice
        if let pidStr = try? String(contentsOfFile: pidFilePath)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), !pidStr.isEmpty, kill(pid, 0) == 0 {
            existingPid = pid
        }
        
        // 2. Fall back to pgrep
        if existingPid == nil {
            let pgrepExec = URL(fileURLWithPath: "/usr/bin/pgrep")
            if let pgrepResult = try? await runProcess(executable: pgrepExec, arguments: ["-f", "openconnect"]),
               !pgrepResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // We know a process exists, but we don't have a reliable PID yet
                // (the pgrep output could include multiple PIDs). We'll rely on
                // sudo pkill -9 below to kill it.
            } else {
                return // No process found
            }
        }
        
        await MainActor.run {
            self.debugOutput += "Found existing openconnect process. Terminating...\n"
        }
        
        // 3. Gracefully terminate by PID file first
        if let pid = existingPid {
            await MainActor.run {
                self.debugOutput += "Gracefully terminating existing openconnect (PID: \(pid))...\n"
            }
            terminateGracefully(pid: pid)
        } else {
            await MainActor.run {
                self.debugOutput += "No PID file found, sending SIGTERM via pkill...\n"
            }
            // Use pkill with SIGTERM (signal 15) instead of SIGKILL,
            // giving openconnect a chance to restore network configuration.
            _ = try? await runProcess(
                executable: URL(fileURLWithPath: "/usr/bin/pkill"),
                arguments: ["-15", "-f", "openconnect"]
            )
            // Give it time to clean up
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        
        // 4. Clean up any stale vpn-slice entries from /etc/hosts
        // (entries from a partially-killed previous session prevent the new connection from working)
        await MainActor.run {
            self.cleanupVpnSliceHosts()
        }
        
        // 5. Clean up the stale PID file
        try? FileManager.default.removeItem(atPath: pidFilePath)
        
        // Wait for cleanup to complete
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
    
    /// The elevation snapshot, taken off the main thread: it shells out to
    /// `sudo -n -v` (bounded, but up to 3 s) and reads two files. Neither the
    /// window nor the cooperative pool should be waiting on that.
    private static func elevationSnapshot() async -> ElevationSnapshot {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ElevationProbe.live(
                    readFile: { try? String(contentsOfFile: $0, encoding: .utf8) },
                    sudoTimestampIsWarm: { SudoProbe.isTimestampWarm() }
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
    
    /// Polls the PID file every 2 seconds to detect when openconnect has
    /// successfully started. Since we now run bash directly (not through
    /// osascript), stdout/stderr arrive in real-time via readability handlers.
    /// This polling timer is a secondary fallback for detecting the connection.
    ///
    /// Detection strategy (tiered):
    /// 1. Check the PID file (written by openconnect via `--pid-file`) — instant
    ///    when openconnect supports it.
    /// 2. After 10 seconds without a PID file, fall back to pgrep. Since
    ///    `terminateExistingOpenConnect()` already cleaned up stale processes
    ///    before starting, any new openconnect PID found by pgrep must be from
    ///    the current connection. We exclude the bash process PID itself.
    ///
    /// This avoids false positives from stale processes (which pgrep without
    /// cleanup would detect) while still working when openconnect doesn't
    /// write the PID file in foreground mode.
    private func startConnectionPollingTimer(log: VpnConnectionLogger, gen: UInt64) {
        // Cancel any previous polling timer
        connectionPollTimer?.cancel()
        
        // The bash process that launched this connection. At this point
        // `self.process` has been set and `proc.run()` has been called,
        // so `processIdentifier` should be valid. We'll exclude this PID
        // from pgrep results to avoid detecting the bash wrapper itself.
        let bashPid: Int32? = self.process?.processIdentifier
        
        // Track how many polls have elapsed. After 5 (10 seconds), fall back
        // to pgrep if the PID file hasn't appeared.
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
            
            // Tier 1: Check the PID file (fast path)
            if let pidStr = try? String(contentsOfFile: self.pidFilePath)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let pid = Int32(pidStr),
               !pidStr.isEmpty,
               kill(pid, 0) == 0 {
                detectedPid = pid
                log.write("[POLL] PID file found — PID \(pid) is alive")
            }
            
            // Tier 2: After 10 seconds, fall back to pgrep
            // We exclude the osascript PID because `pgrep -f openconnect`
            // will match osascript's command line (the -e argument contains
            // "openconnect").
            if detectedPid == nil && pollCount >= 5 {
                let pgrepTask = Process()
                pgrepTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
                pgrepTask.arguments = ["-f", "openconnect"]
                let outPipe = Pipe()
                pgrepTask.standardOutput = outPipe
                pgrepTask.standardError = FileHandle.nullDevice
                try? pgrepTask.run()
                pgrepTask.waitUntilExit()
                
                if pgrepTask.terminationStatus == 0 {
                    let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: .newlines)
                        .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                    
                    // Pick the first PID that is NOT the shell process and is still alive
                    detectedPid = pids.first { runningPid in
                        runningPid != bashPid
                        && runningPid != ProcessInfo.processInfo.processIdentifier
                        && kill(runningPid, 0) == 0
                    }
                    
                    if let pid = detectedPid {
                        log.write("[POLL] pgrep fallback found openconnect PID \(pid) (bash PID: \(bashPid ?? -1))")
                    }
                }
            }
            
            guard let pid = detectedPid else { return }
            
            // Connection detected! Update status.
            log.flush()
            pollTimer.cancel()
            self.connectionPollTimer = nil
            
            DispatchQueue.main.async {
                guard case .connecting = self.status, self.connectionGeneration == gen else { return }
                self.debugOutput += "VPN connection established (PID: \(pid))\n"
                self.status = .connected
                self.startDurationTimer()
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
    
    private func startDurationTimer() {
        DispatchQueue.main.async {
            self.connectionStartTime = Date()
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
    private func terminateGracefully(pid: Int32, timeoutSeconds: TimeInterval = 3.0) -> Bool {
        guard kill(pid, 0) == 0 else { return true } // already dead
        
        kill(pid, SIGTERM)
        
        let deadline = DispatchTime.now() + .seconds(Int(timeoutSeconds))
        while DispatchTime.now() < deadline {
            usleep(200_000) // 200ms
            if kill(pid, 0) != 0 { return true } // exited cleanly
        }
        
        // Only force-kill as last resort — this may leave network in a bad state
        kill(pid, SIGKILL)
        return false
    }
    
    private func forceTerminate() {
        // Mark the pipe as closed so readability handlers skip writes
        pipeClosed = true
        
        // Clear readability handlers FIRST to prevent any new callbacks
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        
        // Gracefully terminate openconnect (allows clean network teardown)
        if let pidStr = try? String(contentsOfFile: pidFilePath).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            terminateGracefully(pid: pid)
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
    
    // MARK: - /etc/hosts Cleanup
    
    /// Removes any stale vpn-slice entries from /etc/hosts.
    /// vpn-slice marks its entries with "# vpn-slice-<IFACE> AUTOCREATED".
    /// When openconnect is terminated, vpn-slice's atexit handlers should
    /// clean these up, but they often fail because:
    ///   - sudo's credential cache expires (default 5 min), causing the
    ///     cleanup to hang waiting for a password that never arrives
    ///   - SIGKILL (after the 3-second grace window) kills vpn-slice
    ///     before its atexit handlers can run
    /// Stale entries cause the next connection to fail because DNS
    /// resolution still points to old tunnel IPs that no longer exist.
    ///
    /// `.warmTimestamp`, never `.storedPassword`: this can run while the app is
    /// quitting, and a dialog raised on the way out is one nobody can answer.
    /// `sudo -n` either works or fails immediately, and the app does not need the
    /// administrator password at all in this mode — so the cleanup now happens
    /// even when no password is stored.
    private func cleanupVpnSliceHosts() {
        let plan = OpenConnectCommand.hostsCleanupPlan(
            adminPassword: SettingsManager.shared.adminPassword,
            elevation: .warmTimestamp
        )

        // Bounded, because this runs on the quit path: a wedged `sudo` must not be
        // able to hold the app open. The runner gives the script /dev/null on
        // stdin, which is not a compromise here — `.warmTimestamp` writes no
        // credential to the pipe, so there is nothing to withhold.
        do {
            let result = try SystemBoundedProcessRunner().run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", plan.script],
                timeout: 5
            )
            if result.timedOut {
                debugOutput += "Warning: /etc/hosts cleanup timed out; the next connect will retry it\n"
            } else if result.terminationStatus == 0 {
                debugOutput += "Cleaned up stale vpn-slice entries from /etc/hosts\n"
            } else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let reason = stderr.isEmpty ? "exit status \(result.terminationStatus)" : stderr
                debugOutput += "Warning: Failed to clean /etc/hosts: \(reason)\n"
            }
        } catch {
            debugOutput += "Warning: Failed to clean /etc/hosts: \(error.localizedDescription)\n"
        }
    }
    
    // MARK: - Existing Connection Detection
    
    /// Checks if openconnect is already running (from a previous session)
    /// and updates the app status accordingly. Called on launch.
    private func checkForExistingConnection() {
        // Tier 1: Check PID file
        var existingPid: Int32?
        if let pidStr = try? String(contentsOfFile: pidFilePath)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr), !pidStr.isEmpty, kill(pid, 0) == 0 {
            existingPid = pid
        }
        
        // Tier 2: Fall back to pgrep
        if existingPid == nil {
            let pgrepTask = Process()
            pgrepTask.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrepTask.arguments = ["-f", "openconnect"]
            let outPipe = Pipe()
            pgrepTask.standardOutput = outPipe
            pgrepTask.standardError = FileHandle.nullDevice
            do {
                try pgrepTask.run()
                pgrepTask.waitUntilExit()
                if pgrepTask.terminationStatus == 0 {
                    let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        .components(separatedBy: .newlines)
                        .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                    // Exclude our own process
                    existingPid = pids.first { $0 != ProcessInfo.processInfo.processIdentifier && kill($0, 0) == 0 }
                }
            } catch {
                // pgrep not available — no detection possible
                return
            }
        }
        
        guard let pid = existingPid else { return }
        
        // Get the process start time for the duration display
        let startTime = processStartTime(pid: pid)
        
        // Write the PID to the PID file so disconnect(), forceTerminate(),
        // and cleanupOnTermination() can find and gracefully kill openconnect.
        try? "\(pid)\n".write(toFile: pidFilePath, atomically: false, encoding: .utf8)
        
        debugOutput += "Found existing VPN connection (PID: \(pid))\n"
        status = .connected
        connectionStartTime = startTime ?? Date()
        startDurationTimer()
        
        // Also log to connection history
        let attemptId = UUID()
        currentAttemptId = attemptId
        let attempt = ConnectionAttempt(
            id: attemptId,
            timestamp: connectionStartTime ?? Date(),
            host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
            status: "Connected (adopted from existing process)",
            logOutput: debugOutput
        )
        ConnectionHistoryManager.shared.addAttempt(attempt)
    }
    
    /// Gets the process start time by parsing `ps -o lstart= -p <pid>`.
    /// Returns nil if the process is gone or the command fails.
    private func processStartTime(pid: Int32) -> Date? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "lstart=", "-p", "\(pid)"]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !output.isEmpty else { return nil }
            // ps -o lstart= format: "Sat Jun 29 10:30:45 2026"
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            return formatter.date(from: output)
        } catch {
            return nil
        }
    }
}
