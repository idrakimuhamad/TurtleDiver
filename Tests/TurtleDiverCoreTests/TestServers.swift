import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TurtleDiverCore

// MARK: - Shared socket helpers for test servers

enum TestSockets {
    /// Creates a loopback TCP listener on an ephemeral port.
    static func listenOnEphemeralLoopback() -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ephemeral
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bindResult == 0)
        precondition(listen(fd, 16) == 0)

        // Read the ephemeral port with everything inside the pointer closure —
        // a pointer escaping `withUnsafeMutablePointer` would dangle.
        var outAddr = sockaddr_in()
        let port: Int = withUnsafeMutablePointer(to: &outAddr) { outPtr in
            outPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                getsockname(fd, sa, &len)
            }
            return Int(UInt16(bigEndian: outPtr.pointee.sin_port))
        }
        return (fd, port)
    }

    /// Accepts one connection with a wall-clock timeout (seconds).
    ///
    /// ⚠️ Callers own the listener fd's lifetime: because this polls by
    /// *number*, the caller must guarantee no accept loop is still inside it
    /// when the fd is closed, or the kernel may hand the number to an
    /// unrelated socket and the stale accept will steal its connection. Inside
    /// a fake server use `TestListenerLoop`, which enforces that ordering.
    static func acceptWithTimeout(fd: Int32, seconds: Double) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            var pfd = pollfd()
            pfd.fd = fd
            pfd.events = Int16(POLLIN)
            pfd.revents = 0
            let rc = poll(&pfd, 1, 100)
            if rc > 0 {
                // Listener closed under us (stop()): tell the caller to exit
                // its serve loop instead of spinning on a dead fd — a spinning
                // loop permanently consumes a dispatch-pool thread.
                if pfd.revents & Int16(POLLNVAL) != 0 { return -1 }
                let client = accept(fd, nil, nil)
                if client >= 0 { return client }
                if errno == EBADF { return -1 }
            }
        }
        return nil
    }

    /// Errno of the last `readSome` failure, captured before any other thread
    /// can clobber it (errno is thread-local, but the CALLER may resume on a
    /// different thread or run other syscalls first).
    private static let errnoLock = NSLock()
    private static var _lastReadErrno: Int32 = 0
    static var lastReadErrno: Int32 { errnoLock.withLock { _lastReadErrno } }

    /// Reads once. Returns bytes, `[]` on orderly EOF, `nil` on error.
    /// Tolerates momentary EAGAIN (poll + one retry) so callers on GCD worker
    /// threads never misread scheduling hiccups as connection death.
    static func readSome(fd: Int32, max: Int = 4096) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: max)
        let n = recv(fd, &buf, max, 0)
        if n > 0 { return Array(buf[0..<n]) }
        if n == 0 { return [] }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
            guard TestSockets.waitForReadable(fd: fd, timeoutSeconds: 1.0) else {
                errnoLock.withLock { _lastReadErrno = errno }
                return nil
            }
            let n2 = recv(fd, &buf, max, 0)
            if n2 > 0 { return Array(buf[0..<n2]) }
            if n2 == 0 { return [] }
        }
        errnoLock.withLock { _lastReadErrno = errno }
        return nil
    }

    static func sendAll(fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { buf in
                send(fd, buf.baseAddress! + offset, bytes.count - offset, Int32(MSG_NOSIGNAL))
            }
            if n > 0 {
                offset += n
                continue
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // Non-blocking fd: wait for writability, then retry.
                    guard waitForWritable(fd: fd, timeoutSeconds: 5) else { return false }
                    continue
                }
                return false
            }
        }
        return true
    }

    /// Polls until `fd` is writable (or timeout).
    static func waitForWritable(fd: Int32, timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            var pfd = pollfd()
            pfd.fd = fd
            pfd.events = Int16(POLLOUT)
            pfd.revents = 0
            let rc = poll(&pfd, 1, 100)
            if rc > 0 { return true }
            if rc == 0 { continue }
            if errno == EINTR { continue }
            return false
        }
        return false
    }

    /// Polls until `fd` is readable (or timeout). Test-side twin of
    /// `TCPClient.waitForReadable` for harness servers.
    static func waitForReadable(fd: Int32, timeoutSeconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            var pfd = pollfd()
            pfd.fd = fd
            pfd.events = Int16(POLLIN)
            pfd.revents = 0
            let rc = poll(&pfd, 1, 100)
            if rc > 0 { return true }
            if rc == 0 { continue }
            if errno == EINTR { continue }
            return false
        }
        return false
    }

    static func closeFD(_ fd: Int32) {
        if fd >= 0 { close(fd) }
    }
}

// MARK: - Listener loop with a joined shutdown

/// A loopback listener plus the two things a serve loop needs in order to be
/// safe to stop.
///
/// **Why this exists.** A serve loop accepts by *descriptor number*, so closing
/// the listener while the loop may still be inside `poll()`/`accept()` is a
/// use-after-close: the kernel is free to hand that number to an unrelated
/// socket, and the stale loop then accepts a connection belonging to somebody
/// else — answering it with its own canned response, or (for a server whose
/// first byte must be a SOCKS5 greeting) closing it outright. That is what a
/// test observes as an intermittently *empty* reply or a response from the
/// wrong origin. `stop()` here waits for the loop to leave the descriptor
/// alone *before* closing it, so the number can never be recycled into a loop
/// that is still using it.
///
/// The loop itself slices its wait and re-checks the stop flag, so it exits on
/// its own rather than depending on the close to wake it.
final class TestListenerLoop: @unchecked Sendable {
    let fd: Int32
    let port: Int

    private let lock = NSLock()
    private var stoppedFlag = false
    private var liveClients: Set<Int32> = []
    private var loopStarted = false
    private var loopFinished = false
    private let finished = DispatchSemaphore(value: 0)

    init() {
        let (fd, port) = TestSockets.listenOnEphemeralLoopback()
        self.fd = fd
        self.port = port
    }

    /// Whether `stop()` has been asked for.
    var isStopped: Bool { lock.withLock { stoppedFlag } }

    /// Connections accepted and not yet released (diagnostics).
    var activeClientCount: Int { lock.withLock { liveClients.count } }

    /// True once the serve loop has exited (also true when `stop()` found that
    /// it never started). `stop()` waits for this unless it had to give up.
    var isLoopFinished: Bool { lock.withLock { loopFinished } }

    /// First statement of the serve loop.
    func noteLoopStarted() { lock.withLock { loopStarted = true } }

    /// Last statement of the serve loop (`defer` it).
    func noteLoopFinished() {
        lock.lock()
        loopFinished = true
        lock.unlock()
        finished.signal()
    }

    /// Accepts one connection, or `nil` when none arrived within `seconds` or
    /// the server is stopping. Slices the wait so the stop flag is honoured
    /// promptly instead of after the whole timeout.
    func acceptOne(seconds: Double = 0.5) -> Int32? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !isStopped {
            guard TestSockets.waitForReadable(fd: fd, timeoutSeconds: 0.1) else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                if errno == EINTR || errno == ECONNABORTED || errno == EPROTO { continue }
                return nil
            }
            // A connection that arrived to wake us during stop(), or one that
            // raced the flag: never hand it to a handler.
            if isStopped {
                TestSockets.closeFD(client)
                return nil
            }
            lock.withLock { liveClients.insert(client) }
            return client
        }
        return nil
    }

    /// Called by the serve loop when it is done with a client.
    func release(_ client: Int32) { lock.withLock { liveClients.remove(client) } }

    /// Stops the serve loop and *then* closes the listener.
    ///
    /// Order matters: flag → wake the parked accept → unblock in-flight client
    /// reads → wait for the loop to exit → close. Closing first (the original
    /// shape) is what let a stale loop accept on a recycled descriptor.
    func stop() {
        lock.lock()
        if stoppedFlag {
            lock.unlock()
            return // idempotent: tests call stop() from a defer and directly
        }
        stoppedFlag = true
        let started = loopStarted
        let clients = Array(liveClients)
        lock.unlock()

        // Wake a parked poll/accept. A throwaway connection is safe (a closed
        // fd is not: the loop owns the close).
        wakeListener()

        // A handler blocked in recv() would otherwise hold the loop open until
        // its peer closes — which, for a client still talking to the engine,
        // may be after this test ends. SHUT_RDWR makes that recv return 0;
        // the handler still owns closing the fd.
        for client in clients { shutdown(client, SHUT_RDWR) }

        if started {
            // Real condition, not a sleep: the loop signals when it is out of
            // the accept path. The timeout only exists so a harness bug cannot
            // hang the suite forever — `isLoopFinished` reports it.
            if finished.wait(timeout: .now() + 5) == .timedOut {
                lock.withLock { loopFinished = false }
                TestSockets.closeFD(fd)
                return
            }
        }
        lock.withLock { loopFinished = true }
        TestSockets.closeFD(fd)
    }

    /// Connects to ourselves so a parked `poll`/`accept` returns immediately.
    private func wakeListener() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        // Best-effort: if this fails the loop still exits within one slice.
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(clamping: port).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

// MARK: - Fake HTTP Origin Server

/// A minimal HTTP server on loopback: replies `HTTP/1.1 204 No Content` to any
/// request, then closes. Used as the "test URL" target for probes.
final class FakeHTTPServer {
    let loop: TestListenerLoop
    var fd: Int32 { loop.fd }
    var port: Int { loop.port }
    private let queue = DispatchQueue(label: "fake-http-server")

    /// Number of requests received (atomic-ish via lock).
    private let lock = NSLock()
    private var _requestCount = 0
    var requestCount: Int { lock.withLock { _requestCount } }

    init?() {
        let loop = TestListenerLoop()
        self.loop = loop
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client: client)
            loop.release(client)
        }
    }

    private func handle(client: Int32) {
        defer { TestSockets.closeFD(client) }
        lock.withLock { _requestCount += 1 }
        // Read the request head (probe sends and waits for response).
        _ = TestSockets.readSome(fd: client)
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = TestSockets.sendAll(fd: client, Array(response.utf8))
    }

    func stop() { loop.stop() }

    var testURL: String { "http://127.0.0.1:\(port)/generate_204" }
}

// MARK: - Fake SOCKS5 Server

/// A minimal RFC 1928 SOCKS5 server: completes greeting (no-auth), CONNECT
/// (always succeeds), then relays bytes to a destination accepted in-process.
final class FakeSOCKS5Server {
    let loop: TestListenerLoop
    var fd: Int32 { loop.fd }
    var port: Int { loop.port }
    private let queue = DispatchQueue(label: "fake-socks5-server")
    private let lock = NSLock()
    private var _connectCount = 0
    var connectCount: Int { lock.withLock { _connectCount } }

    init?() {
        let loop = TestListenerLoop()
        self.loop = loop
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client: client)
            loop.release(client)
        }
    }

    private func handle(client: Int32) {
        defer { TestSockets.closeFD(client) }
        lock.withLock { _connectCount += 1 }

        // Greeting
        guard let greeting = TestSockets.readSome(fd: client), greeting.count >= 3, greeting[0] == 0x05 else {
            return
        }
        _ = TestSockets.sendAll(fd: client, [0x05, 0x00]) // no-auth

        // CONNECT request
        guard let request = TestSockets.readSome(fd: client), request.count >= 7, request[1] == 0x01 else {
            return
        }
        // Reply: success with a dummy bind address (IPv4 0.0.0.0:0)
        _ = TestSockets.sendAll(fd: client, [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])

        // The probe will now send its HTTP request; reply 204 and close.
        _ = TestSockets.readSome(fd: client)
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = TestSockets.sendAll(fd: client, Array(response.utf8))
    }

    func stop() { loop.stop() }
}

// MARK: - Fake SOCKS5 Server (auth required)

/// SOCKS5 server that requires username/password auth (RFC 1929) — used to
/// verify the prober sends credentials correctly.
final class FakeSOCKS5AuthServer {
    let loop: TestListenerLoop
    var fd: Int32 { loop.fd }
    var port: Int { loop.port }
    let expectedUser: String
    let expectedPass: String
    private let queue = DispatchQueue(label: "fake-socks5-auth-server")
    private let lock = NSLock()
    private var _authOK = false
    var authOK: Bool { lock.withLock { _authOK } }

    init?(user: String, pass: String) {
        let loop = TestListenerLoop()
        self.loop = loop
        self.expectedUser = user
        self.expectedPass = pass
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client: client)
            loop.release(client)
        }
    }

    private func handle(client: Int32) {
        defer { TestSockets.closeFD(client) }

        guard let greeting = TestSockets.readSome(fd: client), greeting.count >= 2, greeting[0] == 0x05 else {
            return
        }
        // Demand user/pass auth.
        _ = TestSockets.sendAll(fd: client, [0x05, 0x02])

        guard let auth = TestSockets.readSome(fd: client), auth.count >= 2, auth[0] == 0x01 else {
            return
        }
        let ulen = Int(auth[1])
        guard auth.count >= 2 + ulen + 1 else { return }
        let user = String(bytes: auth[2..<(2 + ulen)], encoding: .utf8) ?? ""
        let plen = Int(auth[2 + ulen])
        guard auth.count >= 2 + ulen + 1 + plen else { return }
        let pass = String(bytes: auth[(3 + ulen)..<(3 + ulen + plen)], encoding: .utf8) ?? ""

        let ok = (user == expectedUser && pass == expectedPass)
        lock.withLock { _authOK = ok }
        _ = TestSockets.sendAll(fd: client, [0x01, ok ? 0x00 : 0x01])
        if !ok { return }

        // CONNECT
        guard let request = TestSockets.readSome(fd: client), request.count >= 7, request[1] == 0x01 else {
            return
        }
        _ = TestSockets.sendAll(fd: client, [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        _ = TestSockets.readSome(fd: client)
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = TestSockets.sendAll(fd: client, Array(response.utf8))
    }

    func stop() { loop.stop() }
}

// MARK: - Fake HTTP Forward Proxy

/// A minimal HTTP forward proxy on loopback: accepts absolute-form requests
/// (`GET http://host/path HTTP/1.1`) and replies 204. Verifies the prober's
/// http-proxy code path sends absolute-form requests to the proxy.
final class FakeHTTPProxyServer {
    let loop: TestListenerLoop
    var fd: Int32 { loop.fd }
    var port: Int { loop.port }
    private let queue = DispatchQueue(label: "fake-http-proxy")
    private let lock = NSLock()
    private var _requestLines: [String] = []
    var requestLines: [String] { lock.withLock { _requestLines } }

    init?() {
        let loop = TestListenerLoop()
        self.loop = loop
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client: client)
            loop.release(client)
        }
    }

    private func handle(client: Int32) {
        defer { TestSockets.closeFD(client) }
        guard let data = TestSockets.readSome(fd: client),
              let request = String(bytes: data, encoding: .utf8) else {
            return
        }
        lock.withLock { _requestLines.append(request) }
        let response = "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = TestSockets.sendAll(fd: client, Array(response.utf8))
    }

    func stop() { loop.stop() }
}

// MARK: - Echo Server

/// TCP echo server: relays every byte it receives back to the sender until
/// EOF on either side. Used as the relay's "destination" to verify byte
/// fidelity and bidirectional pumping.
final class FakeEchoServer {
    let loop: TestListenerLoop
    var fd: Int32 { loop.fd }
    var port: Int { loop.port }
    private let queue = DispatchQueue(label: "fake-echo-server")

    init?() {
        let loop = TestListenerLoop()
        self.loop = loop
        queue.async { [weak self] in self?.serve() }
    }

    // NOTE: connections are handled inline on the serve loop (same pattern as
    // the other fakes) — dispatching to the same serial queue would deadlock.
    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            relay(client: client)
            loop.release(client)
        }
    }

    private func relay(client: Int32) {
        defer { TestSockets.closeFD(client) }
        while !loop.isStopped {
            guard let data = TestSockets.readSome(fd: client) else { return }
            if data.isEmpty { return } // EOF
            guard TestSockets.sendAll(fd: client, data) else { return }
        }
    }

    func stop() { loop.stop() }
}

// MARK: - Recording HTTP Origin

/// HTTP origin server that replies to any request with a fixed status/body
/// and records the exact request bytes it received (origin-form checks).
final class RecordingHTTPOrigin {
    let loop: TestListenerLoop
    var fd: Int32 { loop.fd }
    var port: Int { loop.port }
    let statusLine: String
    let body: String
    private let queue = DispatchQueue(label: "recording-http-origin")
    private let lock = NSLock()
    private var _receivedRequests: [String] = []
    var receivedRequests: [String] { lock.withLock { _receivedRequests } }

    init(statusLine: String = "HTTP/1.1 200 OK", body: String = "hello-from-origin") {
        let loop = TestListenerLoop()
        self.loop = loop
        self.statusLine = statusLine
        self.body = body
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client: client)
            loop.release(client)
        }
    }

    private func handle(client: Int32) {
        defer { TestSockets.closeFD(client) }
        guard let data = TestSockets.readSome(fd: client), !data.isEmpty else { return }
        lock.withLock { _receivedRequests.append(String(bytes: data, encoding: .utf8) ?? "") }
        let response = "\(statusLine)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = TestSockets.sendAll(fd: client, Array(response.utf8))
    }

    func stop() { loop.stop() }
}

// MARK: - Fake HTTP CONNECT Upstream Proxy

/// An upstream HTTP proxy for testing the engine's CONNECT-to-upstream path:
/// answers `CONNECT host:port` with 200 and then relays bytes to an in-process
/// echo peer, or (when `connectTarget` is set) opens a real TCP connection.
final class FakeHTTPConnectProxyServer {
    let loop: TestListenerLoop
    var fd: Int32 { loop.fd }
    var port: Int { loop.port }
    /// When true, CONNECT is answered with 403 to exercise refusal handling.
    let refusesConnects: Bool
    private let queue = DispatchQueue(label: "fake-connect-proxy")
    private let lock = NSLock()
    private var _connectTargets: [String] = []
    var connectTargets: [String] { lock.withLock { _connectTargets } }
    private var _authorizationHeaders: [String] = []
    var authorizationHeaders: [String] { lock.withLock { _authorizationHeaders } }

    init(refusesConnects: Bool = false) {
        let loop = TestListenerLoop()
        self.loop = loop
        self.refusesConnects = refusesConnects
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client: client)
            loop.release(client)
        }
    }

    private func handle(client: Int32) {
        defer { TestSockets.closeFD(client) }
        guard let data = TestSockets.readSome(fd: client), !data.isEmpty else { return }
        guard let text = String(bytes: data, encoding: .utf8) else { return }
        lock.withLock {
            _connectTargets.append(firstLineTarget(of: text) ?? "")
            if let auth = extractHeader("Proxy-Authorization", from: text) {
                _authorizationHeaders.append(auth)
            }
        }

        guard text.hasPrefix("CONNECT") else {
            let response = "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = TestSockets.sendAll(fd: client, Array(response.utf8))
            return
        }

        if refusesConnects {
            let response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            _ = TestSockets.sendAll(fd: client, Array(response.utf8))
            return
        }

        let response = "HTTP/1.1 200 Connection established\r\n\r\n"
        guard TestSockets.sendAll(fd: client, Array(response.utf8)) else { return }
        // Relay until EOF (echo behavior: clients connect here to exchange
        // bytes "through" the tunnel).
        while !loop.isStopped {
            guard let more = TestSockets.readSome(fd: client) else { break }
            if more.isEmpty { break }
            guard TestSockets.sendAll(fd: client, more) else { break }
        }
    }

    private func firstLineTarget(of request: String) -> String? {
        guard let first = request.components(separatedBy: "\r\n").first else { return nil }
        return first.split(separator: " ").dropFirst().first.map(String.init)
    }

    private func extractHeader(_ name: String, from request: String) -> String? {
        for line in request.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    func stop() { loop.stop() }
}

// MARK: - Fake Latency Measurer

/// Deterministic measurer for policy-logic tests: maps policy names to
/// canned results.
final class FakeLatencyMeasurer: LatencyMeasuring {
    private let lock = NSLock()
    private var results: [String: LatencyResult]
    var measuredTargets: [String] = []

    init(results: [String: LatencyResult]) {
        self.results = results
    }

    func setResult(_ result: LatencyResult, for name: String) {
        lock.withLock { results[name] = result }
    }

    func measure(_ target: ProbeTarget, testURL: String, timeoutSeconds: Double) -> LatencyResult {
        lock.withLock { measuredTargets.append(target.policyName) }
        return lock.withLock { results[target.policyName] ?? .failure("no canned result") }
    }
}

// MARK: - NSLock helper (tests target)

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
