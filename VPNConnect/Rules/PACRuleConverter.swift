import Foundation

// Profile types (Profile, ProfileRule, ProxyDefinition, ProxyGroup) live in
// the Profile sources: one module in the app target, the TurtleDiverCore
// module under `swift test`.
#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif

// MARK: - Conversion Result

/// Output of converting a PAC (`FindProxyForURL`) script into Surge-style
/// rules and policies. Purely derived data — `apply(_:to:)` folds it into a
/// `Profile`.
public struct PACConversionResult: Sendable {
    /// Ordered rules to insert (excludes `FINAL`).
    public var rules: [ProfileRule]
    /// New upstream proxies discovered in PAC return values.
    public var proxies: [ProxyDefinition]
    /// Fallback groups created for multi-upstream return values.
    public var groups: [ProxyGroup]
    /// Policy for traffic nothing matched (the PAC's default return), or nil
    /// when the PAC had no explicit/default branch.
    public var fallbackPolicy: String?
    /// Human-readable notes: unsupported conditions, approximations, etc.
    public var diagnostics: [String]

    public init(
        rules: [ProfileRule] = [],
        proxies: [ProxyDefinition] = [],
        groups: [ProxyGroup] = [],
        fallbackPolicy: String? = nil,
        diagnostics: [String] = []
    ) {
        self.rules = rules
        self.proxies = proxies
        self.groups = groups
        self.fallbackPolicy = fallbackPolicy
        self.diagnostics = diagnostics
    }

    /// True when nothing usable was extracted.
    public var isEmpty: Bool {
        rules.isEmpty && proxies.isEmpty && groups.isEmpty && fallbackPolicy == nil
    }
}

// MARK: - Intermediate Types

/// One condition → match mapping. `value` is already normalized.
struct PACConditionMatch: Equatable {
    var type: RuleType
    var value: String
}

/// One `return "…"` from the PAC, together with the `if` condition guarding
/// it (nil = the default branch, including a bare `else`).
struct PACStatement: Equatable {
    var condition: String?
    var isElse: Bool
    var result: String
}

// MARK: - Converter

/// Statically converts the common shapes of a PAC script into TurtleDiver
/// rules. PAC is arbitrary JavaScript, so no converter can be complete; this
/// handles the constructs that appear in virtually every real PAC file:
///
/// | PAC expression | Rule |
/// |---|---|
/// | `shExpMatch(host, "*.example.com")` | `DOMAIN-SUFFIX,example.com` |
/// | `shExpMatch(host, "example.com")` | `DOMAIN,example.com` |
/// | `shExpMatch(url, "*://example.com/*")` | `DOMAIN,example.com` |
/// | `dnsDomainIs(host, ".example.com")` | `DOMAIN-SUFFIX,example.com` |
/// | `localHostOrDomainIs(host, "example.com")` | `DOMAIN-SUFFIX,example.com` |
/// | `host == "example.com"` | `DOMAIN,example.com` |
/// | `isInNet(host, "10.0.0.0", "255.0.0.0")` | `IP-CIDR,10.0.0.0/8` |
/// | `isInNet(dnsResolve(host), "10.0.0.0", "255.0.0.0")` | `IP-CIDR,10.0.0.0/8` |
///
/// `||` alternatives expand into separate rules (same policy). Unsupported
/// conditions (`&&`, negation, `isPlainHostName`, unknown functions) are
/// reported in `diagnostics` and skipped — the import is never blocked by a
/// construct the converter doesn't understand.
///
/// Return values are parsed into policies:
/// - `DIRECT` → `DIRECT`
/// - `PROXY host:port` / `HTTP …` → a `http` proxy
/// - `HTTPS host:port` → an `https` proxy
/// - `SOCKS …` / `SOCKS5 …` → a `socks5` proxy
/// - `"PROXY a; PROXY b; DIRECT"` → a `fallback` group over those policies
public enum PACRuleConverter {

    // MARK: Public API

    /// Converts PAC source into rules/policies. `existingProxies` /
    /// `existingGroups` are matched so re-imports reuse policies instead of
    /// duplicating them (pass the target profile's lists).
    public static func convert(
        pacSource: String,
        existingProxies: [ProxyDefinition] = [],
        existingGroups: [ProxyGroup] = []
    ) -> PACConversionResult {
        var diagnostics: [String] = []
        let cleaned = stripComments(pacSource)
        let statements = scanStatements(cleaned)

        var extracted: [(PACConditionMatch, String)] = []
        var defaultResult: String?

        for statement in statements {
            if let condition = statement.condition {
                let matched = matches(forCondition: condition, diagnostics: &diagnostics)
                if matched.isEmpty {
                    diagnostics.append("Skipped condition (no rule equivalent): \(condition.trimmingCharacters(in: .whitespaces))")
                }
                for match in matched { extracted.append((match, statement.result)) }
            } else {
                defaultResult = statement.result
            }
        }

        // First match wins (PAC semantics): drop later duplicates of the same
        // (type, value) pair before resolving policies, so we don't mint
        // unused proxies.
        var deduped: [(PACConditionMatch, String)] = []
        var seenMatches = Set<String>()
        for (match, result) in extracted {
            let signature = "\(match.type.rawValue),\(match.value.lowercased())"
            if seenMatches.insert(signature).inserted { deduped.append((match, result)) }
        }

        let resolver = PolicyResolver(existingProxies: existingProxies, existingGroups: existingGroups)

        var rules: [ProfileRule] = []
        for (match, result) in deduped {
            guard let policy = resolver.resolve(result: result) else { continue }
            rules.append(ProfileRule(type: match.type, value: match.value, policy: policy))
        }

        let fallbackPolicy = defaultResult.flatMap { resolver.resolve(result: $0) }

        return PACConversionResult(
            rules: rules,
            proxies: resolver.newProxies,
            groups: resolver.newGroups,
            fallbackPolicy: fallbackPolicy,
            diagnostics: diagnostics + resolver.diagnostics
        )
    }

    /// Folds a conversion result into `profile`: appends new policies, inserts
    /// the rules before `FINAL` (so existing user rules keep priority), and
    /// points `FINAL` at the PAC default when there was one.
    public static func apply(_ result: PACConversionResult, to profile: Profile) -> Profile {
        var updated = profile

        for proxy in result.proxies where !updated.proxies.contains(where: { sameServer($0, proxy) }) {
            updated.proxies.append(proxy)
        }
        for group in result.groups where !updated.groups.contains(where: { $0.name == group.name }) {
            updated.groups.append(group)
        }

        var rules = updated.rules
        let insertAt = rules.lastIndex(where: { $0.type == .final }) ?? rules.count
        var existing = Set(rules.map(ruleSignature))
        var inserted: [ProfileRule] = []
        for rule in result.rules {
            let signature = ruleSignature(rule)
            if existing.insert(signature).inserted { inserted.append(rule) }
        }
        rules.insert(contentsOf: inserted, at: insertAt)

        if let fallback = result.fallbackPolicy, let finalIndex = rules.lastIndex(where: { $0.type == .final }) {
            rules[finalIndex].policy = fallback
        }
        if !rules.contains(where: { $0.type == .final }) {
            rules.append(ProfileRule(
                type: .final,
                value: "",
                policy: result.fallbackPolicy ?? BuiltinPolicy.direct.rawValue
            ))
        }

        updated.rules = rules
        return updated
    }

    // MARK: Policy resolution

    /// Resolves PAC return strings into policy names, creating/looking up
    /// concrete proxies and fallback groups along the way.
    private final class PolicyResolver {
        var existingProxies: [ProxyDefinition]
        let existingGroups: [ProxyGroup]
        var diagnostics: [String] = []
        var newProxies: [ProxyDefinition] = []
        var newGroups: [ProxyGroup] = []

        init(existingProxies: [ProxyDefinition], existingGroups: [ProxyGroup]) {
            self.existingProxies = existingProxies
            self.existingGroups = existingGroups
        }

        func resolve(result: String) -> String? {
            let tokens = result
                .split(separator: ";")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return nil }

            var policyNames: [String] = []
            for token in tokens {
                let upper = token.uppercased()
                if upper == "DIRECT" {
                    policyNames.append(BuiltinPolicy.direct.rawValue)
                    continue
                }
                guard let space = token.firstIndex(of: " ") else {
                    diagnostics.append("Unrecognized PAC directive: \(token)")
                    continue
                }
                let typeWord = token[..<space].uppercased()
                let endpoint = String(token[token.index(after: space)...]).trimmingCharacters(in: .whitespaces)
                guard let proxyType = proxyType(for: typeWord) else {
                    diagnostics.append("Unrecognized PAC proxy type: \(token)")
                    continue
                }
                guard let (host, port) = parseEndpoint(endpoint) else {
                    diagnostics.append("Invalid PAC proxy endpoint: \(token)")
                    continue
                }
                policyNames.append(resolveProxy(type: proxyType, host: host, port: port))
            }

            switch policyNames.count {
            case 0:
                return nil
            case 1:
                return policyNames[0]
            default:
                return resolveGroup(members: policyNames)
            }
        }

        private func resolveProxy(type: ProxyType, host: String, port: Int) -> String {
            if let existing = existingProxies.first(where: {
                $0.type == type && $0.port == port && $0.host.caseInsensitiveCompare(host) == .orderedSame
            }) {
                return existing.name
            }
            let name = uniqueProxyName(type: type, host: host, port: port)
            let proxy = ProxyDefinition(name: name, type: type, host: host, port: port)
            existingProxies.append(proxy)
            newProxies.append(proxy)
            return name
        }

        private func resolveGroup(members: [String]) -> String {
            if let existing = existingGroups.first(where: { $0.type == .fallback && $0.policies == members }) {
                return existing.name
            }
            if let existing = newGroups.first(where: { $0.policies == members }) {
                return existing.name
            }
            var index = 1
            var name = "PAC Fallback"
            let taken = Set(existingGroups.map(\.name) + newGroups.map(\.name))
            while taken.contains(name) {
                index += 1
                name = "PAC Fallback \(index)"
            }
            let group = ProxyGroup(name: name, type: .fallback, policies: members)
            newGroups.append(group)
            return name
        }

        private func uniqueProxyName(type: ProxyType, host: String, port: Int) -> String {
            let base = "\(host):\(port)"
            let taken = Set(existingProxies.map(\.name) + newProxies.map(\.name))
            if !taken.contains(base) { return base }
            let typed = "\(base) (\(type.rawValue))"
            if !taken.contains(typed) { return typed }
            var index = 2
            var candidate = "\(typed) \(index)"
            while taken.contains(candidate) {
                index += 1
                candidate = "\(typed) \(index)"
            }
            return candidate
        }
    }

    private static func proxyType(for word: String) -> ProxyType? {
        switch word {
        case "PROXY", "HTTP": return .http
        case "HTTPS": return .https
        case "SOCKS", "SOCKS4", "SOCKS5": return .socks5
        default: return nil
        }
    }

    private static func parseEndpoint(_ text: String) -> (host: String, port: Int)? {
        // Bracketed IPv6: [::1]:8080
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
            return (host, port)
        }
        guard let colon = text.lastIndex(of: ":") else { return nil }
        let host = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        let portText = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else { return nil }
        return (host, port)
    }

    private static func sameServer(_ a: ProxyDefinition, _ b: ProxyDefinition) -> Bool {
        a.type == b.type && a.port == b.port && a.host.caseInsensitiveCompare(b.host) == .orderedSame
    }

    private static func ruleSignature(_ rule: ProfileRule) -> String {
        "\(rule.type.rawValue),\(rule.value.lowercased()),\(rule.policy)"
    }

    // MARK: Condition matching

    static func matches(forCondition rawCondition: String, diagnostics: inout [String]) -> [PACConditionMatch] {
        let condition = stripOuterParens(rawCondition.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !condition.isEmpty else { return [] }
        if condition.hasPrefix("!") {
            diagnostics.append("Negated condition not convertible: \(condition)")
            return []
        }

        let alternatives = splitTopLevel(condition, separator: "||")
        if alternatives.count > 1 {
            return alternatives.flatMap { matches(forCondition: $0, diagnostics: &diagnostics) }
        }
        if splitTopLevel(condition, separator: "&&").count > 1 {
            diagnostics.append("Compound (&&) condition not convertible: \(condition)")
            return []
        }
        return matchesForSingle(condition, diagnostics: &diagnostics)
    }

    private static func matchesForSingle(_ condition: String, diagnostics: inout [String]) -> [PACConditionMatch] {
        if let call = parseCall(condition) {
            if let match = matchCall(name: call.name.lowercased(), args: call.args, diagnostics: &diagnostics) {
                return [match]
            }
            return []
        }
        if let match = matchComparison(condition, diagnostics: &diagnostics) {
            return [match]
        }
        diagnostics.append("Unsupported condition: \(condition)")
        return []
    }

    private static func matchCall(name: String, args: [String], diagnostics: inout [String]) -> PACConditionMatch? {
        switch name {
        case "shexpmatch":
            guard args.count >= 2, let pattern = unquote(args[1]) else {
                diagnostics.append("shExpMatch with non-literal pattern not convertible")
                return nil
            }
            return domainMatch(pattern: pattern, diagnostics: &diagnostics)

        case "dnsdomainis", "dnsdomainissuffix", "localhostordomainis":
            guard args.count >= 2, let domain = unquote(args[1]) else {
                diagnostics.append("\(name) with non-literal domain not convertible")
                return nil
            }
            return suffixMatch(domain: domain, diagnostics: &diagnostics)

        case "isinnet":
            return inNetMatch(args, diagnostics: &diagnostics)

        case "isplainhostname":
            diagnostics.append("isPlainHostName(host) matches dot-less hosts and has no rule equivalent; skipped")
            return nil

        default:
            return nil
        }
    }

    /// `shExpMatch` pattern → domain rule. Handles scheme/path/wildcards.
    static func domainMatch(pattern raw: String, diagnostics: inout [String]) -> PACConditionMatch? {
        var pattern = raw.trimmingCharacters(in: .whitespaces).lowercased()

        if let scheme = pattern.range(of: "://") {
            pattern = String(pattern[scheme.upperBound...])
        }
        if let at = pattern.firstIndex(of: "@") {
            pattern = String(pattern[pattern.index(after: at)...])
        }
        if let slash = pattern.firstIndex(of: "/") {
            pattern = String(pattern[..<slash])
        }
        if let query = pattern.firstIndex(of: "?") {
            pattern = String(pattern[..<query])
        }
        if let colon = pattern.lastIndex(of: ":"), !pattern.contains("]") {
            let after = pattern[pattern.index(after: colon)...]
            if !after.isEmpty, after.allSatisfy({ $0.isNumber }) {
                pattern = String(pattern[..<colon])
            }
        }
        pattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !pattern.isEmpty else { return nil }

        if !pattern.contains("*") {
            guard isValidHost(pattern) else {
                diagnostics.append("Invalid host in PAC pattern: \(raw)")
                return nil
            }
            return PACConditionMatch(type: .domain, value: pattern)
        }

        if pattern.hasPrefix("*.") {
            let rest = String(pattern.dropFirst(2))
            if !rest.contains("*"), isValidHost(rest) {
                return PACConditionMatch(type: .domainSuffix, value: rest)
            }
        }
        if pattern.hasPrefix("*") {
            var rest = String(pattern.dropFirst())
            if rest.hasPrefix(".") { rest = String(rest.dropFirst()) }
            if !rest.contains("*"), isValidHost(rest) {
                return PACConditionMatch(type: .domainSuffix, value: rest)
            }
        }
        if pattern.hasSuffix("*") {
            let rest = String(pattern.dropLast())
            if !rest.contains("*"), isValidHost(rest) {
                return PACConditionMatch(type: .domainSuffix, value: rest)
            }
        }

        // Wildcard in the middle: approximate with the longest dotted segment.
        let segments = pattern
            .split(separator: "*")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { $0.contains(".") }
        if let longest = segments.max(by: { $0.count < $1.count }), isValidHost(longest) {
            diagnostics.append("Pattern \"\(raw)\" approximated as DOMAIN-KEYWORD,\(longest)")
            return PACConditionMatch(type: .domainKeyword, value: longest)
        }
        diagnostics.append("Could not convert PAC pattern: \(raw)")
        return nil
    }

    private static func suffixMatch(domain raw: String, diagnostics: inout [String]) -> PACConditionMatch? {
        var domain = raw.lowercased()
        if domain.hasPrefix(".") { domain = String(domain.dropFirst()) }
        guard isValidHost(domain) else {
            diagnostics.append("Invalid domain in PAC condition: \(raw)")
            return nil
        }
        return PACConditionMatch(type: .domainSuffix, value: domain)
    }

    private static func inNetMatch(_ args: [String], diagnostics: inout [String]) -> PACConditionMatch? {
        guard args.count >= 3,
              let ipText = unquote(args[1]),
              let maskText = unquote(args[2]) else {
            diagnostics.append("isInNet with non-literal arguments not convertible")
            return nil
        }
        guard let ip = IPAddress.parse(ipText) else {
            diagnostics.append("isInNet has invalid address \(ipText)")
            return nil
        }
        guard let prefix = prefixLength(fromMask: maskText, isIPv4: ip.isIPv4) else {
            diagnostics.append("isInNet netmask \(maskText) is not a contiguous CIDR mask; skipped")
            return nil
        }
        return PACConditionMatch(type: ip.isIPv4 ? .ipCIDR : .ipCIDR6, value: "\(ip.text)/\(prefix)")
    }

    private static func matchComparison(_ condition: String, diagnostics: inout [String]) -> PACConditionMatch? {
        for op in ["===", "=="] {
            let parts = splitTopLevel(condition, separator: op)
            guard parts.count == 2 else { continue }
            let left = parts[0].trimmingCharacters(in: .whitespaces)
            let right = parts[1].trimmingCharacters(in: .whitespaces)
            if let literal = unquote(left), right.lowercased().contains("host") {
                return exactDomain(literal, diagnostics: &diagnostics)
            }
            if let literal = unquote(right), left.lowercased().contains("host") {
                return exactDomain(literal, diagnostics: &diagnostics)
            }
            diagnostics.append("Comparison not convertible: \(condition)")
            return nil
        }
        return nil
    }

    private static func exactDomain(_ raw: String, diagnostics: inout [String]) -> PACConditionMatch? {
        let domain = raw.lowercased()
        guard isValidHost(domain) else {
            diagnostics.append("Invalid domain in comparison: \(raw)")
            return nil
        }
        return PACConditionMatch(type: .domain, value: domain)
    }

    /// Converts a dotted netmask into a prefix length; nil when the mask has
    /// non-contiguous bits.
    static func prefixLength(fromMask mask: String, isIPv4: Bool) -> Int? {
        guard let parsed = IPAddress.parse(mask), parsed.isIPv4 == isIPv4 else { return nil }
        var count = 0
        var sawZero = false
        for byte in parsed.bytes {
            var bit: UInt8 = 0x80
            for _ in 0..<8 {
                if byte & bit != 0 {
                    if sawZero { return nil }
                    count += 1
                } else {
                    sawZero = true
                }
                bit >>= 1
            }
        }
        return count
    }

    // MARK: Scanning helpers

    static func parseStatements(_ source: String) -> [PACStatement] {
        scanStatements(stripComments(source))
    }

    static func scanStatements(_ source: String) -> [PACStatement] {
        let chars = Array(source)
        var statements: [PACStatement] = []
        var index = 0
        var pendingCondition: String?
        var afterElse = false

        while index < chars.count {
            if matchWord(chars, at: index, "if") {
                var cursor = index + 2
                skipWhitespace(chars, &cursor)
                if cursor < chars.count, chars[cursor] == "(", let end = matchParens(chars, from: cursor) {
                    pendingCondition = String(chars[(cursor + 1)..<end])
                    afterElse = false
                    index = end + 1
                    continue
                }
                index += 2
                continue
            }
            if matchWord(chars, at: index, "else") {
                afterElse = true
                index += 4
                continue
            }
            if matchWord(chars, at: index, "return") {
                var cursor = index + 6
                skipWhitespace(chars, &cursor)
                if let (value, end) = readString(chars, from: cursor) {
                    if let condition = pendingCondition {
                        statements.append(PACStatement(condition: condition, isElse: false, result: value))
                    } else {
                        statements.append(PACStatement(condition: nil, isElse: afterElse, result: value))
                    }
                    pendingCondition = nil
                    afterElse = false
                    index = end
                    continue
                }
                index += 6
                continue
            }
            // A statement boundary clears a condition whose `if` had no
            // `return` (e.g. `if (x) { y(); }`), so a later bare return is
            // not mis-attributed.
            if chars[index] == ";" || chars[index] == "}" { pendingCondition = nil }
            index += 1
        }
        return statements
    }

    static func stripComments(_ source: String) -> String {
        let chars = Array(source)
        var output = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" || char == "'" {
                let quote = char
                output.append(char)
                index += 1
                while index < chars.count {
                    let next = chars[index]
                    output.append(next)
                    if next == "\\", index + 1 < chars.count {
                        output.append(chars[index + 1])
                        index += 2
                        continue
                    }
                    index += 1
                    if next == quote { break }
                }
                continue
            }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
                continue
            }
            if char == "/", index + 1 < chars.count, chars[index + 1] == "*" {
                index += 2
                while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") { index += 1 }
                index += 2
                continue
            }
            output.append(char)
            index += 1
        }
        return output
    }

    /// Splits on a separator that occurs at bracket depth 0 and outside string
    /// literals.
    static func splitTopLevel(_ text: String, separator: String) -> [String] {
        let chars = Array(text)
        let separatorChars = Array(separator)
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inString: Character?
        var index = 0

        while index < chars.count {
            let char = chars[index]
            if let quote = inString {
                current.append(char)
                if char == "\\", index + 1 < chars.count {
                    current.append(chars[index + 1])
                    index += 2
                    continue
                }
                if char == quote { inString = nil }
                index += 1
                continue
            }
            if char == "\"" || char == "'" {
                inString = char
                current.append(char)
                index += 1
                continue
            }
            if char == "(" { depth += 1 }
            if char == ")" { depth -= 1 }
            if depth == 0, index + separatorChars.count <= chars.count,
               Array(chars[index..<(index + separatorChars.count)]) == separatorChars {
                parts.append(current)
                current = ""
                index += separatorChars.count
                continue
            }
            current.append(char)
            index += 1
        }
        parts.append(current)
        return parts
    }

    static func stripOuterParens(_ text: String) -> String {
        var result = text
        while result.hasPrefix("("), result.hasSuffix(")") {
            let chars = Array(result)
            guard matchParens(chars, from: 0) == chars.count - 1 else { break }
            result = String(chars[1..<(chars.count - 1)]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Parses `name(arg, arg, …)` into a function/method name and raw argument
    /// strings. Returns nil when the text isn't a single trailing call (e.g. a
    /// comparison after the closing paren).
    static func parseCall(_ text: String) -> (name: String, args: [String])? {
        guard let open = text.firstIndex(of: "("), text.hasSuffix(")") else { return nil }
        let name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "." }) else {
            return nil
        }
        let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        return (name, splitTopLevel(inner, separator: ","))
    }

    /// Returns the string literal value when `text` is exactly one quoted
    /// string.
    static func unquote(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let chars = Array(trimmed)
        guard let (value, end) = readString(chars, from: 0), end == chars.count else { return nil }
        return value
    }

    static func readString(_ chars: [Character], from index: Int) -> (value: String, end: Int)? {
        guard index < chars.count, chars[index] == "\"" || chars[index] == "'" else { return nil }
        let quote = chars[index]
        var value = ""
        var cursor = index + 1
        while cursor < chars.count {
            let char = chars[cursor]
            if char == "\\", cursor + 1 < chars.count {
                value.append(chars[cursor + 1])
                cursor += 2
                continue
            }
            if char == quote { return (value, cursor + 1) }
            value.append(char)
            cursor += 1
        }
        return nil
    }

    /// Index of the `)` matching the `(` at `from`, honoring nested parens and
    /// string literals.
    static func matchParens(_ chars: [Character], from index: Int) -> Int? {
        guard index < chars.count, chars[index] == "(" else { return nil }
        var depth = 0
        var inString: Character?
        var cursor = index
        while cursor < chars.count {
            let char = chars[cursor]
            if let quote = inString {
                if char == "\\" { cursor += 2; continue }
                if char == quote { inString = nil }
            } else {
                if char == "\"" || char == "'" { inString = char }
                else if char == "(" { depth += 1 }
                else if char == ")" {
                    depth -= 1
                    if depth == 0 { return cursor }
                }
            }
            cursor += 1
        }
        return nil
    }

    private static func matchWord(_ chars: [Character], at index: Int, _ word: String) -> Bool {
        let wordChars = Array(word)
        guard index + wordChars.count <= chars.count else { return false }
        for offset in 0..<wordChars.count where chars[index + offset] != wordChars[offset] { return false }
        if index > 0, isIdentifier(chars[index - 1]) { return false }
        if index + wordChars.count < chars.count, isIdentifier(chars[index + wordChars.count]) { return false }
        return true
    }

    private static func isIdentifier(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_" || char == "$"
    }

    private static func skipWhitespace(_ chars: [Character], _ index: inout Int) {
        while index < chars.count, chars[index].isWhitespace { index += 1 }
    }

    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels where label.isEmpty || label.hasPrefix("-") || label.hasSuffix("-") {
            return false
        }
        if let last = labels.last, last.allSatisfy(\.isNumber) { return false }
        return true
    }
}
