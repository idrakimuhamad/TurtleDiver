import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif
#if canImport(TurtleDiverRules)
import TurtleDiverRules
#endif

// MARK: - Request Log

/// Transport that produced the request.
public enum RequestTransport: String, Sendable {
    case http
    case socks5
}

/// One request row for the dashboard (Phase 5 renders this).
public struct RequestEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let host: String
    public let port: Int
    /// The rule that matched (nil = default/FINAL-miss).
    public let rule: ProfileRule?
    /// Policy the request was resolved to (as written in the profile).
    public let policy: String
    public var bytesToDestination: Int
    public var bytesToClient: Int
    public let transport: RequestTransport
    /// Error text when the relay finished abnormally.
    public var error: String?
    public var endedAt: Date?
    /// Everything the engine could learn about this request without
    /// decrypting anything (nil = not captured, or nothing to capture).
    public var detail: RequestDetail?

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        host: String,
        port: Int,
        rule: ProfileRule?,
        policy: String,
        bytesToDestination: Int,
        bytesToClient: Int,
        transport: RequestTransport,
        error: String?,
        detail: RequestDetail? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.host = host
        self.port = port
        self.rule = rule
        self.policy = policy
        self.bytesToDestination = bytesToDestination
        self.bytesToClient = bytesToClient
        self.transport = transport
        self.error = error
        self.endedAt = nil
        self.detail = detail
    }
}

/// Ring buffer of recent requests (last N), thread-safe. `onChange` fires on
/// the mutating thread; the UI bridges to main.
public final class RequestLog: @unchecked Sendable {

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [RequestEntry] = []
    private var byID: [UUID: Int] = [:]

    public var onChange: (() -> Void)?

    /// How many of the most recent entries may carry a detail payload. A detail
    /// is an order of magnitude larger than its row, and nobody scrolls 200
    /// rows back to read headers, so the oldest details are dropped first —
    /// the row itself always survives until the ring turns it over.
    public static let detailCapacity = 200

    private var capturesDetailsStorage = true
    private var revealsSensitiveHeadersStorage = false

    /// Whether newly captured entries keep a detail payload. The servers read
    /// this per request, so turning it off takes effect immediately; turning it
    /// back on cannot recover what was never kept.
    public var capturesDetails: Bool {
        get { lock.withLock { capturesDetailsStorage } }
        set { lock.withLock { capturesDetailsStorage = newValue } }
    }

    /// Whether sensitive header values (cookies, authorization, tokens) are
    /// kept as-is. Off by default, and it only affects *new* captures: a value
    /// withheld at capture time is not held anywhere to reveal later.
    public var revealsSensitiveHeaders: Bool {
        get { lock.withLock { revealsSensitiveHeadersStorage } }
        set { lock.withLock { revealsSensitiveHeadersStorage = newValue } }
    }

    public init(capacity: Int = 1000) {
        self.capacity = max(1, capacity)
    }

    /// Appends a new in-flight entry and returns it (with its id).
    @discardableResult
    public func append(_ entry: RequestEntry) -> RequestEntry {
        lock.lock()
        var entry = entry
        entries.append(entry)
        byID[entry.id] = entries.count - 1
        trimIfNeededLocked()
        lock.unlock()
        onChange?()
        return entry
    }

    /// Attaches (or extends) the detail for an entry.
    ///
    /// Captures arrive from two directions that race with each other and with
    /// the entry's own retirement, so a late or repeated capture merges rather
    /// than replaces, and one for an entry that has already been trimmed away
    /// is dropped.
    public func attachDetail(id: UUID, detail: RequestDetail) {
        guard !detail.isEmpty else { return }
        lock.lock()
        if capturesDetailsStorage, let index = byID[id] {
            entries[index].detail = (entries[index].detail ?? RequestDetail()).merged(with: detail)
            trimDetailsLocked()
        }
        lock.unlock()
        onChange?()
    }

    /// Updates an in-flight entry when its relay finishes.
    public func finish(id: UUID, bytesToDestination: Int, bytesToClient: Int, error: String?) {
        lock.lock()
        if let index = byID[id] {
            entries[index].bytesToDestination = bytesToDestination
            entries[index].bytesToClient = bytesToClient
            entries[index].error = error
            entries[index].endedAt = Date()
        }
        lock.unlock()
        onChange?()
    }

    /// Snapshot of the most recent entries (newest last).
    public func snapshot() -> [RequestEntry] {
        lock.withLock { entries }
    }

    public var count: Int {
        lock.withLock { entries.count }
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        byID.removeAll()
        lock.unlock()
        onChange?()
    }

    /// Drops details from the oldest entries once too many carry one.
    private func trimDetailsLocked() {
        var carrying = entries.reduce(0) { $0 + ($1.detail == nil ? 0 : 1) }
        guard carrying > Self.detailCapacity else { return }
        for index in entries.indices where carrying > Self.detailCapacity {
            if entries[index].detail != nil {
                entries[index].detail = nil
                carrying -= 1
            }
        }
    }

    private func trimIfNeededLocked() {
        guard entries.count > capacity else { return }
        let excess = entries.count - capacity
        let removed = Array(entries[..<excess])
        entries.removeFirst(excess)
        for entry in removed { byID.removeValue(forKey: entry.id) }
        // Reindex survivors.
        byID.removeAll()
        for (index, entry) in entries.enumerated() { byID[entry.id] = index }
    }
}

// MARK: - Relay Registry

/// Owns live relays and the shared relay queue. Retain/release counts keep
/// the process from exiting a connect-completion closure into a freed relay.
public final class RelayRegistry: @unchecked Sendable {

    /// Serial queue all relays pump on. One queue keeps the event handlers
    /// ordered; the pump does no blocking work, so a single queue scales fine
    /// for a local proxy's typical load.
    public let queue = DispatchQueue(label: "com.turtlediver.engine.relay", qos: .userInitiated)

    private let lock = NSLock()
    private var relays: [ObjectIdentifier: RelayConnection] = [:]
    private var counts: [ObjectIdentifier: Int] = [:]

    /// Fired when the last relay retires (engine can idle-stop timers).
    public var onAllRelaysFinished: (() -> Void)?

    public init() {}

    func retain(_ relay: RelayConnection) {
        lock.lock()
        let key = ObjectIdentifier(relay)
        relays[key] = relay
        counts[key, default: 0] += 1
        lock.unlock()
    }

    func release(_ relay: RelayConnection) {
        lock.lock()
        let key = ObjectIdentifier(relay)
        let remaining = (counts[key] ?? 0) - 1
        if remaining <= 0 {
            counts.removeValue(forKey: key)
            relays.removeValue(forKey: key)
        } else {
            counts[key] = remaining
        }
        let empty = relays.isEmpty
        lock.unlock()
        if empty { onAllRelaysFinished?() }
    }

    /// Number of live relays (for the dashboard).
    public var activeCount: Int {
        lock.withLock { relays.count }
    }

    /// Force-closes every live relay (engine stop).
    public func closeAll() {
        lock.lock()
        let all = Array(relays.values)
        lock.unlock()
        for relay in all { relay.finish(with: RelayError.upstreamConnectFailed("engine stopped")) }
    }
}

// MARK: - ProxyEngine

/// Lifecycle owner for the local proxy listeners:
/// - starts/stops the HTTP and SOCKS5 listeners from the profile's
///   `[General]` listen addresses,
/// - owns the `RuleMatcher` (matching), `PolicyStore` (resolution),
///   `RequestLog` (dashboard data) and `RelayRegistry` (live relays),
/// - hot-swaps the profile into matcher + policy store.
///
/// The engine is independent of the VPN (Surge-like): the app may run it with
/// or without a tunnel, and the VPN's own flow is untouched.
public final class ProxyEngine: @unchecked Sendable {

    // MARK: Collaborators

    public let matcher: RuleMatcher
    public let policyStore: PolicyStore
    public let requestLog: RequestLog
    public let relayRegistry: RelayRegistry

    private let httpServer: HTTPProxyServer
    private let socksServer: SOCKS5Server

    private let lock = NSLock()
    private var running = false
    private var httpPort: Int?
    private var socksPort: Int?

    // MARK: Init

    public convenience init(
        profile: Profile,
        policyStore: PolicyStore? = nil,
        requestLog: RequestLog = RequestLog(),
        relayRegistry: RelayRegistry = RelayRegistry(),
        dnsResolver: DNSResolving = CachingDNSResolver()
    ) {
        let store = policyStore ?? PolicyStore(profile: profile, autoStartTesting: false)
        self.init(
            matcher: RuleMatcher(profile: profile, resolver: dnsResolver),
            policyStore: store,
            requestLog: requestLog,
            relayRegistry: relayRegistry
        )
    }

    /// Designated initializer: collaborators are created or injected.
    public init(
        matcher: RuleMatcher,
        policyStore: PolicyStore,
        requestLog: RequestLog = RequestLog(),
        relayRegistry: RelayRegistry = RelayRegistry()
    ) {
        self.matcher = matcher
        self.policyStore = policyStore
        self.requestLog = requestLog
        self.relayRegistry = relayRegistry
        self.httpServer = HTTPProxyServer(
            matcher: matcher, policyStore: policyStore,
            requestLog: requestLog, relayRegistry: relayRegistry
        )
        self.socksServer = SOCKS5Server(
            matcher: matcher, policyStore: policyStore,
            requestLog: requestLog, relayRegistry: relayRegistry
        )
    }

    // MARK: Status

    public var isRunning: Bool {
        lock.withLock { running }
    }

    /// Bound ports after a successful start (nil = not listening).
    public var listeningPorts: (http: Int?, socks5: Int?) {
        lock.withLock { (httpPort, socksPort) }
    }

    // MARK: Lifecycle

    /// Starts listeners per the profile's `http-listen` / `socks5-listen`
    /// settings. `http-listen` / `socks5-listen` accept `host:port`; empty
    /// disables that listener.
    public func start(profile: Profile, ruleSets: [String: [ProfileRule]]? = nil) throws {
        lock.lock()
        if running {
            lock.unlock()
            stop() // hot-restart with the new profile
        }
        lock.unlock()

        var errors: [Error] = []

        let httpListen = profile.general.httpListen
        if !httpListen.isEmpty, let (host, port) = Self.parseListen(httpListen) {
            do {
                try httpServer.start(host: host, port: port)
                lock.lock(); httpPort = port; lock.unlock()
            } catch {
                errors.append(error)
            }
        }

        let socksListen = profile.general.socks5Listen
        if !socksListen.isEmpty, let (host, port) = Self.parseListen(socksListen) {
            do {
                try socksServer.start(host: host, port: port)
                lock.lock(); socksPort = port; lock.unlock()
            } catch {
                errors.append(error)
            }
        }

        matcher.updateProfile(profile, ruleSets: ruleSets)
        policyStore.updateProfile(profile)

        lock.lock()
        if errors.count == ((profile.general.httpListen.isEmpty ? 0 : 1) + (profile.general.socks5Listen.isEmpty ? 0 : 1)) {
            running = false
        } else {
            running = true
        }
        lock.unlock()

        if let first = errors.first {
            stop() // partial start: tear down what did bind
            throw first
        }
    }

    public func stop() {
        lock.lock()
        running = false
        httpPort = nil
        socksPort = nil
        lock.unlock()
        httpServer.stop()
        socksServer.stop()
        relayRegistry.closeAll()
    }

    deinit {
        stop()
    }

    /// Re-applies a (possibly edited) profile: matcher + policy store hot
    /// swap. Listener addresses only change on `start(profile:)`.
    /// - Parameter ruleSets: cached rules per set name. `nil` keeps the
    ///   expansions the matcher already has, so an unrelated profile edit does
    ///   not disturb them.
    public func reload(profile: Profile, ruleSets: [String: [ProfileRule]]? = nil) {
        matcher.updateProfile(profile, ruleSets: ruleSets)
        policyStore.updateProfile(profile)
    }

    // MARK: Helpers

    /// Parses `host:port` (IPv6 literal: `[::1]:6152`).
    public static func parseListen(_ value: String) -> (host: String, port: Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let rest = trimmed[trimmed.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        let parts = trimmed.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port), !parts[0].isEmpty else {
            return nil
        }
        return (String(parts[0]), port)
    }

    /// Creates a non-blocking TCP listener bound to `host:port`.
    static func makeListenerFD(host: String, port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RelayError.upstreamConnectFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(clamping: port).bigEndian
        guard let addrUnion = in_addr(s_string: host) else {
            TCPClient.closeSocket(fd)
            throw RelayError.invalidTarget("listener host \(host)")
        }
        addr.sin_addr = addrUnion

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = String(cString: strerror(errno))
            TCPClient.closeSocket(fd)
            throw RelayError.upstreamConnectFailed("bind \(host):\(port) failed: \(detail)")
        }
        guard listen(fd, 128) == 0 else {
            let detail = String(cString: strerror(errno))
            TCPClient.closeSocket(fd)
            throw RelayError.upstreamConnectFailed("listen failed: \(detail)")
        }

        // Non-blocking: the accept source drains until EAGAIN.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }
}

// MARK: - in_addr helper

extension in_addr {
    /// Parses dotted-quad into `in_addr` (network byte order, matching what
    /// `inet_aton` would store).
    init?(s_string: String) {
        guard let ip = IPAddress.parseIPv4(s_string) else { return nil }
        var value = in_addr()
        var packed: UInt32 = 0
        for byte in ip.bytes {
            packed = (packed << 8) | UInt32(byte)
        }
        // packed is big-endian semantics; s_addr expects network byte order,
        // which on little-endian hosts means the value must be byte-swapped
        // from host order. Constructing via bytes avoids endianness math.
        withUnsafeMutableBytes(of: &value.s_addr) { dst in
            dst.copyBytes(from: ip.bytes)
        }
        self = value
    }
}
