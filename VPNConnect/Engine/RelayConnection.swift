import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Profile types (ProxyDefinition, BuiltinPolicy, …) live in the Profile
// sources: one module in the app target, the TurtleDiverCore module under
// `swift test`.
#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif

// MARK: - Errors

/// Failures while establishing the outbound leg of a relay.
public enum RelayError: LocalizedError, Equatable {
    /// The policy decision says drop the connection (REJECT policy).
    case rejected
    case invalidTarget(String)
    case upstreamConnectFailed(String)
    case upstreamHandshakeFailed(String)
    case tlsUpstreamUnsupported

    public var errorDescription: String? {
        switch self {
        case .rejected: return "rejected by policy"
        case .invalidTarget(let detail): return "invalid target: \(detail)"
        case .upstreamConnectFailed(let detail): return "upstream connect failed: \(detail)"
        case .upstreamHandshakeFailed(let detail): return "upstream handshake failed: \(detail)"
        case .tlsUpstreamUnsupported: return "TLS upstream proxies are not supported yet (use http or socks5)"
        }
    }
}

// MARK: - Destination

/// Where the outbound leg should go, as learned from the client protocol.
public struct RelayDestination: Equatable, Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

// MARK: - Outbound Connector

/// Runs blocking connects off the relay queues, a bounded number at a time.
///
/// A connect blocks for as long as its timeout, and an unreachable upstream (a
/// corporate proxy while the VPN is down, say) blocks for the whole of it.
/// Running those on a *serial* queue takes the whole engine down with the
/// upstream: every other dial waits its turn behind one that is going to fail
/// anyway, so one dead proxy is indistinguishable from a dead engine — new
/// requests sit there until the client gives up, including requests that had
/// nothing to do with the dead proxy.
///
/// Concurrent, with a cap, so a hung upstream costs one slot instead of all of
/// them. The cap bounds how many threads the blocking dials hold.
public final class ConnectScheduler {
    private let queue: DispatchQueue
    private let slots: DispatchSemaphore

    /// - Parameter limit: how many connects may block at once. Values below 1
    ///   would deadlock, so they are clamped to 1.
    public init(limit: Int = 8, queue: DispatchQueue = DispatchQueue.global(qos: .userInitiated)) {
        self.slots = DispatchSemaphore(value: max(1, limit))
        self.queue = queue
    }

    /// Runs `body` (a blocking connect) as soon as a slot is free. The slot is
    /// held for exactly as long as `body` runs.
    public func run(_ body: @escaping () -> Void) {
        queue.async {
            self.slots.wait()
            defer { self.slots.signal() }
            body()
        }
    }
}

/// Establishes the outbound TCP connection for one relayed request according
/// to the resolved policy decision. Split out from the pump so tests can
/// exercise policy plumbing without real networks.
public enum OutboundConnector {

    /// Connects to `destination` per the policy decision.
    /// - DIRECT: resolve + connect locally.
    /// - proxy(.http): TCP to the proxy, then HTTP CONNECT to the destination.
    /// - proxy(.socks5): SOCKS5 handshake to the destination (RFC 1928).
    /// - proxy(.https): unsupported until relay TLS lands (Phase 4+).
    public static func connect(
        decision: PolicyStore.ResolvedDecision,
        destination: RelayDestination,
        timeoutSeconds: Double
    ) throws -> Int32 {
        switch decision {
        case .reject:
            throw RelayError.rejected

        case .direct:
            guard (1...65535).contains(destination.port) else {
                throw RelayError.invalidTarget("port \(destination.port)")
            }
            return try TCPClient.connect(
                host: destination.host, port: destination.port,
                timeoutSeconds: timeoutSeconds
            )

        case .proxy(let proxy):
            switch proxy.type {
            case .https:
                throw RelayError.tlsUpstreamUnsupported
            case .http:
                return try connectViaHTTPProxy(proxy: proxy, destination: destination, timeoutSeconds: timeoutSeconds)
            case .socks5:
                return try LatencyTester.connectViaSOCKS5(
                    proxyHost: proxy.host, proxyPort: proxy.port,
                    destinationHost: destination.host, destinationPort: destination.port,
                    username: proxy.username, password: proxy.password,
                    timeoutSeconds: timeoutSeconds
                )
            }
        }
    }

    /// HTTP CONNECT tunneling through an upstream forward proxy.
    private static func connectViaHTTPProxy(
        proxy: ProxyDefinition, destination: RelayDestination, timeoutSeconds: Double
    ) throws -> Int32 {
        let fd = try TCPClient.connect(host: proxy.host, port: proxy.port, timeoutSeconds: timeoutSeconds)
        do {
            var request = "CONNECT \(destination.host):\(destination.port) HTTP/1.1\r\nHost: \(destination.host):\(destination.port)\r\n"
            if let username = proxy.username, let password = proxy.password, !username.isEmpty {
                let token = Data("\(username):\(password)".utf8).base64EncodedString()
                request += "Proxy-Authorization: Basic \(token)\r\n"
            }
            request += "\r\n"
            try TCPClient.sendAll(fd: fd, Array(request.utf8), timeoutSeconds: timeoutSeconds)

            // Read until the blank line that ends the response head.
            var head: [UInt8] = []
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while head.count < 65536 {
                guard Date() < deadline else { throw TCPClientError.timeout }
                let chunk = try TCPClient.receiveSome(
                    fd: fd, max: 4096,
                    timeoutSeconds: max(deadline.timeIntervalSinceNow, 0.1)
                )
                if chunk.isEmpty { break } // upstream closed early
                head.append(contentsOf: chunk)
                if Self.headTerminatorRange(head) != nil { break }
            }
            guard let statusLine = Self.statusLine(from: head) else {
                throw RelayError.upstreamHandshakeFailed("malformed CONNECT response")
            }
            // "HTTP/1.1 200 Connection established" → tunnel open.
            let parts = statusLine.split(separator: " ", maxSplits: 2)
            guard parts.count >= 2, parts[1].hasPrefix("2") else {
                let reason = parts.count >= 3 ? String(parts[2]) : statusLine
                throw RelayError.upstreamHandshakeFailed("CONNECT refused: \(reason)")
            }
            return fd
        } catch {
            TCPClient.closeSocket(fd)
            throw error
        }
    }

    /// Finds the `\r\n\r\n` terminator in a partial response head.
    static func headTerminatorRange(_ bytes: [UInt8]) -> Range<Int>? {
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4)
        where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
            return i..<(i + 4)
        }
        return nil
    }

    /// First line of a response head ("HTTP/1.1 200 Connection established").
    static func statusLine(from head: [UInt8]) -> String? {
        guard let firstLineEnd = head.firstIndex(of: 10) else { return nil }
        var line = String(bytes: head[..<firstLineEnd], encoding: .utf8) ?? ""
        if line.hasSuffix("\r") { line.removeLast() }
        return line.isEmpty ? nil : line
    }
}

// MARK: - Connection Metrics

/// Byte counters and lifecycle timestamps for one relayed connection.
public struct RelayMetrics: Equatable, Sendable {
    public var bytesToDestination: Int = 0   // client → outbound
    public var bytesToClient: Int = 0        // outbound → client
    public var startedAt: Date = Date()
    public var endedAt: Date?

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public var totalBytes: Int { bytesToDestination + bytesToClient }
}

// MARK: - RelayConnection

/// Pumps bytes bidirectionally between the client socket and the outbound
/// socket after the policy decision has been made.
///
/// Design: fully event-driven — no blocked threads per connection. Each
/// direction is a `DispatchSourceRead` that reads one chunk and writes it to
/// the other side. Backpressure:
/// - A short/EAGAIN write leaves data in the per-direction buffer and arms a
///   `DispatchSourceWrite` on the destination; the write source flushes and
///   disarms itself once the buffer drains.
/// - If a direction's buffer grows past the pause watermark, its read source
///   suspends until the write source drains it below the resume watermark.
/// - EOF from one side half-closes the other (`shutdown(SHUT_WR)`) so
///   protocols that signal completion via FIN relay cleanly, and stops
///   reading the side that hit EOF: a read source left armed on an EOF'd
///   socket is ready forever and fires continuously.
/// - The relay closes both fds in `finish` (not in a read source's cancel
///   handler) because a source cancelled at EOF keeps its fd — the peer that
///   stopped sending may still be receiving.
///
/// All socket state mutates on the serial `queue`; only `metrics` is shared
/// with other threads (guarded by `stateLock`).
public final class RelayConnection: @unchecked Sendable {

    /// Whether env-gated IO diagnostics (TD_FD_TRACE=1) are on.
    ///
    /// Read once and stored: `ProcessInfo.environment` rebuilds the whole
    /// environment dictionary on every access, and the EOF path below used to
    /// consult it per relay event. A sample of the relay busy-looping on a
    /// half-closed connection showed 1940 of 1943 samples inside
    /// `_ProcessInfo.environment.getter` — the loop was spinning on the
    /// environment, not on the socket.
    static let fdTraceEnabled = ProcessInfo.processInfo.environment["TD_FD_TRACE"] == "1"

    /// Env-gated IO diagnostics (TD_FD_TRACE=1): one line per relay read
    /// error with both endpoint fds, for correlating engine relays with their
    /// peers (e.g. a test echo server) in stress runs.
    static func traceIO(_ message: String) {
        #if DEBUG
        if Self.fdTraceEnabled {
            FileHandle.standardError.write(Data("TD-RELAY [seq=\(Self.nextSeq())] \(message)\n".utf8))
        }
        #endif
    }

    /// Monotonic sequence for trace lines: identical-looking events (same fds,
    /// reused across recycled connections) must never be collapsed or
    /// mis-ordered when correlating stress-test traces.
    private static let seqLock = NSLock()
    private static var _seq = 0
    private static func nextSeq() -> Int {
        seqLock.lock()
        defer { seqLock.unlock() }
        _seq += 1
        return _seq
    }

    /// Local port of `fd` for trace correlation (0 when unavailable).
    static func localPort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getsockname(fd, withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &len) == 0 else { return 0 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Peer address of `fd`, numeric (nil when unavailable). Used only to
    /// report which server a hostname resolved to; both families are handled,
    /// so an IPv6 peer is not reported as garbage IPv4.
    static func peerAddress(_ fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        guard result == 0 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let info = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        guard info == 0 else { return nil }
        let address = String(cString: host)
        // A scoped IPv6 link-local address carries a "%en0" suffix that means
        // nothing to the reader of a request row.
        return address.isEmpty ? nil : address.split(separator: "%").first.map(String.init)
    }

    /// Peer port of `fd` for trace correlation (0 when unavailable).
    static func remotePort(_ fd: Int32) -> Int {
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard getpeername(fd, withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, &len) == 0 else { return 0 }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    static let bufferSize = 64 * 1024
    static let pauseWatermark = 256 * 1024
    static let resumeWatermark = 128 * 1024

    /// Outbound establishment (DNS resolution + TCP connect, and upstream
    /// proxy handshakes) runs here, NOT on the shared relay queue: these are
    /// blocking operations that can take seconds, and serializing them behind
    /// the relay queue would stall every active connection's pumping.
    private static let connects = ConnectScheduler(limit: 8)

    // MARK: Endpoints

    public let clientFD: Int32
    public private(set) var outboundFD: Int32?

    // MARK: Sources & queue

    private let queue: DispatchQueue
    private var clientReadSource: DispatchSourceRead?
    private var outboundReadSource: DispatchSourceRead?
    private var clientWriteSource: DispatchSourceWrite?
    private var outboundWriteSource: DispatchSourceWrite?

    // MARK: Buffers (queue-confined)

    private var clientToOutbound = [UInt8]()
    private var outboundToClient = [UInt8]()

    // MARK: Flow state (queue-confined)

    private var clientReadPaused = false
    private var outboundReadPaused = false
    private var clientEOF = false
    private var outboundEOF = false
    private var started = false
    /// Whether read sources have been armed (queue-confined). When false at
    /// teardown, the outbound fd (if any) belongs to the connect path's error
    /// handler, so the relay closes only the client fd.
    private var sourcesArmed = false

    // MARK: Lifecycle state

    private enum Lifecycle { case idle, connecting, running, closing, closed }
    private var lifecycle: Lifecycle = .idle
    private let lifecycleLock = NSLock()

    /// Metrics guarded by `lifecycleLock`; readable from any thread.
    public private(set) var metrics = RelayMetrics()

    /// Called once from `queue` when the relay finishes (both sides closed or
    /// an error occurred). The engine retires the request-log entry here.
    public var onFinished: ((RelayMetrics, Error?) -> Void)?

    private var finishedError: Error?

    /// Optional prefix watcher, called from `queue` only. Set from the relay
    /// queue in `start` (never from the caller's thread) so its buffers are
    /// confined to the same serial queue the reads run on.
    private var observer: RelayStreamObserver?

    public init(clientFD: Int32, queue: DispatchQueue) {
        self.clientFD = clientFD
        self.queue = queue
    }

    // MARK: Lifecycle

    /// Connects the outbound leg and starts pumping. `completion` fires on
    /// `queue` with the connect outcome (before any bytes flow).
    /// `initialBytes` (e.g. the rewritten absolute-form request) are queued
    /// for the outbound leg before sources arm, preserving byte order.
    public func start(
        decision: PolicyStore.ResolvedDecision,
        destination: RelayDestination,
        timeoutSeconds: Double,
        initialBytes: [UInt8]? = nil,
        /// Watches the first bytes of either leg (see `RelayStreamObserver`).
        /// Purely an observer: the bytes forwarded are never altered.
        observer: RelayStreamObserver? = nil,
        errorReply: ((Error) -> [UInt8])? = nil,
        completion: @escaping (Error?) -> Void
    ) {
        lifecycleLock.lock()
        guard lifecycle == .idle else {
            lifecycleLock.unlock()
            completion(RelayError.invalidTarget("relay already started"))
            return
        }
        lifecycle = .connecting
        lifecycleLock.unlock()

        // Slow, blocking phase on the dedicated connect scheduler.
        Self.connects.run { [weak self] in
            guard let self else { return }
            do {
                let fd = try OutboundConnector.connect(
                    decision: decision, destination: destination, timeoutSeconds: timeoutSeconds
                )
                // Attach + start pumping on the relay queue.
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.lifecycleLock.lock()
                    let stillConnecting = self.lifecycle == .connecting
                    self.lifecycleLock.unlock()
                    guard stillConnecting else {
                        // Finished while connecting (owner tore it down): the
                        // finish() teardown already ran, so just drop the fd.
                        TCPClient.closeSocket(fd)
                        return
                    }
                    self.outboundFD = fd
                    self.observer = observer
                    // Read from the relay queue, before any byte can be read,
                    // so the capture handlers see it without a lock.
                    observer?.setPeerAddress(Self.peerAddress(fd))
                    // The connector restores blocking mode for its callers;
                    // the relay pump REQUIRES non-blocking (dispatch sources
                    // + EAGAIN-driven backpressure). A blocking outbound fd
                    // here turns flush() into a blocking send on the serial
                    // relay queue: one full socket buffer wedges EVERY relay
                    // sharing the queue until the peer drains (observed as
                    // 15s whole-engine stalls with zero source events).
                    TCPClient.setNonBlocking(fd)
                    self.lifecycleLock.lock()
                    self.lifecycle = .running
                    self.lifecycleLock.unlock()
                    if let initial = initialBytes, !initial.isEmpty {
                        self.clientToOutbound.append(contentsOf: initial)
                    }
                    self.armSources()
                    // Kick pending initial bytes: with no further client data
                    // in flight (absolute-form requests arrive as one head),
                    // nothing else would trigger the client→outbound flush.
                    if !self.clientToOutbound.isEmpty {
                        self.flush(buffer: &self.clientToOutbound, toFD: self.outboundFD, clientSide: true)
                    }
                    completion(nil)
                }
            } catch {
                // Report the failure to the client and tear down on the relay
                // queue, in that order — the relay owns the client fd end to
                // end. The server must NOT also write/close this fd: a close
                // here frees the number, and a second close (or a write) can
                // land on a recycled fd of an unrelated live connection.
                self.queue.async { [weak self] in
                    guard let self else { return }
                    if let errorReply {
                        _ = try? TCPClient.sendAll(fd: self.clientFD, errorReply(error), timeoutSeconds: 5)
                    }
                    self.finish(with: error)
                    completion(error)
                }
            }
        }
    }

    private func armSources() {
        sourcesArmed = true
        // The fds are closed by `finish`, not by a cancel handler: a read
        // source cancelled at EOF keeps its fd open, because the peer that
        // stopped sending may still be receiving (see `stopReading`).
        // Cancelling happens on this queue, so no handler can be mid-flight
        // when the close lands.
        let clientSource = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: queue)
        clientSource.setEventHandler { [weak self] in self?.readFromClient() }
        clientSource.resume()
        clientReadSource = clientSource

        guard let outbound = outboundFD else { return }
        let outboundSource = DispatchSource.makeReadSource(fileDescriptor: outbound, queue: queue)
        outboundSource.setEventHandler { [weak self] in self?.readFromOutbound() }
        outboundSource.resume()
        outboundReadSource = outboundSource

        // Lost-edge guard: GCD read sources are edge-triggered and on this OS
        // do not report data that arrived BEFORE resume() (observed on
        // macOS 27: a fast upstream peer can deliver bytes between connect()
        // and armSources(), leaving the source silent forever and the relay
        // stalled). Probe both sockets once; the read path is safe to invoke
        // directly (it only reads when data is present and tolerates EAGAIN).
        probePreArmedData(fd: clientFD, clientSide: true)
        probePreArmedData(fd: outbound, clientSide: false)
    }

    /// One-shot manual readability check to cover the pre-resume window.
    private func probePreArmedData(fd: Int32, clientSide: Bool) {
        var pfd = pollfd()
        pfd.fd = fd
        pfd.events = Int16(POLLIN)
        pfd.revents = 0
        if poll(&pfd, 1, 0) > 0, pfd.revents & Int16(POLLIN) != 0 {
            if clientSide {
                readFromClient()
            } else {
                readFromOutbound()
            }
        }
    }

    // MARK: Reading

    private func readFromClient() {
        read(from: clientFD, into: &clientToOutbound, toFD: outboundFD, clientSide: true)
    }

    private func readFromOutbound() {
        Self.traceIO("first-outbound-read client=\(clientFD) outbound=\(outboundFD.map(String.init) ?? "nil")")
        read(from: outboundFD ?? -1, into: &outboundToClient, toFD: clientFD, clientSide: false)
    }

    private func read(from fd: Int32, into buffer: inout [UInt8], toFD: Int32?, clientSide: Bool) {
        guard lifecycle == .running else { return }

        // Flush pending data first so ordering client→outbound is preserved.
        flush(buffer: &buffer, toFD: toFD, clientSide: clientSide)

        var chunk = [UInt8](repeating: 0, count: Self.bufferSize)
        let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, Self.bufferSize) }
        if n > 0 {
            // Observe before buffering: forwarding is unconditional either way,
            // so this cannot reorder or drop a byte.
            observer?.observe(chunk: Array(chunk[0..<n]), direction: clientSide ? .toDestination : .toClient)
            buffer.append(contentsOf: chunk[0..<n])
            lifecycleLock.lock()
            if clientSide {
                metrics.bytesToDestination += n
            } else {
                metrics.bytesToClient += n
            }
            lifecycleLock.unlock()
            flush(buffer: &buffer, toFD: toFD, clientSide: clientSide)
            if buffer.count >= Self.pauseWatermark {
                pauseRead(clientSide: clientSide)
            }
        } else if n == 0 {
            sawEOF(clientSide: clientSide, otherFD: toFD)
        } else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                return // spurious wakeup; source fires again when readable
            }
            let err = errno // snapshot before any other call clobbers it
            Self.traceIO("read-error fd=\(fd):\(Self.localPort(fd))->\(Self.remotePort(fd)) errno=\(err) client=\(clientFD):\(Self.localPort(clientFD)) clientSide=\(clientSide)")
            finish(with: RelayError.upstreamConnectFailed("read failed: \(String(cString: strerror(err)))"))
        }
    }

    /// EOF from one side: half-close the other direction and finish when both
    /// sides are done.
    private func sawEOF(clientSide: Bool, otherFD: Int32?) {
        if Self.fdTraceEnabled {
            let from = clientSide ? "client" : "outbound"
            let to = clientSide ? "outbound" : "client"
            let fd = clientSide ? clientFD : (outboundFD ?? -1)
            let other = clientSide ? (outboundFD ?? -1) : clientFD
            FileHandle.standardError.write(Data("TD-RELAY [\(Int(Date().timeIntervalSince1970 * 1000))] EOF from=\(from) fd=\(fd) -> shut \(to) fd=\(other) toDest=\(metrics.bytesToDestination) toClient=\(metrics.bytesToClient)\n".utf8))
        }
        stopReading(clientSide: clientSide)
        // Propagate FIN to the other side (ignore errors on dead sockets).
        if let otherFD, otherFD >= 0 {
            shutdown(otherFD, SHUT_WR)
        }
        if clientEOF && outboundEOF {
            finish(with: nil)
        }
    }

    /// Stops reading one side at EOF, keeping its fd open.
    ///
    /// A read source on a socket that has reached EOF is ready **forever**:
    /// the handler re-reads, gets 0 again, and is requeued immediately. Left
    /// armed that is a busy loop in the kernel — measured live as ~94% of a
    /// core inside `sawEOF` on `com.turtlediver.engine.relay`, one `read` per
    /// iteration, for as long as the other side stayed open (a browser's
    /// keep-alive connection to the proxy after an origin sent
    /// `Connection: close`, for instance). Cancelling is what stops the source
    /// firing, and dropping the reference with it means the relay cannot
    /// accidentally re-arm it. The fd stays open: EOF ends one direction, not
    /// the connection.
    private func stopReading(clientSide: Bool) {
        if clientSide {
            guard !clientEOF else { return }
            clientEOF = true
            let source = clientReadSource
            clientReadSource = nil
            source?.cancel()
        } else {
            guard !outboundEOF else { return }
            outboundEOF = true
            let source = outboundReadSource
            outboundReadSource = nil
            source?.cancel()
        }
    }

    private func pauseRead(clientSide: Bool) {
        guard lifecycle == .running else { return }
        if clientSide {
            guard !clientReadPaused else { return }
            clientReadPaused = true
            clientReadSource?.suspend()
        } else {
            guard !outboundReadPaused else { return }
            outboundReadPaused = true
            outboundReadSource?.suspend()
        }
    }

    private func resumeRead(clientSide: Bool) {
        guard lifecycle == .running else { return }
        let fd: Int32
        if clientSide {
            guard clientReadPaused else { return }
            clientReadPaused = false
            clientReadSource?.resume()
            fd = clientFD
        } else {
            guard outboundReadPaused else { return }
            outboundReadPaused = false
            outboundReadSource?.resume()
            fd = outboundFD ?? -1
        }
        guard fd >= 0 else { return }

        // The lost-edge probe must hop a turn on `queue` before pumping reads:
        // `resumeRead` is reachable from inside `flush`, which was itself called
        // with an exclusive `inout` access to the very buffer the probe would
        // append into (the write source's handler passes `&clientToOutbound` /
        // `&outboundToClient` down). Probing inline re-enters `read(from:into:)`
        // while that access is still live, and the Swift runtime's exclusivity
        // check traps — observed as a hard crash in `readFromOutbound()` on
        // `com.turtlediver.engine.relay`. One deferred turn releases the access
        // first; a read source is already resumed by then, so nothing is lost.
        queue.async { [weak self] in
            self?.probeReadAfterResume(fd: fd, clientSide: clientSide)
        }
    }

    /// Lost-edge guard for suspended→resumed read sources: data that arrives
    /// while a source is suspended does not produce a new readiness edge on
    /// resume() (same EV_CLEAR behavior as the pre-arm window), so the source
    /// would stay silent with bytes queued — stalling the relay. Probe once
    /// and pump manually; `read(from:into:toFD:clientSide:)` is safe to call
    /// when data is present and tolerates EAGAIN spurious wakeups.
    private func probeReadAfterResume(fd: Int32, clientSide: Bool) {
        guard fd >= 0, lifecycle == .running else { return }
        var pfd = pollfd()
        pfd.fd = fd
        pfd.events = Int16(POLLIN)
        pfd.revents = 0
        if poll(&pfd, 1, 0) > 0, pfd.revents & Int16(POLLIN) != 0 {
            if clientSide {
                readFromClient()
            } else {
                readFromOutbound()
            }
        }
    }

    // MARK: Writing

    /// Tries to drain `buffer` into `fd`. On EAGAIN arms a write source that
    /// retries; when the buffer drains below the resume watermark the
    /// corresponding paused read source is resumed.
    private func flush(buffer: inout [UInt8], toFD: Int32?, clientSide: Bool) {
        guard let target = toFD, target >= 0, !buffer.isEmpty else { return }
        while !buffer.isEmpty {
            let written = buffer.withUnsafeBytes { raw -> Int in
                send(target, raw.baseAddress, raw.count, Int32(MSG_NOSIGNAL))
            }
            if written > 0 {
                buffer.removeFirst(written)
                continue
            }
            if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                armWriteSource(fd: target, clientSide: clientSide)
                return
            }
            if written < 0 && errno == EINTR {
                continue
            }
            let err = errno // snapshot before any other call clobbers it
            Self.traceIO("write-error fd=\(target):\(Self.localPort(target))->\(Self.remotePort(target)) errno=\(err) client=\(clientFD):\(Self.localPort(clientFD)) clientSide=\(clientSide) pending=\(buffer.count)")
            finish(with: RelayError.upstreamConnectFailed("write failed: \(String(cString: strerror(err)))"))
            return
        }
        // Fully drained: no write source needed anymore.
        disarmWriteSource(clientSide: clientSide)
        resumeRead(clientSide: clientSide)
    }

    private func armWriteSource(fd: Int32, clientSide: Bool) {
        let existing = clientSide ? clientWriteSource : outboundWriteSource
        if existing != nil { return } // already armed
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // GCD orders a source's own events before its cancel handler, but
            // NOT across sources: this write event can already be dequeued on
            // `queue` when `finish` closes the fds. The lifecycle check makes
            // such late handlers no-ops instead of writing into a recycled
            // descriptor.
            self.lifecycleLock.lock()
            let running = self.lifecycle == .running
            self.lifecycleLock.unlock()
            guard running else { return }
            if clientSide {
                self.flush(buffer: &self.clientToOutbound, toFD: self.outboundFD, clientSide: true)
            } else {
                self.flush(buffer: &self.outboundToClient, toFD: self.clientFD, clientSide: false)
            }
        }
        source.setCancelHandler {}
        source.resume()
        if clientSide {
            clientWriteSource = source
        } else {
            outboundWriteSource = source
        }
    }

    private func disarmWriteSource(clientSide: Bool) {
        let source = clientSide ? clientWriteSource : outboundWriteSource
        guard let source else { return }
        source.cancel()
        if clientSide {
            clientWriteSource = nil
        } else {
            outboundWriteSource = nil
        }
    }

    // MARK: Shutdown

    /// Tears the relay down: cancels sources (their cancel handlers close the
    /// fds), records metrics, notifies the owner. Idempotent. Safe from any
    /// queue — including the connect queue when a connect attempt fails.
    public func finish(with error: Error?) {
        lifecycleLock.lock()
        guard lifecycle != .closing, lifecycle != .closed else { lifecycleLock.unlock(); return }
        lifecycle = .closing
        if finishedError == nil { finishedError = error }
        metrics.endedAt = Date()
        lifecycleLock.unlock()
        Self.traceIO("finish client=\(clientFD) outbound=\(outboundFD.map(String.init) ?? "nil") error=\(error.map { String(describing: $0) } ?? "clean") toDest=\(metrics.bytesToDestination) toClient=\(metrics.bytesToClient)")

        queue.async { [weak self] in
            guard let self else { return }
            if self.sourcesArmed {
                // Cancel the sources, then close the fds — all on this queue,
                // so nothing can be reading or writing them in between. The
                // close is here rather than in a cancel handler because a read
                // source cancelled at EOF deliberately leaves its fd open.
                self.clientReadSource?.cancel()
                self.clientReadSource = nil
                self.outboundReadSource?.cancel()
                self.outboundReadSource = nil
                self.disarmWriteSource(clientSide: true)
                self.disarmWriteSource(clientSide: false)
                TCPClient.closeSocket(self.clientFD)
                if let outbound = self.outboundFD { TCPClient.closeSocket(outbound) }
            } else {
                // Teardown before arming (e.g. upstream connect failed): the
                // relay closes the client fd here. (The outbound fd, if any, is
                // closed by the connector's error path.) Without this the fd
                // would leak on every failed connect.
                TCPClient.closeSocket(self.clientFD)
            }

            self.lifecycleLock.lock()
            self.lifecycle = .closed
            let snapshot = self.metrics
            let err = self.finishedError
            self.lifecycleLock.unlock()
            self.onFinished?(snapshot, err)
        }
    }
}
