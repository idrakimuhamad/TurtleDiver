import Foundation

// MARK: - Proxy Type

/// Surge-style upstream proxy/forwarding types for a `[Proxy]` entry.
public enum ProxyType: String, CaseIterable, Codable, Sendable {
    case http
    case https
    case socks5
}

// MARK: - Proxy Definition

/// One entry in the `[Proxy]` section — a concrete upstream proxy server.
public struct ProxyDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var type: ProxyType
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    public var tls: Bool
    public var skipCertVerify: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        type: ProxyType,
        host: String,
        port: Int,
        username: String? = nil,
        password: String? = nil,
        tls: Bool = false,
        skipCertVerify: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.tls = tls
        self.skipCertVerify = skipCertVerify
    }
}

// MARK: - Group Type

/// Surge-style policy group behaviors.
public enum ProxyGroupType: String, CaseIterable, Codable, Sendable {
    /// User-chosen policy; the selection persists.
    case select
    /// Periodically tests candidates and picks the lowest latency.
    case urlTest = "url-test"
    /// Uses the first candidate (in order) that passes the health test.
    case fallback
    /// Spreads connections across healthy candidates (round-robin).
    case loadBalance = "load-balance"
}

// MARK: - Proxy Group

/// One entry in the `[Proxy Group]` section.
///
/// Members reference other policies by name: concrete proxies from `[Proxy]`,
/// other groups, or the built-ins `DIRECT` / `REJECT`.
public struct ProxyGroup: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var type: ProxyGroupType
    /// Names of member policies, in priority order.
    public var policies: [String]
    /// URL used for latency testing (url-test / fallback / load-balance).
    public var testURL: String?
    /// Test interval in seconds.
    public var interval: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        type: ProxyGroupType,
        policies: [String],
        testURL: String? = nil,
        interval: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.policies = policies
        self.testURL = testURL
        self.interval = interval
    }
}

// MARK: - Rule

/// Built-in policies that always exist and cannot be redefined.
public enum BuiltinPolicy: String, CaseIterable, Sendable {
    case direct = "DIRECT"
    case reject = "REJECT"

    /// All policy names that are built-ins.
    public static var names: [String] { allCases.map(\.rawValue) }
}

/// Surge-compatible rule types supported by the matcher (Phase 2 implements
/// matching; Phase 0 defines the model and parsing).
public enum RuleType: String, CaseIterable, Codable, Sendable {
    case domain = "DOMAIN"
    case domainSuffix = "DOMAIN-SUFFIX"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR"
    case ipCIDR6 = "IP-CIDR6"
    case geoIP = "GEOIP"            // reserved; not matched until GeoIP lands
    case userAgent = "USER-AGENT"   // HTTP path only
    case urlRegex = "URL-REGEX"     // HTTP path only
    case processName = "PROCESS-NAME"
    case destPort = "DEST-PORT"
    case srcIP = "SRC-IP"
    case protocolRule = "PROTOCOL"
    /// `RULE-SET,<name>,<policy>`: expand a cached remote list in place. Written
    /// by the Rule Sets pane, never by hand-picked in the rule editor.
    case ruleSet = "RULE-SET"
    case final = "FINAL"

    /// Types offered by the rule editor: everything except the ones that are
    /// either generated (`RULE-SET`) or reserved (`GEOIP`).
    public static var editorCases: [RuleType] {
        allCases.filter { $0 != .ruleSet }
    }

    /// True for rules whose value is a policy name rather than a match value.
    public var takesNoValue: Bool { self == .final }
}

/// One ordered rule from the `[Rule]` section: `TYPE,value,policy[,options]`.
public struct ProfileRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var type: RuleType
    /// Match value. Empty for `FINAL`.
    public var value: String
    /// Policy name the traffic is forwarded to when this rule matches.
    public var policy: String
    /// `no-resolve` option: skip this rule if matching would require a DNS lookup.
    public var noResolve: Bool
    /// Name of the remote rule set this rule was expanded from, when it was.
    /// Written by the matcher, never by the parser: it is provenance for the
    /// request log and the Rules pane, not part of the profile text.
    public var ruleSet: String?

    public init(
        id: UUID = UUID(),
        type: RuleType,
        value: String,
        policy: String,
        noResolve: Bool = false,
        ruleSet: String? = nil
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.policy = policy
        self.noResolve = noResolve
        self.ruleSet = ruleSet
    }

    /// Stable identity of the *rule text*, used to dedupe expanded rule sets.
    var dedupeKey: String { "\(type.rawValue)|\(value.lowercased())|\(noResolve)" }
}

// MARK: - General Settings

/// `[General]` section settings. Values mirror Surge option names where
/// applicable so profiles stay familiar.
public struct GeneralSettings: Codable, Equatable, Sendable {
    /// HTTP proxy listener, e.g. `127.0.0.1:6152`. Empty = disabled.
    public var httpListen: String
    /// SOCKS5 listener, e.g. `127.0.0.1:6153`. Empty = disabled.
    public var socks5Listen: String
    /// URL used by policy-group latency tests.
    public var testURL: String
    /// Latency test timeout in seconds.
    public var testTimeout: Int
    /// Interval (seconds) between automatic group tests.
    public var testInterval: Int
    /// When true, the engine configures the macOS system proxy.
    public var systemProxy: Bool
    /// Hosts/CIDRs that bypass the proxy entirely (skip-proxy list).
    public var skipProxy: [String]
    /// Log verbosity: `info` or `debug`.
    public var logLevel: String

    public init(
        httpListen: String = "127.0.0.1:6152",
        socks5Listen: String = "127.0.0.1:6153",
        testURL: String = "http://cp.cloudflare.com/generate_204",
        testTimeout: Int = 5,
        testInterval: Int = 600,
        systemProxy: Bool = false,
        skipProxy: [String] = GeneralSettings.defaultSkipProxy,
        logLevel: String = "info"
    ) {
        self.httpListen = httpListen
        self.socks5Listen = socks5Listen
        self.testURL = testURL
        self.testTimeout = testTimeout
        self.testInterval = testInterval
        self.systemProxy = systemProxy
        self.skipProxy = skipProxy
        self.logLevel = logLevel
    }

    /// Sensible macOS defaults: RFC1918 + loopback + link-local + multicast.
    public static let defaultSkipProxy: [String] = [
        "127.0.0.1", "192.168.0.0/16", "10.0.0.0/8", "172.16.0.0/12",
        "localhost", "*.local", "169.254.0.0/16", "224.0.0.0/4", "fe80::/10"
    ]
}

// MARK: - Profile

/// A complete Surge-style profile: general options, proxies, groups, rules.
/// `Codable` is used for in-memory snapshots (undo/backup); the on-disk format
/// is the INI text handled by `ProfileParser`/`ProfileSerializer`.
public struct Profile: Codable, Equatable, Sendable {
    public var name: String
    public var general: GeneralSettings
    public var proxies: [ProxyDefinition]
    public var groups: [ProxyGroup]
    public var rules: [ProfileRule]
    /// `[Rule Set]` entries; referenced from `rules` by name.
    public var ruleSets: [RemoteRuleSet]

    public init(
        name: String,
        general: GeneralSettings = GeneralSettings(),
        proxies: [ProxyDefinition] = [],
        groups: [ProxyGroup] = [],
        rules: [ProfileRule] = [],
        ruleSets: [RemoteRuleSet] = []
    ) {
        self.name = name
        self.general = general
        self.proxies = proxies
        self.groups = groups
        self.rules = rules
        self.ruleSets = ruleSets
    }

    /// The declared set with this name, if any.
    public func ruleSet(named name: String) -> RemoteRuleSet? {
        ruleSets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Names referenced by `RULE-SET` rules.
    public var referencedRuleSetNames: [String] {
        rules.filter { $0.type == .ruleSet }.map(\.value)
    }

    /// Points `RULE-SET,<name>` at `policy`, or removes the reference when
    /// `policy` is nil. An existing reference is replaced rather than
    /// duplicated, the rule is placed before `FINAL` so the catch-all stays
    /// last, and a no-op returns false so callers can skip a write.
    @discardableResult
    public mutating func setRuleSetReference(named name: String, policy: String?) -> Bool {
        let matches: (ProfileRule) -> Bool = {
            $0.type == .ruleSet && $0.value.caseInsensitiveCompare(name) == .orderedSame
        }

        guard let policy else {
            let before = rules.count
            rules.removeAll(where: matches)
            return rules.count != before
        }

        let referencing = rules.filter(matches)
        guard !(referencing.count == 1 && referencing[0].policy == policy) else { return false }

        if let index = rules.firstIndex(where: matches) {
            // Replace in place: an existing reference sits where the user (or a
            // previous version) put it, and moving it down to just before FINAL
            // would quietly change which rules outrank it.
            rules[index].policy = policy
            var kept = false
            rules.removeAll { rule in
                guard matches(rule) else { return false }
                defer { kept = true }
                return kept
            }
            return true
        }

        let rule = ProfileRule(type: .ruleSet, value: name, policy: policy)
        let index = rules.lastIndex(where: { $0.type == .final }) ?? rules.count
        rules.insert(rule, at: index)
        return true
    }

    /// Every policy name that exists in this profile: built-ins, proxies, groups.
    public var allPolicyNames: [String] {
        BuiltinPolicy.names + proxies.map(\.name) + groups.map(\.name)
    }

    // MARK: Validation

    public enum ValidationError: LocalizedError, Equatable, Hashable {
        case duplicatePolicyName(String)
        case invalidPolicyName(String)
        case groupSelfReference(String)
        case groupCycle(path: [String])
        case groupUnknownMember(group: String, member: String)
        case groupEmpty(String)
        case duplicateRuleID(Int)
        case ruleUnknownPolicy(index: Int, policy: String)
        case ruleSetUnknown(index: Int, name: String)
        case ruleSetDuplicateName(String)
        case ruleSetInsecureURL(name: String, url: String)
        case invalidPort(name: String, port: Int)
        case invalidListener(String)
        case invalidCIDR(String)
        case invalidDestPort(String)
        case invalidLogLevel(String)

        public var errorDescription: String? {
            switch self {
            case .duplicatePolicyName(let name):
                return "Duplicate policy name: \"\(name)\""
            case .invalidPolicyName(let name):
                return "Invalid policy name: \"\(name)\" (cannot be empty, contain commas, or be \"FINAL\")"
            case .groupSelfReference(let name):
                return "Group \"\(name)\" references itself"
            case .groupCycle(let path):
                return "Policy group cycle: " + path.joined(separator: " → ")
            case .groupUnknownMember(let group, let member):
                return "Group \"\(group)\" references unknown policy \"\(member)\""
            case .groupEmpty(let name):
                return "Group \"\(name)\" has no member policies"
            case .duplicateRuleID(let index):
                return "More than one FINAL rule (first at rule #\(index)); FINAL must appear at most once, last"
            case .ruleUnknownPolicy(let index, let policy):
                return "Rule #\(index + 1) references unknown policy \"\(policy)\""
            case .ruleSetUnknown(let index, let name):
                return "Rule #\(index + 1) references undeclared rule set \"\(name)\""
            case .ruleSetDuplicateName(let name):
                return "Duplicate rule set name: \"\(name)\""
            case .ruleSetInsecureURL(let name, let url):
                return "Rule set \"\(name)\" must use an https:// URL (got \"\(url)\")"
            case .invalidPort(let name, let port):
                return "Proxy \"\(name)\" has invalid port \(port) (expected 1–65535)"
            case .invalidListener(let value):
                return "Invalid listener address \"\(value)\" (expected host:port)"
            case .invalidCIDR(let value):
                return "Invalid CIDR value \"\(value)\""
            case .invalidDestPort(let value):
                return "Invalid DEST-PORT value \"\(value)\" (expected single port, range, or comma-separated list)"
            case .invalidLogLevel(let value):
                return "Invalid loglevel \"\(value)\" (expected info or debug)"
            }
        }
    }

    /// Validates structural integrity: unique names, resolvable references,
    /// acyclic groups, sane values. Cheap; safe to call after every parse/edit.
    public func validate() -> [ValidationError] {
        var errors: [ValidationError] = []

        // --- Policy names unique, non-empty, and not reserved ---
        var seen = Set<String>()
        for policy in proxies.map(\.name) + groups.map(\.name) {
            if policy.isEmpty || policy.contains(",") || policy == "FINAL" {
                errors.append(.invalidPolicyName(policy))
                continue
            }
            if !seen.insert(policy).inserted {
                errors.append(.duplicatePolicyName(policy))
            }
        }

        // --- Proxy ports ---
        for proxy in proxies where !(1...65535).contains(proxy.port) {
            errors.append(.invalidPort(name: proxy.name, port: proxy.port))
        }

        // --- General ---
        for listener in [general.httpListen, general.socks5Listen] where !listener.isEmpty {
            let parts = listener.split(separator: ":", maxSplits: 1)
            let portOK = parts.count == 2 && Int(parts[1]).map { (1...65535).contains($0) } == true
            if parts.isEmpty || parts[0].isEmpty || !portOK {
                errors.append(.invalidListener(listener))
            }
        }
        if !["info", "debug"].contains(general.logLevel) {
            errors.append(.invalidLogLevel(general.logLevel))
        }

        // --- Groups: non-empty, members resolvable, acyclic ---
        for group in groups {
            if group.policies.isEmpty {
                errors.append(.groupEmpty(group.name))
                continue
            }
            for member in group.policies where !allPolicyNames.contains(member) {
                errors.append(.groupUnknownMember(group: group.name, member: member))
            }
        }
        for group in groups where group.policies.contains(group.name) {
            errors.append(.groupSelfReference(group.name))
        }
        errors.append(contentsOf: detectGroupCycles())

        // --- Rules ---
        if let finalIndex = rules.lastIndex(where: { $0.type == .final }) {
            if finalIndex > 0, rules[..<finalIndex].contains(where: { $0.type == .final }) {
                errors.append(.duplicateRuleID(finalIndex))
            }
            if finalIndex != rules.count - 1 {
                errors.append(.duplicateRuleID(finalIndex)) // FINAL not last
            }
        }
        for (index, rule) in rules.enumerated() where rule.type != .final {
            if !allPolicyNames.contains(rule.policy) {
                errors.append(.ruleUnknownPolicy(index: index, policy: rule.policy))
            }
        }

        // --- Rule sets: unique names, https only, and every reference resolves ---
        var declared = Set<String>()
        for set in ruleSets {
            if !declared.insert(set.name.lowercased()).inserted {
                errors.append(.ruleSetDuplicateName(set.name))
            }
            if !RemoteRuleSet.isAllowedURLString(set.url) {
                errors.append(.ruleSetInsecureURL(name: set.name, url: set.url))
            }
        }
        for (index, rule) in rules.enumerated() where rule.type == .ruleSet {
            if ruleSet(named: rule.value) == nil {
                errors.append(.ruleSetUnknown(index: index, name: rule.value))
            }
        }

        return errors
    }

    /// Detects reference cycles among groups via DFS.
    private func detectGroupCycles() -> [ValidationError] {
        var errors: [ValidationError] = []
        var reported = Set<[String]>()
        var visiting = Set<String>()
        let groupNames = Set(groups.map(\.name))

        func visit(_ name: String, path: [String]) {
            guard !reported.contains(path) else { return }
            if visiting.contains(name) {
                // Trim path to start at the first occurrence of `name`.
                if let start = path.firstIndex(of: name) {
                    let cycle = Array(path[start...]) + [name]
                    if reported.insert(cycle).inserted {
                        errors.append(.groupCycle(path: cycle))
                    }
                }
                return
            }
            guard let group = groups.first(where: { $0.name == name }) else { return }
            visiting.insert(name)
            for member in group.policies where groupNames.contains(member) {
                visit(member, path: path + [name])
            }
            visiting.remove(name)
        }

        for group in groups { visit(group.name, path: []) }
        return errors
    }
}
