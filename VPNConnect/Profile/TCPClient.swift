import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Errors

/// Errors raised by `TCPClient` connection attempts.
public enum TCPClientError: LocalizedError, Equatable {
    case dnsResolutionFailed(String)
    case connectionFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .dnsResolutionFailed(let host): return "DNS resolution failed for \(host)"
        case .connectionFailed(let detail): return "Connection failed: \(detail)"
        case .timeout: return "Connection timed out"
        }
    }
}

// MARK: - TCP Client

/// Minimal blocking TCP client over POSIX sockets.
///
/// Design note: `getaddrinfo` results are converted into *typed Swift value
/// structs* (`sockaddr_in` / `sockaddr_in6`) before the C list is freed, so no
/// C pointers outlive `freeaddrinfo` and no raw-byte memcpy is needed.
public final class TCPClient {

    /// Whether env-gated fd diagnostics (`TD_FD_TRACE=1`) are on.
    ///
    /// Read once, deliberately. `ProcessInfo.environment` builds a fresh
    /// dictionary out of the process environment on *every* access (~30 µs
    /// measured, against ~0 for a stored constant), and this flag is consulted
    /// on paths that run per relay event and per accepted connection — the
    /// relay's EOF path burned a whole core of user time inside
    /// `_ProcessInfo.environment.getter` doing exactly this
    /// (`RelayHalfCloseTests.testTheFdTraceFlagIsReadOnceRatherThanPerEvent`
    /// pins it).
    public static let fdTraceEnabled = ProcessInfo.processInfo.environment["TD_FD_TRACE"] == "1"

    /// A resolved destination as a typed Swift value. Either IPv4 or IPv6.
    enum ResolvedAddress {
        case v4(sockaddr_in)
        case v6(sockaddr_in6)

        var family: Int32 {
            switch self {
            case .v4: return AF_INET
            case .v6: return AF_INET6
            }
        }
    }

    /// Connects and returns an open, connected socket descriptor.
    /// `timeoutSeconds` bounds TCP connect (DNS is resolved first).
    public static func connect(
        host: String, port: Int,
        timeoutSeconds: Double,
        bindHost: String? = nil
    ) throws -> Int32 {
        guard let portInt = UInt16(exactly: port), port != 0 else {
            throw TCPClientError.connectionFailed("invalid port \(port)")
        }

        let addrs = try resolve(host: host)
        guard !addrs.isEmpty else { throw TCPClientError.dnsResolutionFailed(host) }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastError: TCPClientError = .timeout
        for addr in addrs {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw TCPClientError.timeout }
            do {
                return try connectSocket(
                    addr: addr, port: portInt,
                    timeoutSeconds: remaining,
                    bindHost: bindHost
                )
            } catch let error as TCPClientError {
                lastError = error
                if case .timeout = error { throw error }
                continue // try next resolved address
            }
        }
        throw lastError
    }

    /// Sends all bytes (looping over partial writes).
    public static func sendAll(fd: Int32, _ bytes: [UInt8], timeoutSeconds: Double) throws {
        var offset = 0
        while offset < bytes.count {
            guard waitForWritable(fd: fd, timeoutSeconds: timeoutSeconds) else {
                throw TCPClientError.timeout
            }
            let n = bytes.withUnsafeBufferPointer { buf -> Int in
                send(fd, buf.baseAddress! + offset, bytes.count - offset, Int32(MSG_NOSIGNAL))
            }
            if n <= 0 {
                if errno == EINTR { continue }
                throw TCPClientError.connectionFailed("send failed: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }

    /// Receives up to `max` bytes; returns fewer on short read, [] on EOF.
    public static func receiveSome(fd: Int32, max: Int, timeoutSeconds: Double) throws -> [UInt8] {
        guard waitForReadable(fd: fd, timeoutSeconds: timeoutSeconds) else {
            throw TCPClientError.timeout
        }
        var buffer = [UInt8](repeating: 0, count: max)
        let n = recv(fd, &buffer, max, 0)
        if n > 0 { return Array(buffer[0..<n]) }
        if n == 0 { return [] } // orderly EOF
        if errno == EINTR { return try receiveSome(fd: fd, max: max, timeoutSeconds: timeoutSeconds) }
        throw TCPClientError.connectionFailed("recv failed: \(String(cString: strerror(errno)))")
    }

    /// Reads until EOF (bounded); used for small handshake responses.
    public static func receiveUntilEOF(fd: Int32, timeoutSeconds: Double, maxBytes: Int = 65536) throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < maxBytes {
            let chunk = try receiveSome(fd: fd, max: Swift.min(4096, maxBytes - out.count), timeoutSeconds: timeoutSeconds)
            if chunk.isEmpty { break }
            out.append(contentsOf: chunk)
        }
        return out
    }

    /// Closes a socket descriptor, ignoring errors.
    public static func closeSocket(_ fd: Int32) {
        guard fd >= 0 else { return }
        if fdTraceEnabled {
            FileHandle.standardError.write(Data("TD-FD-CLOSE [\(Int(Date().timeIntervalSince1970 * 1000))] fd=\(fd)\n".utf8))
        }
        close(fd)
    }

    /// Puts `fd` into non-blocking mode (used for listener fds and
    /// DispatchSource-driven sockets).
    public static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Disables SIGPIPE on writes so a dying peer cannot kill the process.
    public static func setNoSigpipe(_ fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    // MARK: - Internals

    /// Resolves `host` into typed value addresses. Everything extracted from
    /// the C `addrinfo` list is copied into Swift values *before* freeaddrinfo.
    static func resolve(host: String) throws -> [ResolvedAddress] {
        // Numeric literals bypass the system resolver entirely: getaddrinfo
        // serializes across threads on macOS, so one slow lookup stalls every
        // concurrent relay. IP-literal destinations (and loopback-heavy tests)
        // must never queue behind DNS.
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            var sin = sockaddr_in()
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_addr = v4
            return [.v4(sin)]
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            var sin6 = sockaddr_in6()
            sin6.sin6_family = sa_family_t(AF_INET6)
            sin6.sin6_addr = v6
            return [.v6(sin6)]
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC     // IPv4 or IPv6
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>? = nil
        // No AI_ADDRCONFIG: explicitly allow loopback resolution in tests.
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw TCPClientError.dnsResolutionFailed(host)
        }
        defer { freeaddrinfo(result) }

        var addrs: [ResolvedAddress] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let node = current {
            let family = Int32(node.pointee.ai_family)
            if family == AF_INET, let sa = node.pointee.ai_addr {
                // Copy the pointed-to sockaddr_in value into a Swift value.
                let value = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                addrs.append(.v4(value))
            } else if family == AF_INET6, let sa = node.pointee.ai_addr {
                let value = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                addrs.append(.v6(value))
            }
            current = node.pointee.ai_next
        }
        return addrs
    }

    private static func connectSocket(
        addr: ResolvedAddress, port: UInt16,
        timeoutSeconds: Double,
        bindHost: String?
    ) throws -> Int32 {
        let fd = socket(addr.family, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TCPClientError.connectionFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        if fdTraceEnabled {
            FileHandle.standardError.write(Data("TD-FD-OPEN [\(Int(Date().timeIntervalSince1970 * 1000))] fd=\(fd) kind=connect\n".utf8))
        }
        // Set non-blocking for the connect() phase only.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Patch the port into a local copy of the sockaddr value, then call
        // connect() with the value in scope. No pointers escape the closures.
        // NOTE: on a non-blocking socket, connect() returning -1 with
        // EINPROGRESS is the normal path — completion is detected via poll +
        // SO_ERROR below. Only other errnos are real failures.
        func connectWithPort(_ port: UInt16) throws {
            switch addr {
            case .v4(var sin):
                sin.sin_port = port.bigEndian
                let rc = withUnsafePointer(to: &sin) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if rc != 0 && errno != EINPROGRESS {
                    throw posixConnectError()
                }
            case .v6(var sin6):
                sin6.sin6_port = port.bigEndian
                let rc = withUnsafePointer(to: &sin6) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
                    }
                }
                if rc != 0 && errno != EINPROGRESS {
                    throw posixConnectError()
                }
            }
        }

        do {
            try connectWithPort(port)
        } catch {
            TCPClient.closeSocket(fd)
            throw error
        }

        if !waitForWritable(fd: fd, timeoutSeconds: timeoutSeconds) {
            TCPClient.closeSocket(fd)
            throw TCPClientError.timeout
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        if soError != 0 {
            TCPClient.closeSocket(fd)
            throw TCPClientError.connectionFailed("connect failed: \(String(cString: strerror(soError)))")
        }

        // Restore blocking mode for the caller.
        _ = fcntl(fd, F_SETFL, flags)

        // Disable SIGPIPE on writes so a dying peer doesn't kill the process.
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        return fd
    }

    private static func posixConnectError() -> TCPClientError {
        .connectionFailed("connect failed: \(String(cString: strerror(errno)))")
    }

    /// Waits until `fd` is writable (connect completion / send buffer space).
    public static func waitForWritable(fd: Int32, timeoutSeconds: Double) -> Bool {
        pollLoop(fd: fd, events: Int16(POLLOUT), timeoutSeconds: timeoutSeconds)
    }

    /// Waits until `fd` has data (or EOF) available to read.
    public static func waitForReadable(fd: Int32, timeoutSeconds: Double) -> Bool {
        pollLoop(fd: fd, events: Int16(POLLIN), timeoutSeconds: timeoutSeconds)
    }

    static func pollLoop(fd: Int32, events: Int16, timeoutSeconds: Double) -> Bool {
        var remaining = timeoutSeconds
        while remaining > 0 {
            var pfd = pollfd()
            pfd.fd = fd
            pfd.events = events
            pfd.revents = 0
            let ms = Int32(min(remaining, 3600) * 1000)
            let rc = poll(&pfd, 1, ms)
            if rc > 0 { return true }
            if rc == 0 { return false } // timed out
            if errno == EINTR {
                remaining -= 0.05 // approximate; loop continues
                continue
            }
            return false
        }
        return false
    }
}
