import XCTest
@testable import TurtleDiverAppGlue

/// The VPN pane decides whether to light up "Unsaved changes" with
/// `VPNConfigurationDraft.differs(from:)`, and turns the slice text area into a
/// stored list. Both are pure, so they can be pinned down here.
final class VPNConfigurationDraftTests: XCTestCase {

    private func draft(host: String = "vpn.example.com",
                       username: String = "451799",
                       password: String = "pw",
                       passcode: String = "123456",
                       adminPassword: String = "admin",
                       tokenFilePath: String = "/tmp/token.stid",
                       useTunneling: Bool = false,
                       sliceURLsText: String = "") -> VPNConfigurationDraft {
        VPNConfigurationDraft(host: host,
                              username: username,
                              password: password,
                              passcode: passcode,
                              adminPassword: adminPassword,
                              tokenFilePath: tokenFilePath,
                              useTunneling: useTunneling,
                              sliceURLsText: sliceURLsText)
    }

    // MARK: Dirty detection

    func testAnUnchangedDraftIsNotDirty() {
        XCTAssertFalse(draft().differs(from: draft()))
    }

    func testEachCredentialCountsAsAChange() {
        XCTAssertTrue(draft(password: "other").differs(from: draft()))
        XCTAssertTrue(draft(passcode: "654321").differs(from: draft()))
        XCTAssertTrue(draft(adminPassword: "other").differs(from: draft()))
    }

    func testEveryOtherFieldCountsAsAChange() {
        XCTAssertTrue(draft(host: "other.example.com").differs(from: draft()))
        XCTAssertTrue(draft(username: "999").differs(from: draft()))
        XCTAssertTrue(draft(tokenFilePath: "/tmp/other.stid").differs(from: draft()))
        XCTAssertTrue(draft(useTunneling: true).differs(from: draft()))
        XCTAssertTrue(draft(sliceURLsText: "a.example.com").differs(from: draft()))
    }

    /// Whitespace inside a credential may be significant, so it is compared
    /// verbatim rather than trimmed.
    func testCredentialWhitespaceIsSignificant() {
        XCTAssertTrue(draft(password: " pw").differs(from: draft()))
        XCTAssertTrue(draft(password: "pw ").differs(from: draft()))
        XCTAssertTrue(draft(password: "").differs(from: draft()))
    }

    /// The slice list is a text area: blank lines, indentation and CRLF are
    /// presentation, not content.
    func testCosmeticDifferencesInTheSliceListAreNotChanges() {
        let loaded = draft(useTunneling: true, sliceURLsText: "a.example.com\n10.0.0.0/8")
        let retyped = draft(useTunneling: true, sliceURLsText: "a.example.com\n\n  10.0.0.0/8  \n")
        XCTAssertFalse(retyped.differs(from: loaded))

        let windows = draft(useTunneling: true, sliceURLsText: "a.example.com\r\n10.0.0.0/8\r\n")
        XCTAssertFalse(windows.differs(from: loaded))
    }

    func testAReorderedOrChangedSliceListIsAChange() {
        let loaded = draft(useTunneling: true, sliceURLsText: "a.example.com\nb.example.com")
        XCTAssertTrue(draft(useTunneling: true, sliceURLsText: "b.example.com\na.example.com").differs(from: loaded))
        XCTAssertTrue(draft(useTunneling: true, sliceURLsText: "a.example.com").differs(from: loaded))
    }

    // MARK: Slice parsing

    func testSliceListTrimsAndDropsBlankLines() {
        let parsed = draft(sliceURLsText: "\n  corp.example.com \n\n\t10.0.0.0/8\n  \n").sliceURLList
        XCTAssertEqual(parsed, ["corp.example.com", "10.0.0.0/8"])
    }

    func testSliceListHandlesCRLFAndAnEmptyDocument() {
        XCTAssertEqual(draft(sliceURLsText: "a\r\nb\r\n").sliceURLList, ["a", "b"])
        XCTAssertEqual(draft(sliceURLsText: "").sliceURLList, [])
        XCTAssertEqual(draft(sliceURLsText: "\n \n").sliceURLList, [])
    }

    /// Interior whitespace is part of the target, only the edges are trimmed.
    func testSliceListKeepsInteriorCharacters() {
        XCTAssertEqual(draft(sliceURLsText: "  *.corp.example.com  ").sliceURLList, ["*.corp.example.com"])
    }
}

/// The formatters that keep raw values out of `Text`.
final class SettingsDisplayTests: XCTestCase {

    func testListenerNeverLeaksAnOptional() {
        XCTAssertEqual(SettingsDisplay.listener(port: 6152), "127.0.0.1:6152")
        XCTAssertEqual(SettingsDisplay.listener(port: 6153), "127.0.0.1:6153")
        XCTAssertEqual(SettingsDisplay.listener(host: "0.0.0.0", port: 8080), "0.0.0.0:8080")
        XCTAssertFalse(SettingsDisplay.listener(port: 6152).contains("Optional"))
    }

    func testListenerShowsADashWhileStopped() {
        XCTAssertEqual(SettingsDisplay.listener(port: nil), "—")
    }

    func testHomeIsAbbreviated() {
        let home = "/Users/idraki"
        XCTAssertEqual(SettingsDisplay.abbreviateHome("\(home)/Library/Logs/TurtleDiver/vpn.log", home: home),
                       "~/Library/Logs/TurtleDiver/vpn.log")
    }

    func testPathsOutsideHomeAreLeftAlone() {
        let home = "/Users/idraki"
        XCTAssertEqual(SettingsDisplay.abbreviateHome("/tmp/TurtleDiver-launch.log", home: home),
                       "/tmp/TurtleDiver-launch.log")
        XCTAssertEqual(SettingsDisplay.abbreviateHome("/Volumes/Backup/logs", home: home),
                       "/Volumes/Backup/logs")
    }

    /// A sibling directory that merely starts with the home path must not be
    /// rewritten: `/Users/idraki2` is not inside `/Users/idraki`.
    func testOnlyARealPathComponentBoundaryCounts() {
        let home = "/Users/idraki"
        XCTAssertEqual(SettingsDisplay.abbreviateHome("/Users/idraki2/Library", home: home),
                       "/Users/idraki2/Library")
        XCTAssertEqual(SettingsDisplay.abbreviateHome(home, home: home), "~")
    }

    func testEmptyHomeDoesNotMangleThePath() {
        XCTAssertEqual(SettingsDisplay.abbreviateHome("/tmp/x", home: ""), "/tmp/x")
    }
}

/// History keeps raw status strings from earlier builds; the pill needs a short
/// label and a tone, and both are derived.
final class ConnectionStatusDisplayTests: XCTestCase {

    private func label(_ raw: String) -> (String, SettingsDisplay.Tone) {
        let s = SettingsDisplay.connectionStatus(raw)
        return (s.title, s.tone)
    }

    func testKnownStatusesMapToShortLabels() {
        XCTAssertEqual(label("Connected").0, "Connected")
        XCTAssertEqual(label("Connecting").0, "Connecting")
        XCTAssertEqual(label("Disconnected").0, "Disconnected")
        XCTAssertEqual(label("Terminated by App Exit").0, "App exited")
        XCTAssertEqual(label("Connected (adopted from existing process)").0, "Connected")
    }

    func testTonesFollowTheOutcome() {
        XCTAssertEqual(label("Connected").1, .ok)
        XCTAssertEqual(label("Connecting").1, .warn)
        XCTAssertEqual(label("Disconnected").1, .neutral)
        XCTAssertEqual(label("Terminated by App Exit").1, .neutral)
        XCTAssertEqual(label("Failed - Missing Settings").1, .error)
        XCTAssertEqual(label("Failed - Token Error").1, .error)
    }

    func testFailuresAreShortenedButStillSpecific() {
        XCTAssertEqual(label("Failed - Missing Settings").0, "Missing settings")
        XCTAssertEqual(label("Failed - Token Error").0, "Token error")
        XCTAssertEqual(label("Failed - whatever").0, "Failed")
    }

    func testEveryLabelFitsInAPill() {
        let raws = ["Connected", "Connecting", "Disconnected", "Terminated by App Exit",
                    "Failed - Missing Settings", "Failed - Token Error",
                    "Connected (adopted from existing process)", "something new entirely"]
        for raw in raws {
            let title = label(raw).0
            XCTAssertFalse(title.isEmpty)
            XCTAssertLessThanOrEqual(title.count, 24, "\(raw) → \(title) is too long for a pill")
            XCTAssertEqual(title, title.trimmingCharacters(in: .whitespaces))
        }
    }

    func testUnknownAndBlankStatusesDegradeGracefully() {
        XCTAssertEqual(label("").0, "Unknown")
        XCTAssertEqual(label("   ").0, "Unknown")
        XCTAssertEqual(label(String(repeating: "x", count: 60)).0.count, 24)
        XCTAssertEqual(label("Something New").1, .neutral)
    }
}

extension SettingsDisplayTests {

    func testProfileSummaryPluralisesEveryCount() {
        XCTAssertEqual(SettingsDisplay.profileSummary(proxies: 2, groups: 1, rules: 35),
                       "2 proxies · 1 group · 35 rules")
        XCTAssertEqual(SettingsDisplay.profileSummary(proxies: 1, groups: 2, rules: 1),
                       "1 proxy · 2 groups · 1 rule")
        XCTAssertEqual(SettingsDisplay.profileSummary(proxies: 0, groups: 0, rules: 0),
                       "0 proxies · 0 groups · 0 rules")
    }

    func testProfileSummaryDoesNotAddThousandsSeparators() {
        XCTAssertEqual(SettingsDisplay.profileSummary(proxies: 0, groups: 0, rules: 1200),
                       "0 proxies · 0 groups · 1200 rules")
    }
}
