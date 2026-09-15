import Foundation

// The app target compiles these files into one module; the SPM target
// `TurtleDiverAppGlue` compiles them standalone, so the engine modules are
// imported only when they exist as modules (see Package.swift).
#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif

/// The VPN pane's editable state, held as a value.
///
/// Two reasons it is not just a pile of `@State` strings: the pane can then
/// tell whether the user actually changed anything (`differs(from:)`), and the
/// comparison — including how the multi-line slice list is normalised — is
/// testable without touching the Keychain or `UserDefaults`.
public struct VPNConfigurationDraft: Equatable, Sendable {
    public var host: String
    public var username: String
    public var password: String
    public var passcode: String
    public var adminPassword: String
    public var tokenFilePath: String
    public var useTunneling: Bool
    /// As typed: one domain or IP range per line.
    public var sliceURLsText: String

    public init(host: String = "",
                username: String = "",
                password: String = "",
                passcode: String = "",
                adminPassword: String = "",
                tokenFilePath: String = "",
                useTunneling: Bool = false,
                sliceURLsText: String = "") {
        self.host = host
        self.username = username
        self.password = password
        self.passcode = passcode
        self.adminPassword = adminPassword
        self.tokenFilePath = tokenFilePath
        self.useTunneling = useTunneling
        self.sliceURLsText = sliceURLsText
    }

    /// The slice list as it will be stored: one entry per non-blank line,
    /// whitespace trimmed. `components(separatedBy: .newlines)` also splits the
    /// `\r\n` of a file pasted from Windows into an empty component, which the
    /// empty filter drops.
    public var sliceURLList: [String] {
        sliceURLsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// True when the draft differs from `other` in a way that matters.
    ///
    /// Cosmetic differences in the slice list (blank lines, trailing spaces,
    /// CRLF line endings) are ignored; every other field — credentials
    /// included, where a leading space may well be significant — is compared
    /// verbatim.
    public func differs(from other: VPNConfigurationDraft) -> Bool {
        if host != other.host || username != other.username { return true }
        if password != other.password || passcode != other.passcode { return true }
        if adminPassword != other.adminPassword { return true }
        if tokenFilePath != other.tokenFilePath || useTunneling != other.useTunneling { return true }
        return sliceURLList != other.sliceURLList
    }
}

/// Small pure formatters shared by the Settings panes.
///
/// They exist so the panes never hand raw values to `Text`: `Int?` would
/// interpolate as `Optional(6152)`, and a full home path eats the row width.
public enum SettingsDisplay {

    /// The listener address, or `—` when that listener isn't up.
    public static func listener(host: String = "127.0.0.1", port: Int?) -> String {
        guard let port else { return "—" }
        return "\(host):\(port)"
    }

    /// Pill for a rule set: its rule count, or why there is none.
    public static func ruleSetStatus(_ summary: RuleSetSummary) -> StatusLabel {
        if summary.error != nil { return StatusLabel(title: "Error", tone: .error) }
        guard let count = summary.ruleCount else { return StatusLabel(title: "Not downloaded", tone: .warn) }
        if summary.isStale { return StatusLabel(title: "Stale", tone: .warn) }
        return StatusLabel(title: "\(count) \(count == 1 ? "rule" : "rules")", tone: .ok)
    }

    /// How old the cached copy is. Coarse on purpose: the exact minute a list
    /// was fetched does not change what the user should do about it.
    public static func ruleSetAge(_ summary: RuleSetSummary, now: Date = Date()) -> String {
        guard let fetchedAt = summary.fetchedAt else { return "Never downloaded" }
        let seconds = max(0, now.timeIntervalSince(fetchedAt))
        if seconds < 90 { return "Updated just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours) h ago" }
        let days = hours / 24
        return "Updated \(days) day\(days == 1 ? "" : "s") ago"
    }

    /// "Refreshes every day" / "Manual refresh only".
    public static func ruleSetRefresh(interval: Int?) -> String {
        guard let interval, interval > 0 else { return "Refreshes when you ask" }
        func every(_ count: Int, _ unit: String) -> String {
            count == 1 ? "Refreshes every \(unit)" : "Refreshes every \(count) \(unit)s"
        }
        if interval % 86400 == 0 { return every(interval / 86400, "day") }
        if interval % 3600 == 0 { return every(interval / 3600, "hour") }
        if interval % 60 == 0 { return every(interval / 60, "minute") }
        return "Refreshes every \(interval) s"
    }

    /// `/Users/me/Library/Logs/x` → `~/Library/Logs/x`, so paths fit a row.
    /// A path outside the home directory (or the home directory itself) is
    /// returned unchanged.
    public static func abbreviateHome(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, path.hasPrefix(home) else { return path }
        let suffix = path.dropFirst(home.count)
        guard suffix.isEmpty || suffix.hasPrefix("/") else { return path }
        return "~" + suffix
    }
}

extension SettingsDisplay {

    public enum Tone: String, Sendable {
        case ok, warn, error, neutral
    }

    public struct StatusLabel: Equatable, Sendable {
        public let title: String
        public let tone: Tone
    }

    /// Connection history stores raw status strings — some written by earlier
    /// builds — so the label is derived, not stored: "Terminated by App Exit"
    /// is fine in a log and much too long inside a pill.
    public static func connectionStatus(_ raw: String) -> StatusLabel {
        let lower = raw.lowercased()
        if lower.hasPrefix("connected") { return StatusLabel(title: "Connected", tone: .ok) }
        if lower.contains("connecting") { return StatusLabel(title: "Connecting", tone: .warn) }
        if lower.contains("disconnected") { return StatusLabel(title: "Disconnected", tone: .neutral) }
        if lower.contains("app exit") { return StatusLabel(title: "App exited", tone: .neutral) }
        if lower.contains("missing settings") { return StatusLabel(title: "Missing settings", tone: .error) }
        if lower.contains("token") { return StatusLabel(title: "Token error", tone: .error) }
        if lower.contains("fail") || lower.contains("error") { return StatusLabel(title: "Failed", tone: .error) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return StatusLabel(title: trimmed.isEmpty ? "Unknown" : String(trimmed.prefix(24)), tone: .neutral)
    }
}

extension SettingsDisplay {

    /// "2 proxies · 1 group · 35 rules" — counted nouns need to read right at
    /// every count, and the numbers are built as strings so 1000 stays "1000"
    /// rather than picking up a grouping separator.
    public static func profileSummary(proxies: Int, groups: Int, rules: Int) -> String {
        func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
            "\(count) \(count == 1 ? singular : plural)"
        }
        return [
            counted(proxies, "proxy", "proxies"),
            counted(groups, "group", "groups"),
            counted(rules, "rule", "rules")
        ].joined(separator: " · ")
    }
}

// MARK: - Rule-set refresh cadence

/// The refresh intervals the Rule Sets pane offers. Stored as seconds in the
/// profile (`interval=86400`), presented as words — nobody wants to type
/// 604800 to say "weekly".
public enum RuleSetInterval: Int, CaseIterable, Identifiable, Sendable {
    case manual = 0
    case hourly = 3600
    case daily = 86400
    case weekly = 604800

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .manual: return "Only when I ask"
        case .hourly: return "Hourly"
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    /// `nil` for manual, which is what `RemoteRuleSet.interval` stores.
    public var seconds: Int? { self == .manual ? nil : rawValue }

    /// Maps a stored interval onto the closest choice, so a profile written by
    /// hand (`interval=7200`) still has something selected in the picker.
    public static func closest(to seconds: Int?) -> RuleSetInterval {
        guard let seconds, seconds > 0 else { return .manual }
        return allCases
            .filter { $0 != .manual }
            .min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) } ?? .manual
    }
}
