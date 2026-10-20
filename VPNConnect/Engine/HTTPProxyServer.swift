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

// MARK: - Request framing

/// How a request's body is delimited, per RFC 9112 §6. A shared-listener plain
/// HTTP exchange forwards exactly one message, so the boundary has to be known
/// before a single byte goes out: anything past it belongs to a *second*
/// request, which the first request's authentication does not cover.
enum HTTPRequestFraming: Equatable {
    /// No body: the message ends at the head (GET/HEAD/DELETE, HTTP/1.0 style).
    case none
    /// `Content-Length: n`
    case fixed(Int)
    /// `Transfer-Encoding: chunked` (terminating chunk + trailers included).
    case chunked
    /// Ambiguous or unsupported framing. The request must fail closed rather
    /// than be forwarded with a guessed boundary.
    case unsupported(String)

    /// Whether the message carries bytes after its head.
    var hasBody: Bool {
        switch self {
        case .fixed(let length): return length > 0
        case .chunked: return true
        case .none, .unsupported: return false
        }
    }
}

/// What a chunked body buffer turned out to be. `incomplete` means "read more";
/// the other two mean the message can be judged now.
enum ChunkedBodyParse: Equatable {
    case complete(Int)
    case incomplete
    case invalid(String)
    case tooLarge
}

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
    ///
    /// - Parameter stripExpect: drop `Expect: 100-continue`. Set by a listener
    ///   that already answered the expectation itself (the body is on its way, so
    ///   forwarding the expectation would invite a second interim response).
    static func originFormBytes(head: HTTPRequestHead, stripExpect: Bool = false) -> [UInt8]? {
        guard let (host, port, path) = LatencyTester.parseHTTPURL(head.target) else { return nil }
        var lines = ["\(head.method) \(path) HTTP/1.1"]
        var sawHost = false
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "proxy-connection" { continue } // hop-by-hop, do not forward
            if lower == "connection" { continue }       // we manage keep-alive
            if lower == "keep-alive" { continue }
            // Proxy credentials are ours to consume, never the origin's: a
            // shared listener authenticates the client and must not leak the
            // credential onward (which would also confuse an upstream proxy
            // the resolved policy may dial).
            if lower == "proxy-authorization" { continue }
            if stripExpect, lower == "expect" { continue }
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

    /// Whether the client is waiting for `100 Continue` before sending its body.
    static func expectsContinue(_ head: HTTPRequestHead) -> Bool {
        guard let value = head.header("expect") else { return false }
        return value.lowercased().contains("100-continue")
    }

    // MARK: Body framing

    /// Determines the body boundary of `head`.
    ///
    /// A request carrying both `Transfer-Encoding` and `Content-Length` is
    /// ambiguous (RFC 9112 §6.3: the two can disagree about the message end,
    /// which is exactly the smuggling shape), so it is rejected instead of
    /// silently preferring one.
    ///
    /// Both fields are parsed strictly, because a shared-listener exchange
    /// forwards exactly one message and the boundary must be the one the origin
    /// will use:
    /// - list members are split **without** dropping empty ones (an empty member
    ///   or an empty field is a malformed list, not something to ignore);
    /// - `Content-Length` members must be ASCII decimal digits only, so `+5`,
    ///   `-1`, `5 5` and overflow are refused (Swift's `Int(_:)` would accept
    ///   signs and whitespace) — duplicates are allowed only when every value is
    ///   identical, which is the one RFC-compatible reading;
    /// - `Transfer-Encoding` must be exactly the single coding `chunked`; any
    ///   other coding, a duplicate, a parameter or an empty member is refused
    ///   rather than forwarded as a boundary we do not decode.
    static func framing(of head: HTTPRequestHead) -> HTTPRequestFraming {
        let transferEncoding = head.headers.filter { $0.name == "transfer-encoding" }
        let contentLengths = head.headers.filter { $0.name == "content-length" }

        if !transferEncoding.isEmpty {
            guard contentLengths.isEmpty else {
                return .unsupported("both Transfer-Encoding and Content-Length")
            }
            return chunkedFraming(transferEncoding.map { $0.value })
        }
        guard !contentLengths.isEmpty else { return .none }
        return contentLengthFraming(contentLengths.map { $0.value })
    }

    /// One or more `Content-Length` fields, each possibly a comma-separated
    /// list. Every member must be a plain decimal number and every member must
    /// agree.
    private static func contentLengthFraming(_ values: [String]) -> HTTPRequestFraming {
        var lengths: [Int] = []
        for value in values {
            // `omittingEmptySubsequences: false` is the point: `5,`, `,5` and an
            // empty field have to surface as an empty member and be refused.
            for member in value.split(separator: ",", omittingEmptySubsequences: false) {
                let text = member.trimmingCharacters(in: .whitespaces)
                guard let length = decimalLength(text) else {
                    return .unsupported("invalid Content-Length")
                }
                lengths.append(length)
            }
        }
        guard let first = lengths.first else { return .unsupported("invalid Content-Length") }
        guard lengths.allSatisfy({ $0 == first }) else {
            return .unsupported("conflicting Content-Length values")
        }
        return .fixed(first)
    }

    /// ASCII decimal digits only, saturating refusal on overflow. Deliberately
    /// not `Int(_:)`: that accepts a leading `+`/`-` and Unicode digits.
    private static func decimalLength(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        var value = 0
        for byte in text.utf8 {
            guard (0x30...0x39).contains(byte) else { return nil }
            let digit = Int(byte - 0x30)
            guard value <= (Int.max - digit) / 10 else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    /// `Transfer-Encoding` must be exactly `chunked` — the only coding this
    /// proxy frames without decoding.
    private static func chunkedFraming(_ values: [String]) -> HTTPRequestFraming {
        var codings: [String] = []
        for value in values {
            for member in value.split(separator: ",", omittingEmptySubsequences: false) {
                let token = member.trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty else {
                    return .unsupported("empty Transfer-Encoding member")
                }
                guard !token.contains(";") else {
                    return .unsupported("Transfer-Encoding parameters are not supported")
                }
                codings.append(token.lowercased())
            }
        }
        guard codings == ["chunked"] else {
            return .unsupported("unsupported Transfer-Encoding: \(codings.joined(separator: ","))")
        }
        return .chunked
    }

    /// Number of bytes at the start of `bytes` that make up one complete chunked
    /// body — chunk data plus the terminating zero chunk and its trailers.
    ///
    /// The three outcomes are deliberately distinct: "not all here yet" must
    /// never be confused with "this framing can never be valid", because the
    /// first waits for more bytes and the second has to fail the request closed.
    /// Every size and offset is bounds- and overflow-checked before use: a
    /// `Content-Length`-sized hex token in a client-supplied chunk line must not
    /// be able to wrap an index or force a giant allocation.
    static func parseChunkedBody(_ bytes: [UInt8], maxBody: Int) -> ChunkedBodyParse {
        var index = 0
        while true {
            guard let lineEnd = crlfIndex(bytes, from: index) else {
                // A size line that keeps growing without a CRLF can never become
                // valid; bound it so a hostile client cannot pin the buffer.
                return bytes.count - index > 1024 ? .invalid("chunk size line is too long") : .incomplete
            }
            guard let text = String(bytes: bytes[index..<lineEnd], encoding: .utf8) else {
                return .invalid("chunk size line is not ASCII")
            }
            let sizeToken = (text.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces)
            guard let size = chunkSize(sizeToken) else { return .invalid("invalid chunk size") }
            // Reject an oversized chunk before using its size in any arithmetic.
            guard size <= maxBody else { return .tooLarge }
            index = lineEnd + 2

            if size == 0 {
                // Trailer section: header lines until an empty line.
                while true {
                    guard let trailerEnd = crlfIndex(bytes, from: index) else {
                        return bytes.count > maxBody ? .tooLarge : .incomplete
                    }
                    if trailerEnd == index {
                        let total = trailerEnd + 2
                        return total > maxBody ? .tooLarge : .complete(total)
                    }
                    index = trailerEnd + 2
                    if index > maxBody { return .tooLarge }
                }
            }

            // Chunk data, then CRLF. `size <= maxBody` and `index <= bytes.count`
            // keep both subtractions below from overflowing.
            guard index <= bytes.count else { return .incomplete }
            guard size <= bytes.count - index else { return .incomplete }
            let dataEnd = index + size
            guard bytes.count - dataEnd >= 2 else { return .incomplete }
            guard bytes[dataEnd] == 0x0D, bytes[dataEnd + 1] == 0x0A else {
                return .invalid("chunk data is not followed by CRLF")
            }
            index = dataEnd + 2
            if index > maxBody { return .tooLarge }
        }
    }

    /// Hex chunk size, saturating instead of overflowing. `Int.max` is safe here:
    /// the caller rejects anything above the body cap immediately.
    private static func chunkSize(_ token: String) -> Int? {
        guard !token.isEmpty else { return nil }
        var value = 0
        for byte in token.utf8 {
            let digit: Int
            switch byte {
            case 0x30...0x39: digit = Int(byte - 0x30)
            case 0x41...0x46: digit = Int(byte - 0x41) + 10
            case 0x61...0x66: digit = Int(byte - 0x61) + 10
            default: return nil
            }
            if value > (Int.max - digit) / 16 { return Int.max }
            value = value * 16 + digit
        }
        return value
    }

    private static func crlfIndex(_ bytes: [UInt8], from start: Int) -> Int? {
        guard start >= 0, start < bytes.count else { return nil }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0x0D, bytes[index + 1] == 0x0A { return index }
            index += 1
        }
        return nil
    }
}

// MARK: - Access policy

/// Access policy enforced by a shared (LAN) listener. Absent on the loopback
/// listener, which is unauthenticated by design.
struct ProxyAccessPolicy: Equatable, Sendable {
    var username: String
    var password: String
    /// IPv4 addresses admitted without credentials (e.g. the phone the user
    /// trusts). Compared against the accepted peer address, never the target.
    var allowedClients: Set<String>

    init(username: String, password: String, allowedClients: Set<String>) {
        self.username = username
        self.password = password
        self.allowedClients = allowedClients
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

    /// Set once by `stop()`, under `lock`, before anything is torn down. It is
    /// the single admission fence: accepting, routing and relay registration all
    /// consult it in the same critical section that owns the descriptor, so a
    /// connection accepted in the shadow of `stop()` can never be served.
    private var stopped = false
    /// Accepted connections that do not own a relay yet (reading a head, or
    /// sitting in the accept backlog). `stop()` shuts these down instead of
    /// closing them: the io path owns their close, so closing here could free a
    /// descriptor an io thread is still reading (and the kernel could hand that
    /// number to an unrelated socket).
    private var pendingClientFDs: Set<Int32> = []

    /// `nil` on the unauthenticated loopback listener; set for the shared (LAN)
    /// listener. Swapped in place by `updateAccessPolicy`, never rebound.
    private var accessPolicy: ProxyAccessPolicy?
    /// Called when a request is refused for want of valid credentials. Only the
    /// shared listener sets it.
    private let onRefusedClient: (@Sendable (String) -> Void)?
    /// Builds the PAC document for the shared listener. `nil` on the loopback
    /// listener, which never serves one. Weakly captured by the engine, so it
    /// cannot outlive its state.
    private let pacProvider: (@Sendable () -> String?)?
    /// Relays this listener started, so its teardown closes exactly them and
    /// leaves relays owned by another listener on the shared registry alone.
    private var liveRelays: [ObjectIdentifier: RelayConnection] = [:]

    /// How long outbound connects may take (also used for handshakes).
    var connectTimeout: Double = 10
    /// How long a shared-listener request body may take to arrive, and the most
    /// of it that will be buffered while its framing is resolved.
    static let requestBodyTimeout: Double = 15
    static let maxBufferedBody = 8 * 1024 * 1024

    init(
        matcher: RuleMatcher,
        policyStore: PolicyStore,
        requestLog: RequestLog,
        relayRegistry: RelayRegistry,
        acceptQueue: DispatchQueue = DispatchQueue(label: "com.turtlediver.engine.http.accept", qos: .userInitiated),
        ioQueues: [DispatchQueue]? = nil,
        accessPolicy: ProxyAccessPolicy? = nil,
        onRefusedClient: (@Sendable (String) -> Void)? = nil,
        pacProvider: (@Sendable () -> String?)? = nil
    ) {
        self.matcher = matcher
        self.policyStore = policyStore
        self.requestLog = requestLog
        self.relayRegistry = relayRegistry
        self.acceptQueue = acceptQueue
        self.accessPolicy = accessPolicy
        self.onRefusedClient = onRefusedClient
        self.pacProvider = pacProvider
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
        stopped = false
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

    /// Tears the listener down: no new acceptance, no new relay registration,
    /// every pre-relay connection woken, every relay this listener owns
    /// finished. Idempotent.
    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        // Fence first, then take ownership of everything to tear down — all in
        // one critical section, so `drainListener` (which holds this lock across
        // accept) either accepted before the fence and is in `pendingClientFDs`,
        // or sees `stopped`/a closed listener and closes what it just accepted.
        stopped = true
        acceptSource?.cancel()
        acceptSource = nil
        safetySource?.cancel()
        safetySource = nil
        let fd = listenerFD
        listenerFD = -1
        let pending = Array(pendingClientFDs)
        pendingClientFDs.removeAll()
        // Woken while the lock is still held: once it is released an io task may
        // take a descriptor out of the set and close it, and `stop()` must never
        // touch that number afterwards (the kernel could have recycled it into an
        // unrelated socket by then). shutdown() only wakes the reader — the io
        // path keeps ownership of the close.
        for client in pending { shutdown(client, SHUT_RDWR) }
        let relays = Array(liveRelays.values)
        lock.unlock()

        TCPClient.closeSocket(fd)
        for relay in relays {
            relay.finish(with: RelayError.upstreamConnectFailed("listener stopped"))
        }
    }

    /// Hot-swaps the access policy (share credential edits) without rebinding.
    /// In-flight relays are untouched — only the next request is judged anew.
    func updateAccessPolicy(_ policy: ProxyAccessPolicy?) {
        lock.withLock { accessPolicy = policy }
    }

    /// Whether `stop()` has fenced this listener.
    var isStopped: Bool { lock.withLock { stopped } }

    /// Connections accepted but not yet handed to a relay (diagnostics/tests:
    /// `stop()` must fence and wake these).
    var pendingConnectionCount: Int { lock.withLock { pendingClientFDs.count } }

    /// Checks the admission fence WITHOUT taking the descriptor out of the
    /// pending set.
    ///
    /// A shared request can sit in this server for seconds while its body is
    /// read (a chunked upload, a client that stalls). Its descriptor must stay
    /// owned by the pending set for that whole time, or `stop()` has nothing to
    /// wake and the reader keeps the connection until its own timeout. Ownership
    /// moves to the relay in `handoffToRelay`, or is taken for the final close by
    /// `takePending`.
    private func admitsService(_ clientFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else {
            // Post-stop: the shutdown already happened (it is still pending), so
            // the caller may close it unserved.
            pendingClientFDs.remove(clientFD)
            return false
        }
        return true
    }

    /// Takes `clientFD` out of the pending set and reports whether admission is
    /// still open. `false` means `stop()` fenced the listener: the caller owns
    /// the descriptor (stop only shut it down) and must close it unserved.
    private func takePending(_ clientFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pendingClientFDs.remove(clientFD)
        return !stopped
    }

    /// Moves an accepted connection from the pending set to `relay`'s ownership,
    /// atomically against `stop()`. Returns false when the listener stopped in
    /// the meantime: the caller owns the fd and must hand it to `relay.finish`
    /// (or close it) rather than serve it.
    private func handoffToRelay(_ relay: RelayConnection, clientFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pendingClientFDs.remove(clientFD)
        guard !stopped else { return false }
        liveRelays[ObjectIdentifier(relay)] = relay
        return true
    }

    /// Drops a finished relay from this listener's book.
    private func unregisterRelay(_ relay: RelayConnection) {
        _ = lock.withLock { liveRelays.removeValue(forKey: ObjectIdentifier(relay)) }
    }

    // MARK: Accepting

    /// Accepts every pending connection (drains until EAGAIN). GCD read
    /// sources deliver events on the readable *transition*: connections that
    /// queue up behind an in-flight handler run may never generate another
    /// event, so accepting one-per-event strands the tail of a burst in the
    /// kernel backlog (observed as multi-second stalls under stress load).
    private func drainListener() {
        while true {
            // Capture the peer address so a shared listener can authenticate the
            // client (accept(fd, nil, nil) throws it away).
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            // The lock is held ACROSS accept(): `stop()` closes the listener
            // under the same lock, so the descriptor cannot be closed (and
            // recycled) between the read of `listenerFD` and the call. The
            // listener is non-blocking, so this costs one syscall.
            let clientAddress: String?
            let queue: DispatchQueue
            let fd: Int32
            lock.lock()
            let listener = listenerFD
            guard listener >= 0, !stopped else {
                lock.unlock()
                return
            }
            fd = withUnsafeMutablePointer(to: &storage) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listener, sa, &length)
                }
            }
            guard fd >= 0 else {
                lock.unlock()
                if errno == EINTR { continue }
                return // EAGAIN/EWOULDBLOCK or real error: wait for new events
            }
            // Registered while still holding the lock: `stop()` either sees it
            // here and shuts it down, or the fence above refused us.
            pendingClientFDs.insert(fd)
            clientAddress = Self.ipv4Text(from: storage)
            queue = ioQueues[nextQueue % ioQueues.count]
            nextQueue += 1
            lock.unlock()

            TCPClient.setNonBlocking(fd)
            TCPClient.setNoSigpipe(fd)
            if TCPClient.fdTraceEnabled {
                FileHandle.standardError.write(Data("TD-FD-OPEN [\(Int(Date().timeIntervalSince1970 * 1000))] fd=\(fd) kind=http-accept\n".utf8))
            }

            queue.async { [weak self] in
                guard let self else {
                    // The listener was released before this task ran: nobody else
                    // owns the descriptor, so close it here (stop() only shut
                    // pending connections down; it never closes them).
                    TCPClient.closeSocket(fd)
                    return
                }
                self.readRequestHead(clientFD: fd, clientAddress: clientAddress)
            }
        }
    }

    // MARK: Request head

    private func readRequestHead(clientFD: Int32, clientAddress: String?) {
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(30)

        while buffer.count < 65536 {
            if let range = OutboundConnector.headTerminatorRange(buffer) {
                let headBytes = Array(buffer[..<range.lowerBound])
                let leftover = Array(buffer[range.upperBound...])
                route(headBytes: headBytes, leftover: leftover, clientFD: clientFD, clientAddress: clientAddress)
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
        // Past the fence nothing is served on this connection, and `stop()` has
        // already woken it — close silently instead of writing a reply.
        guard takePending(clientFD) else {
            TCPClient.closeSocket(clientFD)
            return
        }
        _ = try? TCPClient.sendAll(
            fd: clientFD,
            Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
            timeoutSeconds: 5
        )
        TCPClient.closeSocket(clientFD)
    }

    private func route(headBytes: [UInt8], leftover: [UInt8], clientFD: Int32, clientAddress: String?) {
        // Admission fence: a head that completed after `stop()` must not be
        // routed, let alone turn into a relay. The descriptor stays in the
        // pending set (so `stop()` can still wake a body read); ownership moves
        // at handoff or at the terminal close.
        guard admitsService(clientFD) else {
            TCPClient.closeSocket(clientFD)
            return
        }
        guard let head = Self.parseRequestHead(headBytes) else {
            respondSimple(clientFD: clientFD, status: "400 Bad Request", body: "malformed request head")
            return
        }

        // Shared (LAN) listener: the peer must be an allow-listed address or
        // present valid Proxy-Authorization. Judged once, right after the head
        // is parsed and before any CONNECT/forward branching, so no destination
        // is contacted for an unauthenticated client.
        let policy = lock.withLock { accessPolicy }
        if let policy {
            // PAC fetch: the token path, answered *before* the credential
            // gate. Phones fetch a PAC automatically and cannot attach
            // Proxy-Authorization to that fetch; the token in the path
            // (derived from the share password) is what authorises it. Any
            // other origin-form target still falls through to the gate and
            // then to the usual 400. Both origin-form and absolute-form are
            // recognised so a proxy-style request for the PAC URL is served
            // here too — and never reaches the request log, where the token
            // would otherwise be recorded.
            let pacPath = "/\(SharePACGenerator.token(password: policy.password))/proxy.pac"
            if let path = Self.requestPath(head: head),
               Self.constantTimeEquals(path, pacPath) {
                let method = head.method.uppercased()
                if method == "GET" || method == "HEAD" {
                    respondPAC(clientFD: clientFD, includeBody: method != "HEAD")
                } else {
                    respondSimple(
                        clientFD: clientFD,
                        status: "400 Bad Request",
                        body: "the PAC URL is fetched with GET or HEAD"
                    )
                }
                return
            }

            let admittedByAddress = clientAddress.map { policy.allowedClients.contains($0) } ?? false
            let admittedByCredentials = Self.credentialsMatch(head: head, policy: policy)
            if !admittedByAddress && !admittedByCredentials {
                refuseClient(clientFD: clientFD, address: clientAddress)
                return
            }
        }
        // Only the shared listener has a client worth naming; on the loopback
        // listener the peer is always this Mac, so it stays blank.
        let reportedClient = policy == nil ? nil : clientAddress

        // CONNECT tunnel
        if head.method.uppercased() == "CONNECT" {
            guard let destination = HTTPRequestRouter.destination(head: head) else {
                respondSimple(clientFD: clientFD, status: "400 Bad Request", body: "CONNECT requires host:port")
                return
            }
            handleDecision(clientFD: clientFD, destination: destination, head: head, leftover: leftover, isConnect: true, clientAddress: reportedClient)
            return
        }

        // Forward-proxy request (absolute-URI)
        if let destination = HTTPRequestRouter.absoluteFormDestination(head: head) {
            handleDecision(clientFD: clientFD, destination: destination, head: head, leftover: leftover, isConnect: false, clientAddress: reportedClient)
            return
        }

        // Origin-form: we are not a web server.
        respondSimple(clientFD: clientFD, status: "400 Bad Request", body: "TurtleDiver proxies CONNECT and absolute-URI requests only")
    }

    // MARK: Policy plumbing

    /// Match context for HTTP: host (from target), port, URL, User-Agent, and —
    /// for the shared listener — the accepted peer address, so `SRC-IP` rules
    /// see the device the request actually came from.
    private func matchContext(
        head: HTTPRequestHead,
        destination: RelayDestination,
        sourceIP: IPAddress?
    ) -> MatchContext {
        MatchContext(
            host: destination.host,
            port: destination.port,
            userAgent: head.header("user-agent"),
            url: head.target,
            sourceIP: sourceIP
        )
    }

    private func handleDecision(
        clientFD: Int32,
        destination: RelayDestination,
        head: HTTPRequestHead,
        leftover: [UInt8],
        isConnect: Bool,
        clientAddress: String?
    ) {
        // The loopback listener passes nil here (its peer is always this Mac), so
        // SRC-IP rules behave exactly as before on it.
        let sourceIP = clientAddress.flatMap { IPAddress.parseIPv4($0) }
        let context = matchContext(head: head, destination: destination, sourceIP: sourceIP)
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
                transport: .http, client: clientAddress, error: "rejected"
            ))
            if capture { requestLog.attachDetail(id: rejected.id, detail: requestDetail) }
            respondSimple(clientFD: clientFD, status: "403 Forbidden", body: "rejected by rule")
            return
        }

        let entry = requestLog.append(.init(
            host: destination.host, port: destination.port, rule: outcome.rule,
            policy: outcome.policy, bytesToDestination: 0, bytesToClient: 0,
            transport: .http, client: clientAddress, error: nil
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
                observer.onClientPrefix = { [weak self, weak observer] bytes in
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
                        merged.resolvedAddress = observer?.peerAddress
                        self?.requestLog.attachDetail(id: entry.id, detail: merged)
                        return true
                    }
                }
            }
            // Establish first so we can report success/failure honestly.
            //
            // Completion is owned by the registry and the log, not by this
            // server: `stop()` releases the server while relays may still be
            // draining, and the registry retain / unfinished log row must be
            // retired regardless. The server is captured weakly for the
            // `liveRelays` bookkeeping only.
            let log = requestLog
            let registry = relayRegistry
            let relay = RelayConnection(clientFD: clientFD, queue: registry.queue)
            registry.retain(relay)
            relay.onFinished = { [weak self, weak relay] metrics, error in
                log.finish(id: entry.id, bytesToDestination: metrics.bytesToDestination, bytesToClient: metrics.bytesToClient, error: error?.localizedDescription)
                guard let relay else { return }
                self?.unregisterRelay(relay)
                registry.release(relay)
            }
            // Registered (and the hook installed) before `start`, so a stop in
            // this window tears the relay down through the same hook instead of
            // leaking the retain.
            guard handoffToRelay(relay, clientFD: clientFD) else {
                relay.finish(with: RelayError.upstreamConnectFailed("listener stopped"))
                return
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
        //
        // A shared-listener connection carries EXACTLY ONE plain-HTTP message.
        // Only the first head was authenticated, so a byte belonging to a second
        // request must never reach the origin: the body is framed here and the
        // relay is given a byte budget that ends at the body's last byte. (A
        // CONNECT tunnel is authenticated once and then opaque, as before; the
        // loopback listener is unauthenticated and keeps its old behaviour.)
        let isSharedListener = (lock.withLock { accessPolicy }) != nil
        let framing = isSharedListener
            ? HTTPRequestRouter.framing(of: head)
            : HTTPRequestFraming.none
        // Nothing may be written to the origin if the message's end is not
        // knowable: the shared listener fails closed rather than guess.
        if case .unsupported(let detail) = framing {
            failRequest(entry: entry, clientFD: clientFD, status: "502 Bad Gateway",
                        detail: "unsupported request framing: \(detail)")
            return
        }
        guard var requestBytes = HTTPRequestRouter.originFormBytes(head: head, stripExpect: isSharedListener) else {
            failRequest(entry: entry, clientFD: clientFD, status: "502 Bad Gateway",
                        detail: "unsupported request target")
            return
        }

        // `Expect: 100-continue`: answer it here, before reading the body. The
        // client is blocked waiting for the interim response, so a chunked read
        // would deadlock against it. Only after the framing was accepted — a
        // rejected message must not earn a `100`.
        if isSharedListener, framing.hasBody, HTTPRequestRouter.expectsContinue(head) {
            _ = try? TCPClient.sendAll(
                fd: clientFD,
                Array("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                timeoutSeconds: 5
            )
        }

        var clientByteBudget: Int?
        if isSharedListener {
            switch framing {
            case .none, .unsupported:
                clientByteBudget = 0
            case .fixed(let length):
                if leftover.count >= length {
                    requestBytes.append(contentsOf: leftover.prefix(length))
                    clientByteBudget = 0
                } else {
                    requestBytes.append(contentsOf: leftover)
                    clientByteBudget = length - leftover.count
                }
            case .chunked:
                switch readChunkedBody(clientFD: clientFD, initial: leftover) {
                case .body(let body):
                    requestBytes.append(contentsOf: body)
                    clientByteBudget = 0
                case .rejected(let status, let detail):
                    failRequest(entry: entry, clientFD: clientFD, status: status, detail: detail)
                    return
                case .aborted:
                    // Client gone, listener stopped, or socket error: nothing is
                    // owed a reply, and no origin is contacted.
                    finishAbortedRequest(entry: entry, clientFD: clientFD)
                    return
                }
            }
        } else {
            clientByteBudget = nil
            if !leftover.isEmpty {
                requestBytes.append(contentsOf: leftover)
            }
        }

        // Plain HTTP: the response head comes back in the clear on the
        // destination→client leg, so the status line and response headers are
        // readable without touching the (unencrypted anyway) body.
        let observer = RelayStreamObserver()
        if capture {
            let base = requestDetail
            observer.onServerPrefix = { [weak self, weak observer] bytes in
                switch HTTPResponseHead.probe(bytes) {
                case .incomplete:
                    return false
                case .notHTTP:
                    return true
                case .parsed(let statusLine, let headers):
                    var merged = base
                    merged.statusLine = statusLine
                    merged.captureResponseHeaders(headers, revealSensitive: reveal)
                    merged.resolvedAddress = observer?.peerAddress
                    self?.requestLog.attachDetail(id: entry.id, detail: merged)
                    return true
                }
            }
        }

        let log = requestLog
        let registry = relayRegistry
        let relay = RelayConnection(clientFD: clientFD, queue: registry.queue)
        registry.retain(relay)
        relay.onFinished = { [weak self, weak relay] metrics, error in
            log.finish(id: entry.id, bytesToDestination: metrics.bytesToDestination, bytesToClient: metrics.bytesToClient, error: error?.localizedDescription)
            guard let relay else { return }
            self?.unregisterRelay(relay)
            registry.release(relay)
        }
        guard handoffToRelay(relay, clientFD: clientFD) else {
            relay.finish(with: RelayError.upstreamConnectFailed("listener stopped"))
            return
        }
        relay.start(
            decision: decision, destination: destination,
            timeoutSeconds: connectTimeout,
            initialBytes: requestBytes,
            clientByteBudget: clientByteBudget,
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

    /// Result of framing a chunked body from the socket.
    private enum ChunkedBodyRead {
        case body([UInt8])
        /// The message can be judged now: answer `status` and contact nobody.
        case rejected(status: String, detail: String)
        /// No reply is owed (client gone, listener stopped, socket error).
        case aborted
    }

    /// Reads a chunked request body from the client through its terminating
    /// chunk (trailers included).
    ///
    /// The descriptor stays in `pendingClientFDs` for the whole read, so
    /// `stop()` can wake it with a shutdown instead of leaving the reader parked
    /// until its own deadline.
    private func readChunkedBody(clientFD: Int32, initial: [UInt8]) -> ChunkedBodyRead {
        var buffer = initial
        let deadline = Date().addingTimeInterval(Self.requestBodyTimeout)
        while true {
            switch HTTPRequestRouter.parseChunkedBody(buffer, maxBody: Self.maxBufferedBody) {
            case .complete(let length):
                return .body(Array(buffer[0..<length]))
            case .invalid(let detail):
                return .rejected(status: "502 Bad Gateway", detail: "invalid chunked body: \(detail)")
            case .tooLarge:
                return .rejected(
                    status: "413 Payload Too Large",
                    detail: "chunked request body exceeds \(Self.maxBufferedBody) bytes"
                )
            case .incomplete:
                break
            }
            // Belt-and-braces: the parser bounds what it can reason about, this
            // bounds what it has to keep in memory while waiting.
            if buffer.count > Self.maxBufferedBody {
                return .rejected(
                    status: "413 Payload Too Large",
                    detail: "chunked request body exceeds \(Self.maxBufferedBody) bytes"
                )
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0,
                  TCPClient.waitForReadable(fd: clientFD, timeoutSeconds: remaining) else {
                return isStopped ? .aborted
                    : .rejected(status: "400 Bad Request", detail: "request body timed out")
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(clientFD, $0.baseAddress, 4096) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                // EOF, or the shutdown `stop()` sent to wake this read.
                return isStopped ? .aborted
                    : .rejected(status: "400 Bad Request", detail: "client closed mid-body")
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                return .aborted
            }
        }
    }

    /// Answers a request that cannot be served, closing its request-log row so
    /// the dashboard does not keep an in-flight entry forever.
    private func failRequest(entry: RequestEntry, clientFD: Int32, status: String, detail: String) {
        requestLog.finish(id: entry.id, bytesToDestination: 0, bytesToClient: 0, error: detail)
        respondSimple(clientFD: clientFD, status: status, body: detail)
    }

    /// Same, for a connection that died on its own: no reply is written.
    private func finishAbortedRequest(entry: RequestEntry, clientFD: Int32) {
        requestLog.finish(id: entry.id, bytesToDestination: 0, bytesToClient: 0, error: "client aborted")
        _ = takePending(clientFD)
        TCPClient.closeSocket(clientFD)
    }

    private func respondSimple(clientFD: Int32, status: String, body: String) {
        // Fence: once stopped, a reply would be written to a connection this
        // listener no longer serves. Close it unserved instead.
        guard takePending(clientFD) else {
            TCPClient.closeSocket(clientFD)
            return
        }
        let bodyBytes = Array(body.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
        do {
            try TCPClient.sendAll(fd: clientFD, Array(response.utf8) + bodyBytes, timeoutSeconds: 5)
        } catch {
            // Client already gone; nothing to report to.
        }
        TCPClient.closeSocket(clientFD)
    }

    /// The PAC document: one fixed URL, no credentials, no logging as a proxied
    /// request. `Content-Length` always describes the body, so `HEAD` can answer
    /// with the same headers and no body.
    private func respondPAC(clientFD: Int32, includeBody: Bool) {
        guard let document = pacProvider?() else {
            respondSimple(clientFD: clientFD, status: "503 Service Unavailable", body: "PAC unavailable")
            return
        }
        guard takePending(clientFD) else {
            TCPClient.closeSocket(clientFD)
            return
        }
        let body = Array(document.utf8)
        let head = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/x-ns-proxy-autoconfig\r\n"
            + "Cache-Control: no-store\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var response = Array(head.utf8)
        if includeBody { response += body }
        do {
            try TCPClient.sendAll(fd: clientFD, response, timeoutSeconds: 5)
        } catch {
            // Client already gone; nothing to report to.
        }
        TCPClient.closeSocket(clientFD)
    }

    /// The path of an origin-form or absolute-form request, without its query.
    /// CONNECT's authority-form and anything unparseable return nil. Used only
    /// to recognise (and keep out of the request log) the PAC URL.
    static func requestPath(head: HTTPRequestHead) -> String? {
        let path: String
        if head.target.hasPrefix("/") {
            path = head.target
        } else if let (_, _, parsed) = LatencyTester.parseHTTPURL(head.target) {
            path = parsed
        } else {
            return nil
        }
        guard let query = path.firstIndex(of: "?") else { return path }
        return String(path[..<query])
    }

    // MARK: Shared-listener access

    /// Answers an unauthenticated request with `407` and closes. The peer is
    /// reported so the engine can surface it in `refusedClients` and fire
    /// `onRefusedClient`.
    private func refuseClient(clientFD: Int32, address: String?) {
        guard takePending(clientFD) else {
            TCPClient.closeSocket(clientFD)
            return
        }
        let response = "HTTP/1.1 407 Proxy Authentication Required\r\n"
            + "Proxy-Authenticate: Basic realm=\"TurtleDiver\"\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        _ = try? TCPClient.sendAll(fd: clientFD, Array(response.utf8), timeoutSeconds: 5)
        TCPClient.closeSocket(clientFD)
        if let address { onRefusedClient?(address) }
    }

    /// Whether the head carries `Proxy-Authorization: Basic <base64(user:pass)>`
    /// matching the policy, compared without early exit on the secret.
    static func credentialsMatch(head: HTTPRequestHead, policy: ProxyAccessPolicy) -> Bool {
        guard let value = head.header("proxy-authorization") else { return false }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].caseInsensitiveCompare("basic") == .orderedSame else { return false }
        let encoded = parts[1].trimmingCharacters(in: .whitespaces)
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8),
              let colon = decoded.firstIndex(of: ":") else { return false }
        let user = String(decoded[..<colon])
        let pass = String(decoded[decoded.index(after: colon)...])
        let userOK = constantTimeEquals(user, policy.username)
        let passOK = constantTimeEquals(pass, policy.password)
        return userOK && passOK
    }

    /// Byte-wise comparison that does not short-circuit on the first mismatch.
    /// (Only the length is allowed to leak — the standard, and unavoidable,
    /// disclosure for a fixed-format credential.)
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for index in a.indices { diff |= a[index] ^ b[index] }
        return diff == 0
    }

    /// Dotted-quad text for an accepted IPv4 peer (`nil` for anything else —
    /// the shared listener is IPv4-only).
    static func ipv4Text(from storage: sockaddr_storage) -> String? {
        guard storage.ss_family == sa_family_t(AF_INET) else { return nil }
        var addr = sockaddr_in()
        withUnsafeMutableBytes(of: &addr) { dst in
            withUnsafeBytes(of: storage) { src in
                dst.copyBytes(from: src.prefix(MemoryLayout<sockaddr_in>.size))
            }
        }
        var sinAddr = addr.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buffer)
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
