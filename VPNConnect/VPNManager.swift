import Foundation
import Cocoa
import Combine

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
    
    func clearHistory() {
        UserDefaults.standard.removeObject(forKey: historyKey)
    }
}

enum VPNStatus {
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
    private let pidFilePath = "/tmp/turtlediver.pid"
    private var currentAttemptId: UUID?
    
    private init() {}
    
    func connect() {
        guard case .disconnected = status else { return }
        
        status = .connecting
        debugOutput = "Starting VPN connection...\n"
        errorBurst = 0
        challengePending = false
        
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
        
        DispatchQueue.global(qos: .background).async {
            self.executeVPNConnection()
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
        
        // Try to kill using sudo if we have admin password
        let adminPwd = SettingsManager.shared.adminPassword
        if !adminPwd.isEmpty {
             // 1. Try kill by PID file
             if let pidStr = try? String(contentsOfFile: pidFilePath).trimmingCharacters(in: .whitespacesAndNewlines),
                !pidStr.isEmpty {
                 let killProc = Process()
                 killProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                 killProc.arguments = ["-S", "kill", pidStr]
                 let pipe = Pipe()
                 killProc.standardInput = pipe
                 try? killProc.run()
                 if let data = "\(adminPwd)\n".data(using: .utf8) {
                     try? pipe.fileHandleForWriting.write(contentsOf: data)
                 }
                 killProc.waitUntilExit()
             }
             
             // 2. Try pkill openconnect as backup
             let pkillProc = Process()
             pkillProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
             pkillProc.arguments = ["-S", "pkill", "openconnect"]
             let pipe = Pipe()
             pkillProc.standardInput = pipe
             try? pkillProc.run()
             if let data = "\(adminPwd)\n".data(using: .utf8) {
                 try? pipe.fileHandleForWriting.write(contentsOf: data)
             }
             pkillProc.waitUntilExit()
        } else {
             // Fallback for non-sudo or missing password (might fail if root)
             let pkillProc = Process()
             pkillProc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
             pkillProc.arguments = ["openconnect"]
             try? pkillProc.run()
             pkillProc.waitUntilExit()
        }
    }
    
    func disconnect() {
        if case .disconnected = status { return }
        
        status = .disconnecting
        debugOutput += "Disconnecting VPN...\n"
        
        // Log disconnection attempt
        if let id = currentAttemptId {
            let duration = connectionStartTime.map { Date().timeIntervalSince($0) }
            let attempt = ConnectionAttempt(
                id: id,
                timestamp: connectionStartTime ?? Date(),
                host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                status: "Disconnected",
                duration: duration,
                logOutput: debugOutput
            )
            ConnectionHistoryManager.shared.updateAttempt(attempt)
        }
        
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process {
            if proc.isRunning {
                let pid = proc.processIdentifier
                proc.terminate()
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) {
                    if proc.isRunning {
                        _ = kill(pid, SIGTERM)
                    }
                }
            }
        }
        process = nil
        cancelConnectionTimer()
        
        status = .disconnected
        debugOutput += "VPN disconnected\n"
        stopDurationTimer()
    }
    
    private func executeVPNConnection() {
        // Check for existing openconnect processes
        terminateExistingOpenConnect()
        
        let settings = SettingsManager.shared
        let withTunneling = settings.useTunneling
        
        // Generate token using stoken
        let token = generateToken(passcode: settings.vpnPasscode)
        guard !token.isEmpty else {
            DispatchQueue.main.async {
                self.status = .error("Failed to generate token")
                self.debugOutput += "Error: Failed to generate token using stoken\n"
            }
            return
        }
        
        let pin = settings.vpnPasscode + token
        
        if settings.adminPassword.isEmpty {
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Admin Password Required"
                alert.informativeText = "Please enter your local administrator password to configure network settings."
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Cancel")
                
                let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
                alert.accessoryView = input
                alert.window.initialFirstResponder = input
                
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    settings.adminPassword = input.stringValue
                }
                semaphore.signal()
            }
            semaphore.wait()
        }
        
        guard !settings.adminPassword.isEmpty else {
            DispatchQueue.main.async {
                self.status = .error("Admin password required")
                self.debugOutput += "Error: Admin password required for elevated openconnect\n"
            }
            return
        }
        
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
        
        // Create process
        let process = Process()
        let openconnectPath = binaryPath("openconnect")
        let sudoPath = "/usr/bin/sudo"
        if let oc = openconnectPath {
            process.executableURL = URL(fileURLWithPath: sudoPath)
            process.arguments = ["-S", oc] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["sudo", "-S", "openconnect"] + arguments
        }
        
        // Ensure PATH includes Homebrew locations
        var env = ProcessInfo.processInfo.environment
        let defaultPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = "\(defaultPaths):\(env["PATH"] ?? "")"
        process.environment = env
        
        // Set up pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Set up input for password
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        
        // Handle output
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.debugOutput += output
                    let lowerOut = output.lowercased()
                    
                    if lowerOut.contains("enter next passcode") {
                        self.challengePending = true
                    }
                    
                    if lowerOut.contains("passcode:") || lowerOut.contains("enter pin") {
                        if self.challengePending {
                            self.onChallenge?("Enter Next PASSCODE", { response in
                                let answer = "\(response)\n"
                                if let data = answer.data(using: .utf8) {
                                    inputPipe.fileHandleForWriting.write(data)
                                }
                                self.challengePending = false
                            })
                        } else {
                            let creds = "\(pin)\n"
                            if let data = creds.data(using: .utf8) {
                                inputPipe.fileHandleForWriting.write(data)
                            }
                        }
                    }
                    if lowerOut.contains("password:") {
                        let pw = "\(settings.vpnPassword)\n"
                        if let data = pw.data(using: .utf8) {
                            inputPipe.fileHandleForWriting.write(data)
                        }
                    }
                    if output.contains("Established DTLS")
                        || output.contains("ESP session established")
                        || output.contains("Connected as")
                        || output.contains("CSTP connected")
                        || output.contains("Configured as")
                        || output.contains("Got CONNECT response") {
                        if case .connecting = self.status {
                            self.status = .connected
                            self.startDurationTimer()
                            self.cancelConnectionTimer()
                            // Update history with successful connection
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
                    self.errorBurst = 0
                }
            }
        }
        
        let usingSlice = withTunneling
        var errorBuffer = Data()
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            
            errorBuffer.append(data)
            
            guard let fullString = String(data: errorBuffer, encoding: .utf8) else { return }
            
            // Process only if we have newlines or buffer is getting large
            if fullString.contains("\n") || errorBuffer.count > 4096 {
                var lines = fullString.components(separatedBy: .newlines)
                
                // Handle buffering
                if !fullString.hasSuffix("\n") {
                    if let last = lines.last {
                        errorBuffer = last.data(using: .utf8) ?? Data()
                        lines.removeLast()
                    }
                } else {
                    errorBuffer = Data()
                    if lines.last == "" { lines.removeLast() }
                }
                
                for line in lines {
                    let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleanLine.isEmpty { continue }
                    
                    DispatchQueue.main.async {
                        let lower = cleanLine.lowercased()
                        
                        // Benign slice output: show without "ERROR:" prefix
                        if usingSlice {
                            if lower.contains("got results:")
                               || lower.contains("dns in a rdata")
                               || lower.contains("route: writing to routing socket") {
                                
                                // Strip any leading "error: " and append
                                var display = cleanLine
                                if lower.hasPrefix("error: ") {
                                    display = String(cleanLine.dropFirst(7))
                                } else if lower.hasPrefix("error:") {
                                    display = String(cleanLine.dropFirst(6))
                                }
                                self.debugOutput += display + "\n"
                                self.errorBurst = 0
                                return
                            }
                        }
                        
                        // Ignore normal portal/transport messages during setup
                        if lower.contains("got http response")
                            || lower.contains("unexpected 404 result from server")
                            || lower.contains("get `http")
                            || lower.contains("post `http")
                            || lower.contains("no dtls address")
                            || lower.contains("set up udp failed; using ssl instead") {
                            return
                        }
                        
                        // Prompt handling
                        if lower.contains("enter next passcode") {
                            self.challengePending = true
                        }
                        
                        if lower.contains("please enter your username and password") || lower.contains("passcode:") {
                            if self.challengePending {
                                self.onChallenge?("Enter Next PASSCODE", { response in
                                    let answer = "\(response)\n"
                                    if let data = answer.data(using: .utf8) {
                                        inputPipe.fileHandleForWriting.write(data)
                                    }
                                    self.challengePending = false
                                })
                            } else {
                                let creds = "\(pin)\n"
                                if let data = creds.data(using: .utf8) {
                                    inputPipe.fileHandleForWriting.write(data)
                                }
                            }
                            self.debugOutput += "\(cleanLine)\n"
                            return
                        }
                        if lower.contains("password:") {
                            let pw = "\(settings.vpnPassword)\n"
                            if let data = pw.data(using: .utf8) {
                                inputPipe.fileHandleForWriting.write(data)
                            }
                            self.debugOutput += "\(cleanLine)\n"
                            return
                        }
                        
                        // Fatal errors
                        if lower.contains("sudo") || lower.contains("permission denied") {
                            self.debugOutput += "ERROR: \(cleanLine)\n"
                            if case .connecting = self.status {
                                self.status = .error("Requires admin privileges")
                                self.cancelConnectionTimer()
                            }
                            return
                        } else if lower.contains("operation not permitted") {
                            self.debugOutput += "ERROR: \(cleanLine)\n"
                            if case .connecting = self.status {
                                self.status = .error("Operation not permitted")
                                self.cancelConnectionTimer()
                                self.forceTerminate()
                            }
                            return
                        } else if lower.contains("administrator username or password was incorrect") || lower.contains("-60005") {
                             self.debugOutput += "ERROR: \(cleanLine)\n"
                            if case .connecting = self.status {
                                self.status = .error("Admin password incorrect")
                                self.cancelConnectionTimer()
                                self.forceTerminate()
                            }
                            return
                        } else if lower.contains("failed to open tun device") || lower.contains("failed to connect utun unit") {
                             self.debugOutput += "ERROR: \(cleanLine)\n"
                            if case .connecting = self.status {
                                self.status = .error("Tun setup failed")
                                self.cancelConnectionTimer()
                                self.forceTerminate()
                            }
                            return
                        } else if lower.contains("cstp dead peer detection detected dead peer!") {
                            self.debugOutput += "WARNING: \(cleanLine)\n"
                            return
                        } else if lower.contains("failed to reconnect to host") {
                            self.debugOutput += "WARNING: \(cleanLine)\n"
                            return
                        } else if lower.contains("login failed") {
                            self.debugOutput += "ERROR: \(cleanLine)\n"
                            self.forceTerminate()
                            self.status = .error("Login failed")
                            self.cancelConnectionTimer()
                            // Log error attempt
                            if let id = self.currentAttemptId {
                                let attempt = ConnectionAttempt(
                                    id: id,
                                    timestamp: self.connectionStartTime ?? Date(),
                                    host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                                    status: "Failed - Login Failed",
                                    logOutput: self.debugOutput
                                )
                                ConnectionHistoryManager.shared.updateAttempt(attempt)
                            }
                            return
                        } else if lower.contains("fgets (stdin): inappropriate ioctl for device") {
                            self.debugOutput += "ERROR: \(cleanLine)\n"
                            self.forceTerminate()
                            self.status = .error("Credential input error")
                            self.cancelConnectionTimer()
                            // Log error attempt
                            if let id = self.currentAttemptId {
                                let attempt = ConnectionAttempt(
                                    id: id,
                                    timestamp: self.connectionStartTime ?? Date(),
                                    host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                                    status: "Failed - Credential Error",
                                    logOutput: self.debugOutput
                                )
                                ConnectionHistoryManager.shared.updateAttempt(attempt)
                            }
                            return
                        }
                        
                        // Generic error handling
                        if lower.contains("error") {
                            // If it already says ERROR, don't duplicate
                            if lower.hasPrefix("error") {
                                self.debugOutput += "\(cleanLine)\n"
                            } else {
                                self.debugOutput += "ERROR: \(cleanLine)\n"
                            }
                            
                            if case .connecting = self.status {
                                self.status = .error("OpenConnect error")
                                self.cancelConnectionTimer()
                                // Log error attempt
                                if let id = self.currentAttemptId {
                                    let attempt = ConnectionAttempt(
                                        id: id,
                                        timestamp: self.connectionStartTime ?? Date(),
                                        host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                                        status: "Failed - \(cleanLine)",
                                        logOutput: self.debugOutput
                                    )
                                    ConnectionHistoryManager.shared.updateAttempt(attempt)
                                }
                            }
                            return
                        }
                        
                        if lower.contains("send bye") || lower.contains("terminating") {
                            self.debugOutput += "\(cleanLine)\n"
                            self.forceTerminate()
                            self.status = .disconnected
                            self.cancelConnectionTimer()
                            return
                        }
                        
                        // Default fallback for unknown stderr lines
                        if lower.hasPrefix("error") {
                            self.debugOutput += "\(cleanLine)\n"
                        } else {
                            self.debugOutput += "ERROR: \(cleanLine)\n"
                        }
                        self.errorBurst += 1
                    }
                }
            }
        }
        
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.inputPipe = inputPipe
        
        do {
            try process.run()
            
            // Send credentials
            let admin = settings.adminPassword
            if let d = "\(admin)\n\(pin)\n\(settings.vpnPassword)\n".data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(d)
            }
            
            DispatchQueue.main.async {
                if case .connecting = self.status {
                    self.debugOutput += "Awaiting connection confirmation...\n"
                }
            }
            
            process.terminationHandler = { proc in
                DispatchQueue.main.async {
                    self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                    self.errorPipe?.fileHandleForReading.readabilityHandler = nil
                    if proc.terminationStatus == 0 {
                        self.debugOutput += "VPN connection terminated normally\n"
                    } else {
                        self.debugOutput += "VPN connection terminated with error: \(proc.terminationStatus)\n"
                    }
                    self.status = .disconnected
                    self.cancelConnectionTimer()
                    self.errorBurst = 0
                    // Log termination attempt
                    if let id = self.currentAttemptId {
                        let duration = self.connectionStartTime.map { Date().timeIntervalSince($0) }
                        let attempt = ConnectionAttempt(
                            id: id,
                            timestamp: self.connectionStartTime ?? Date(),
                            host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                            status: proc.terminationStatus == 0 ? "Disconnected" : "Failed - Terminated",
                            duration: duration,
                            logOutput: self.debugOutput
                        )
                        ConnectionHistoryManager.shared.updateAttempt(attempt)
                    }
                }
            }
            
            self.startConnectionTimer(timeoutSeconds: 90)
            
        } catch {
            DispatchQueue.main.async {
                self.status = .error("Failed to start VPN: \(error.localizedDescription)")
                self.debugOutput += "Error: \(error.localizedDescription)\n"
                self.cancelConnectionTimer()
                // Log error attempt
                if let id = self.currentAttemptId {
                    let attempt = ConnectionAttempt(
                        id: id,
                        timestamp: self.connectionStartTime ?? Date(),
                        host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                        status: "Failed - \(error.localizedDescription)",
                        logOutput: self.debugOutput
                    )
                    ConnectionHistoryManager.shared.updateAttempt(attempt)
                }
            }
            self.forceTerminate()
        }
    }
    private func terminateExistingOpenConnect() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["openconnect"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                DispatchQueue.main.async {
                    self.debugOutput += "Found existing openconnect process. Terminating...\n"
                }
                
                // Kill existing openconnect processes
                let killProcess = Process()
                killProcess.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                killProcess.arguments = ["openconnect"]
                try? killProcess.run()
                killProcess.waitUntilExit()
                
                // Also try sudo kill if regular kill fails (likely needs sudo)
                if killProcess.terminationStatus != 0 {
                     // We can't easily sudo pkill without prompting, 
                     // but we can try to use the admin password if we have it,
                     // or just warn the user.
                     // For now, let's assume if we started it, we can kill it, 
                     // or if it was started with sudo, we might need sudo to kill it.
                     // Let's try to use the stored admin password to sudo kill if available
                    if !SettingsManager.shared.adminPassword.isEmpty {
                        let sudoKill = Process()
                        sudoKill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                        sudoKill.arguments = ["-S", "pkill", "openconnect"]
                        let inPipe = Pipe()
                        sudoKill.standardInput = inPipe
                        try? sudoKill.run()
                        if let d = "\(SettingsManager.shared.adminPassword)\n".data(using: .utf8) {
                            inPipe.fileHandleForWriting.write(d)
                        }
                        sudoKill.waitUntilExit()
                    }
                }
                
                // Wait a moment for cleanup
                Thread.sleep(forTimeInterval: 1.0)
            }
        } catch {
            print("Error checking for openconnect: \(error)")
        }
    }

    private func generateToken(passcode: String) -> String {
        let process = Process()
        let stokenPath = binaryPath("stoken")
        if let path = stokenPath {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["tokencode"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["stoken", "tokencode"]
        }
        
        // Ensure PATH includes Homebrew locations
        var env = ProcessInfo.processInfo.environment
        let defaultPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = "\(defaultPaths):\(env["PATH"] ?? "")"
        var startedAccess = false
        var usingTokenFile = false
        var tokenFilePath: String?
        if let tokenURL = SettingsManager.shared.resolvedStokenTokenURL() {
            if tokenURL.startAccessingSecurityScopedResource() {
                startedAccess = true
                usingTokenFile = true
                tokenFilePath = tokenURL.path
                var args = ["tokencode", "--file", tokenURL.path]
                if !passcode.isEmpty { args.append(contentsOf: ["-p", passcode]) }
                process.arguments = args
            }
        } else {
            let tokenPath = SettingsManager.shared.stokenTokenFilePath
            if !tokenPath.isEmpty {
                usingTokenFile = true
                tokenFilePath = tokenPath
                var args = ["tokencode", "--file", tokenPath]
                if !passcode.isEmpty { args.append(contentsOf: ["-p", passcode]) }
                process.arguments = args
            } else {
                if let stokenPath = stokenPath {
                    var args = ["tokencode"]
                    if !passcode.isEmpty { args.append(contentsOf: ["-p", passcode]) }
                    process.arguments = args
                } else {
                    var args = ["stoken", "tokencode"]
                    if !passcode.isEmpty { args.append(contentsOf: ["-p", passcode]) }
                    process.arguments = args
                }
                if let stokenURL = SettingsManager.shared.resolvedStokenURL() {
                    if stokenURL.startAccessingSecurityScopedResource() {
                        startedAccess = true
                        env["STOKEN_RC"] = stokenURL.path
                    }
                } else {
                    let rcPath = SettingsManager.shared.stokenRCPath
                    if !rcPath.isEmpty {
                        env["STOKEN_RC"] = rcPath
                    }
                }
            }
        }
        process.environment = env
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOut = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            if output.isEmpty {
                if usingTokenFile, let filePath = tokenFilePath {
                    let p2 = Process()
                    if let path = stokenPath {
                        p2.executableURL = URL(fileURLWithPath: path)
                        p2.arguments = ["tokencode", "--file", filePath]
                    } else {
                        p2.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        p2.arguments = ["stoken", "tokencode", "--file", filePath]
                    }
                    p2.environment = env
                    let o2 = Pipe()
                    let e2 = Pipe()
                    p2.standardOutput = o2
                    p2.standardError = e2
                    try? p2.run()
                    p2.waitUntilExit()
                    let out2 = String(data: o2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !out2.isEmpty {
                        if startedAccess {
                            if usingTokenFile, let url = SettingsManager.shared.resolvedStokenTokenURL() {
                                url.stopAccessingSecurityScopedResource()
                            } else if let url = SettingsManager.shared.resolvedStokenURL() {
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                        return out2
                    }
                }
                DispatchQueue.main.async {
                    self.debugOutput += "stoken error: \(errorOut)\n"
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
                    // Log error attempt
                    if let id = self.currentAttemptId {
                        let attempt = ConnectionAttempt(
                            id: id,
                            timestamp: self.connectionStartTime ?? Date(),
                            host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                            status: "Failed - Token Error",
                            logOutput: self.debugOutput
                        )
                        ConnectionHistoryManager.shared.updateAttempt(attempt)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.debugOutput += "stoken path: \(stokenPath ?? "/usr/bin/env stoken")\n"
                    if usingTokenFile {
                        self.debugOutput += "Using --file\n"
                    } else {
                        if let rc = env["STOKEN_RC"] {
                            self.debugOutput += "Using STOKEN_RC: \(rc)\n"
                        }
                    }
                }
            }
            
            if startedAccess {
                if usingTokenFile, let url = SettingsManager.shared.resolvedStokenTokenURL() {
                    url.stopAccessingSecurityScopedResource()
                } else if let url = SettingsManager.shared.resolvedStokenURL() {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return output
        } catch {
            DispatchQueue.main.async {
                self.debugOutput += "Error generating token: \(error.localizedDescription)\n"
                self.debugOutput += "Tried path: \(stokenPath ?? "/usr/bin/env stoken")\n"
                if usingTokenFile {
                    self.debugOutput += "Using --file\n"
                } else {
                    if let rc = env["STOKEN_RC"] {
                        self.debugOutput += "STOKEN_RC: \(rc)\n"
                    }
                }
                // Log error attempt
                if let id = self.currentAttemptId {
                    let attempt = ConnectionAttempt(
                        id: id,
                        timestamp: self.connectionStartTime ?? Date(),
                        host: SettingsManager.shared.vpnHost.isEmpty ? "Unknown" : SettingsManager.shared.vpnHost,
                        status: "Failed - Token Error",
                        logOutput: self.debugOutput
                    )
                    ConnectionHistoryManager.shared.updateAttempt(attempt)
                }
            }
            if startedAccess {
                if usingTokenFile, let url = SettingsManager.shared.resolvedStokenTokenURL() {
                    url.stopAccessingSecurityScopedResource()
                } else if let url = SettingsManager.shared.resolvedStokenURL() {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return ""
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
    
    private func forceTerminate() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        if let proc = process {
            if proc.isRunning {
                let pid = proc.processIdentifier
                proc.terminate()
                DispatchQueue.global(qos: .background).async {
                    usleep(500_000)
                    if proc.isRunning {
                        _ = kill(pid, SIGTERM)
                        usleep(500_000)
                        if proc.isRunning {
                            _ = kill(pid, SIGKILL)
                        }
                    }
                }
            }
        }
        // Fallback: kill by pid file if exists
        if let pidStr = try? String(contentsOfFile: pidFilePath).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            _ = kill(pid, SIGTERM)
            usleep(500_000)
            _ = kill(pid, SIGKILL)
        }
        process = nil
        stopDurationTimer()
    }
    
    private func shellEscape(_ s: String) -> String {
        if s.isEmpty { return "''" }
        return "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    
    private func launchElevatedViaAppleScript(openconnectPath: String?, args: [String], pin: String, password: String) {
        let oc = openconnectPath ?? "openconnect"
        let pathEnv = "export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        let ocQ = shellEscape(oc)
        let argsQ = args.map(shellEscape).joined(separator: " ")
        let pinQ = shellEscape(pin)
        let passQ = shellEscape(password)
        let pidQ = shellEscape(pidFilePath)
        let shell = "\(pathEnv); printf %s\\\\n%s\\\\n \(pinQ) \(passQ) | \(ocQ) --passwd-on-stdin \(argsQ) -b --pid-file \(pidQ)"
        let appleScript = "do shell script \"\(shell)\" with administrator privileges"
        
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if !stdout.isEmpty { self.debugOutput += stdout + "\n" }
                if !stderr.isEmpty { self.debugOutput += "ERROR: \(stderr)\n" }
                if proc.terminationStatus == 0 {
                    self.debugOutput += "Elevated openconnect launched. Verifying...\n"
                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1.0) {
                        if let pidStr = try? String(contentsOfFile: self.pidFilePath).trimmingCharacters(in: .whitespacesAndNewlines),
                           !pidStr.isEmpty {
                            DispatchQueue.main.async {
                                self.debugOutput += "Elevated openconnect running with PID \(pidStr)\n"
                                if case .connecting = self.status {
                                    self.status = .connected
                                }
                            }
                        } else {
                            DispatchQueue.main.async {
                                self.status = .error("Elevated launch verification failed")
                            }
                        }
                    }
                } else {
                    self.status = .error("Elevated launch failed")
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.debugOutput += "AppleScript elevation error: \(error.localizedDescription)\n"
                self.status = .error("Elevation error")
            }
        }
    }
}
