import Foundation

// MARK: - Errors

public enum SystemProxyError: LocalizedError, Equatable {
    case cannotListServices(String)
    case snapshotUnavailable
    case restoreFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotListServices(let detail):
            return "Could not list network services: \(detail)"
        case .snapshotUnavailable:
            return "No saved proxy snapshot to restore (proxy was not enabled)"
        case .restoreFailed(let detail):
            return "Failed to restore previous proxy settings: \(detail)"
        }
    }
}

// MARK: - Service List

/// One network service as reported by `networksetup -listallnetworkservices`.
public struct NetworkService: Equatable, Sendable {
    public let name: String
    /// True for the hardware ports macOS auto-enables (Wi-Fi, Ethernet…);
    /// false for disabled services and placeholder lines like `*` or `**`.
    public let enabled: Bool

    public init(name: String, enabled: Bool = true) {
        self.name = name
        self.enabled = enabled
    }
}

// MARK: - Snapshot

/// Per-service proxy state captured before enabling the system proxy, so
/// `disable()` can put everything back exactly as it was.
public struct ProxySettingsSnapshot: Codable, Equatable, Sendable {
    public struct ServiceState: Codable, Equatable, Sendable {
        public let service: String
        /// `networksetup -getwebproxy` output (verbatim).
        public let web: String
        /// `networksetup -getsecurewebproxy` output (verbatim).
        public let secureWeb: String
        /// `networksetup -getsocksfirewallproxy` output (verbatim).
        public let socks: String
        /// `networksetup -getautoproxyurl` output (verbatim). Optional so
        /// snapshots written before PAC capture existed still decode.
        public let autoProxy: String?

        public init(service: String, web: String, secureWeb: String, socks: String, autoProxy: String? = nil) {
            self.service = service
            self.web = web
            self.secureWeb = secureWeb
            self.socks = socks
            self.autoProxy = autoProxy
        }
    }

    /// Only services that had at least one non-disabled proxy are snapshotted;
    /// untouched services are cleared on disable instead of restored.
    public var states: [ServiceState]
    public let capturedAt: Date

    public init(states: [ServiceState], capturedAt: Date = Date()) {
        self.states = states
        self.capturedAt = capturedAt
    }
}

// MARK: - Command Runner Abstraction

/// Runs a `networksetup` invocation. Abstracted so the manager's logic can be
/// tested without touching real system settings.
public protocol NetworkSetupRunning: AnyObject, Sendable {
    /// Returns stdout; throws on non-zero exit.
    func run(arguments: [String]) throws -> String
}

/// Thread-safe output accumulator (local copy of the app-level buffer so this
/// target stays Foundation-only).
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ other: Data) {
        lock.lock(); data.append(other); lock.unlock()
    }
    var value: Data {
        lock.withLockUnchecked { data }
    }
}

private extension NSLock {
    /// Fileprivate mirror of `withLock` (macOS 13 SDK) kept local to avoid
    /// clashing with the app target's extension.
    func withLockUnchecked<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

/// Real runner: shells out to `/usr/sbin/networksetup`, piping the admin
/// password to `sudo -S` style auth via stdin (networksetup reads the admin
/// credentials from stdin when launched non-interactively).
public final class NetworkSetupRunner: NetworkSetupRunning, @unchecked Sendable {

    /// Provides the admin password for auth (read fresh per invocation).
    public var adminPasswordProvider: () -> String

    public init(adminPasswordProvider: @escaping () -> String) {
        self.adminPasswordProvider = adminPasswordProvider
    }

    public func run(arguments: [String]) throws -> String {
        let password = adminPasswordProvider()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stdoutBuffer.append(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { stderrBuffer.append(data) }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        // networksetup prompts on stdin for admin credentials for set-commands.
        if let data = password.data(using: .utf8) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
        }
        inputPipe.fileHandleForWriting.closeFile()

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        semaphore.wait()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        stdoutBuffer.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBuffer.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrBuffer.value, encoding: .utf8) ?? ""
            throw SystemProxyError.restoreFailed("networksetup \(arguments.first ?? ""): \(stderr)")
        }
        return String(data: stdoutBuffer.value, encoding: .utf8) ?? ""
    }
}

// MARK: - System Proxy Manager

/// Configures the macOS system proxy for **all enabled network services** so
/// apps honoring system proxy settings route through the local engine.
///
/// Lifecycle: `enable()` snapshots current per-service state, then sets
/// web/secure-web/SOCKS proxies to the engine listeners plus the skip-proxy
/// bypass list. `disable()` clears the listeners everywhere and restores the
/// snapshot on the services that had proxies before. The snapshot is persisted
/// to Application Support so a crash or force-quit can still be repaired on the
/// next launch (`hasStaleSnapshot` → `restoreFromSnapshot()`).
public final class SystemProxyManager: @unchecked Sendable {

    // MARK: Dependencies

    private let runner: NetworkSetupRunning
    private let defaults: UserDefaults
    /// Where the pre-enable snapshot is persisted (injectable for tests;
    /// defaults into Application Support).
    private let snapshotURL: URL
    private let lock = NSLock()
    private var cachedSnapshot: ProxySettingsSnapshot?

    // MARK: UserDefaults keys

    private enum Keys {
        static let systemProxyEnabled = "systemProxyEnabled"
        /// Set once the one-time cleanup of the retired legacy PAC server has run.
        static let legacyPACCleaned = "legacyPACCleaned"
    }

    // MARK: Init

    /// Real runner for production use; tests inject a fake.
    public static func defaultRunner(adminPasswordProvider: @escaping () -> String) -> NetworkSetupRunning {
        NetworkSetupRunner(adminPasswordProvider: adminPasswordProvider)
    }

    /// URL prefix of the PAC server the retired legacy proxy mode installed
    /// (`ProxyManager`: a `python3 -m http.server` on port 8765). That server no
    /// longer exists, so an armed PAC pointing at it black-holes every request
    /// it used to proxy — and it must never be restored from a snapshot.
    public static let legacyPACURLPrefix = "http://127.0.0.1:8765"

    /// One-time cleanup for installs upgrading from the legacy PAC mode: turns
    /// off any PAC still pointing at the dead legacy server and drops it from
    /// the persisted snapshot so a later restore cannot resurrect it. Shells
    /// out to `networksetup`, so call it off the main thread; runs at most once
    /// (`Keys.legacyPACCleaned`) and returns the services it turned off.
    @discardableResult
    public func clearLegacyPAC() -> [String] {
        guard !defaults.bool(forKey: Keys.legacyPACCleaned) else { return [] }

        var cleaned: [String] = []
        if let services = try? listEnabledServices() {
            for service in services {
                guard let output = try? runner.run(arguments: ["-getautoproxyurl", service.name]),
                      Self.isLegacyPAC(Self.parseGetAutoProxyOutput(output).url) else { continue }
                _ = try? runner.run(arguments: ["-setautoproxystate", service.name, "off"])
                cleaned.append(service.name)
            }
        }
        scrubLegacyPACFromSnapshot()
        defaults.set(true, forKey: Keys.legacyPACCleaned)
        return cleaned
    }

    /// Whether a PAC URL belongs to the retired legacy server.
    public static func isLegacyPAC(_ url: String) -> Bool {
        url.hasPrefix(legacyPACURLPrefix)
    }

    /// Subprocess-free half of the retirement, so it is safe to run on the main
    /// thread at launch: rewrites the persisted snapshot without its legacy PAC
    /// entries (deleting it when nothing else was captured), which is what stops
    /// a restore from re-arming the dead server. No-ops unless the file changed.
    public func scrubLegacyPACFromSnapshot() {
        guard let snapshot = loadPersistedSnapshot() else { return }
        var changed = false
        let scrubbed = snapshot.states.map { state -> ProxySettingsSnapshot.ServiceState in
            guard let raw = state.autoProxy,
                  Self.isLegacyPAC(Self.parseGetAutoProxyOutput(raw).url) else { return state }
            changed = true
            return .init(
                service: state.service,
                web: state.web,
                secureWeb: state.secureWeb,
                socks: state.socks,
                autoProxy: nil
            )
        }
        guard changed else { return }
        if scrubbed.isEmpty {
            removePersistedSnapshot()
        } else {
            persistSnapshot(ProxySettingsSnapshot(states: scrubbed, capturedAt: snapshot.capturedAt))
        }
    }

    /// Production snapshot location.
    public static var defaultSnapshotURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("TurtleDiver", isDirectory: true)
            .appendingPathComponent("proxy-snapshot.json")
    }

    public init(
        runner: NetworkSetupRunning,
        defaults: UserDefaults = .standard,
        snapshotURL: URL? = nil
    ) {
        self.runner = runner
        self.defaults = defaults
        self.snapshotURL = snapshotURL ?? Self.defaultSnapshotURL
        self.cachedSnapshot = Self.loadSnapshot(from: self.snapshotURL)
    }

    // MARK: Status

    /// Whether the manager believes the system proxy is currently configured
    /// (persisted so it survives relaunches).
    public var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.bool(forKey: Keys.systemProxyEnabled)
    }

    // MARK: Service discovery

    /// Parses `networksetup -listallnetworkservices` output. Lines like
    /// `Wi-Fi` are enabled services; `*`/`**` prefixes mark disabled ones.
    public func listNetworkServices() throws -> [NetworkService] {
        let output = try runner.run(arguments: ["-listallnetworkservices"])
        return Self.parseServiceList(output)
    }

    /// Pure parser, exposed for tests.
    public static func parseServiceList(_ output: String) -> [NetworkService] {
        var services: [NetworkService] = []
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Skip the legend line: "An asterisk (*) denotes that a network service is disabled."
            if line.hasPrefix("An asterisk") { continue }
            if line == "*" || line == "**" { continue }
            let enabled = !line.hasPrefix("*")
            let name = enabled ? line : String(line.dropFirst()) // strip the `*`
            if name.isEmpty { continue }
            services.append(NetworkService(name: name, enabled: enabled))
        }
        return services
    }

    // MARK: Enable / Disable

    /// Snapshots current settings (once), then configures HTTP/HTTPS/SOCKS
    /// proxies on every enabled service. Throws if the snapshot failed —
    /// never leaves the system configured without a way back.
    public func enable(httpHost: String, httpPort: Int, socksHost: String, socksPort: Int, skipProxy: [String]) throws {
        lock.lock()
        let alreadyEnabled = defaults.bool(forKey: Keys.systemProxyEnabled)
        lock.unlock()

        // Idempotency guard: repeated enable with no intervening disable
        // must not overwrite the pre-enable snapshot with our own settings.
        if !alreadyEnabled {
            let snapshot = try captureSnapshot(services: try listEnabledServices())
            persistSnapshot(snapshot)
        }

        let services = try listEnabledServices()
        for service in services {
            try applyToService(service, httpHost: httpHost, httpPort: httpPort, socksHost: socksHost, socksPort: socksPort, skipProxy: skipProxy)
        }

        lock.lock()
        defaults.set(true, forKey: Keys.systemProxyEnabled)
        lock.unlock()
    }

    /// Clears the proxy on all enabled services, then restores snapshotted
    /// per-service state for services that had custom proxies before.
    public func disable() throws {
        let services = try listEnabledServices()
        for service in services {
            clearService(service.name)
        }

        if let snapshot = loadPersistedSnapshot() {
            for state in snapshot.states {
                restoreService(state)
            }
        }

        lock.lock()
        defaults.set(false, forKey: Keys.systemProxyEnabled)
        lock.unlock()
        removePersistedSnapshot()
    }

    /// Applies proxy settings to one service (used by enable and re-apply).
    func applyToService(_ service: NetworkService, httpHost: String, httpPort: Int, socksHost: String, socksPort: Int, skipProxy: [String]) throws {
        guard service.enabled else { return }
        _ = try runner.run(arguments: ["-setwebproxy", service.name, httpHost, String(httpPort)])
        _ = try runner.run(arguments: ["-setwebproxystate", service.name, "on"])
        _ = try runner.run(arguments: ["-setsecurewebproxy", service.name, httpHost, String(httpPort)])
        _ = try runner.run(arguments: ["-setsecurewebproxystate", service.name, "on"])
        _ = try runner.run(arguments: ["-setsocksfirewallproxy", service.name, socksHost, String(socksPort)])
        _ = try runner.run(arguments: ["-setsocksfirewallproxystate", service.name, "on"])

        // CFNetwork prefers a PAC over the explicit proxies, so an enabled PAC
        // silently shadows the engine (the legacy `Use Proxy` path installs
        // one). Turn it off while the engine owns the system proxy.
        _ = try runner.run(arguments: ["-setautoproxystate", service.name, "off"])

        if !skipProxy.isEmpty {
            _ = try runner.run(arguments: ["-setproxybypassdomains", service.name] + skipProxy)
        }
    }

    /// Turns the three proxies off for one service (without touching bypass
    /// domains — restore path rewrites those only when a snapshot exists).
    func clearService(_ service: String) {
        _ = try? runner.run(arguments: ["-setwebproxystate", service, "off"])
        _ = try? runner.run(arguments: ["-setsecurewebproxystate", service, "off"])
        _ = try? runner.run(arguments: ["-setsocksfirewallproxystate", service, "off"])
        _ = try? runner.run(arguments: ["-setautoproxystate", service, "off"])
    }

    /// Re-applies `restoreFromGetOutput` semantics for one snapshotted service.
    func restoreService(_ state: ProxySettingsSnapshot.ServiceState) {
        // Restore stored host/port/enabled/auth triplets by re-running the
        // set-commands with the snapshotted values, then match the on/off
        // state exactly (off wins — a service that had proxies disabled must
        // stay disabled).
        let web = Self.parseGetProxyOutput(state.web)
        let secure = Self.parseGetProxyOutput(state.secureWeb)
        let socks = Self.parseGetProxyOutput(state.socks)

        restoreOne(state.service, kind: .web, parsed: web)
        restoreOne(state.service, kind: .secureWeb, parsed: secure)
        restoreOne(state.service, kind: .socks, parsed: socks)

        // Put back the PAC that enable() turned off. A PAC that was off keeps
        // its URL untouched (enable never rewrites it) — only the state has to
        // be re-asserted.
        if let raw = state.autoProxy {
            let pac = Self.parseGetAutoProxyOutput(raw)
            let hasURL = !pac.url.isEmpty && pac.url != "(null)"
            // The legacy PAC server is gone; re-arming it would point macOS at
            // a dead port. `clearLegacyPAC()` scrubs snapshots, this is the
            // backstop for one captured before the cleanup ran.
            if pac.enabled && hasURL && !Self.isLegacyPAC(pac.url) {
                _ = try? runner.run(arguments: ["-setautoproxyurl", state.service, pac.url])
                _ = try? runner.run(arguments: ["-setautoproxystate", state.service, "on"])
            } else {
                _ = try? runner.run(arguments: ["-setautoproxystate", state.service, "off"])
            }
        }
    }

    private enum ProxyKind {
        case web
        case secureWeb
        case socks
    }

    private func restoreOne(_ service: String, kind: ProxyKind, parsed: ParsedProxyState) {
        let setProxy: [String]
        let setState: [String]
        switch kind {
        case .web:
            setProxy = ["-setwebproxy", service]
            setState = ["-setwebproxystate", service]
        case .secureWeb:
            setProxy = ["-setsecurewebproxy", service]
            setState = ["-setsecurewebproxystate", service]
        case .socks:
            setProxy = ["-setsocksfirewallproxy", service]
            setState = ["-setsocksfirewallproxystate", service]
        }
        // Re-assert the server values only when the snapshotted state was
        // actually enabled; disabled kinds must simply stay off (writing an
        // empty host would be garbage).
        if parsed.enabled && !parsed.host.isEmpty {
            _ = try? runner.run(arguments: setProxy + [parsed.host, parsed.port])
            if let domain = parsed.authDomain, let password = parsed.authPassword {
                _ = try? runner.run(arguments: setProxy + [parsed.host, parsed.port, "Authenticated", domain, password])
            }
        }
        _ = try? runner.run(arguments: setState + [parsed.enabled ? "on" : "off"])
    }

    // MARK: Snapshot handling

    private func listEnabledServices() throws -> [NetworkService] {
        try listNetworkServices().filter(\.enabled)
    }

    private func captureSnapshot(services: [NetworkService]) throws -> ProxySettingsSnapshot {
        var states: [ProxySettingsSnapshot.ServiceState] = []
        for service in services {
            let web = try runner.run(arguments: ["-getwebproxy", service.name])
            let secureWeb = try runner.run(arguments: ["-getsecurewebproxy", service.name])
            let socks = try runner.run(arguments: ["-getsocksfirewallproxy", service.name])
            let autoProxy = try runner.run(arguments: ["-getautoproxyurl", service.name])
            // Only remember services that actually had a proxy configured, so
            // disable() can simply clear the rest without resurrecting noise.
            let anyEnabled = [web, secureWeb, socks].contains { output in
                Self.parseGetProxyOutput(output).enabled
            }
            // A PAC counts as "had a proxy configured": enable() turns it off,
            // so disable() must remember to put it back.
            let pacEnabled = Self.parseGetAutoProxyOutput(autoProxy).enabled
            if anyEnabled || pacEnabled {
                states.append(.init(service: service.name, web: web, secureWeb: secureWeb, socks: socks, autoProxy: autoProxy))
            }
        }
        return ProxySettingsSnapshot(states: states)
    }

    private func persistSnapshot(_ snapshot: ProxySettingsSnapshot) {
        lock.lock()
        cachedSnapshot = snapshot
        lock.unlock()
        let url = snapshotURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadPersistedSnapshot() -> ProxySettingsSnapshot? {
        lock.lock()
        let cached = cachedSnapshot
        lock.unlock()
        return cached ?? Self.loadSnapshot(from: snapshotURL)
    }

    private func removePersistedSnapshot() {
        lock.lock()
        cachedSnapshot = nil
        lock.unlock()
        try? FileManager.default.removeItem(at: snapshotURL)
    }

    private static func loadSnapshot(from url: URL) -> ProxySettingsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProxySettingsSnapshot.self, from: data)
    }

    /// A snapshot exists on disk while the manager says the proxy is off —
    /// i.e. the app (or machine) died between enable and disable.
    public var hasStaleSnapshot: Bool {
        Self.loadSnapshot(from: snapshotURL) != nil
    }

    /// Restores from a stale snapshot left by a previous crashed session.
    /// Returns false when there is nothing to restore.
    @discardableResult
    public func restoreFromSnapshot() -> Bool {
        guard let snapshot = Self.loadSnapshot(from: snapshotURL) else { return false }
        for state in snapshot.states { restoreService(state) }
        removePersistedSnapshot()
        return true
    }

    /// Test hook: last persisted (or in-memory) snapshot.
    public var snapshotForTesting: ProxySettingsSnapshot? {
        loadPersistedSnapshot()
    }

    // MARK: - Parsed `networksetup -get*proxy` output

    public struct ParsedProxyState: Equatable, Sendable {
        public var enabled: Bool
        public var host: String
        public var port: String
        public var authDomain: String?
        public var authPassword: String?

        public init(enabled: Bool, host: String, port: String, authDomain: String? = nil, authPassword: String? = nil) {
            self.enabled = enabled
            self.host = host
            self.port = port
            self.authDomain = authDomain
            self.authPassword = authPassword
        }
    }

    /// Pure parser for `-getwebproxy` / `-getsecurewebproxy` /
    /// `-getsocksfirewallproxy` output, e.g.:
    /// ```
    /// Enabled: Yes
    /// Server: 127.0.0.1
    /// Port: 6152
    /// Authenticated Proxy Enabled: 0
    /// ```
    public static func parseGetProxyOutput(_ output: String) -> ParsedProxyState {
        var enabled = false
        var host = ""
        var port = "0"
        var authDomain: String?
        var authPassword: String?

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            case "enabled":
                enabled = (value.lowercased() == "yes" || value == "1")
            case "server":
                host = value
            case "port":
                port = value
            case "authenticated proxy enabled":
                break
            case "username":
                break
            case "password":
                authPassword = value
            case "domain":
                authDomain = value
            default:
                break
            }
        }
        return ParsedProxyState(enabled: enabled, host: host, port: port, authDomain: authDomain, authPassword: authPassword)
    }

    /// Snapshot of `-getautoproxyurl` output, e.g.:
    /// ```
    /// URL: http://127.0.0.1:8765/proxy.pac
    /// Enabled: Yes
    /// ```
    public struct ParsedAutoProxy: Equatable, Sendable {
        public var enabled: Bool
        /// `"(null)"` / empty when no PAC was ever configured.
        public var url: String

        public init(enabled: Bool, url: String) {
            self.enabled = enabled
            self.url = url
        }
    }

    /// Pure parser for `-getautoproxyurl` output.
    public static func parseGetAutoProxyOutput(_ output: String) -> ParsedAutoProxy {
        var enabled = false
        var url = ""

        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key.lowercased() {
            case "enabled":
                enabled = (value.lowercased() == "yes" || value == "1")
            case "url":
                url = value
            default:
                break
            }
        }
        return ParsedAutoProxy(enabled: enabled, url: url)
    }
}
