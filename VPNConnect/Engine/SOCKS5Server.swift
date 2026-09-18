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

// MARK: - SOCKS5 Server

/// Local SOCKS5 listener (default `127.0.0.1:6153`), RFC 1928.
///
/// Scope (Phase 3):
/// - Version 5, TCP CONNECT only (BIND/UDP ASSOCIATE → command not supported).
/// - No-auth method only (user/pass exists on upstreams, not this listener).
/// - Addressing: IPv4 (0x01), domain name (0x03, resolved by the rule
///   engine's DNS when IP rules need it), IPv6 (0x04).
///
/// Matching: the client-provided host feeds the `RuleMatcher`; the decision
/// comes from `PolicyStore`. Every request lands in the shared `RequestLog`.
final class SOCKS5Server: @unchecked Sendable {

    private let matcher: RuleMatcher
    private let policyStore: PolicyStore
    private let requestLog: RequestLog
    private let relayRegistry: RelayRegistry
    private let acceptQueue: DispatchQueue
    private let ioQueues: [DispatchQueue]
    private var nextQueue: Int = 0

    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var safetySource: DispatchSourceTimer?
    private(set) var port: Int = 0

    /// Outbound connect timeout (also bounds the SOCKS handshake).
    var connectTimeout: Double = 10

    init(
        matcher: RuleMatcher,
        policyStore: PolicyStore,
        requestLog: RequestLog,
        relayRegistry: RelayRegistry,
        acceptQueue: DispatchQueue = DispatchQueue(label: "com.turtlediver.engine.socks.accept", qos: .userInitiated),
        ioQueues: [DispatchQueue]? = nil
    ) {
        self.matcher = matcher
        self.policyStore = policyStore
        self.requestLog = requestLog
        self.relayRegistry = relayRegistry
        self.acceptQueue = acceptQueue
        self.ioQueues = ioQueues ?? (0..<4).map {
            DispatchQueue(label: "com.turtlediver.engine.socks.io\($0)", qos: .userInitiated)
        }
    }

    // MARK: Lifecycle

    func start(host: String, port: Int) throws {
        let fd = try ProxyEngine.makeListenerFD(host: host, port: port)
        lock.lock()
        listenerFD = fd
        self.port = port
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.drainListener() }
        // Listener fd is closed synchronously in `stop()` for immediate reuse.
        source.setCancelHandler {}
        source.resume()

        // Belt-and-braces: a periodic drain rescues any connection a lost
        // wakeup could still strand in the kernel backlog.
        let safety = DispatchSource.makeTimerSource(queue: acceptQueue)
        safety.schedule(deadline: .now() + 1, repeating: 1)
        safety.setEventHandler { [weak self] in self?.drainListener() }
        safety.setCancelHandler {}
        safety.resume()

        lock.lock()
        acceptSource = source
        safetySource = safety
        lock.unlock()
    }

    func stop() {
        lock.lock()
        acceptSource?.cancel()
        acceptSource = nil
        safetySource?.cancel()
        safetySource = nil
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()
        TCPClient.closeSocket(fd)
    }

    // MARK: Accepting

    /// Accepts every pending connection (drains until EAGAIN). GCD read
    /// sources deliver events on the readable *transition*: connections that
    /// queue up behind an in-flight handler run may never generate another
    /// event, so accepting one-per-event strands the tail of a burst in the
    /// kernel backlog (observed as multi-second stalls under stress load).
    private func drainListener() {
        while true {
            let fd = accept(lock.withLock { listenerFD }, nil, nil)
            guard fd >= 0 else {
                if errno == EINTR { continue }
                return // EAGAIN/EWOULDBLOCK or real error: wait for new events
            }
            TCPClient.setNonBlocking(fd)
            TCPClient.setNoSigpipe(fd)
            if TCPClient.fdTraceEnabled {
                FileHandle.standardError.write(Data("TD-FD-OPEN [\(Int(Date().timeIntervalSince1970 * 1000))] fd=\(fd) kind=socks-accept\n".utf8))
            }

            lock.lock()
            let queue = ioQueues[nextQueue % ioQueues.count]
            nextQueue += 1
            lock.unlock()

            queue.async { [weak self] in
                self?.handleClient(clientFD: fd)
            }
        }
    }

    // MARK: Handshake

    private func handleClient(clientFD: Int32) {
        let io = SOCKS5ClientIO(fd: clientFD, timeout: connectTimeout)

        // --- Method negotiation ---
        guard let methods = io.readExactly(2) else { return Self.close(clientFD) }
        guard methods[0] == 0x05 else { return Self.close(clientFD) }
        let count = Int(methods[1])
        guard count > 0, count <= 255, let offered = io.readExactly(count) else { return Self.close(clientFD) }

        let supportsNoAuth = offered.contains(0x00)
        guard supportsNoAuth else {
            // No acceptable method; client will close.
            _ = io.write([0x05, 0xFF])
            return Self.close(clientFD)
        }
        guard io.write([0x05, 0x00]) else { return Self.close(clientFD) }

        // --- Request: VER CMD RSV ATYP ADDR PORT ---
        guard let request = io.readExactly(4) else { return Self.close(clientFD) }
        guard request[0] == 0x05 else { return Self.close(clientFD) }
        let command = request[1]
        let addressType = request[3]

        var host = ""
        switch addressType {
        case 0x01: // IPv4
            guard let raw = io.readExactly(4) else { return Self.close(clientFD) }
            host = raw.map { String($0) }.joined(separator: ".")
        case 0x03: // Domain name
            guard let lengthByte = io.readExactly(1), let length = lengthByte.first, length > 0 else {
                return Self.close(clientFD)
            }
            guard let raw = io.readExactly(Int(length)) else { return Self.close(clientFD) }
            host = String(bytes: raw, encoding: .utf8) ?? ""
        case 0x04: // IPv6
            guard let raw = io.readExactly(16) else { return Self.close(clientFD) }
            host = IPAddress(bytes: raw)?.text ?? ""
        default:
            _ = io.write([0x05, 0x08]) // ATYP not supported
            return Self.close(clientFD)
        }

        guard let portBytes = io.readExactly(2) else { return Self.close(clientFD) }
        let port = (Int(portBytes[0]) << 8) | Int(portBytes[1])
        guard (1...65535).contains(port), !host.isEmpty else {
            _ = io.write([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            return Self.close(clientFD)
        }

        // CONNECT only.
        guard command == 0x01 else {
            _ = io.write([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) // command not supported
            return Self.close(clientFD)
        }

        // --- Policy plumbing ---
        let destination = RelayDestination(host: host, port: port)
        let context = MatchContext(host: host, port: port)
        let outcome = (try? matcher.match(context))
            ?? MatchOutcome(rule: nil, policy: BuiltinPolicy.direct.rawValue, performedDNS: false)
        let decision: PolicyStore.ResolvedDecision
        do {
            decision = try policyStore.resolve(outcome.policy)
        } catch {
            _ = io.write(SOCKS5Server.reply(code: 0x01))
            requestLog.append(.init(
                host: host, port: port, rule: outcome.rule, policy: outcome.policy,
                bytesToDestination: 0, bytesToClient: 0, transport: .socks5,
                error: "policy error: \(error.localizedDescription)"
            ))
            return Self.close(clientFD)
        }

        if case .reject = decision {
            _ = io.write(SOCKS5Server.reply(code: 0x02)) // connection not allowed by ruleset
            requestLog.append(.init(
                host: host, port: port, rule: outcome.rule, policy: "REJECT",
                bytesToDestination: 0, bytesToClient: 0, transport: .socks5, error: "rejected"
            ))
            return Self.close(clientFD)
        }

        let entry = requestLog.append(.init(
            host: host, port: port, rule: outcome.rule, policy: outcome.policy,
            bytesToDestination: 0, bytesToClient: 0, transport: .socks5, error: nil
        ))

        // The client speaks SOCKS5 to us and TLS to the site; the ClientHello's
        // SNI is the only place the site's name exists on this connection.
        let capture = requestLog.capturesDetails
        let observer = RelayStreamObserver()
        if capture {
            observer.onClientPrefix = { [weak self] bytes in
                switch TLSClientHello.probe(bytes) {
                case .incomplete:
                    return false
                case .notTLS:
                    return true
                case .parsed(let summary):
                    var detail = RequestDetail()
                    detail.serverName = summary.serverName
                    detail.tlsVersion = summary.version
                    detail.alpn = summary.alpn
                    detail.resolvedAddress = observer.peerAddress
                    self?.requestLog.attachDetail(id: entry.id, detail: detail)
                    return true
                }
            }
        }

        // Bind address in the success reply: 0.0.0.0:0 (client ignores it).
        guard io.write(SOCKS5Server.reply(code: 0x00)) else { return Self.close(clientFD) }
        if TCPClient.fdTraceEnabled {
            FileHandle.standardError.write(Data("TD-RELAY [\(Int(Date().timeIntervalSince1970 * 1000))] tunnel-established socks client=\(clientFD)\n".utf8))
        }

        // --- Relay ---
        let relay = RelayConnection(clientFD: clientFD, queue: relayRegistry.queue)
        relayRegistry.retain(relay)
        relay.onFinished = { [weak self] metrics, error in
            self?.requestLog.finish(
                id: entry.id,
                bytesToDestination: metrics.bytesToDestination,
                bytesToClient: metrics.bytesToClient,
                error: error?.localizedDescription
            )
            self?.relayRegistry.release(relay)
        }
        relay.start(
            decision: decision, destination: destination,
            timeoutSeconds: connectTimeout,
            observer: capture ? observer : nil
        ) { error in
            if let error {
                // Connect failed after the success greeting was sent: the
                // relay's onFinished closure owns log-finish + release, and
                // finish() closes the client fd. The client observes a dead
                // tunnel — same as Surge's fast-fail on dead policies.
                _ = error
            }
        }
    }

    /// RFC 1928 success/failure reply (IPv4 dummy bind address).
    static func reply(code: UInt8) -> [UInt8] {
        [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
    }

    static func close(_ fd: Int32) {
        TCPClient.closeSocket(fd)
    }
}

// MARK: - Blocking-style IO over non-blocking fd

/// Read/write helpers for the SOCKS5 handshake phase. The fd is non-blocking
/// (needed for DispatchSources later) so reads poll with a deadline — the
/// handshake is tiny (a few bytes) and this keeps the flow linear.
struct SOCKS5ClientIO {
    let fd: Int32
    let timeout: Double

    func readExactly(_ count: Int) -> [UInt8]? {
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            guard TCPClient.waitForReadable(fd: fd, timeoutSeconds: remaining) else { return nil }
            var chunk = [UInt8](repeating: 0, count: count - buffer.count)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, count - buffer.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                return nil // closed
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                return nil
            }
        }
        return buffer
    }

    func write(_ bytes: [UInt8]) -> Bool {
        (try? TCPClient.sendAll(fd: fd, bytes, timeoutSeconds: timeout)) != nil
    }
}
