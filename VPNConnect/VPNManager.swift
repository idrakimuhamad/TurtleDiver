import Foundation
import Cocoa
import Combine

// MARK: - Connection Log File

/// Writes a detailed, timestamped trace of the VPN connection I/O to a file.
/// Use this to debug credential flow issues that are not visible in the UI debug panel.
final class VpnConnectionLogger: @unchecked Sendable {
    static let logPath = "/tmp/turtlediver-vpn.log"
    
    private let queue = DispatchQueue(label: "com.turtlediver.vpn-log", qos: .utility)
    private var fileHandle: FileHandle?
    
    init() {
        // Truncate the log file on each connection
        FileManager.default.createFile(atPath: Self.logPath, contents: nil, attributes: nil)
        if let handle = FileHandle(forWritingAtPath: Self.logPath) {
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
    private var durationTimer: Timer?
    private var connectionStartTime: Date?
    private var errorBurst: Int = 0
    private var challengePending = false
    /// Tracks whether we have already sent credentials for the current
    /// prompt round, preventing duplicate writes when the server sends
    /// multiple "PASSCODE:" lines in the same batch.
    private var passcodePromptCount = 0
    private let pidFilePath = "/tmp/turtlediver.pid"
    private var currentAttemptId: UUID?
    
    /// Incremented on each `connect()` call so stale termination handlers
    /// from a previous connection can detect they should not act on state.
    private var connectionGeneration: UInt64 = 0
    
    /// Timer that polls for openconnect connection success via PID file / pgrep.
    private var connectionPollTimer: DispatchSourceTimer?
    
    /// Flag set when the pipe write-end has been closed, preventing
    /// readability handlers from attempting writes after forceTerminate().
    private var pipeClosed = false
    
    private init() {}
    
    func connect() {
        guard case .disconnected = status else { return }
        
        connectionGeneration += 1
        status = .connecting
        debugOutput = "Starting VPN connection...\n"
        errorBurst = 0
        challengePending = false
        passcodePromptCount = 0
        
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
        
        // Setup proxy if enabled
        if settings.useProxy, let proxyConfig = settings.selectedProxy {
            DispatchQueue.main.async {
                self.debugOutput += "Setting up proxy: \(proxyConfig.name)...\n"
            }
            Task {
                do {
                    try await ProxyManager.shared.setupProxy(for: proxyConfig, adminPassword: settings.adminPassword)
                    await MainActor.run {
                        self.debugOutput += "Proxy configured successfully\n"
                    }
                } catch {
                    await MainActor.run {
                        self.debugOutput += "Warning: Failed to setup proxy: \(error.localizedDescription)\n"
                    }
                }
            }
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
        
        // Teardown proxy if it was enabled
        let settings = SettingsManager.shared
        if settings.useProxy {
            Task {
                await ProxyManager.shared.teardownProxy(adminPassword: settings.adminPassword)
            }
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
        
        // Teardown proxy if it was enabled
        let settings = SettingsManager.shared
        if settings.useProxy {
            Task {
                await ProxyManager.shared.teardownProxy(adminPassword: settings.adminPassword)
            }
            debugOutput += "Proxy teardown complete\n"
        }
        
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
    }
    
    private func executeVPNConnection() async {
        // Check for existing openconnect processes
        await terminateExistingOpenConnect()
        
        let settings = SettingsManager.shared
        let withTunneling = settings.useTunneling
        
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
        var arguments: [String] = ["--force-dpd=10", "--user=\(settings.vpnID)", "--pid-file", pidFilePath]
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
        
        // Ensure admin password is available for sudo -S
        if settings.adminPassword.isEmpty {
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
        let defaultPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let pathEnv = "export PATH=\(shellEscape(defaultPaths)):$PATH"
        let ocEscaped = shellEscape(openconnectPath)
        let argsEscaped = arguments.map(shellEscape).joined(separator: " ")
        let adminPwdEscaped = shellEscape(settings.adminPassword)
        let pinEscaped = shellEscape(pin)
        let passEscaped = shellEscape(settings.vpnPassword)
        
        // Build command matching the working vpn.sh script:
        // 1. Pre-cache sudo password via `echo <pwd> | sudo -S -v`
        // 2. Pipe credentials directly to `sudo openconnect` (no -S — all stdin goes to openconnect)
        // This avoids sudo -S consuming credential data meant for openconnect, matching the
        // working script where `printf "$PIN\n$PASSWORD" | sudo openconnect ...` passes all stdin to openconnect.
        // Credential order: PIN (passcode+tokencode) first, VPN password second.
        let shellCommand = "\(pathEnv); echo \(adminPwdEscaped) | sudo -S -v && printf '%s\\n%s\\n' \(pinEscaped) \(passEscaped) | sudo \(ocEscaped) \(argsEscaped)"
        
        // Connection file logger
        let log = VpnConnectionLogger()
        log.write("Host: \(settings.vpnHost)")
        log.write("User: \(settings.vpnID)")
        log.write("Tunneling: \(withTunneling)")
        log.write("openconnect path: \(openconnectPath)")
        log.write("Arguments: \(arguments)")
        log.write("Command: printf '<admin_pwd>\\n<PIN>\\n<PASS>' | sudo -S -v && sudo openconnect <args> (matches working vpn.sh)")
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
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        
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
            
            self.startConnectionTimer(timeoutSeconds: 90)
            
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
        
        // 4. Clean up the stale PID file
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
    
    private func logTokenErrorAttempt() {
        if let id = currentAttemptId {
            let attempt = ConnectionAttempt(
                id: id,
                timestamp: connectionStartTime ?? Date(),
                host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                status: "Failed - Token Error",
                logOutput: debugOutput
            )
            ConnectionHistoryManager.shared.updateAttempt(attempt)
        }
    }
    
    private func binaryPath(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        let fm = FileManager.default
        for p in candidates {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
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
                    self.status = .error("Connection timeout")
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
    
    private func shellEscape(_ s: String) -> String {
        if s.isEmpty { return "''" }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
    }
}
