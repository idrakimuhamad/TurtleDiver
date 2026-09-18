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

// MARK: - Parsed Request

/// One parsed HTTP request head from the local listener.
struct HTTPRequestHead {
    let method: String
    /// Request target as sent: authority-form (`host:port`) for CONNECT,
    /// absolute-URI or origin-form otherwise.
    let target: String
    let version: String
    /// Header names lowercased, in order of appearance.
    let headers: [(name: String, value: String)]

    func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.name == lower }?.value
    }

    /// Keep-alive heuristics (HTTP/1.1 defaults to keep-alive).
    var wantsKeepAlive: Bool {
        guard let connection = header("connection")?.lowercased() else {
            return version.uppercased() == "HTTP/1.1"
        }
        return !connection.contains("close")
    }
}

// MARK: - Parsed Request Decision

/// The host/port the outbound leg should connect to, extracted per request
/// flavor.
enum HTTPRequestRouter {

    /// CONNECT: target is authority-form `host:port` (port required).
    static func destination(head: HTTPRequestHead) -> RelayDestination? {
        guard head.method.uppercased() == "CONNECT" else { return nil }
        let parts = head.target.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port) else { return nil }
        return RelayDestination(host: String(parts[0]), port: port)
    }

    /// Absolute-URI (`GET http://host/path`) → destination for the relay,
    /// with the request forwarded as origin-form.
    static func absoluteFormDestination(head: HTTPRequestHead) -> RelayDestination? {
        guard head.method.uppercased() != "CONNECT" else { return nil }
        guard let (host, port, _) = LatencyTester.parseHTTPURL(head.target) else { return nil }
        return RelayDestination(host: host, port: port)
    }

    /// Rewrites an absolute-form request head into origin-form bytes
    /// (`GET /path HTTP/1.1`) for the outbound leg. `Connection: close` is
    /// injected so the relay can treat the exchange as one-shot.
    static func originFormBytes(head: HTTPRequestHead) -> [UInt8]? {
        guard let (host, port, path) = LatencyTester.parseHTTPURL(head.target) else { return nil }
        var lines = ["\(head.method) \(path) HTTP/1.1"]
        var sawHost = false
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" { continue } // hop-by-hop, do not forward
            if lower == "connection" { continue }       // we manage keep-alive
            if lower == "keep-alive" { continue }
            if lower == "host" {
                sawHost = true
                // Port 80 is implied; keep explicit host header otherwise.
                if port == 80 {
                    lines.append("Host: \(value)")
                } else {
                    lines.append("Host: \(host):\(port)")
                }
                continue
            }
            lines.append("\(name): \(value)")
        }
        if !sawHost {
            if port == 80 {
                lines.append("Host: \(host)")
            } else {
                lines.append("Host: \(host):\(port)")
            }
        }
        lines.append("Connection: close")
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

// MARK: - HTTP Proxy Server

/// Local HTTP proxy listener (default `127.0.0.1:6152`).
///
/// Supported per-connection flows:
/// - **CONNECT** — tunnel establishment; the decision's byte stream is
///   relayed verbatim (TLS, HTTP/2, anything).
/// - **absolute-URI requests** — classic forward-proxy form; the request is
///   forwarded to the origin in origin-form and the response relayed back.
///   `Connection: close` semantics: one request per outbound leg, the client
///   connection persists per its own `Connection` header.
/// - **origin-form requests** — when the client treats us as an HTTP server
///   (misconfiguration), respond 400 with a hint.
///
/// Requests are matched against the `RuleMatcher` and resolved through the
/// `PolicyStore`; every decision lands in the shared `RequestLog`.
final class HTTPProxyServer: @unchecked Sendable {

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

    /// How long outbound connects may take (also used for handshakes).
    var connectTimeout: Double = 10

    init(
        matcher: RuleMatcher,
        policyStore: PolicyStore,
        requestLog: RequestLog,
        relayRegistry: RelayRegistry,
        acceptQueue: DispatchQueue = DispatchQueue(label: "com.turtlediver.engine.http.accept", qos: .userInitiated),
        ioQueues: [DispatchQueue]? = nil
    ) {
        self.matcher = matcher
        self.policyStore = policyStore
        self.requestLog = requestLog
        self.relayRegistry = relayRegistry
        self.acceptQueue = acceptQueue
        // Small round-robin pool keeps independent connections off one queue.
        self.ioQueues = ioQueues ?? (0..<4).map {
            DispatchQueue(label: "com.turtlediver.engine.http.io\($0)", qos: .userInitiated)
        }
    }

    // MARK: Lifecycle

    /// Binds and starts accepting. Throws if the port cannot be bound.
    func start(host: String, port: Int) throws {
        let fd = try ProxyEngine.makeListenerFD(host: host, port: port)
        lock.lock()
        listenerFD = fd
        self.port = port
        lock.unlock()

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.drainListener() }
        // The listener fd is closed synchronously in `stop()` (before cancel
        // returns on the accept queue) so a port is reusable immediately.
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
                FileHandle.standardError.write(Data("TD-FD-OPEN [\(Int(Date().timeIntervalSince1970 * 1000))] fd=\(fd) kind=http-accept\n".utf8))
            }

            lock.lock()
            let queue = ioQueues[nextQueue % ioQueues.count]
            nextQueue += 1
            lock.unlock()

            queue.async { [weak self] in
                self?.readRequestHead(clientFD: fd)
            }
        }
    }

    // MARK: Request head

    private func readRequestHead(clientFD: Int32) {
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(30)

        while buffer.count < 65536 {
            if let range = OutboundConnector.headTerminatorRange(buffer) {
                let headBytes = Array(buffer[..<range.lowerBound])
                let leftover = Array(buffer[range.upperBound...])
                route(headBytes: headBytes, leftover: leftover, clientFD: clientFD)
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, TCPClient.waitForReadable(fd: clientFD, timeoutSeconds: remaining) else { break }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(clientFD, $0.baseAddress, 4096) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                break // client closed before sending a full head
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }
        }
        // No complete head arrived: reject politely (if the client is alive).
        _ = try? TCPClient.sendAll(
            fd: clientFD,
            Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            timeoutSeconds: 5
        )
        TCPClient.closeSocket(clientFD)
    }

    private func route(headBytes: [UInt8], leftover: [UInt8], clientFD: Int32) {
        guard let head = Self.parseRequestHead(headBytes) else {
            respondSimple(clientFD: clientFD, status: "400 Bad Request", body: "malformed request head")
            return
        }

        // CONNECT tunnel
        if head.method.uppercased() == "CONNECT" {
            guard let destination = HTTPRequestRouter.destination(head: head) else {
                respondSimple(clientFD: clientFD, status: "400 Bad Request", body: "CONNECT requires host:port")
                return
            }
            handleDecision(clientFD: clientFD, destination: destination, head: head, leftover: leftover, isConnect: true)
            return
        }

        // Forward-proxy request (absolute-URI)
        if let destination = HTTPRequestRouter.absoluteFormDestination(head: head) {
            handleDecision(clientFD: clientFD, destination: destination, head: head, leftover: leftover, isConnect: false)
            return
        }

        // Origin-form: we are not a web server.
        respondSimple(clientFD: clientFD, status: "400 Bad Request", body: "TurtleDiver proxies CONNECT and absolute-URI requests only")
    }

    // MARK: Policy plumbing

    /// Match context for HTTP: host (from target), port, URL, User-Agent.
    private func matchContext(head: HTTPRequestHead, destination: RelayDestination) -> MatchContext {
        MatchContext(
            host: destination.host,
            port: destination.port,
            userAgent: head.header("user-agent"),
            url: head.target
        )
    }

    private func handleDecision(
        clientFD: Int32,
        destination: RelayDestination,
        head: HTTPRequestHead,
        leftover: [UInt8],
        isConnect: Bool
    ) {
        let context = matchContext(head: head, destination: destination)
        let outcome = (try? matcher.match(context)) ?? MatchOutcome(rule: nil, policy: BuiltinPolicy.direct.rawValue, performedDNS: false)
        let decision: PolicyStore.ResolvedDecision
        do {
            decision = try policyStore.resolve(outcome.policy)
        } catch {
            respondSimple(clientFD: clientFD, status: "502 Bad Gateway", body: "policy resolution failed: \(error.localizedDescription)")
            return
        }

        // What can be read in the clear, built once here so the rejected path
        // — the one where you most want to know what was blocked — carries the
        // same detail as a tunnelled one. Nothing is decrypted: for a CONNECT
        // this is the request line and whatever headers the client put on the
        // CONNECT itself.
        let capture = requestLog.capturesDetails
        let reveal = requestLog.revealsSensitiveHeaders
        var requestDetail = RequestDetail()
        if capture {
            requestDetail.requestLine = "\(head.method) \(head.target) \(head.version)"
            requestDetail.captureRequestHeaders(
                head.headers.map { ($0.name, $0.value) }, revealSensitive: reveal
            )
        }

        // REJECT: immediate close (tiny-gif variant comes later).
        if case .reject = decision {
            let rejected = requestLog.append(.init(
                host: destination.host, port: destination.port, rule: outcome.rule,
                policy: "REJECT", bytesToDestination: 0, bytesToClient: 0,
                transport: .http, error: "rejected"
            ))
            if capture { requestLog.attachDetail(id: rejected.id, detail: requestDetail) }
            respondSimple(clientFD: clientFD, status: "403 Forbidden", body: "rejected by rule")
            return
        }

        let entry = requestLog.append(.init(
            host: destination.host, port: destination.port, rule: outcome.rule,
            policy: outcome.policy, bytesToDestination: 0, bytesToClient: 0,
            transport: .http, error: nil
        ))

        if isConnect {
            // Attach what is already readable before a single tunnel byte
            // flows: the ClientHello only arrives once the tunnel is up, and a
            // tunnelled protocol that is not TLS (SSH, a database) never sends
            // one — its CONNECT line would otherwise be dropped entirely.
            if capture { requestLog.attachDetail(id: entry.id, detail: requestDetail) }
            // The tunnel's first bytes are the client's TLS ClientHello — the
            // one place a hostname appears in the clear on an encrypted stream.
            let observer = RelayStreamObserver()
            if capture {
                let base = requestDetail
                observer.onClientPrefix = { [weak self] bytes in
                    switch TLSClientHello.probe(bytes) {
                    case .incomplete:
                        return false
                    case .notTLS:
                        return true // not TLS: there is nothing here to read
                    case .parsed(let summary):
                        var merged = base
                        merged.serverName = summary.serverName
                        merged.tlsVersion = summary.version
                        merged.alpn = summary.alpn
                        merged.resolvedAddress = observer.peerAddress
                        self?.requestLog.attachDetail(id: entry.id, detail: merged)
                        return true
                    }
                }
            }
            // Establish first so we can report success/failure honestly.
            let relay = RelayConnection(clientFD: clientFD, queue: relayRegistry.queue)
            relayRegistry.retain(relay)
            relay.onFinished = { [weak self] metrics, error in
                self?.requestLog.finish(id: entry.id, bytesToDestination: metrics.bytesToDestination, bytesToClient: metrics.bytesToClient, error: error?.localizedDescription)
                self?.relayRegistry.release(relay)
            }
            relay.start(
                decision: decision, destination: destination,
                timeoutSeconds: connectTimeout,
                observer: capture ? observer : nil,
                // The relay owns the client fd end to end: on a failed connect
                // IT sends the 502 and closes. Writing/closing here too would
                // double-close the fd (and can hit a recycled fd of an
                // unrelated connection under fd churn).
                errorReply: { error in
                    Self.gatewayErrorResponse(body: "connect failed: \(error.localizedDescription)")
                }
            ) { error in
                if error == nil {
                    // Tunnel open: tell the client, then pump.
                    _ = try? TCPClient.sendAll(
                        fd: clientFD,
                        Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8),
                        timeoutSeconds: 5
                    )
                }
            }
            return
        }

        // Non-CONNECT: forward the (origin-form) request bytes, then relay the
        // response back. The outbound fd carries the request; the relay handles
        // the rest of the exchange.
        guard var requestBytes = HTTPRequestRouter.originFormBytes(head: head) else {
            respondSimple(clientFD: clientFD, status: "502 Bad Gateway", body: "unsupported request target")
            return
        }
        if !leftover.isEmpty {
            requestBytes.append(contentsOf: leftover)
        }

        // Plain HTTP: the response head comes back in the clear on the
        // destination→client leg, so the status line and response headers are
        // readable without touching the (unencrypted anyway) body.
        let observer = RelayStreamObserver()
        if capture {
            let base = requestDetail
            observer.onServerPrefix = { [weak self] bytes in
                switch HTTPResponseHead.probe(bytes) {
                case .incomplete:
                    return false
                case .notHTTP:
                    return true
                case .parsed(let statusLine, let headers):
                    var merged = base
                    merged.statusLine = statusLine
                    merged.captureResponseHeaders(headers, revealSensitive: reveal)
                    merged.resolvedAddress = observer.peerAddress
                    self?.requestLog.attachDetail(id: entry.id, detail: merged)
                    return true
                }
            }
        }

        let relay = RelayConnection(clientFD: clientFD, queue: relayRegistry.queue)
        relayRegistry.retain(relay)
        relay.onFinished = { [weak self] metrics, error in
            self?.requestLog.finish(id: entry.id, bytesToDestination: metrics.bytesToDestination, bytesToClient: metrics.bytesToClient, error: error?.localizedDescription)
            self?.relayRegistry.release(relay)
        }
        relay.start(
            decision: decision, destination: destination,
            timeoutSeconds: connectTimeout,
            initialBytes: requestBytes,
            observer: capture ? observer : nil,
            // Relay owns the fd: it sends the 502 and closes on failure.
            errorReply: { error in
                Self.gatewayErrorResponse(body: "connect failed: \(error.localizedDescription)")
            }
        ) { error in
            _ = error // reply + teardown are handled by the relay
        }
    }

    /// Full 502 response bytes (sent by the relay when a connect fails).
    static func gatewayErrorResponse(body: String) -> [UInt8] {
        let bodyBytes = Array(body.utf8)
        let head = "HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
        return Array(head.utf8) + bodyBytes
    }

    private func respondSimple(clientFD: Int32, status: String, body: String) {
        let bodyBytes = Array(body.utf8)
        var response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
        do {
            try TCPClient.sendAll(fd: clientFD, Array(response.utf8) + bodyBytes, timeoutSeconds: 5)
        } catch {
            // Client already gone; nothing to report to.
        }
        TCPClient.closeSocket(clientFD)
    }

    // MARK: Head parsing

    /// Parses `METHOD target HTTP/x.y\r\nHeader: value\r\n…`.
    static func parseRequestHead(_ bytes: [UInt8]) -> HTTPRequestHead? {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }
        let method = String(parts[0])
        guard !method.isEmpty else { return nil }
        let target = String(parts[1])
        let version = String(parts[2]).uppercased()
        guard version.hasPrefix("HTTP/") else { return nil }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers.append((name, value))
        }
        return HTTPRequestHead(method: method, target: target, version: version, headers: headers)
    }
}
