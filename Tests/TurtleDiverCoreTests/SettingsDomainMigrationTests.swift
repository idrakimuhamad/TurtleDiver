import XCTest
@testable import TurtleDiverSystem

/// Settings live in the `UserDefaults` domain named after the bundle
/// identifier, so renaming the app would silently reset every preference (VPN
/// host, username, toggles, window state, connection history) unless they are
/// carried across. These tests cover the carry-across, using throwaway suites
/// instead of the user's real plist.
final class SettingsDomainMigrationTests: XCTestCase {

    private var suites: [String] = []
    /// The suite `makeSuite()` last handed out, so a test can inspect what was
    /// *written* to it rather than what it can read from it.
    private var lastSuiteName = ""

    override func tearDown() {
        for name in suites {
            UserDefaults().removePersistentDomain(forName: name)
        }
        suites = []
        super.tearDown()
    }

    /// A unique, throwaway `UserDefaults` suite — never `.standard`.
    private func makeSuite() -> UserDefaults {
        let name = "turtlediver.migration.tests.\(UUID().uuidString)"
        suites.append(name)
        lastSuiteName = name
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: copy(_:into:)

    func testEveryMissingKeyIsCopied() {
        let legacy: [String: Any] = ["vpnHost": "vpn.example.com", "useTunneling": true]
        let current = makeSuite()

        let copied = SettingsDomainMigration.copy(legacy, into: current)

        XCTAssertEqual(copied, ["useTunneling", "vpnHost"])
        XCTAssertEqual(current.string(forKey: "vpnHost"), "vpn.example.com")
        XCTAssertTrue(current.bool(forKey: "useTunneling"))
    }

    /// A value already set under the new identity always wins: the user may
    /// have re-entered it after the rename, and the old copy is stale.
    func testAnExistingValueIsNeverOverwritten() {
        let current = makeSuite()
        current.set("new-host", forKey: "vpnHost")

        let copied = SettingsDomainMigration.copy(["vpnHost": "old-host"], into: current)

        XCTAssertTrue(copied.isEmpty)
        XCTAssertEqual(current.string(forKey: "vpnHost"), "new-host")
    }

    /// Non-primitive values move as-is — a security-scoped bookmark is `Data`,
    /// and losing it would make the user pick the token file again.
    func testBinaryAndArrayValuesSurviveTheMove() {
        let bookmark = Data([0x01, 0x02, 0x03])
        let current = makeSuite()

        SettingsDomainMigration.copy(
            ["stokenTokenBookmarkData": bookmark, "vpnSliceURLs": ["a.example.com", "10.0.0.0/8"]],
            into: current
        )

        XCTAssertEqual(current.data(forKey: "stokenTokenBookmarkData"), bookmark)
        XCTAssertEqual(current.stringArray(forKey: "vpnSliceURLs"), ["a.example.com", "10.0.0.0/8"])
    }

    func testCopyingTheSameDomainTwiceIsAHarmlessNoOp() {
        let current = makeSuite()

        XCTAssertEqual(SettingsDomainMigration.copy(["vpnHost": "vpn.example.com"], into: current),
                       ["vpnHost"])
        XCTAssertTrue(SettingsDomainMigration.copy(["vpnHost": "vpn.example.com"], into: current).isEmpty)
    }

    // MARK: copyLegacyDomains

    func testARealDomainIsFoundByNameAndCopied() {
        let legacyName = "turtlediver.migration.legacy.\(UUID().uuidString)"
        suites.append(legacyName)
        let legacy = UserDefaults(suiteName: legacyName)!
        legacy.set("vpn.example.com", forKey: "vpnHost")
        legacy.set(3, forKey: "httpPort")
        legacy.synchronize()

        let current = makeSuite()
        let copied = SettingsDomainMigration.copyLegacyDomains(into: current, from: [legacyName])

        XCTAssertEqual(copied, ["httpPort", "vpnHost"])
        XCTAssertEqual(current.string(forKey: "vpnHost"), "vpn.example.com")
        XCTAssertEqual(current.integer(forKey: "httpPort"), 3)
    }

    /// The reason the migration reads `persistentDomain(forName:)` rather than a
    /// suite's `dictionaryRepresentation()`: the latter merges in the *global*
    /// domain, so copying from it would pin system-wide settings such as
    /// `AppleLanguages` inside the app's own preferences.
    func testTheGlobalDomainIsNotDraggedIntoTheAppDomain() {
        let legacyName = "turtlediver.migration.global.\(UUID().uuidString)"
        suites.append(legacyName)
        let legacy = UserDefaults(suiteName: legacyName)!
        legacy.set("vpn.example.com", forKey: "vpnHost")
        legacy.synchronize()

        let current = makeSuite()
        SettingsDomainMigration.copyLegacyDomains(into: current, from: [legacyName])

        XCTAssertNotNil(UserDefaults.standard.persistentDomain(forName: legacyName)?["vpnHost"])
        // Inspect what was *written*, not what can be read: `object(forKey:)`
        // answers from the global domain too, so `AppleLocale` would look
        // "present" even though nothing copied it.
        let written = current.persistentDomain(forName: lastSuiteName) ?? [:]
        for key in ["AppleLanguages", "AppleLocale", "NSInterfaceStyle"] {
            XCTAssertNil(written[key], "\(key) leaked into the app's domain")
        }
    }

    func testAMissingLegacyDomainIsNotAnError() {
        let current = makeSuite()

        let copied = SettingsDomainMigration.copyLegacyDomains(
            into: current,
            from: ["turtlediver.migration.absent.\(UUID().uuidString)"]
        )

        XCTAssertTrue(copied.isEmpty)
    }
}
