import XCTest
@testable import TurtleDiverAppGlue

/// The main window is one window in two states: compact controls by default and
/// the full dashboard when expanded. `AppDelegate` sizes the frame from these
/// values, so the maths is pinned here rather than left to magic numbers.
final class MainWindowLayoutTests: XCTestCase {

    func testCompactIsTheNarrowSingleColumnWindow() {
        let size = MainWindowLayout.targetSize(expanded: false)
        XCTAssertEqual(size.width, MainWindowLayout.compactWidth)
        XCTAssertEqual(size.height, MainWindowLayout.compactHeight)
        XCTAssertEqual(size.width, 380)
    }

    func testExpandedIsWiderAndTallerThanCompact() {
        let compact = MainWindowLayout.targetSize(expanded: false)
        let expanded = MainWindowLayout.targetSize(expanded: true)
        XCTAssertGreaterThan(expanded.width, compact.width)
        XCTAssertGreaterThan(expanded.height, compact.height)
        XCTAssertEqual(expanded.width, MainWindowLayout.expandedWidth)
        XCTAssertEqual(expanded.height, MainWindowLayout.expandedHeight)
    }

    func testLargeScreenLeavesTheTargetSizeAlone() {
        let expanded = MainWindowLayout.targetSize(expanded: true, screen: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(expanded, CGSize(width: MainWindowLayout.expandedWidth, height: MainWindowLayout.expandedHeight))
        let compact = MainWindowLayout.targetSize(expanded: false, screen: CGSize(width: 2560, height: 1440))
        XCTAssertEqual(compact, CGSize(width: MainWindowLayout.compactWidth, height: MainWindowLayout.compactHeight))
    }

    func testSmallScreenClampsTheExpandedWindow() {
        // 1024×768 display: width still fits, height loses the vertical margin.
        let size = MainWindowLayout.targetSize(expanded: true, screen: CGSize(width: 1024, height: 768))
        XCTAssertEqual(size.width, 940)
        XCTAssertEqual(size.height, 768 - MainWindowLayout.minimumScreenMargin.height)
    }

    func testTinyScreenNeverGoesBelowTheCompactFloor() {
        let size = MainWindowLayout.targetSize(expanded: true, screen: CGSize(width: 700, height: 500))
        XCTAssertEqual(size.width, 700 - MainWindowLayout.minimumScreenMargin.width)
        XCTAssertEqual(size.height, MainWindowLayout.compactHeight, "the compact height is the floor — the dashboard scrolls")
        XCTAssertGreaterThanOrEqual(size.width, MainWindowLayout.compactWidth)
    }

    func testUnknownOrDegenerateScreenSizeIsIgnored() {
        for screen in [CGSize?.none, CGSize(width: 0, height: 900), CGSize(width: 1440, height: 0)] {
            let size = MainWindowLayout.targetSize(expanded: true, screen: screen)
            XCTAssertEqual(size.width, MainWindowLayout.expandedWidth)
            XCTAssertEqual(size.height, MainWindowLayout.expandedHeight)
        }
    }

    func testExpansionStateIsPersistedForTheNextLaunch() {
        let settings = SettingsManager.shared
        let original = settings.dashboardExpanded
        defer { settings.dashboardExpanded = original }

        settings.dashboardExpanded = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "mainWindowDashboardExpanded"))

        settings.dashboardExpanded = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "mainWindowDashboardExpanded"))
    }
}
