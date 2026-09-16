import XCTest
@testable import TurtleDiverAppGlue
import TurtleDiverSystem

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

    // MARK: Bundle-identifier rename

    /// The rename from `com.idraki.turtle.vpn` to `com.xvii.kurakura.vpn` moves
    /// the Keychain *service*, so every stored credential lives somewhere the
    /// app no longer looks. This is the plan that copies them across — decided
    /// from an injected reader, so no test ever opens the login keychain (a real
    /// read of another identity's item raises a system dialog).
    private func makeMigrationReader(
        _ items: [String: [String: String]]
    ) -> (_ service: String, _ account: String) -> String? {
        { service, account in items[service]?[account] }
    }

    func testACredentialOnlyInTheLegacyServiceIsCopiedFromIt() {
        let read = makeMigrationReader(["com.idraki.turtle.vpn": ["vpnPassword": "old"]])

        let plan = KeychainMigration.sources(
            accounts: ["vpnPassword"],
            currentService: "com.xvii.kurakura.vpn",
            legacyServices: ["com.idraki.turtle.vpn"],
            read: read
        )

        XCTAssertEqual(plan.map(\.account), ["vpnPassword"])
        XCTAssertEqual(plan.map(\.service), ["com.idraki.turtle.vpn"])
    }

    /// Once copied, a second launch must not copy again — and must not read the
    /// legacy item again, which is what would re-raise the access dialog.
    func testACredentialAlreadyInTheCurrentServiceIsLeftAlone() {
        var legacyReads = 0
        let plan = KeychainMigration.sources(
            accounts: ["vpnPassword"],
            currentService: "com.xvii.kurakura.vpn",
            legacyServices: ["com.idraki.turtle.vpn"],
            read: { service, _ in
                if service == "com.idraki.turtle.vpn" { legacyReads += 1 }
                return "value"
            }
        )

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(legacyReads, 0, "the legacy service was read despite the current one having a value")
    }

    func testAnEmptyLegacyValueIsNotCopied() {
        let read = makeMigrationReader(["com.idraki.turtle.vpn": ["vpnPassword": ""]])

        let plan = KeychainMigration.sources(
            accounts: ["vpnPassword"],
            currentService: "com.xvii.kurakura.vpn",
            legacyServices: ["com.idraki.turtle.vpn"],
            read: read
        )

        XCTAssertTrue(plan.isEmpty)
    }

    func testAnAccountNobodyHasIsSkipped() {
        let read = makeMigrationReader([:])

        let plan = KeychainMigration.sources(
            accounts: ["vpnPassword", "adminPassword"],
            currentService: "com.xvii.kurakura.vpn",
            legacyServices: ["com.idraki.turtle.vpn", "com.turtlediver"],
            read: read
        )

        XCTAssertTrue(plan.isEmpty)
    }

    /// With more than one historical name, the newest source wins — an older
    /// build's value must never overwrite a newer one.
    func testTheNewestLegacyServiceWinsWhenSeveralHaveAValue() {
        let read = makeMigrationReader([
            "com.idraki.turtle.vpn": ["vpnPassword": "newest"],
            "com.turtlediver": ["vpnPassword": "ancient"],
        ])

        let plan = KeychainMigration.sources(
            accounts: ["vpnPassword"],
            currentService: "com.xvii.kurakura.vpn",
            legacyServices: ["com.idraki.turtle.vpn", "com.turtlediver"],
            read: read
        )

        XCTAssertEqual(plan.map(\.service), ["com.idraki.turtle.vpn"])
    }

    func testThePlanFollowsTheAccountOrderItWasGiven() {
        let read = makeMigrationReader([
            "com.idraki.turtle.vpn": ["vpnPasscode": "c", "adminPassword": "a", "vpnPassword": "b"],
        ])

        let plan = KeychainMigration.sources(
            accounts: ["adminPassword", "vpnPassword", "vpnPasscode"],
            currentService: "com.xvii.kurakura.vpn",
            legacyServices: ["com.idraki.turtle.vpn"],
            read: read
        )

        XCTAssertEqual(plan.map(\.account), ["adminPassword", "vpnPassword", "vpnPasscode"])
    }

    /// The service the app writes under is `AppIdentity`'s, not the bundle's —
    /// the two are only equal because the project says so.
    func testTheAppStoresUnderTheIdentityTheMigrationCopiesInto() {
        XCTAssertEqual(KeychainHelper.serviceName, AppIdentity.bundleIdentifier)
    }

    // MARK: Applying the plan

    /// The apply step exists because the reads that built the plan can be
    /// minutes old: answering the access dialog is not instant, and the VPN
    /// pane is already on screen showing *NOT SET* while it waits.
    private func apply(
        _ plan: [(account: String, service: String)],
        items: [String: [String: String]]
    ) -> (copied: [String], written: [(String, String, String)]) {
        var store = items
        var written: [(String, String, String)] = []
        let copied = KeychainMigration.apply(
            plan: plan,
            currentService: "com.xvii.kurakura.vpn",
            read: { service, account in store[service]?[account] },
            write: { service, account, value in
                store[service, default: [:]][account] = value
                written.append((service, account, value))
            }
        )
        return (copied, written)
    }

    func testApplyingThePlanCopiesIntoTheCurrentService() {
        let result = apply(
            [("vpnPassword", "com.idraki.turtle.vpn")],
            items: ["com.idraki.turtle.vpn": ["vpnPassword": "old"]]
        )

        XCTAssertEqual(result.copied, ["vpnPassword"])
        XCTAssertEqual(result.written.count, 1)
        XCTAssertEqual(result.written.first?.0, "com.xvii.kurakura.vpn")
        XCTAssertEqual(result.written.first?.2, "old")
    }

    /// The user retyped the credential while the dialog was open — their value
    /// wins, and the stale plan does not clobber it.
    func testAValueThatAppearedWhileTheDialogWasOpenIsNotOverwritten() {
        let result = apply(
            [("vpnPassword", "com.idraki.turtle.vpn")],
            items: [
                "com.idraki.turtle.vpn": ["vpnPassword": "old"],
                "com.xvii.kurakura.vpn": ["vpnPassword": "typed by the user"],
            ]
        )

        XCTAssertTrue(result.copied.isEmpty)
        XCTAssertTrue(result.written.isEmpty)
    }

    /// An empty item counts as missing, so a user who saved an empty field
    /// (the VPN pane's Save writes what is on screen) cannot block the copy.
    func testAnEmptyCurrentValueDoesNotBlockTheCopy() {
        let result = apply(
            [("vpnPassword", "com.idraki.turtle.vpn")],
            items: [
                "com.idraki.turtle.vpn": ["vpnPassword": "old"],
                "com.xvii.kurakura.vpn": ["vpnPassword": ""],
            ]
        )

        XCTAssertEqual(result.copied, ["vpnPassword"])
        XCTAssertEqual(result.written.first?.2, "old")
    }

    func testAnAccountWhoseLegacyValueVanishedIsSkipped() {
        let result = apply([("vpnPassword", "com.idraki.turtle.vpn")], items: [:])

        XCTAssertTrue(result.copied.isEmpty)
        XCTAssertTrue(result.written.isEmpty)
    }

    /// Request details hold headers — cookies included — and live only in the
    /// requests table's memory. `vpn.log` is a file on disk that outlives the
    /// app, so the capture path must not be able to write to it at all.
    func testTheRequestCapturePathNeverReferencesTheDebugLog() throws {
        let engine = repoRoot.appendingPathComponent("VPNConnect/Engine")
        let captureFiles = [
            "RequestDetail.swift", "TLSClientHello.swift", "RelayStreamObserver.swift",
            "RelayConnection.swift", "HTTPProxyServer.swift", "SOCKS5Server.swift",
        ]
        let forbidden = ["debugOutput", "logSend(", "DebugLog", "VpnConnectionLogger", "vpn.log"]

        for name in captureFiles {
            let text = try String(contentsOf: engine.appendingPathComponent(name), encoding: .utf8)
            // Comments are allowed to *talk* about the log (and do, to record
            // why the bytes stay in memory); code is not allowed to reach it.
            let code = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for symbol in forbidden {
                XCTAssertFalse(code.contains(symbol),
                               "\(name) mentions \(symbol): captured request bytes must never reach a log")
            }
        }
    }

    private var repoRoot: URL {
        // …/Tests/TurtleDiverAppTests/SecretHygieneTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
