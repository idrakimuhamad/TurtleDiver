import Foundation

// MARK: - Remote rule set

/// One entry of the `[Rule Set]` section: a list of rules that lives on the
/// internet and is referenced from `[Rule]` with `RULE-SET,<name>,<policy>`.
///
/// ```ini
/// [Rule Set]
/// Sukkaw = https://raw.githubusercontent.com/SukkaW/Surge/master/...conf, interval=86400
///
/// [Rule]
/// RULE-SET,Sukkaw,ProxyA
/// FINAL,DIRECT
/// ```
///
/// The rules themselves are *not* part of the profile: they are cached under
/// `Application Support/TurtleDiver/RuleSets/` and refreshed on request (or on
/// `interval`). Rule sets are a supply chain, so the rules here are strict:
/// HTTPS only, one hard size cap, never executed — only ever parsed as text.
public struct RemoteRuleSet: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Name used by `RULE-SET` rules. Unique within a profile.
    public var name: String
    /// `https://…` URL of the rule list.
    public var url: String
    /// Seconds between refreshes. `nil` means "only when the user asks".
    public var interval: Int?

    public init(id: UUID = UUID(), name: String, url: String, interval: Int? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.interval = interval
    }

    /// `id` is deliberately not compared: it is a local SwiftUI identity that
    /// never reaches the profile text, so a parse of the serialized form must
    /// equal the set that was written.
    public static func == (lhs: RemoteRuleSet, rhs: RemoteRuleSet) -> Bool {
        lhs.name == rhs.name && lhs.url == rhs.url && lhs.interval == rhs.interval
    }

    // MARK: Parsing

    /// Parses the value half of `Name = url[, interval=seconds]`.
    ///
    /// Returns the set plus a diagnostic message when the line cannot be used,
    /// so `ProfileParser` can report *why* rather than silently dropping it.
    public static func parseValue(_ value: String, name: String) -> (set: RemoteRuleSet?, error: String?) {
        let parts = ProfileParser.splitTopLevel(value)
        guard let rawURL = parts.first?.trimmingCharacters(in: .whitespaces), !rawURL.isEmpty else {
            return (nil, "Rule set \"\(name)\" has no URL")
        }

        var interval: Int?
        for option in parts.dropFirst() {
            let (key, optionValue) = splitOption(option)
            switch key {
            case "interval":
                if let seconds = Int(optionValue), seconds > 0 {
                    interval = seconds
                } else {
                    return (nil, "Rule set \"\(name)\" has an invalid interval \"\(optionValue)\" (expected seconds)")
                }
            default:
                return (nil, "Rule set \"\(name)\" has an unknown option \"\(key)\"")
            }
        }

        guard isAllowedURLString(rawURL) else {
            return (nil, "Rule set \"\(name)\" must use an https:// URL (got \"\(rawURL)\")")
        }

        return (RemoteRuleSet(name: name, url: rawURL, interval: interval), nil)
    }

    /// Only `https` is fetched. `http` would let the network rewrite the rules
    /// that decide where traffic goes, and anything else is not a web URL.
    public static func isAllowedURLString(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" && (url.host?.isEmpty == false)
    }

    private static func splitOption(_ option: String) -> (key: String, value: String) {
        guard let eq = option.firstIndex(of: "=") else { return (option.lowercased(), "") }
        return (
            option[..<eq].trimmingCharacters(in: .whitespaces).lowercased(),
            option[option.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        )
    }

    // MARK: Cache identity

    /// Stable, filesystem-safe name for this set's cache files.
    ///
    /// Two sets that differ only in name still get different files (the hash is
    /// over the URL), and a set whose URL changes gets a fresh file instead of
    /// serving the old list. The slug is only there so a human can tell the
    /// files apart in Finder; it is never used for lookup.
    public var cacheFileName: String { "\(slug)-\(urlHash)" }

    /// Lowercased, hyphenated, length-capped version of `name`.
    var slug: String {
        var out = ""
        var lastWasDash = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= 32 { break }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "set" : trimmed
    }

    /// FNV-1a, 64-bit, hex. Not a security hash — it only has to be stable and
    /// collision-resistant enough for a directory of rule sets. Collisions are
    /// detected anyway: the sidecar records the URL and a mismatch is treated
    /// as "not cached".
    var urlHash: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Cached state

/// The sidecar written next to a cached rule body. Also the record the Rule
/// Sets pane (and the matcher) reads to know how old a list is.
public struct RuleSetCacheEntry: Codable, Equatable, Sendable {
    public var name: String
    public var url: String
    public var etag: String?
    public var lastModified: String?
    /// When the stored body was last *confirmed* (a 304 counts).
    public var fetchedAt: Date
    /// Rules the body parsed into last time.
    public var ruleCount: Int
    /// Lines that could not be parsed last time.
    public var skippedCount: Int
    public var byteCount: Int

    public init(
        name: String,
        url: String,
        etag: String? = nil,
        lastModified: String? = nil,
        fetchedAt: Date,
        ruleCount: Int,
        skippedCount: Int,
        byteCount: Int
    ) {
        self.name = name
        self.url = url
        self.etag = etag
        self.lastModified = lastModified
        self.fetchedAt = fetchedAt
        self.ruleCount = ruleCount
        self.skippedCount = skippedCount
        self.byteCount = byteCount
    }

    public func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(fetchedAt) }

    /// Older than the set's own interval. A set without an interval never goes
    /// stale on its own — it is only ever refreshed when the user asks.
    public func isStale(interval: Int?, now: Date = Date()) -> Bool {
        guard let interval, interval > 0 else { return false }
        return age(now: now) > TimeInterval(interval)
    }
}

// MARK: - Body parser

/// Parses the *body* of a remote rule list into `ProfileRule`s.
///
/// Surge rule-set format is a plain list of rules without the policy that will
/// be applied to them:
///
/// ```
/// # comments, and blank lines, are ignored
/// DOMAIN-SUFFIX,example.com
/// IP-CIDR,10.0.0.0/8,no-resolve
/// ```
///
/// A line may carry a policy (`DOMAIN,example.com,ProxyA`), which is kept but
/// loses to the policy on the `RULE-SET` reference. `FINAL` and nested
/// `RULE-SET` lines are rejected: a rule set is not allowed to end the profile
/// or to reference another set.
public enum RuleSetParser {
    /// Guard against a pathological list: 8 MB of text is capped by the store,
    /// this caps the *rule* count the matcher will ever hold.
    public static let maxRules = 100_000

    public struct Skipped: Equatable, Sendable {
        public var line: Int
        public var text: String
        public var reason: String
    }

    public struct Result: Equatable, Sendable {
        /// Policy is empty unless the line carried one; `ruleSet` is filled in
        /// by the matcher when it expands a `RULE-SET` reference.
        public var rules: [ProfileRule]
        public var skipped: [Skipped]
        /// Exact duplicate lines that were dropped.
        public var duplicateCount: Int
        /// True when `maxRules` stopped the parse early.
        public var truncated: Bool
    }

    public static func parse(_ text: String) -> Result {
        var rules: [ProfileRule] = []
        var skipped: [Skipped] = []
        var seen = Set<String>()
        var duplicates = 0
        var truncated = false

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNo = index + 1
            let line = stripComments(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if rules.count >= maxRules {
                truncated = true
                break
            }

            let parts = ProfileParser.splitTopLevel(line)
            guard let typePart = parts.first, !typePart.isEmpty else { continue }
            let upper = typePart.uppercased()

            guard let type = RuleType(rawValue: upper) else {
                skipped.append(Skipped(line: lineNo, text: line, reason: "unknown rule type \"\(typePart)\""))
                continue
            }
            guard type != .final else {
                skipped.append(Skipped(line: lineNo, text: line, reason: "FINAL is not allowed in a rule set"))
                continue
            }
            guard type != .ruleSet else {
                skipped.append(Skipped(line: lineNo, text: line, reason: "rule sets cannot reference other rule sets"))
                continue
            }

            var value: String
            var policy = ""
            var noResolve = false

            guard parts.count >= 2, !parts[1].isEmpty else {
                skipped.append(Skipped(line: lineNo, text: line, reason: "\(upper) needs a value"))
                continue
            }
            value = parts[1]

            // TYPE,value[,policy][,no-resolve]
            var options = Array(parts.dropFirst(2))
            if let last = options.last, last.lowercased() == "no-resolve" {
                noResolve = true
                options.removeLast()
            }
            if let first = options.first, !first.isEmpty {
                policy = first
                options.removeFirst()
            }
            if !options.isEmpty {
                skipped.append(Skipped(
                    line: lineNo, text: line,
                    reason: "\(upper) has unrecognised options \"\(options.joined(separator: ","))\""
                ))
                continue
            }

            let key = "\(upper)|\(value.lowercased())|\(noResolve)"
            guard seen.insert(key).inserted else {
                duplicates += 1
                continue
            }

            rules.append(ProfileRule(type: type, value: value, policy: policy, noResolve: noResolve))
        }

        return Result(rules: rules, skipped: skipped, duplicateCount: duplicates, truncated: truncated)
    }

    /// Rule sets use `#` and `;` like profiles, plus `//`, which is common in
    /// the wild. No quoting is honoured: URLs are not part of a rule body.
    static func stripComments(_ line: String) -> String {
        var result = ""
        result.reserveCapacity(line.count)
        var previous: Character?
        for character in line {
            if character == "#" || character == ";" { break }
            if character == "/" && previous == "/" {
                // Drop the first slash too, otherwise `a.com // note` would
                // leave `a.com /` as the value.
                result.removeLast()
                break
            }
            result.append(character)
            previous = character
        }
        return result
    }
}

// MARK: - Summary (Rule Sets pane)

/// One row of the Rule Sets pane: the declared set plus whatever we know about
/// its cached copy. Pure data — the view decides how to render "3 days ago".
public struct RuleSetSummary: Equatable, Sendable, Identifiable {
    public var name: String
    public var url: String
    public var interval: Int?
    /// Rules in the cached copy. `nil` means "never downloaded".
    public var ruleCount: Int?
    public var skippedCount: Int
    public var fetchedAt: Date?
    /// Older than the set's own interval (never-downloaded counts as stale).
    public var isStale: Bool
    /// Last refresh failure, cleared by the next success.
    public var error: String?

    public var id: String { name }
    public var isDownloaded: Bool { ruleCount != nil }

    /// The cache identity behind this row. The cache file name is derived from
    /// the name and the URL, which the summary carries, so a caller that only
    /// holds a summary can still drop (or re-fetch) the right files.
    public var declaration: RemoteRuleSet {
        RemoteRuleSet(name: name, url: url, interval: interval)
    }

    /// Automatic refresh is off unless the set declares an interval.
    public var refreshesAutomatically: Bool { interval != nil }

    public init(
        name: String,
        url: String,
        interval: Int? = nil,
        ruleCount: Int? = nil,
        skippedCount: Int = 0,
        fetchedAt: Date? = nil,
        isStale: Bool = false,
        error: String? = nil
    ) {
        self.name = name
        self.url = url
        self.interval = interval
        self.ruleCount = ruleCount
        self.skippedCount = skippedCount
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.error = error
    }
}

public extension RuleSetSummary {
    /// Builds the pane's rows, in profile order. `entries` and `errors` are
    /// keyed by lowercased set name (matching `RuleSetStore`).
    static func summaries(
        for profile: Profile,
        entries: [String: RuleSetCacheEntry],
        errors: [String: String] = [:],
        now: Date = Date()
    ) -> [RuleSetSummary] {
        profile.ruleSets.map { set in
            let key = set.name.lowercased()
            let entry = entries[key]
            return RuleSetSummary(
                name: set.name,
                url: set.url,
                interval: set.interval,
                ruleCount: entry?.ruleCount,
                skippedCount: entry?.skippedCount ?? 0,
                fetchedAt: entry?.fetchedAt,
                isStale: entry?.isStale(interval: set.interval, now: now) ?? true,
                error: errors[key]
            )
        }
    }
}
