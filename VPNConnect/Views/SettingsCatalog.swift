import Foundation
import CoreGraphics

// MARK: - Route

/// A pane in the Settings window.
///
/// The raw value is what gets persisted (`SettingsManager.settingsPane`), so
/// renaming a case silently migrates users back to the default pane — which is
/// exactly what `SettingsCatalog.route(forStoredValue:)` is there to absorb.
public enum SettingsRoute: String, Hashable, CaseIterable, Identifiable, Sendable {
    case vpn
    case profiles
    case dashboard
    case policies
    case rules
    case routing
    case ruleSets
    case history
    case appearance
    case advanced

    public var id: String { rawValue }
}

/// Sidebar grouping. Order of `allCases` is the order in the sidebar.
public enum SettingsGroup: String, Hashable, CaseIterable, Identifiable, Sendable {
    case connection
    case engine
    case monitoring
    case application

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .connection: return "Connection"
        case .engine: return "Proxy Engine"
        case .monitoring: return "Monitoring"
        case .application: return "Application"
        }
    }
}

/// Semantic colour for a sidebar icon chip. Kept as data (rather than a
/// `Color`) so the catalog stays Foundation-only and testable; the view layer
/// maps it in `SettingsTint.color`.
public enum SettingsTint: String, Hashable, Sendable {
    case blue, green, orange, purple, teal, indigo, gray, red
}

/// Everything the sidebar and the pane header need to know about a pane.
public struct SettingsItem: Identifiable, Equatable, Sendable {
    public let route: SettingsRoute
    public let title: String
    /// One-line description, shown under the pane title. Also searched.
    public let subtitle: String
    public let symbol: String
    public let tint: SettingsTint
    public let group: SettingsGroup
    /// Extra words a user might type into the sidebar search.
    public let keywords: [String]

    public var id: SettingsRoute { route }
}

/// The single source of truth for Settings navigation: sidebar order, titles,
/// icons and search keywords.
public enum SettingsCatalog {

    /// Where Settings opens when nothing else is remembered.
    public static let defaultRoute: SettingsRoute = .vpn

    public static let items: [SettingsItem] = [
        SettingsItem(
            route: .vpn,
            title: "VPN",
            subtitle: "Credentials, software token and split tunneling for the active profile",
            symbol: "lock.shield.fill",
            tint: .blue,
            group: .connection,
            keywords: ["password", "passcode", "2fa", "token", "stoken", "sudo", "admin",
                       "tunneling", "split", "vpn-slice", "slice", "host", "username", "login"]
        ),
        SettingsItem(
            route: .profiles,
            title: "Profiles",
            subtitle: "Named configurations — one is active at a time",
            symbol: "square.stack.3d.up.fill",
            tint: .indigo,
            group: .connection,
            keywords: ["profile", "conf", "import", "export", "duplicate", "rename", "activate"]
        ),
        SettingsItem(
            route: .dashboard,
            title: "Dashboard",
            subtitle: "Live requests, policy health and engine status",
            symbol: "gauge.with.needle.fill",
            tint: .teal,
            group: .engine,
            keywords: ["requests", "traffic", "bytes", "log", "latency", "health", "monitor"]
        ),
        SettingsItem(
            route: .policies,
            title: "Policies",
            subtitle: "Upstream proxies and the groups that pick between them",
            symbol: "server.rack",
            tint: .purple,
            group: .engine,
            keywords: ["proxy", "upstream", "group", "fallback", "url-test", "select", "latency"]
        ),
        SettingsItem(
            route: .rules,
            title: "Rules",
            subtitle: "The whole rule table, evaluated top to bottom",
            symbol: "list.number",
            tint: .orange,
            group: .engine,
            keywords: ["domain", "ip-cidr", "matcher", "final", "table", "order", "policy"]
        ),
        SettingsItem(
            route: .routing,
            title: "Routing",
            subtitle: "Quickly send a domain or IP range to a policy",
            symbol: "arrow.triangle.branch",
            tint: .green,
            group: .engine,
            keywords: ["quick", "add", "domain", "subnet", "ip", "pac", "import", "assign"]
        ),
        SettingsItem(
            route: .ruleSets,
            title: "Rule Sets",
            subtitle: "Remote rule lists — download them once, then use them like local rules",
            symbol: "arrow.down.circle.fill",
            tint: .orange,
            group: .engine,
            keywords: ["remote", "subscribe", "subscription", "url", "list", "download",
                       "refresh", "interval", "cache", "rule-set", "ruleset"]
        ),
        SettingsItem(
            route: .history,
            title: "History",
            subtitle: "Past connection attempts and the log of each one",
            symbol: "clock.arrow.circlepath",
            tint: .gray,
            group: .monitoring,
            keywords: ["attempts", "connect", "duration", "log", "clear", "past"]
        ),
        SettingsItem(
            route: .appearance,
            title: "Appearance",
            subtitle: "Follow the system, or pin a light or dark look",
            symbol: "circle.lefthalf.filled",
            tint: .blue,
            group: .application,
            keywords: ["theme", "dark", "light", "system", "colors", "appearance"]
        ),
        SettingsItem(
            route: .advanced,
            title: "Advanced",
            subtitle: "Engine ports, log files, storage and reset",
            symbol: "gearshape.2.fill",
            tint: .red,
            group: .application,
            keywords: ["ports", "listener", "log", "path", "storage", "reset", "keychain",
                       "diagnostics", "version"]
        ),
    ]

    /// The item for a route. Every route has one (pinned by a test), so the
    /// fallback is only here to keep the function total.
    public static func item(for route: SettingsRoute) -> SettingsItem {
        items.first { $0.route == route } ?? items[0]
    }

    public static func items(in group: SettingsGroup) -> [SettingsItem] {
        items.filter { $0.group == group }
    }

    /// Groups in sidebar order, skipping any that have no items.
    public static var groups: [SettingsGroup] {
        SettingsGroup.allCases.filter { !items(in: $0).isEmpty }
    }

    /// Turns a persisted raw value back into a route, tolerating anything a
    /// previous build (or a hand-edited plist) might have left behind.
    public static func route(forStoredValue value: String?) -> SettingsRoute {
        guard let value, let route = SettingsRoute(rawValue: value) else { return defaultRoute }
        return route
    }

    /// Sidebar search: matches the title, the subtitle and the keywords,
    /// case- and diacritic-insensitively. An empty or whitespace-only query
    /// returns everything (i.e. "not searching").
    public static func filter(_ query: String) -> [SettingsItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            ([item.title, item.subtitle] + item.keywords).contains {
                $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}

// MARK: - Sidebar geometry

/// How wide the sidebar is, and why.
///
/// The search field is the widest fixed thing in the sidebar and it is not
/// compressible: its placeholder needs a fixed amount of room, so it — not the
/// longest pane name — decides the minimum. 144 pt (the width this window used
/// to open at) clipped the placeholder to "Search setting:"; 172 pt is where it
/// reads as evenly spaced.
///
/// Two things had to be true for `navigationSplitViewColumnWidth` to be
/// honoured at all: it has to be the *outermost* modifier on the sidebar
/// (`searchable(placement: .sidebar)` rebuilds the column's chrome and swallows
/// the preference if it is applied underneath), and the footer asks for
/// `footerMinWidth` so the column's fitting width cannot pull it back under the
/// minimum.
public enum SettingsSidebar {
    /// Magnifier plus "Search settings" at the field's font, as measured on
    /// screen: 9.5 pt of leading inset and 121 pt of content.
    public static let searchFieldContentWidth: CGFloat = 121
    /// The field reserves this much at its trailing edge for the clear button,
    /// whether or not one is showing.
    public static let searchFieldTrailingReserve: CGFloat = 20
    /// A little air between the end of the placeholder and that reserve, so the
    /// text does not look jammed against the end of the pill.
    public static let searchFieldAir: CGFloat = 11
    /// The field's own inset inside the sidebar column.
    public static let fieldInset: CGFloat = 10
    /// The sidebar footer's horizontal padding, so its content can be asked to
    /// hold the column open at `minWidth` (see `footerMinWidth`) — SwiftUI does
    /// not honour the column-width preference here.
    public static let footerPadding: CGFloat = 14
    /// Minimum width for the footer's own content.
    public static var footerMinWidth: CGFloat { minWidth - 2 * footerPadding }
    /// The widest sidebar row: a 21 pt icon chip, its 8 pt gap, "Appearance",
    /// and the list row's horizontal insets.
    public static let widestRowWidth: CGFloat = 166

    /// Narrowest sidebar in which the search field still reads as evenly
    /// spaced. Also wide enough for the longest pane name.
    public static let minWidth: CGFloat = searchFieldContentWidth
        + searchFieldTrailingReserve + searchFieldAir + 2 * fieldInset
    /// Where a window opens, and where it snaps back to if it was ever narrower.
    public static let idealWidth: CGFloat = 196
    /// A ceiling, so a stray drag cannot turn Settings into a sidebar with a
    /// sliver of content.
    public static let maxWidth: CGFloat = 320
}
