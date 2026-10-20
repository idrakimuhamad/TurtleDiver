import Foundation
import CryptoKit

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif

// MARK: - Share PAC generator

/// Builds the tiny PAC file a shared (LAN) device fetches from the engine.
///
/// The generator is pure: it opens no sockets and reads no state of its own.
/// The engine hands it a snapshot of the rules and of the policies they resolve
/// to on every request, so a rule or profile change is visible to the device on
/// its next PAC fetch.
///
/// Only `PROXY` and `DIRECT` are ever emitted. A PAC consumer (Android in
/// particular) understands exactly `PROXY`, `SOCKS` and `DIRECT`, and a
/// `; DIRECT` fallback after `PROXY` would silently defeat the tunnel.
///
/// The guiding rule is *fail open towards the Mac*: a PAC can express only a
/// subset of the rule engine (no ports, no URLs, no user agents), so when the
/// phone cannot reproduce a decision it sends the host to the Mac rather than
/// guessing DIRECT and bypassing a proxy or reject.
///
/// No DNS is performed by the PAC. The phone's resolver is not evidence of the
/// Mac's: split-horizon VPN DNS can return a different address, and the Mac's
/// matcher may still resolve a name for a later rule. So a non-literal host
/// that reaches a decision needing an address goes to the Mac, as does every
/// IPv6 literal.
///
/// Security: every string that reaches the JavaScript is emitted as a JSON
/// string literal. Rule values come from a user-authored profile, so a hostile
/// or merely unusual value must not be able to close the literal and inject
/// code. Neither `dnsResolve` nor `isInNet` is ever used.
public enum SharePACGenerator {

    // MARK: Tunnel mode

    /// Whether the tunnel routes everything (Standard VPN, or split tunneling
    /// with no usable target) or only explicit `vpn-slice` targets.
    public enum TunnelMode: Equatable, Sendable {
        case fullTunnel
        case split(targets: [String])

        public var targets: [String] {
            if case .split(let targets) = self { return targets }
            return []
        }
    }

    /// The mode the tunnel is actually in: Standard VPN (or a split list with
    /// nothing usable) carries everything, otherwise only the listed targets.
    public static func resolvedMode(useTunneling: Bool, targets: [String]) -> TunnelMode {
        guard useTunneling else { return .fullTunnel }
        return parseTargets(.split(targets: targets)).hasAny
            ? .split(targets: targets)
            : .fullTunnel
    }

    // MARK: Rules

    /// One profile rule that a PAC decision can evaluate.
    public struct Rule: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case domain
            case domainSuffix
            case domainKeyword
            case ipCIDR
            /// An IPv6 `IP-CIDR6` rule. Never matched (IPv6 literals go to the
            /// Mac); retained because its position decides what a hostname
            /// does when it is the first address rule without `no-resolve`.
            case ipCIDR6
            /// A `GEOIP` rule. It never matches, but `RuleMatcher` still
            /// resolves DNS for it (unless `no-resolve`), populating the cache
            /// a later `no-resolve` IP rule can use. Its position is therefore
            /// a resolving point for hostnames.
            case geoIP
            /// A terminal rule: every host reaching it takes its policy. Used
            /// for `FINAL` and for rules the phone cannot evaluate.
            case barrier
        }

        public var kind: Kind
        /// `DOMAIN*` value, or an IPv4 CIDR (`10.0.0.0/8`) for `.ipCIDR`.
        public var value: String
        /// Whether a match should send the URL to this Mac's proxy. `false`
        /// means the Mac resolves the policy to DIRECT.
        public var usesProxy: Bool
        /// `.ipCIDR`/`.ipCIDR6` only: the rule was written with `no-resolve`, so
        /// it can match IP literals only. A `no-resolve` rule *after* an
        /// address rule can still match on the Mac (the earlier rule populated
        /// its DNS cache), which is why a hostname terminates at the first
        /// resolving rule below.
        public var noResolve: Bool

        public init(
            kind: Kind,
            value: String,
            usesProxy: Bool,
            noResolve: Bool = false
        ) {
            self.kind = kind
            self.value = value
            self.usesProxy = usesProxy
            self.noResolve = noResolve
        }
    }

    /// Converts expanded profile rules into PAC rules, preserving order.
    ///
    /// `isDirect` must be a side-effect-free, conservative classification: it
    /// may answer `true` only when *every* reachable member of that policy is
    /// DIRECT. Anything unknown is treated as non-DIRECT (fail open to the
    /// Mac).
    public static func rules(
        from profileRules: [ProfileRule],
        isDirect: (String) -> Bool
    ) -> [Rule] {
        var result: [Rule] = []
        for profileRule in profileRules {
            let direct = isDirect(profileRule.policy)
            switch profileRule.type {
            case .domain:
                result.append(Rule(kind: .domain, value: profileRule.value, usesProxy: !direct))
            case .domainSuffix:
                result.append(Rule(kind: .domainSuffix, value: profileRule.value, usesProxy: !direct))
            case .domainKeyword:
                result.append(Rule(kind: .domainKeyword, value: profileRule.value, usesProxy: !direct))
            case .ipCIDR:
                guard parseIPv4CIDR(profileRule.value) != nil else {
                    // Malformed: the Mac cannot match it either, so a DIRECT
                    // rule is safely dropped. A non-DIRECT one cannot be
                    // judged here, so it terminates the scan.
                    if !direct { result.append(Rule(kind: .barrier, value: "", usesProxy: true)) }
                    continue
                }
                result.append(Rule(
                    kind: .ipCIDR,
                    value: profileRule.value,
                    usesProxy: !direct,
                    noResolve: profileRule.noResolve
                ))
            case .ipCIDR6:
                guard let block = IPAddress.parseAddressOrBlock(profileRule.value), !block.ip.isIPv4 else {
                    if !direct { result.append(Rule(kind: .barrier, value: "", usesProxy: true)) }
                    continue
                }
                result.append(Rule(
                    kind: .ipCIDR6,
                    value: profileRule.value,
                    usesProxy: !direct,
                    noResolve: profileRule.noResolve
                ))
            case .final:
                // `RuleMatcher` returns the first FINAL it reaches, for every
                // host. Emit the same terminal decision and stop: anything
                // after it is unreachable on the Mac too.
                result.append(Rule(kind: .barrier, value: "", usesProxy: !direct))
                return result
            case .geoIP:
                result.append(Rule(
                    kind: .geoIP,
                    value: profileRule.value,
                    usesProxy: !direct,
                    noResolve: profileRule.noResolve
                ))
            case .ruleSet:
                // An unexpanded RULE-SET has no rules and never matches.
                continue
            default:
                // USER-AGENT, URL-REGEX, PROCESS-NAME, SRC-IP, DEST-PORT,
                // PROTOCOL: the phone cannot evaluate them and must not skip
                // past them. A DIRECT outcome is safe to drop; any other
                // outcome stops the scan.
                if !direct { result.append(Rule(kind: .barrier, value: "", usesProxy: true)) }
            }
        }
        return result
    }

    // MARK: Configuration

    /// Everything one generated PAC file needs.
    public struct Configuration: Equatable, Sendable {
        /// The Mac's LAN address (the device dials this).
        public var proxyHost: String
        /// The shared listener's port (the loopback HTTP port).
        public var proxyPort: Int
        /// Full tunnel or explicit split targets.
        public var mode: TunnelMode
        /// Expanded profile rules, in first-match order.
        public var rules: [Rule]
        /// What the profile's FINAL policy (or its DIRECT default) resolves to.
        /// Ignored when the rules contain a terminal FINAL.
        public var finalUsesProxy: Bool

        public init(
            proxyHost: String,
            proxyPort: Int,
            mode: TunnelMode,
            rules: [Rule],
            finalUsesProxy: Bool
        ) {
            self.proxyHost = proxyHost
            self.proxyPort = proxyPort
            self.mode = mode
            self.rules = rules
            self.finalUsesProxy = finalUsesProxy
        }
    }

    // MARK: Token

    /// The path token that authorises a PAC fetch: the first 24 hex characters
    /// of `SHA256("turtlediver-pac:" + password)`.
    ///
    /// Derived rather than stored, so rotating the share password rotates the
    /// URL, and deleting the password (reset) makes the old URL dead. 96 bits
    /// are far beyond guessable on a LAN and short enough to type.
    public static func token(password: String) -> String {
        let digest = SHA256.hash(data: Data("turtlediver-pac:\(password)".utf8))
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex += String(format: "%02x", byte)
        }
        return String(hex.prefix(24))
    }

    /// The URL a device should be given, e.g.
    /// `http://192.168.1.20:6152/0123456789abcdef01234567/proxy.pac`.
    public static func pacURL(host: String, port: Int, password: String) -> String {
        "http://\(host):\(port)/\(token(password: password))/proxy.pac"
    }

    // MARK: Generation

    /// Renders the PAC document. Small by design: data arrays plus a fixed
    /// matcher, never code generated per rule.
    public static func pac(_ configuration: Configuration) -> String {
        let targets = parseTargets(configuration.mode)
        let fullTunnel: Bool
        switch configuration.mode {
        case .fullTunnel:
            fullTunnel = true
        case .split:
            // No *usable* target means the split list cannot narrow anything:
            // treat it as the full tunnel it effectively is.
            fullTunnel = !targets.hasAny
        }

        // Each rule that can terminate a hostname needs to know whether it or
        // anything after it (through FINAL) can be non-DIRECT.
        let literals: [String] = configuration.rules.enumerated().map { index, rule in
            let tailCanBeNonDirect = configuration.rules[index...].contains(where: \.usesProxy)
                || configuration.finalUsesProxy
            return ruleLiteral(rule, tailCanBeNonDirect: tailCanBeNonDirect)
        }

        var lines: [String] = []
        lines.append("var VDOM = \(jsonArray(targets.domains.map(jsonString)));")
        lines.append("var VSUF = \(jsonArray(targets.suffixes.map(jsonString)));")
        lines.append("var VNET = \(jsonArray(targets.networks.map { "[\($0.base),\($0.prefix)]" }));")
        lines.append("var VIP6 = \(targets.hasIPv6 ? 1 : 0);")
        lines.append("var FULL = \(fullTunnel ? 1 : 0);")
        lines.append("var R = \(jsonArray(literals));")
        lines.append("var P = \"PROXY \" + \(jsonString(configuration.proxyHost)) + \":\(configuration.proxyPort)\";")
        lines.append("")
        lines.append("function td_ip4(s) {")
        lines.append("  var p = s.split(\".\");")
        lines.append("  if (p.length !== 4) return null;")
        lines.append("  var n = 0;")
        lines.append("  for (var i = 0; i < 4; i++) {")
        lines.append("    var t = p[i];")
        lines.append("    if (t.length < 1 || t.length > 3) return null;")
        lines.append("    for (var j = 0; j < t.length; j++) {")
        lines.append("      var c = t.charCodeAt(j);")
        lines.append("      if (c < 48 || c > 57) return null;")
        lines.append("    }")
        lines.append("    var v = parseInt(t, 10);")
        lines.append("    if (v > 255) return null;")
        lines.append("    n = n * 256 + v;")
        lines.append("  }")
        lines.append("  return n;")
        lines.append("}")
        lines.append("")
        lines.append("function td_net(ip, base, bits) {")
        lines.append("  var size = Math.pow(2, 32 - bits);")
        lines.append("  return Math.floor(ip / size) === Math.floor(base / size);")
        lines.append("}")
        lines.append("")
        lines.append("function td_suffix(h, s) {")
        lines.append("  if (s.length === 0) return false;")
        lines.append("  return h === s || h.slice(-(s.length + 1)) === \".\" + s;")
        lines.append("}")
        lines.append("")
        lines.append("function td_vpn(h, ip) {")
        lines.append("  var i;")
        lines.append("  for (i = 0; i < VDOM.length; i++) if (h === VDOM[i]) return true;")
        lines.append("  for (i = 0; i < VSUF.length; i++) if (td_suffix(h, VSUF[i])) return true;")
        // A non-literal host at an address-bearing split target is not
        // decidable here: the phone's DNS is not the Mac's VPN DNS. An IPv6
        // literal is likewise sent to the Mac.
        lines.append("  if (ip === null) {")
        lines.append("    if (h.indexOf(\":\") >= 0) return true;")
        lines.append("    if (VNET.length > 0 || VIP6 === 1) return true;")
        lines.append("    return false;")
        lines.append("  }")
        lines.append("  for (i = 0; i < VNET.length; i++) if (td_net(ip, VNET[i][0], VNET[i][1])) return true;")
        lines.append("  return false;")
        lines.append("}")
        lines.append("")
        lines.append("function td_match(h, ip, r) {")
        lines.append("  if (r[0] === \"b\") return true;")
        lines.append("  if (r[0] === \"d\") return h === r[1];")
        lines.append("  if (r[0] === \"s\") return td_suffix(h, r[1]);")
        lines.append("  if (r[0] === \"k\") return h.indexOf(r[1]) >= 0;")
        lines.append("  if (r[0] === \"c\") return ip !== null && td_net(ip, r[1], r[2]);")
        lines.append("  return false;")
        lines.append("}")
        lines.append("")
        lines.append("function FindProxyForURL(url, host) {")
        // Rule matching uses the host exactly as `RuleMatcher` sees it:
        // lowercased, but with any trailing root dot left alone. Targets use
        // a dot-stripped copy.
        lines.append("  var h = (host || \"\").toLowerCase();")
        lines.append("  var t = h;")
        lines.append("  while (t.length > 1 && t.charAt(t.length - 1) === \".\") t = t.slice(0, -1);")
        lines.append("  var tip = td_ip4(t);")
        // Explicit targets come first, including single-label ones such as
        // `intranet`. There is no localhost/plain-host shortcut: the Mac
        // evaluates those hosts against the rules, so the PAC must too.
        lines.append("  if (td_vpn(t, tip)) return P;")
        lines.append("  if (FULL === 1) return P;")
        lines.append("  var ip = td_ip4(h);")
        let finalLiteral = configuration.finalUsesProxy ? "P" : "\"DIRECT\""
        lines.append("  for (var i = 0; i < R.length; i++) {")
        lines.append("    var r = R[i];")
        // The first address rule without `no-resolve` resolves a hostname on
        // the Mac (and caches it for later no-resolve rules), so a hostname
        // cannot be evaluated past it. GEOIP never matches but resolves the
        // same way. Take the precomputed outcome: PROXY when this rule or
        // anything after it can be non-DIRECT, else DIRECT.
        lines.append("    if (ip === null && (r[0] === \"c\" || r[0] === \"c6\" || r[0] === \"g\") && r[4] === 0) {")
        lines.append("      return r[5] ? P : \"DIRECT\";")
        lines.append("    }")
        lines.append("    if (td_match(h, ip, r)) return r[3] ? P : \"DIRECT\";")
        lines.append("  }")
        lines.append("  return \(finalLiteral);")
        lines.append("}")

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Literals

    private static func ruleLiteral(_ rule: Rule, tailCanBeNonDirect: Bool) -> String {
        let policy = rule.usesProxy ? "1" : "0"
        let tail = tailCanBeNonDirect ? "1" : "0"
        switch rule.kind {
        case .barrier:
            return "[\"b\",\"\",0,\(policy)]"
        case .domain:
            // `RuleMatcher` lowercases both sides for every DOMAIN* type and
            // does not strip dots. Do exactly that, no more: stripping a dot
            // from a KEYWORD value would broaden a DIRECT rule.
            return "[\"d\",\(jsonString(rule.value.lowercased())),0,\(policy)]"
        case .domainSuffix:
            return "[\"s\",\(jsonString(rule.value.lowercased())),0,\(policy)]"
        case .domainKeyword:
            return "[\"k\",\(jsonString(rule.value.lowercased())),0,\(policy)]"
        case .ipCIDR:
            guard let network = parseIPv4CIDR(rule.value) else {
                // Unparseable at generation time: a DIRECT rule can never
                // match; a non-DIRECT rule still fails open to the Mac.
                return rule.usesProxy ? "[\"b\",\"\",0,1]" : "[\"x\",\"\",0,0]"
            }
            return "[\"c\",\(network.base),\(network.prefix),\(policy),\(rule.noResolve ? 1 : 0),\(tail)]"
        case .ipCIDR6:
            // Never matched in JS: IPv6 literals go to the Mac before rules.
            // Its position still terminates hostnames when it is the first
            // address rule without `no-resolve`.
            return "[\"c6\",0,0,\(policy),\(rule.noResolve ? 1 : 0),\(tail)]"
        case .geoIP:
            // Never matched, but its position is a resolving point on the Mac
            // unless `no-resolve` is set.
            return "[\"g\",0,0,\(policy),\(rule.noResolve ? 1 : 0),\(tail)]"
        }
    }

    private static func jsonArray(_ items: [String]) -> String {
        "[" + items.joined(separator: ",") + "]"
    }

    /// A JSON-compatible string literal, including the escapes JavaScript
    /// requires for U+2028/U+2029 and the control characters JSON permits.
    static func jsonString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.append(String(scalar))
                }
            }
        }
        out += "\""
        return out
    }

    // MARK: Targets

    private struct Targets {
        var domains: [String] = []
        var suffixes: [String] = []
        var networks: [(base: UInt32, prefix: Int)] = []
        var hasIPv6 = false

        var hasAny: Bool {
            !domains.isEmpty || !suffixes.isEmpty || !networks.isEmpty || hasIPv6
        }
    }

    /// Parses the same target shapes `VPNRuleGenerator` accepts. IPv6 targets
    /// are validated (`inet_pton`) but not matched; their presence makes
    /// IPv6-literal hosts go to the Mac rather than fall through to DIRECT.
    /// Invalid entries are ignored.
    private static func parseTargets(_ mode: TunnelMode) -> Targets {
        var targets = Targets()
        var seenDomains = Set<String>()
        var seenSuffixes = Set<String>()
        var seenNetworks = Set<String>()

        for raw in mode.targets {
            let target = raw.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !target.hasPrefix("#") else { continue }

            if let slash = target.firstIndex(of: "/") {
                let base = String(target[..<slash])
                let prefixText = String(target[target.index(after: slash)...])
                guard let prefix = Int(prefixText) else { continue }
                if (0...32).contains(prefix), let address = parseIPv4(base) {
                    let key = "\(address)/\(prefix)"
                    if seenNetworks.insert(key).inserted {
                        targets.networks.append((base: address, prefix: prefix))
                    }
                } else if (0...128).contains(prefix), isValidIPv6(base) {
                    targets.hasIPv6 = true
                }
                continue
            }
            if let address = parseIPv4(target) {
                let key = "\(address)/32"
                if seenNetworks.insert(key).inserted {
                    targets.networks.append((base: address, prefix: 32))
                }
                continue
            }
            if isValidIPv6(target) {
                // Conservatively handled as "IPv6 traffic belongs to the
                // tunnel".
                targets.hasIPv6 = true
                continue
            }

            if target.hasPrefix("*.") {
                let suffix = normalizedTargetValue(String(target.dropFirst(2)))
                guard validHostname(suffix), seenSuffixes.insert(suffix).inserted else { continue }
                targets.suffixes.append(suffix)
            } else {
                let domain = normalizedTargetValue(target)
                guard validHostname(domain), seenDomains.insert(domain).inserted else { continue }
                targets.domains.append(domain)
            }
        }
        return targets
    }

    /// Targets are not profile rules: normalizing their case and trailing root
    /// dot only ever sends *more* traffic to the Mac, which is the safe
    /// direction. Rule values are normalized exactly like `RuleMatcher` does.
    private static func normalizedTargetValue(_ value: String) -> String {
        var normalized = value.lowercased()
        while normalized.hasSuffix(".") { normalized.removeLast() }
        return normalized
    }

    /// `inet_pton` rather than a lexical guess: `not-an-ip:garbage` must not be
    /// mistaken for an IPv6 target (it would turn a full tunnel into a split
    /// one).
    private static func isValidIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    private static func parseIPv4CIDR(_ value: String) -> (base: UInt32, prefix: Int)? {
        guard let slash = value.firstIndex(of: "/") else { return nil }
        let base = String(value[..<slash])
        let prefixText = String(value[value.index(after: slash)...])
        guard let prefix = Int(prefixText), (0...32).contains(prefix),
              let address = parseIPv4(base) else { return nil }
        return (address, prefix)
    }

    static func parseIPv4(_ value: String) -> UInt32? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  let octet = UInt32(part), octet <= 255 else { return nil }
            result = result * 256 + octet
        }
        return result
    }

    /// Lenient hostname check, matching `VPNRuleGenerator.validHostname`: keeps
    /// obviously unusable values out of the PAC without trying to be a DNS
    /// validator.
    private static func validHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels where label.isEmpty || label.hasPrefix("-") || label.hasSuffix("-") {
            return false
        }
        if let last = labels.last, last.allSatisfy(\.isNumber) { return false }
        return true
    }
}
