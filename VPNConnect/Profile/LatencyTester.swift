import Foundation

// MARK: - Result Types

/// Outcome of a single latency probe.
public enum LatencyResult: Equatable, Sendable {
    /// Probe succeeded; rtt is the measured round-trip in milliseconds.
    case success(ms: Double)
    /// Probe failed (connect error, handshake error, bad response).
    case failure(String)
    /// Probe exceeded the timeout.
    case timeout
    /// Policy is a group or built-in with no direct probe semantics.
    case notProbed

    public var isUsable: Bool {
        if case .success = self { return true }
        return false
    }

    /// Milliseconds when successful; nil otherwise.
    public var milliseconds: Double? {
        if case .success(let ms) = self { return ms }
        return nil
    }

    /// Short display string ("12 ms", "timeout", "n/a").
    public var display: String {
        switch self {
        case .success(let ms): return String(format: "%.0f ms", ms)
        case .failure(let reason): return "fail: \(reason)"
        case .timeout: return "timeout"
        case .notProbed: return "n/a"
        }
    }
}

/// What to probe and through which path.
public struct ProbeTarget: Sendable {
    /// Policy name (for logging/UI).
    public let policyName: String
    /// For DIRECT: the host to hit. For proxied probes: the upstream proxy host.
    public let host: String
    public let port: Int
    /// Proxy flavor of the path: nil = DIRECT.
    public let proxyType: ProxyType?
    public let proxyUsername: String?
    public let proxyPassword: String?

    public init(
        policyName: String, host: String, port: Int,
        proxyType: ProxyType? = nil,
        proxyUsername: String? = nil,
        proxyPassword: String? = nil
    ) {
        self.policyName = policyName
        self.host = host
        self.port = port
        self.proxyType = proxyType
        self.proxyUsername = proxyUsername
        self.proxyPassword = proxyPassword
    }
}

// MARK: - Measurer Protocol

/// Abstraction over the actual latency measurement so policy logic can be
/// unit-tested with deterministic fakes.
public protocol LatencyMeasuring: AnyObject {
    /// Measures latency for one target. Called from background queues;
    /// implementations must be thread-safe.
    func measure(_ target: ProbeTarget, testURL: String, timeoutSeconds: Double) -> LatencyResult
}

// MARK: - Real Prober

/// Measures latency by establishing a TCP connection (through the proxy path
/// when applicable) and completing a minimal HTTP request. Reports TCP
/// connect time when the response can't be validated, full RTT when it can.
public final class LatencyTester: LatencyMeasuring {

    public static let defaultTestURL = "http://cp.cloudflare.com/generate_204"

    public init() {}

    public func measure(_ target: ProbeTarget, testURL: String, timeoutSeconds: Double) -> LatencyResult {
        let started = Date()

        // Parse the test URL into host/port/path for the HTTP request.
        guard let (urlHost, urlPort, urlPath) = Self.parseHTTPURL(testURL) else {
            return .failure("invalid test-url")
        }

        do {
            // Step 1: reach the path endpoint (direct, or via proxy CONNECT).
            let fd: Int32
            let connectStart = Date()
            switch target.proxyType {
            case nil, .http?:
                // DIRECT connects to the test URL host; an HTTP proxy connects
                // to the proxy itself and issues an absolute-form request.
                if target.proxyType == .http {
                    fd = try TCPClient.connect(host: target.host, port: target.port, timeoutSeconds: timeoutSeconds)
                } else {
                    fd = try TCPClient.connect(host: urlHost, port: urlPort, timeoutSeconds: timeoutSeconds)
                }
            case .https?:
                // TLS-on-connect proxy: TCP reachability of the proxy only
                // (TLS handshake is Phase 3 relay territory; reachability is
                // a meaningful health signal already).
                fd = try TCPClient.connect(host: target.host, port: target.port, timeoutSeconds: timeoutSeconds)
                TCPClient.closeSocket(fd)
                let ms = Date().timeIntervalSince(connectStart) * 1000
                return .success(ms: Self.round1(ms))
            case .socks5?:
                fd = try Self.connectViaSOCKS5(
                    proxyHost: target.host, proxyPort: target.port,
                    destinationHost: urlHost, destinationPort: urlPort,
                    username: target.proxyUsername, password: target.proxyPassword,
                    timeoutSeconds: timeoutSeconds
                )
            default:
                return .notProbed
            }
            defer { TCPClient.closeSocket(fd) }
            let connectMs = Date().timeIntervalSince(connectStart) * 1000

            // Step 2 (skipped for plain HTTP proxy is handled below): complete
            // an HTTP request so we measure full RTT, not just SYN/ACK.
            let request: String
            if target.proxyType == .http {
                request = "GET \(testURL) HTTP/1.1\r\nHost: \(urlHost)\r\nUser-Agent: TurtleDiver-Probe/1.0\r\nConnection: close\r\n\r\n"
            } else {
                request = "GET \(urlPath) HTTP/1.1\r\nHost: \(urlHost)\r\nUser-Agent: TurtleDiver-Probe/1.0\r\nConnection: close\r\n\r\n"
            }
            try TCPClient.sendAll(fd: fd, Array(request.utf8), timeoutSeconds: timeoutSeconds)
            let response = try TCPClient.receiveUntilEOF(fd: fd, timeoutSeconds: timeoutSeconds, maxBytes: 8192)

            guard let head = String(bytes: response.prefix(while: { $0 != 0 }), encoding: .utf8),
                  head.contains("HTTP/") else {
                // Connected but nonsense response — still proves reachability.
                return .success(ms: Self.round1(connectMs))
            }
            let totalMs = Date().timeIntervalSince(started) * 1000
            return .success(ms: Self.round1(totalMs))
        } catch let error as TCPClientError {
            switch error {
            case .timeout: return .timeout
            default: return .failure(error.localizedDescription)
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - SOCKS5 handshake (client side of RFC 1928, TCP CONNECT)

    /// Opens a SOCKS5 connection through `proxyHost:proxyPort` to
    /// `destinationHost:destinationPort`. Returns the connected fd.
    /// (Shared with the Phase 3 relay for SOCKS upstreams.)
    public static func connectViaSOCKS5(
        proxyHost: String, proxyPort: Int,
        destinationHost: String, destinationPort: Int,
        username: String?, password: String?,
        timeoutSeconds: Double
    ) throws -> Int32 {
        let fd = try TCPClient.connect(host: proxyHost, port: proxyPort, timeoutSeconds: timeoutSeconds)

        do {
            // --- Greeting: offer no-auth (0x00) and user/pass (0x02) if creds exist ---
            let wantAuth = !(username ?? "").isEmpty || !(password ?? "").isEmpty
            let greeting: [UInt8] = wantAuth ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]
            try TCPClient.sendAll(fd: fd, greeting, timeoutSeconds: timeoutSeconds)

            var reply = try TCPClient.receiveSome(fd: fd, max: 2, timeoutSeconds: timeoutSeconds)
            guard reply.count == 2, reply[0] == 0x05 else {
                throw TCPClientError.connectionFailed("SOCKS5: bad greeting response")
            }
            let method = reply[1]

            // --- Optional username/password auth (RFC 1929) ---
            if method == 0x02 {
                guard let user = username, let pass = password else {
                    throw TCPClientError.connectionFailed("SOCKS5: server demands auth but none configured")
                }
                var auth: [UInt8] = [0x01, UInt8(user.utf8.count)]
                auth += Array(user.utf8)
                auth.append(UInt8(pass.utf8.count))
                auth += Array(pass.utf8)
                try TCPClient.sendAll(fd: fd, auth, timeoutSeconds: timeoutSeconds)
                reply = try TCPClient.receiveSome(fd: fd, max: 2, timeoutSeconds: timeoutSeconds)
                guard reply.count == 2, reply[1] == 0x00 else {
                    throw TCPClientError.connectionFailed("SOCKS5: authentication failed")
                }
            } else if method != 0x00 {
                throw TCPClientError.connectionFailed("SOCKS5: no acceptable auth method (0x\(String(method, radix: 16)))")
            }

            // --- CONNECT request (domain-name addressing) ---
            let hostBytes = Array(destinationHost.utf8)
            guard hostBytes.count <= 255 else {
                throw TCPClientError.connectionFailed("SOCKS5: destination host too long")
            }
            var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(hostBytes.count)]
            request += hostBytes
            request += [UInt8((destinationPort >> 8) & 0xFF), UInt8(destinationPort & 0xFF)]
            try TCPClient.sendAll(fd: fd, request, timeoutSeconds: timeoutSeconds)

            // Reply: VER REP RSV ATYP ADDR... (up to 4+16+2 = 262 bytes)
            let response = try TCPClient.receiveSome(fd: fd, max: 270, timeoutSeconds: timeoutSeconds)
            guard response.count >= 4, response[1] == 0x00 else {
                let code = response.count >= 2 ? response[1] : 0xFF
                throw TCPClientError.connectionFailed("SOCKS5: CONNECT failed (reply 0x\(String(code, radix: 16)))")
            }
            return fd
        } catch {
            TCPClient.closeSocket(fd)
            throw error
        }
    }

    // MARK: - Helpers

    /// Parses an http:// URL into (host, port, path). Returns nil for
    /// non-http schemes or malformed URLs. (Shared with the Phase 3 engine.)
    public static func parseHTTPURL(_ url: String) -> (host: String, port: Int, path: String)? {
        guard url.lowercased().hasPrefix("http://") else { return nil }
        let rest = url.dropFirst(7)
        let pathStart = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = rest[..<pathStart]
        let path = rest[pathStart...].isEmpty ? "/" : String(rest[pathStart...])
        // Strip userinfo if present.
        let hostPort: Substring
        if let at = authority.lastIndex(of: "@") {
            hostPort = authority[authority.index(after: at)...]
        } else {
            hostPort = authority
        }
        if let colon = hostPort.lastIndex(of: ":") {
            guard let port = Int(hostPort[hostPort.index(after: colon)...]), port > 0 else { return nil }
            let host = String(hostPort[..<colon])
            guard !host.isEmpty else { return nil }
            return (host, port, path)
        }
        let host = String(hostPort)
        guard !host.isEmpty else { return nil }
        return (host, 80, path)
    }

    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
