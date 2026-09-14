import XCTest
import AppKit
@testable import TurtleDiverAppGlue

/// The Settings sidebar is data (`SettingsCatalog`), so the invariants that
/// keep it coherent — one item per route, every icon resolvable, search
/// behaves — can be tested instead of eyeballed.
final class SettingsCatalogTests: XCTestCase {

    // MARK: Completeness

    func testEveryRouteHasExactlyOneItem() {
        for route in SettingsRoute.allCases {
            let matching = SettingsCatalog.items.filter { $0.route == route }
            XCTAssertEqual(matching.count, 1, "\(route.rawValue) has \(matching.count) sidebar items")
        }
    }

    func testItemLookupIsTotalAndPrefersTheMatchingRoute() {
        for route in SettingsRoute.allCases {
            XCTAssertEqual(SettingsCatalog.item(for: route).route, route)
        }
    }

    func testIdentifiersAreUnique() {
        let ids = SettingsCatalog.items.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testEveryGroupInUseIsListedAndOrderIsStable() {
        XCTAssertEqual(SettingsCatalog.groups, [.connection, .engine, .monitoring, .application])
        // Concatenating the groups must reproduce the flat list in order.
        let flattened = SettingsCatalog.groups.flatMap { SettingsCatalog.items(in: $0) }
        XCTAssertEqual(flattened.map(\.route), SettingsCatalog.items.map(\.route))
    }

    func testConnectionPanesComeFirst() {
        XCTAssertEqual(SettingsCatalog.items.first?.route, .vpn)
    }

    // MARK: Copy

    func testTitlesAndSubtitlesArePresentAndTerse() {
        for item in SettingsCatalog.items {
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.subtitle.isEmpty, "\(item.route.rawValue) has no subtitle")
            XCTAssertLessThanOrEqual(item.subtitle.count, 80, "\(item.title) subtitle is too long to read")
            XCTAssertFalse(item.subtitle.hasSuffix("."), "\(item.title) subtitle should not be a sentence")
            XCTAssertFalse(item.title.hasSuffix(" "), item.title)
        }
    }

    func testKeywordsAreLowercaseAndUnique() {
        for item in SettingsCatalog.items {
            XCTAssertFalse(item.keywords.isEmpty, "\(item.title) has no search keywords")
            for keyword in item.keywords {
                XCTAssertEqual(keyword, keyword.lowercased(), "keyword \(keyword) should be lowercase")
            }
            XCTAssertEqual(Set(item.keywords).count, item.keywords.count,
                           "\(item.title) repeats a keyword")
        }
    }

    /// A typo'd symbol renders as a blank chip with no warning at runtime.
    func testEverySymbolResolves() {
        for item in SettingsCatalog.items {
            XCTAssertNotNil(NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil),
                            "\(item.title) uses an unknown SF Symbol: \(item.symbol)")
        }
    }

    // MARK: Search

    func testEmptyQueryShowsEverything() {
        XCTAssertEqual(SettingsCatalog.filter("").map(\.route), SettingsCatalog.items.map(\.route))
        XCTAssertEqual(SettingsCatalog.filter("   \n ").map(\.route), SettingsCatalog.items.map(\.route))
    }

    func testSearchMatchesTitlesInsensitively() {
        XCTAssertEqual(SettingsCatalog.filter("ROUTING").map(\.route), [.routing])
        XCTAssertEqual(SettingsCatalog.filter("appearance").map(\.route), [.appearance])
    }

    func testSearchMatchesKeywordsAndSubtitleText() {
        XCTAssertEqual(SettingsCatalog.filter("stoken").map(\.route), [.vpn])
        XCTAssertTrue(SettingsCatalog.filter("proxy").contains { $0.route == .policies })
        XCTAssertTrue(SettingsCatalog.filter("url-test").contains { $0.route == .policies })
        // "ports" is only a keyword of Advanced.
        XCTAssertEqual(SettingsCatalog.filter("listener").map(\.route), [.advanced])
    }

    func testSearchTrimsAndReturnsNothingForUnknownTerms() {
        XCTAssertEqual(SettingsCatalog.filter("  routing  ").map(\.route), [.routing])
        XCTAssertTrue(SettingsCatalog.filter("zzzz").isEmpty)
    }

    func testSearchIsDiacriticInsensitive() {
        XCTAssertEqual(SettingsCatalog.filter("Routïng").map(\.route), [.routing])
    }

    // MARK: Persistence

    func testStoredValueRoundTripsForEveryRoute() {
        for route in SettingsRoute.allCases {
            XCTAssertEqual(SettingsCatalog.route(forStoredValue: route.rawValue), route)
        }
    }

    func testUnknownOrMissingStoredValueFallsBackToTheDefault() {
        XCTAssertEqual(SettingsCatalog.route(forStoredValue: nil), SettingsCatalog.defaultRoute)
        XCTAssertEqual(SettingsCatalog.route(forStoredValue: ""), SettingsCatalog.defaultRoute)
        XCTAssertEqual(SettingsCatalog.route(forStoredValue: "connectionDetail"), SettingsCatalog.defaultRoute)
        XCTAssertEqual(SettingsCatalog.defaultRoute, .vpn)
    }

    func testSettingsManagerPersistsAndRestoresTheSelectedPane() {
        let suiteName = "SettingsCatalogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let manager = SettingsManager(defaults: defaults)
        XCTAssertEqual(manager.settingsPane, SettingsCatalog.defaultRoute.rawValue,
                       "a fresh install starts on the default pane")

        manager.settingsPane = SettingsRoute.advanced.rawValue

        let reopened = SettingsManager(defaults: defaults)
        XCTAssertEqual(SettingsCatalog.route(forStoredValue: reopened.settingsPane), .advanced)
    }
}
