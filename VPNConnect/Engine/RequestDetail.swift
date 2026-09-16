import Foundation

// MARK: - Sensitive headers

/// Which header values are withheld from a request detail, and how.
///
/// A proxy sits in front of other people's sessions, so it sees cookies and
/// bearer tokens. A debugging affordance must not become a credential store:
/// values are replaced at *capture* time — they are never held in memory, let
/// alone written to `vpn.log` — unless the user has explicitly opted in.
public enum HeaderRedaction {

    /// Names withheld whatever else they contain. These are the ones that
    /// carry a credential on the wire.
    public static let alwaysSensitive: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
        "x-csrf-token",
        "x-xsrf-token",
    ]

    /// Fragments that mark an otherwise unknown name as sensitive, so a
    /// service-specific header (`x-amz-security-token`) is covered too.
    public static let sensitiveFragments: [String] = [
        "token",
        "secret",
        "password",
        "passwd",
        "api-key",
        "apikey",
        "credential",
        "private-key",
        "session",
        "cookie",
    ]

    public static func isSensitive(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if alwaysSensitive.contains(lowered) { return true }
        return sensitiveFragments.contains { lowered.contains($0) }
    }

    /// What a sensitive value is replaced by: the header stays visibly
    /// *present* (and its size is reported), so "no cookie" and "a cookie I am
    /// not showing you" never look the same.
    public static func withheld(_ value: String) -> String {
        "•••• (\(value.count) chars)"
    }

    /// The value to keep for `name`, withheld unless `revealSensitive`.
    public static func display(_ name: String, value: String, revealSensitive: Bool) -> String {
        guard !revealSensitive, isSensitive(name) else { return value }
        return withheld(value)
    }
}

// MARK: - Request detail

/// What the engine can honestly say about one request, captured without
/// decrypting anything and without a certificate.
///
/// Plain HTTP yields the request line and both header sets; a TLS tunnel yields
/// the CONNECT target plus whatever the ClientHello advertises in the clear
/// (server name, ALPN, TLS version). Bodies are deliberately not captured.
public struct RequestDetail: Equatable, Sendable {

    public struct Field: Equatable, Sendable {
        public let name: String
        public let value: String
        /// True when the value was withheld — the UI dims these.
        public let redacted: Bool
    }

    public var requestLine: String?
    public var requestHeaders: [Field] = []
    public var statusLine: String?
    public var responseHeaders: [Field] = []
    /// TLS ClientHello facts (a CONNECT tunnel or a SOCKS5 destination).
    public var serverName: String?
    public var tlsVersion: String?
    public var alpn: [String] = []
    /// The address actually connected to, when the destination was a name.
    public var resolvedAddress: String?
    /// Anything that makes this capture less complete than it looks.
    public var notes: [String] = []

    /// Caps. A proxy is a hot path shared with 1000-entry history, so a single
    /// detail may not grow without bound — and a hostile peer must not be able
    /// to make it grow at all.
    public static let maxHeadersPerMessage = 32
    public static let maxValueLength = 512

    public init() {}

    /// Whether there is anything worth showing. An empty detail is not stored.
    public var isEmpty: Bool {
        requestLine == nil && requestHeaders.isEmpty
            && statusLine == nil && responseHeaders.isEmpty
            && serverName == nil && tlsVersion == nil && alpn.isEmpty
            && resolvedAddress == nil && notes.isEmpty
    }

    public mutating func captureRequestHeaders(_ headers: [(String, String)], revealSensitive: Bool) {
        requestHeaders = Self.fields(headers, revealSensitive: revealSensitive)
        if headers.count > requestHeaders.count {
            notes.append("\(headers.count - requestHeaders.count) more request headers not shown")
        }
    }

    public mutating func captureResponseHeaders(_ headers: [(String, String)], revealSensitive: Bool) {
        responseHeaders = Self.fields(headers, revealSensitive: revealSensitive)
        if headers.count > responseHeaders.count {
            notes.append("\(headers.count - responseHeaders.count) more response headers not shown")
        }
    }

    /// Turns wire headers into stored fields: redacted per name, capped in
    /// count and in value length. Pure, so the caps are unit-testable.
    public static func fields(_ headers: [(String, String)], revealSensitive: Bool) -> [Field] {
        headers.prefix(maxHeadersPerMessage).map { name, value in
            let display = HeaderRedaction.display(name, value: value, revealSensitive: revealSensitive)
            let redacted = display != value
            let trimmed = display.count > maxValueLength
                ? String(display.prefix(maxValueLength)) + "…"
                : display
            return Field(name: name, value: trimmed, redacted: redacted)
        }
    }

    /// Folds another capture into this one, keeping what is already known.
    ///
    /// The two legs of a relay report independently (the ClientHello from the
    /// client side, the response head from the server side), and they race with
    /// the entry's own retirement, so the merge never clears a field.
    public func merged(with other: RequestDetail) -> RequestDetail {
        var out = self
        if out.requestLine == nil { out.requestLine = other.requestLine }
        if out.requestHeaders.isEmpty { out.requestHeaders = other.requestHeaders }
        if out.statusLine == nil { out.statusLine = other.statusLine }
        if out.responseHeaders.isEmpty { out.responseHeaders = other.responseHeaders }
        if out.serverName == nil { out.serverName = other.serverName }
        if out.tlsVersion == nil { out.tlsVersion = other.tlsVersion }
        if out.alpn.isEmpty { out.alpn = other.alpn }
        if out.resolvedAddress == nil { out.resolvedAddress = other.resolvedAddress }
        for note in other.notes where !out.notes.contains(note) { out.notes.append(note) }
        return out
    }

    /// One line for a table row: what this detail adds over the base row.
    public var summary: String? {
        var parts: [String] = []
        if let serverName, !serverName.isEmpty { parts.append(serverName) }
        if let statusLine, let code = RequestDetail.statusCode(in: statusLine) {
            parts.append(code)
        }
        if let tlsVersion, !tlsVersion.isEmpty { parts.append(tlsVersion) }
        if !alpn.isEmpty { parts.append(alpn.joined(separator: "/")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "HTTP/1.1 200 OK" → "200 OK".
    public static func statusCode(in statusLine: String) -> String? {
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].uppercased().hasPrefix("HTTP/") else { return nil }
        return parts[1...].joined(separator: " ")
    }
}

// MARK: - HTTP response head

/// Probes the first bytes of a server→client stream for an HTTP/1.x response
/// head. Non-HTTP traffic (any TLS tunnel) is reported as such instead of
/// being buffered forever.
public enum HTTPResponseHead {

    public enum Probe: Equatable {
        case incomplete
        case notHTTP
        case parsed(statusLine: String, headers: [(String, String)])

        public static func == (lhs: Probe, rhs: Probe) -> Bool {
            switch (lhs, rhs) {
            case (.incomplete, .incomplete), (.notHTTP, .notHTTP): return true
            case let (.parsed(lStatus, lHeaders), .parsed(rStatus, rHeaders)):
                return lStatus == rStatus
                    && lHeaders.count == rHeaders.count
                    && zip(lHeaders, rHeaders).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: return false
            }
        }
    }

    /// Enough for any realistic head (8 KB of header is already pathological).
    public static let limit = 8 * 1024

    /// Status-line prefixes that a response may start with. Anything else on
    /// this leg is not an HTTP response (a TLS ServerHello, most often).
    private static let methods = ["HTTP/", "ICY "]

    public static func probe(_ bytes: [UInt8]) -> Probe {
        guard let text = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) else {
            return .notHTTP
        }
        if text.hasPrefix("\r\n") || text.hasPrefix("\n") {
            return .incomplete // leading CRLF is tolerated by receivers
        }
        guard methods.contains(where: { text.hasPrefix($0) }) else {
            // Not decidable yet if the prefix is shorter than the shortest marker.
            return text.count < 5 ? .incomplete : .notHTTP
        }
        guard let range = text.range(of: "\r\n\r\n") else {
            return bytes.count >= limit ? .notHTTP : .incomplete
        }
        let head = String(text[text.startIndex..<range.lowerBound])
        var lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first, !statusLine.isEmpty else { return .notHTTP }
        lines.removeFirst()
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            // Continuation lines (obs-fold) are obsolete; fold them into the
            // previous value rather than storing a header with no name.
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let last = headers.popLast() {
                    headers.append((last.0, last.1 + " " + line.trimmingCharacters(in: .whitespaces)))
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers.append((name, value))
        }
        return .parsed(statusLine: statusLine, headers: headers)
    }
}
