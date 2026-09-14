import XCTest
@testable import TurtleDiverAppGlue

/// Tests for the launch-time purge of dead `UserDefaults` keys.
///
/// The regression these cover: the login/admin password used to be stored in
/// `UserDefaults` and was later moved to the Keychain, but the plist entry was
/// never removed — so a plaintext password kept sitting in
/// `~/Library/Preferences/com.idraki.turtle.vpn.plist` (and the same for the
/// PAC-era `useProxy`/`proxyConfigurations`/`selectedProxyID` keys, whose code
/// is gone). The purge has to *move* a credential to the Keychain before it
/// drops the key, and must never write one back to disk.
final class SecretHygieneTests: XCTestCase {

    /// In-memory `SecretStore` so the tests never touch the login keychain.
    private final class FakeSecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String]
        private(set) var stored: [(account: String, value: String)] = []
        private(set) var deleted: [String] = []

        init(items: [String: String] = [:]) { self.items = items }

        func retrieve(account: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return items[account]
        }

        func store(password: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            items[account] = password
            stored.append((account, password))
        }

        func delete(account: String) {
            lock.lock(); defer { lock.unlock() }
            items.removeValue(forKey: account)
            deleted.append(account)
        }
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "turtlediver.secrets.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    // MARK: Migration

    func testLegacyCredentialIsMovedToTheKeychainBeforeTheKeyIsDeleted() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets()

        defaults.set("hunter2", forKey: "adminPassword")
        defaults.set("vpn-secret", forKey: "vpnPassword")

        let purged = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        XCTAssertEqual(secrets.retrieve(account: "adminPassword"), "hunter2")
        XCTAssertEqual(secrets.retrieve(account: "vpnPassword"), "vpn-secret")
        XCTAssertNil(defaults.object(forKey: "adminPassword"), "the plist copy must be gone")
        XCTAssertNil(defaults.object(forKey: "vpnPassword"))
        XCTAssertTrue(purged.contains("adminPassword"))
        XCTAssertTrue(purged.contains("vpnPassword"))
    }

    func testAnExistingKeychainEntryWinsOverTheStaleDefaultsCopy() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        // The Keychain is authoritative — a stale plist value must not clobber
        // the password the user last typed into Settings.
        let secrets = FakeSecrets(items: ["adminPassword": "current"])

        defaults.set("stale", forKey: "adminPassword")

        _ = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        XCTAssertEqual(secrets.retrieve(account: "adminPassword"), "current")
        XCTAssertTrue(secrets.stored.isEmpty, "nothing should have been rewritten")
        XCTAssertNil(defaults.object(forKey: "adminPassword"))
    }

    func testEmptyAndMissingCredentialsAreNotStored() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets()

        defaults.set("", forKey: "adminPassword")
        defaults.set("   ", forKey: "vpnPasscode")

        _ = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        XCTAssertTrue(secrets.stored.isEmpty)
        XCTAssertNil(defaults.object(forKey: "adminPassword"))
    }

    func testOnlyTheEmptyCheckIsTrimmedNotTheValue() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets()

        defaults.set("  spaced  ", forKey: "vpnPassword")

        _ = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        XCTAssertEqual(secrets.retrieve(account: "vpnPassword"), "  spaced  ",
                       "a password is stored verbatim, only blank is treated as absent")
    }

    // MARK: Deletion

    func testEveryDeadKeyIsRemovedIncludingThePacEraOnes() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for key in SettingsManager.legacyDefaultsKeys { defaults.set("value", forKey: key) }

        let purged = SettingsManager(defaults: defaults)
            .purgeLegacyDefaults(secrets: FakeSecrets())

        XCTAssertEqual(Set(purged), Set(SettingsManager.legacyDefaultsKeys))
        for key in SettingsManager.legacyDefaultsKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be gone")
        }
    }

    func testLiveKeysAreLeftAlone() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("Main", forKey: "activeProfileName")
        defaults.set("dark", forKey: "appTheme")
        defaults.set(true, forKey: "legacyPACCleaned")
        defaults.set(true, forKey: "systemProxyEnabled")
        defaults.set(true, forKey: "useProxyEngine")
        defaults.set(["a.com"], forKey: "vpnSliceURLs")
        defaults.set("2026-01-01", forKey: "VPNConnectConnectionHistory")
        defaults.set("value", forKey: "adminPassword")

        _ = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: FakeSecrets())

        XCTAssertEqual(defaults.string(forKey: "activeProfileName"), "Main")
        XCTAssertEqual(defaults.string(forKey: "appTheme"), "dark")
        XCTAssertTrue(defaults.bool(forKey: "legacyPACCleaned"))
        XCTAssertTrue(defaults.bool(forKey: "systemProxyEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "useProxyEngine"))
        XCTAssertEqual(defaults.stringArray(forKey: "vpnSliceURLs"), ["a.com"])
        XCTAssertEqual(defaults.string(forKey: "VPNConnectConnectionHistory"), "2026-01-01")
        XCTAssertNil(defaults.object(forKey: "adminPassword"))
    }

    func testNoCredentialIsEverWrittenBackToDefaults() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets(items: ["adminPassword": "from-keychain"])

        _ = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        for account in KeychainHelper.credentialAccounts {
            XCTAssertNil(defaults.object(forKey: account),
                         "\(account) must never live in UserDefaults")
        }
    }

    // MARK: Idempotence

    func testRunningItAgainIsHarmlessAndDoesNotRewriteTheKeychain() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets()

        defaults.set("hunter2", forKey: "adminPassword")

        let first = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)
        XCTAssertFalse(first.isEmpty)

        let second = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        XCTAssertTrue(second.isEmpty, "there is nothing left to purge")
        XCTAssertEqual(secrets.stored.count, 1, "the Keychain was written exactly once")
        XCTAssertEqual(secrets.retrieve(account: "adminPassword"), "hunter2")
    }

    func testItSelfHealsIfADeadKeyReappears() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets(items: ["adminPassword": "current"])

        _ = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        // Something wrote the key again (an old build, a restored plist).
        defaults.set("old-build-value", forKey: "proxyConfigurations")
        defaults.set("old-build-value", forKey: "useProxy")

        let purged = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        XCTAssertEqual(Set(purged), ["proxyConfigurations", "useProxy"])
        XCTAssertNil(defaults.object(forKey: "proxyConfigurations"))
        XCTAssertNil(defaults.object(forKey: "useProxy"))
    }

    func testACleanInstallIsANoOp() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = FakeSecrets()

        let purged = SettingsManager(defaults: defaults).purgeLegacyDefaults(secrets: secrets)

        XCTAssertTrue(purged.isEmpty)
        XCTAssertTrue(secrets.stored.isEmpty)
    }
}
