import Foundation

// MARK: - Process Error

enum ProcessError: LocalizedError {
    case exitStatus(Int32, String)
    
    var errorDescription: String? {
        switch self {
        case .exitStatus(let code, let stderr):
            return "Process exited with code \(code): \(stderr)"
        }
    }
}

// MARK: - Proxy Manager

class ProxyManager {
    static let shared = ProxyManager()
    
    private var httpServerProcess: Process?
    private let pacDirectory: URL
    
    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        pacDirectory = appSupport.appendingPathComponent("PACFiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: pacDirectory, withIntermediateDirectories: true)
    }
    
    var pacFilesDirectory: URL { return pacDirectory }
    
    // MARK: - Process Helper
    
    /// Runs a subprocess and returns stdout/stderr asynchronously.
    private func runProcess(
        executable: URL,
        arguments: [String] = [],
        input: String? = nil,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil
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
            
            if let dir = currentDirectory {
                process.currentDirectoryURL = dir
            }
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            if input != nil {
                let inputPipe = Pipe()
                process.standardInput = inputPipe
            }
            
            var stdoutData = Data()
            var stderrData = Data()
            
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
                // Clean up handlers
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                
                // Read any remaining data
                stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: (stdout, stderr))
                } else {
                    continuation.resume(throwing: ProcessError.exitStatus(proc.terminationStatus, stderr))
                }
            }
            
            do {
                try process.run()
                
                // Write input after process starts
                if let inputString = input, let inputPipe = process.standardInput as? Pipe {
                    if let data = "\(inputString)\n".data(using: .utf8) {
                        inputPipe.fileHandleForWriting.write(data)
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
    
    // MARK: - PAC File Management
    
    func savePACFile(named name: String, content: String) async throws -> URL {
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let fileURL = pacDirectory.appendingPathComponent("\(safeName).pac")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
    
    func deletePACFile(at url: URL) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    func readPACFile(at url: URL) async throws -> String {
        return try String(contentsOf: url, encoding: .utf8)
    }
    
    // MARK: - PAC Server
    
    func startPACServer(for pacFileURL: URL, port: UInt16 = 8765) async throws {
        await stopPACServer()
        
        // Copy PAC file to /tmp/proxy.pac
        let tmpPAC = URL(fileURLWithPath: "/tmp/proxy.pac")
        try? FileManager.default.removeItem(at: tmpPAC)
        try FileManager.default.copyItem(at: pacFileURL, to: tmpPAC)
        
        // Start Python HTTP server in /tmp
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", "\(port)"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        
        let devNull = FileHandle.nullDevice
        process.standardOutput = devNull
        process.standardError = devNull
        
        try process.run()
        httpServerProcess = process
        
        // Give the server a moment to start
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
    }
    
    func stopPACServer() {
        if let process = httpServerProcess, process.isRunning {
            process.terminate()
        }
        httpServerProcess = nil
    }
    
    func setAutoProxyURL(_ urlString: String, for service: String = "Wi-Fi", adminPassword: String) async throws {
        try await runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/networksetup"),
            arguments: ["-setautoproxyurl", service, urlString],
            input: adminPassword
        )
    }
    
    func disableAutoProxy(for service: String = "Wi-Fi", adminPassword: String) async throws {
        try await runProcess(
            executable: URL(fileURLWithPath: "/usr/sbin/networksetup"),
            arguments: ["-setautoproxystate", service, "off"],
            input: adminPassword
        )
    }
    
    func setupProxy(for proxyConfig: ProxyConfiguration, adminPassword: String, port: UInt16 = 8765) async throws {
        guard let pacURL = proxyConfig.resolvedPACURL else {
            throw ProxyError.invalidPACFile
        }
        
        try await startPACServer(for: pacURL, port: port)
        
        let proxyURLString = "http://127.0.0.1:\(port)/proxy.pac"
        try await setAutoProxyURL(proxyURLString, adminPassword: adminPassword)
    }
    
    func teardownProxy(adminPassword: String) async {
        stopPACServer()
        try? await disableAutoProxy(adminPassword: adminPassword)
    }
}

// MARK: - Proxy Error

enum ProxyError: LocalizedError {
    case invalidPACFile
    case failedToSetProxyURL(String)
    case failedToDisableProxy(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidPACFile:
            return "Invalid PAC file"
        case .failedToSetProxyURL(let detail):
            return "Failed to set proxy URL: \(detail)"
        case .failedToDisableProxy(let detail):
            return "Failed to disable proxy: \(detail)"
        }
    }
}
