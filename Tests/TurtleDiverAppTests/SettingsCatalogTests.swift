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

    /// Setup is the pane a stuck user is sent to, so it sits in Application
    /// next to Appearance, above the technical Advanced pane. Updates is the
    /// other thing a user comes looking for by name rather than by concept.
    func testSetupAndUpdatesSitInApplicationAboveAdvanced() {
        let application = SettingsCatalog.items(in: .application).map(\.route)
        XCTAssertEqual(application, [.appearance, .setup, .updates, .advanced])
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
        // Both panes legitimately own the word: VPN is where the token is used,
        // Setup is where a missing stoken is explained and installed.
        XCTAssertEqual(SettingsCatalog.filter("stoken").map(\.route), [.vpn, .setup])
        XCTAssertEqual(SettingsCatalog.filter("openconnect").map(\.route), [.setup])
        XCTAssertEqual(SettingsCatalog.filter("brew").map(\.route), [.setup])
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

    // MARK: Sidebar geometry

    /// The minimum is derived from the search field, and the search field is
    /// only as wide as its placeholder needs. If someone shortens the prompt,
    /// these numbers should shrink with it — not stay as cargo cult.
    func testMinimumSidebarWidthIsTheSearchFieldPlusItsInsets() {
        let expected = SettingsSidebar.searchFieldContentWidth
            + SettingsSidebar.searchFieldTrailingReserve
            + SettingsSidebar.searchFieldAir
            + 2 * SettingsSidebar.fieldInset
        XCTAssertEqual(SettingsSidebar.minWidth, expected)
        XCTAssertEqual(SettingsSidebar.minWidth, 172,
                       "the measured width at which 'Search settings' stops clipping")
    }

    func testMinimumWidthAlsoFitsTheWidestSidebarRow() {
        XCTAssertGreaterThanOrEqual(SettingsSidebar.minWidth, SettingsSidebar.widestRowWidth)
    }

    func testWidthsAreOrdered() {
        XCTAssertLessThan(SettingsSidebar.minWidth, SettingsSidebar.idealWidth)
        XCTAssertLessThan(SettingsSidebar.idealWidth, SettingsSidebar.maxWidth)
    }

    func testFooterHoldsTheColumnOpenAtTheMinimum() {
        XCTAssertEqual(SettingsSidebar.footerMinWidth + 2 * SettingsSidebar.footerPadding,
                       SettingsSidebar.minWidth)
    }
}

/// The two Dashboard switches that decide whether request details are captured
/// and whether sensitive header values are readable.
@MainActor
final class RequestDetailSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "turtlediver.request.detail.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
    }

    /// Capture on, reveal off. An install that has never seen these keys must
    /// get the feature working but must not print anyone's cookies.
    func testDefaultsAreCaptureOnAndRevealOff() {
        let settings = SettingsManager(defaults: defaults)
        XCTAssertTrue(settings.recordRequestDetails)
        XCTAssertFalse(settings.revealSensitiveHeaders)
    }

    /// The distinction that made the capture flag awkward: a stored `false` is
    /// an answer and must survive, unlike an absent key.
    func testAStoredOffIsRespected() {
        defaults.set(false, forKey: "recordRequestDetails")
        defaults.set(true, forKey: "revealSensitiveHeaders")

        let settings = SettingsManager(defaults: defaults)
        XCTAssertFalse(settings.recordRequestDetails)
        XCTAssertTrue(settings.revealSensitiveHeaders)
    }

    func testBothSwitchesPersist() {
        let first = SettingsManager(defaults: defaults)
        first.recordRequestDetails = false
        first.revealSensitiveHeaders = true

        let second = SettingsManager(defaults: defaults)
        XCTAssertFalse(second.recordRequestDetails)
        XCTAssertTrue(second.revealSensitiveHeaders)
    }
}
