import Foundation

#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif
#if canImport(TurtleDiverRules)
import TurtleDiverRules
#endif

// MARK: - VPN Rule Generator

/// Converts vpn-slice split-tunnel targets (subnets and hostnames) into
/// Surge-compatible rules that force corporate-bound traffic to DIRECT so it
/// flows through the VPN tunnel instead of the proxy engine's upstreams.
///
/// Accepted target shapes (mirroring what users put in `vpnSliceURLs`):
/// - `10.0.0.0/8`        → `IP-CIDR,10.0.0.0/8,DIRECT`
/// - `10.0.0.1`          → `IP-CIDR,10.0.0.1/32,DIRECT`
/// - `fd00::/8`, `2001:…`→ `IP-CIDR6,…,DIRECT`
/// - `*.corp.example.com`→ `DOMAIN-SUFFIX,corp.example.com,DIRECT`
/// - `vpn.corp.com`      → `DOMAIN,vpn.corp.com,DIRECT`
///
/// Pure and synchronous: no DNS, no I/O — easy to unit-test and cheap to
/// recompute on every VPN connect/profile reload.
public enum VPNRuleGenerator {

    /// Builds DIRECT rules for the given vpn-slice targets. Invalid targets
    /// are skipped (returned in `errors` for UI surfacing).
    public static func rules(
        forTargets targets: [String],
        policy: String = "DIRECT"
    ) -> (rules: [ProfileRule], errors: [String]) {
        var rules: [ProfileRule] = []
        var errors: [String] = []
        var seen = Set<String>()

        for rawTarget in targets {
            let target = rawTarget.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty, !target.hasPrefix("#") else { continue }

            guard let rule = rule(forTarget: target, policy: policy) else {
                errors.append(target)
                continue
            }
            // De-duplicate repeated targets (vpn-slice tolerates repeats).
            let signature = "\(rule.type.rawValue),\(rule.value.lowercased())"
            if seen.insert(signature).inserted {
                rules.append(rule)
            }
        }
        return (rules, errors)
    }

    /// Single target → rule (nil when the target is neither IP/CIDR nor a
    /// plausible hostname).
    static func rule(forTarget target: String, policy: String) -> ProfileRule? {
        // CIDR form: base/prefix.
        if let slash = target.firstIndex(of: "/") {
            let base = String(target[..<slash])
            let prefix = String(target[target.index(after: slash)...])
            guard let prefixBits = Int(prefix), prefixBits >= 0 else { return nil }
            if let v4 = IPAddress.parseIPv4(base) {
                guard prefixBits <= 32 else { return nil }
                return ProfileRule(type: .ipCIDR, value: "\(v4.text)/\(prefixBits)", policy: policy)
            }
            if let v6 = IPAddress.parseIPv6(base), prefixBits <= 128 {
                return ProfileRule(type: .ipCIDR6, value: "\(v6.text)/\(prefixBits)", policy: policy)
            }
            return nil
        }

        // Bare IP literal.
        if let v4 = IPAddress.parseIPv4(target) {
            return ProfileRule(type: .ipCIDR, value: "\(v4.text)/32", policy: policy)
        }
        if let v6 = IPAddress.parseIPv6(target) {
            return ProfileRule(type: .ipCIDR6, value: "\(v6.text)/128", policy: policy)
        }

        // Wildcard hostname → suffix rule.
        if target.hasPrefix("*.") {
            let suffix = String(target.dropFirst(2))
            return validHostname(suffix) ? ProfileRule(type: .domainSuffix, value: suffix.lowercased(), policy: policy) : nil
        }

        // Plain hostname.
        guard validHostname(target) else { return nil }
        return ProfileRule(type: .domain, value: target.lowercased(), policy: policy)
    }

    /// Lenient hostname check: letters/digits/hyphens/dots, no spaces or
    /// slashes; each label non-empty and not starting/ending with `-`; the
    /// last label must not be all-numeric (rejects invalid IP literals such
    /// as `999.1.2.3`, which are hostnames in no universe).
    public static func validHostname(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            if label.isEmpty || label.hasPrefix("-") || label.hasSuffix("-") { return false }
        }
        if let last = labels.last, last.allSatisfy(\.isNumber) {
            return false
        }
        return true
    }

    // MARK: Profile merge

    /// Merges generated DIRECT rules into the profile, replacing the rules
    /// produced by the previous generation pass (so a changed vpn-slice list
    /// updates rather than accumulates). Generated rules go to the **top** of
    /// the rule list: corporate traffic must bypass proxy upstreams even if a
    /// user rule would otherwise match, because proxy egress cannot reach the
    /// tunneled subnets.
    public static func merge(
        generated: [ProfileRule],
        replacing previous: [ProfileRule],
        into profile: Profile
    ) -> Profile {
        // Reuse an existing rule's identity when it matches a generated rule
        // semantically, so repeated merges don't mint fresh UUIDs (which would
        // break `==`-based change detection — ProfileRule.id is part of
        // Equatable — and cause main-thread save/reload loops).
        func stabilized(_ rule: ProfileRule) -> ProfileRule {
            var copy = rule
            if let match = profile.rules.first(where: { sameRule(copy, $0) }) {
                copy.id = match.id
            }
            return copy
        }

        var rules = profile.rules

        // Remove the previous generation's rules by (type, value, policy).
        let previousSignatures = Set(previous.map(signature))
        rules.removeAll { previousSignatures.contains(signature($0)) }

        // Skip any generated rule that a surviving user rule already covers
        // identically (keeps repeated merges idempotent).
        let existingSignatures = Set(rules.map(signature))
        let toInsert = generated.filter { !existingSignatures.contains(signature($0)) }

        rules.insert(contentsOf: toInsert.map(stabilized), at: 0)
        var updated = profile
        updated.rules = rules
        return updated
    }

    private static func signature(_ rule: ProfileRule) -> String {
        "\(rule.type.rawValue),\(rule.value.lowercased()),\(rule.policy)"
    }

    /// Equality that ignores the identity UUID (parser/editor-minted IDs
    /// differ run to run; only the semantic content matters).
    public static func sameRule(_ a: ProfileRule, _ b: ProfileRule) -> Bool {
        a.type == b.type
            && a.value.lowercased() == b.value.lowercased()
            && a.policy == b.policy
            && a.noResolve == b.noResolve
    }

    /// Ordered rule-list comparison ignoring per-rule identity UUIDs.
    public static func sameRules(_ a: [ProfileRule], _ b: [ProfileRule]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy(sameRule)
    }
}
