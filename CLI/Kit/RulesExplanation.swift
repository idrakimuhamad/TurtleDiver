import Foundation
import TurtleDiverCore
import TurtleDiverRules

/// "Why does this host go where it goes?"
///
/// The answer the app can only give by clicking: the rule that matched, the
/// policy it names, and — after the policy store has resolved it — the upstream
/// the traffic actually uses. Pure apart from reading the profile and its cached
/// rule sets, so the whole answer is testable from a fixture profile.
///
/// Rule sets are read from the on-disk cache. A set that was never downloaded is
/// reported as unresolved, never fetched: a CLI that reaches the network to
/// answer a question is a surprise, and this one is documented not to.
public struct RulesExplanation: Equatable {
    public struct MatchedRule: Equatable {
        public let type: String
        public let value: String
        public let policy: String
        /// The remote set this rule came from, when it was expanded from one.
        public let ruleSet: String?
    }

    public let host: String
    public let port: Int?
    public let profileName: String
    /// The policy name the matched rule points at, or the profile's default.
    public let policy: String
    public let matched: MatchedRule?
    /// `DIRECT`, `REJECT`, or `<type> <host>:<port>` after resolution.
    public let decision: String
    /// The member a `select`/`url-test` group resolved to, when it was a group.
    public let selectedMember: String?
    public let performedDNS: Bool
    public let unresolvedRuleSets: [String]

    public init(
        host: String,
        port: Int?,
        profileName: String,
        policy: String,
        matched: MatchedRule?,
        decision: String,
        selectedMember: String?,
        performedDNS: Bool,
        unresolvedRuleSets: [String]
    ) {
        self.host = host
        self.port = port
        self.profileName = profileName
        self.policy = policy
        self.matched = matched
        self.decision = decision
        self.selectedMember = selectedMember
        self.performedDNS = performedDNS
        self.unresolvedRuleSets = unresolvedRuleSets
    }

    /// Resolves the policy to the concrete destination, reusing the app's
    /// `PolicyStore` so a group picks the same member the app would.
    public static func explain(
        host: String,
        port: Int?,
        profileName: String,
        directory: ProfileDirectory = ProfileDirectory(),
        defaults: UserDefaults? = AppSettings.appDefaults(),
        ruleSets: [String: [ProfileRule]]? = nil
    ) throws -> RulesExplanation {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw CLIFailure.usage("rules explain needs a host or IP address")
        }
        guard let parsed = directory.load(named: profileName) else {
            throw CLIFailure.notConfigured(
                "no profile named \"\(profileName)\" in \(directory.directory.path)"
            )
        }
        let profile = parsed.profile
        let cached = ruleSets ?? RuleSetStore().rulesBySet(for: profile)
        let matcher = RuleMatcher(profile: profile, ruleSets: cached)

        let outcome = try matcher.match(MatchContext(host: trimmedHost, port: port))

        // The store is what turns "Proxy" into the upstream that "Proxy" means
        // today; the matcher on its own stops at the name.
        let store = PolicyStore(profile: profile, defaults: defaults, autoStartTesting: false)
        var decision = outcome.policy
        var selectedMember: String?
        if let resolved = try? store.resolve(outcome.policy) {
            switch resolved {
            case .direct:
                decision = "DIRECT"
            case .reject:
                decision = "REJECT"
            case .proxy(let definition):
                decision = "\(definition.type.rawValue) \(definition.host):\(definition.port)"
                // For a `select` group, name the member that was chosen, so
                // "which of the three proxies" has an answer too.
                if let group = profile.groups.first(where: { $0.name == outcome.policy }) {
                    selectedMember = store.selectMember(for: group)
                }
            }
        }

        let matched = outcome.rule.map {
            MatchedRule(type: $0.type.rawValue, value: $0.value, policy: $0.policy, ruleSet: $0.ruleSet)
        }

        return RulesExplanation(
            host: trimmedHost,
            port: port,
            profileName: profileName,
            policy: outcome.policy,
            matched: matched,
            decision: decision,
            selectedMember: selectedMember,
            performedDNS: outcome.performedDNS,
            unresolvedRuleSets: matcher.unresolvedRuleSetNames
        )
    }

    public var jsonObject: [String: Any] {
        var body: [String: Any] = [
            "ok": true,
            "host": host,
            "profile": profileName,
            "policy": policy,
            "decision": decision,
            "resolvedByDNS": performedDNS,
        ]
        if let port { body["port"] = port }
        if let matched {
            var rule: [String: Any] = ["type": matched.type, "value": matched.value, "policy": matched.policy]
            if let set = matched.ruleSet { rule["ruleSet"] = set }
            body["rule"] = rule
        } else {
            body["rule"] = NSNull()
            body["matchedBy"] = "no rule matched; the profile's default applies"
        }
        if let selectedMember { body["selectedMember"] = selectedMember }
        if !unresolvedRuleSets.isEmpty { body["unresolvedRuleSets"] = unresolvedRuleSets }
        return body
    }

    public var humanLines: [String] {
        var lines: [String] = []
        if let matched {
            let provenance = matched.ruleSet.map { " (from rule set \($0))" } ?? ""
            lines.append("\(matched.type),\(matched.value) → \(matched.policy)\(provenance)")
        } else {
            lines.append("no rule matched; the profile's default applies")
        }
        lines.append("policy \(policy) resolves to \(decision)"
            + (selectedMember.map { " (member: \($0))" } ?? ""))
        if performedDNS {
            lines.append("note: matching resolved \(host) with DNS")
        }
        if !unresolvedRuleSets.isEmpty {
            lines.append("warning: rule sets with no cached rules (they cannot match): "
                + unresolvedRuleSets.joined(separator: ", "))
        }
        return lines
    }
}
