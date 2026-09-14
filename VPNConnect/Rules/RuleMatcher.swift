import Foundation

// Profile types (Profile, ProfileRule, BuiltinPolicy) live in the Profile
// sources: one module in the app target, the TurtleDiverCore module under
// `swift test`.
#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif

// MARK: - Match Context

/// Everything the matcher may need about one connection. Fields stay optional
/// because different listeners observe different amounts of detail: SOCKS5
/// sees the host only, HTTP also sees UA/URL, and PROCESS-NAME requires the
/// engine to hand over the peer executable name (resolved off the accepted
/// socket fd).
public struct MatchContext: Sendable {
    /// Destination host as the client stated it (hostname or IP literal).
    public var host: String?
    /// Destination port, when known.
    public var port: Int?
    /// Pre-resolved destination IP when the caller already has one
    /// (e.g. an IP-literal destination, or the engine's own resolution).
    public var resolvedIP: IPAddress?
    /// Peer executable name for PROCESS-NAME rules (best-effort).
    public var processName: String?
    /// Client User-Agent header (HTTP path only).
    public var userAgent: String?
    /// Request URL as seen by the HTTP listener (absolute-form when proxied).
    public var url: String?
    /// Source IP of the client connection (for SRC-IP rules).
    public var sourceIP: IPAddress?

    public init(
        host: String? = nil,
        port: Int? = nil,
        resolvedIP: IPAddress? = nil,
        processName: String? = nil,
        userAgent: String? = nil,
        url: String? = nil,
        sourceIP: IPAddress? = nil
    ) {
        self.host = host
        self.port = port
        self.resolvedIP = resolvedIP
        self.processName = processName
        self.userAgent = userAgent
        self.url = url
        self.sourceIP = sourceIP
    }
}

// MARK: - Match Outcome

/// The result of matching a context against the rule list.
public struct MatchOutcome: Equatable, Sendable {
    /// The rule that matched. `nil` when no rule matched and no default is set.
    public let rule: ProfileRule?
    /// Policy name from the matched rule (or the default).
    public let policy: String
    /// True when the matcher had to resolve DNS to reach this decision
    /// (surfaced for logging and `no-resolve` behavior tests).
    public let performedDNS: Bool

    public init(rule: ProfileRule?, policy: String, performedDNS: Bool) {
        self.rule = rule
        self.policy = policy
        self.performedDNS = performedDNS
    }

    public static func == (lhs: MatchOutcome, rhs: MatchOutcome) -> Bool {
        lhs.policy == rhs.policy
            && lhs.performedDNS == rhs.performedDNS
            && lhs.rule?.id == rhs.rule?.id
    }
}

// MARK: - Matcher Errors

public enum RuleMatcherError: LocalizedError, Equatable {
    case invalidRuleValue(index: Int, detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRuleValue(let index, let detail):
            return "Rule #\(index + 1) has an invalid value: \(detail)"
        }
    }
}

// MARK: - Rule Matcher

/// Ordered, first-match-wins evaluation of a profile's `[Rule]` section.
///
/// Matching is Surge-compatible:
/// - `DOMAIN` exact (case-insensitive), `DOMAIN-SUFFIX` on label boundaries,
///   `DOMAIN-KEYWORD` substring.
/// - `IP-CIDR` / `IP-CIDR6` with DNS resolution on demand; resolution is
///   skipped when the host is already an IP literal or a previous match
///   already resolved it. `no-resolve` rules are skipped when resolution
///   would be required.
/// - `USER-AGENT` / `URL-REGEX` only evaluate when HTTP metadata is present
///   (SOCKS5 connections never match them).
/// - `PROCESS-NAME` only evaluates when the engine supplied a peer name.
/// - `DEST-PORT`, `SRC-IP`, `PROTOCOL` as documented in docs/PROFILES.md.
/// - `GEOIP` is reserved: it never matches until the database lands.
/// - `FINAL` terminates matching; when absent, `defaultPolicy` applies.
///
/// Thread-safety: all public methods are safe from any queue. The compiled
/// rule list is swapped atomically by `updateProfile`.
public final class RuleMatcher: @unchecked Sendable {

    // MARK: Dependencies

    private let resolver: DNSResolving

    // MARK: State

    private let lock = NSLock()
    private var rules: [ProfileRule]
    private var defaultPolicy: String

    /// Statistics for the dashboard: how many connections were decided with
    /// and without DNS resolution.
    private var stats = (dnsLookups: 0, directIPDecisions: 0)

    public init(
        profile: Profile,
        resolver: DNSResolving = CachingDNSResolver()
    ) {
        self.rules = profile.rules
        self.defaultPolicy = Self.defaultPolicy(for: profile)
        self.resolver = resolver
    }

    /// Surge behavior when no rule matches and no FINAL exists: DIRECT.
    static func defaultPolicy(for profile: Profile) -> String {
        profile.rules.last(where: { $0.type == .final })?.policy ?? BuiltinPolicy.direct.rawValue
    }

    /// Hot-swaps the rule list (profile change). DNS caches live in the
    /// injected resolver; clear it here so fresh rules see fresh DNS.
    public func updateProfile(_ profile: Profile) {
        lock.lock()
        rules = profile.rules
        defaultPolicy = Self.defaultPolicy(for: profile)
        lock.unlock()
        (resolver as? CachingDNSResolver)?.clearCache()
    }

    // MARK: Matching

    /// Matches `context` against the ordered rule list.
    /// - Throws: `RuleMatcherError` when a rule's stored value cannot be used
    ///   at match time (e.g. malformed CIDR that slipped past validation).
    public func match(_ context: MatchContext) throws -> MatchOutcome {
        lock.lock()
        let snapshot = rules
        let fallback = defaultPolicy
        lock.unlock()

        var performedDNS = false
        var resolved: [IPAddress]?

        for (index, rule) in snapshot.enumerated() {
            // Destination IP for this rule: literal host, pre-resolved IP, or
            // (lazily, once) DNS. Rules that would need DNS but have
            // `no-resolve` are skipped.
            var destinationIP: IPAddress?
            var needsDNS = false

            switch rule.type {
            case .ipCIDR, .ipCIDR6, .geoIP:
                if let direct = Self.hostIPLiteral(context.host) {
                    destinationIP = direct
                } else if let provided = context.resolvedIP {
                    destinationIP = provided
                } else if let cached = resolved {
                    destinationIP = Self.pickAddress(cached, preferIPv4: rule.type == .ipCIDR)
                } else {
                    needsDNS = true
                }
            default:
                break
            }

            if needsDNS && rule.noResolve {
                continue // skip silently, keep scanning later rules
            }

            if needsDNS {
                guard let host = context.host, !host.isEmpty else { continue }
                let addresses = resolver.resolve(host: host)
                lock.lock()
                stats.dnsLookups += 1
                lock.unlock()
                performedDNS = true
                resolved = addresses
                destinationIP = Self.pickAddress(addresses, preferIPv4: rule.type == .ipCIDR)
                // Failed resolution yields nil and the rule simply misses.
            }

            if let matched = try Self.ruleMatches(
                rule, index: index, context: context, destinationIP: destinationIP
            ) {
                if destinationIP != nil && Self.hostIPLiteral(context.host) != nil {
                    lock.lock()
                    stats.directIPDecisions += 1
                    lock.unlock()
                }
                return MatchOutcome(rule: matched, policy: matched.policy, performedDNS: performedDNS)
            }
        }

        return MatchOutcome(rule: nil, policy: fallback, performedDNS: performedDNS)
    }

    /// Core per-rule predicate. Returns the matched rule or nil.
    static func ruleMatches(
        _ rule: ProfileRule, index: Int, context: MatchContext, destinationIP: IPAddress?
    ) throws -> ProfileRule? {
        switch rule.type {
        case .domain:
            guard let host = context.host else { return nil }
            return host.lowercased() == rule.value.lowercased() ? rule : nil

        case .domainSuffix:
            guard let host = context.host else { return nil }
            return Self.hostMatchesSuffix(host: host, suffix: rule.value) ? rule : nil

        case .domainKeyword:
            guard let host = context.host else { return nil }
            return host.lowercased().contains(rule.value.lowercased()) ? rule : nil

        case .ipCIDR, .ipCIDR6:
            guard let valueIP = Self.cidrCacheValue(rule) else {
                throw RuleMatcherError.invalidRuleValue(index: index, detail: "\"\(rule.value)\" is not valid CIDR")
            }
            guard let ip = destinationIP else { return nil }
            // IPv4-mapped IPv6 addresses match either notation.
            if valueIP.address.isIPv4 != ip.isIPv4,
               let normalized = Self.normalizeToIPv4(ip) ?? Self.normalizeToIPv4(valueIP.address) {
                let block = CIDRBlock(address: normalized, prefixLength: valueIP.prefixLength)
                return block.contains(ip) ? rule : nil
            }
            let block = CIDRBlock(address: valueIP.address, prefixLength: valueIP.prefixLength)
            return block.contains(ip) ? rule : nil

        case .geoIP:
            return nil // reserved until the GeoIP database lands

        case .userAgent:
            guard let ua = context.userAgent, !ua.isEmpty else { return nil }
            return Self.regexSearch(rule.value, in: ua) ? rule : nil

        case .urlRegex:
            guard let url = context.url, !url.isEmpty else { return nil }
            return Self.regexSearch(rule.value, in: url) ? rule : nil

        case .processName:
            guard let peer = context.processName, !peer.isEmpty else { return nil }
            return Self.processNameMatches(peer: peer, value: rule.value) ? rule : nil

        case .destPort:
            guard let port = context.port else { return nil }
            return Self.portListContains(rule.value, port: port) ? rule : nil

        case .srcIP:
            guard let value = Self.cidrCacheValue(rule) else {
                throw RuleMatcherError.invalidRuleValue(index: index, detail: "\"\(rule.value)\" is not valid CIDR")
            }
            guard let source = context.sourceIP else { return nil }
            let block = CIDRBlock(address: value.address, prefixLength: value.prefixLength)
            return block.contains(source) ? rule : nil

        case .protocolRule:
            guard let port = context.port else { return nil }
            // Best-effort heuristic until listeners expose the negotiated
            // protocol: well-known ports map to their canonical service.
            let lower = rule.value.lowercased()
            switch (lower, port) {
            case ("http", 80), ("https", 443), ("ftp", 21), ("ssh", 22),
                 ("dns", 53), ("smtp", 25), ("pop3", 110), ("imap", 143):
                return rule
            default:
                return nil
            }
        case .final:
            return rule
        }
    }

    // MARK: - Matching helpers

    /// `DOMAIN-SUFFIX`: label-boundary suffix match, case-insensitive.
    /// `apple.com` matches `www.apple.com` and `apple.com`, but not
    /// `notapple.com`. IP-literal hosts never match domain rules.
    static func hostMatchesSuffix(host: String, suffix: String) -> Bool {
        let h = host.lowercased()
        let s = suffix.lowercased()
        guard !s.isEmpty, !h.isEmpty else { return false }
        guard h.hasSuffix(s) else { return false }
        if h.count == s.count { return true }
        let beforeSuffix = h.dropLast(s.count)
        return beforeSuffix.hasSuffix(".")
    }

    /// Parses a host that is literally an IP address (v4 or v6).
    static func hostIPLiteral(_ host: String?) -> IPAddress? {
        guard let host, !host.isEmpty else { return nil }
        guard !host.allSatisfy({ $0.isLetter }) || host.contains(":") else { return nil }
        return IPAddress.parse(host)
    }

    /// Prefers IPv4 for `IP-CIDR` (v6 rules read the full list anyway via
    /// mapped normalization); returns nil when resolution failed.
    static func pickAddress(_ addresses: [IPAddress], preferIPv4: Bool) -> IPAddress? {
        if preferIPv4, let v4 = addresses.first(where: { $0.isIPv4 }) { return v4 }
        return addresses.first
    }

    /// Normalizes an IPv4-mapped IPv6 address to plain IPv4.
    static func normalizeToIPv4(_ ip: IPAddress) -> IPAddress? {
        guard !ip.isIPv4, let v4 = IPAddress.unwrapIPv4Mapped(ip.bytes) else { return nil }
        return IPAddress(bytes: v4)
    }

    /// Parses a CIDR rule value. Kept as a per-call parse (cheap) rather than
    /// a cache: profile swaps would otherwise invalidate memoized entries.
    static func cidrCacheValue(_ rule: ProfileRule) -> (address: IPAddress, prefixLength: Int)? {
        IPAddress.parseAddressOrBlock(rule.value).map { (address: $0.ip, prefixLength: $0.prefix) }
    }

    /// Surge-compatible PROCESS-NAME: case-insensitive match on the executable
    /// path's last path component.
    static func processNameMatches(peer: String, value: String) -> Bool {
        let lastComponent = peer.split(separator: "/").last.map(String.init) ?? peer
        return lastComponent.lowercased() == value.lowercased()
    }

    /// `DEST-PORT` value: `443`, `80-90`, or comma-separated mix.
    static func portListContains(_ value: String, port: Int) -> Bool {
        for chunk in value.split(separator: ",") {
            let part = chunk.trimmingCharacters(in: .whitespaces)
            if part.contains("-") {
                let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2, let lo = Int(bounds[0]), let hi = Int(bounds[1]) else { continue }
                if port >= lo && port <= hi { return true }
            } else if let exact = Int(part), exact == port {
                return true
            }
        }
        return false
    }

    /// ICU regex search (Surge semantics: match anywhere, not full-string).
    static func regexSearch(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    // MARK: - Stats (dashboard)

    /// Lookup counters since process start.
    public func statistics() -> (dnsLookups: Int, directIPDecisions: Int) {
        lock.withLock { stats }
    }

    /// True when any rule requires data the engine must supply explicitly:
    /// PROCESS-NAME needs the peer executable name. The engine uses this to
    /// decide whether to pay for peer resolution on every accepted socket.
    public var needsProcessNames: Bool {
        lock.withLock { rules.contains { $0.type == .processName } }
    }
}
