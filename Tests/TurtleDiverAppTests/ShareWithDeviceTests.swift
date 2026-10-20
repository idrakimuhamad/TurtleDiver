import XCTest
import Foundation
import CryptoKit
@testable import TurtleDiverAppGlue
import TurtleDiverCore
import TurtleDiverSystem

// MARK: - LAN address selection

/// The *policy* half of ``LANAddress``, exercised with fake interfaces so the
/// test does not depend on this machine's real network.
final class ShareWithDeviceLANAddressTests: XCTestCase {

    private func iface(
        _ name: String,
        _ address: String,
        up: Bool = true,
        loopback: Bool = false
    ) -> LANAddress.Interface {
        LANAddress.Interface(name: name, address: address, isUp: up, isLoopback: loopback)
    }

    private func path(_ name: String, _ kind: LANAddress.InterfaceKind) -> LANAddress.PathInterface {
        LANAddress.PathInterface(name: name, kind: kind)
    }

    // MARK: Preferred-name selection (the path's own ordering)

    func testPreferredNamesKeepWifiAndWiredEthernetInSystemOrder() {
        let names = LANAddress.preferredNames(from: [
            path("en0", .wiredEthernet),
            path("utun3", .other),
            path("en1", .wifi),
        ])
        XCTAssertEqual(names, ["en0", "en1"])
    }

    /// The system's preference outranks the name heuristic: the interface the
    /// machine would actually route through is the one the phone can reach,
    /// even when a "nicer looking" one exists.
    func testPreferredNameWinsOverTheHeuristic() {
        let picked = LANAddress.primaryLANIPv4(
            preferredNames: ["en5"],
            from: [
                iface("en0", "10.0.0.1"),
                iface("en5", "192.168.1.42"),
            ]
        )
        XCTAssertEqual(picked, "192.168.1.42")
    }

    func testPreferredNameWithUnusableAddressIsSkipped() {
        let linkLocal = LANAddress.primaryLANIPv4(
            preferredNames: ["en1"],
            from: [
                iface("en1", "169.254.7.7"),
                iface("en0", "10.0.0.1"),
            ]
        )
        XCTAssertEqual(linkLocal, "10.0.0.1", "a self-assigned address must not win")

        let down = LANAddress.primaryLANIPv4(
            preferredNames: ["en1"],
            from: [
                iface("en1", "192.168.1.9", up: false),
                iface("en0", "10.0.0.1"),
            ]
        )
        XCTAssertEqual(down, "10.0.0.1", "a down interface must not win")
    }

    func testFallsBackToTheHeuristicWhenNoPreferredNameIsPresent() {
        let picked = LANAddress.primaryLANIPv4(
            preferredNames: ["en9"],
            from: [iface("en0", "10.0.0.1")]
        )
        XCTAssertEqual(picked, "10.0.0.1")

        let empty = LANAddress.primaryLANIPv4(preferredNames: [], from: [iface("en0", "10.0.0.1")])
        XCTAssertEqual(empty, "10.0.0.1")
    }

    // MARK: The heuristic

    func testPicksTheEn0Address() {
        let picked = LANAddress.primaryLANIPv4(from: [
            iface("lo0", "127.0.0.1", loopback: true),
            iface("en0", "192.168.1.42"),
        ])
        XCTAssertEqual(picked, "192.168.1.42")
    }

    func testIgnoresLoopbackAndDownInterfaces() {
        let picked = LANAddress.primaryLANIPv4(from: [
            iface("lo0", "127.0.0.1", loopback: true),
            iface("en0", "192.168.1.42", up: false),
            iface("en1", "10.0.0.7"),
        ])
        XCTAssertEqual(picked, "10.0.0.7")
    }

    func testIgnoresNonLanInterfacePrefixes() {
        let picked = LANAddress.primaryLANIPv4(from: [
            iface("utun0", "10.8.0.2"),
            iface("ipsec0", "10.9.0.2"),
            iface("ppp0", "10.10.0.2"),
            iface("awdl0", "169.254.1.1"),
            iface("llw0", "169.254.2.2"),
            iface("en0", "192.168.1.42"),
        ])
        XCTAssertEqual(picked, "192.168.1.42")
    }

    func testIgnoresLinkLocalAddress() {
        let picked = LANAddress.primaryLANIPv4(from: [
            iface("en0", "169.254.33.4"),
        ])
        XCTAssertNil(picked)
    }

    func testPrefersEnOverBridgeAndOrdersByName() {
        let picked = LANAddress.primaryLANIPv4(from: [
            iface("bridge0", "10.0.1.5"),
            iface("en1", "10.0.2.6"),
            iface("en0", "10.0.3.7"),
        ])
        XCTAssertEqual(picked, "10.0.3.7")

        let bridge = LANAddress.primaryLANIPv4(from: [
            iface("bridge0", "10.0.1.5"),
            iface("bridge1", "10.0.0.5"),
        ])
        XCTAssertEqual(bridge, "10.0.1.5")
    }

    func testReturnsNilWhenNothingIsEligible() {
        XCTAssertNil(LANAddress.primaryLANIPv4(from: []))
        XCTAssertNil(LANAddress.primaryLANIPv4(from: [
            iface("lo0", "127.0.0.1", loopback: true),
            iface("utun3", "10.8.0.2"),
        ]))
    }
}

// MARK: - Share password generation

final class ShareWithDevicePasswordTests: XCTestCase {

    /// The characters that must never appear: the ones that are read as each
    /// other on a phone's on-screen keyboard.
    private let ambiguous: Set<Character> = ["0", "O", "1", "l", "I"]

    /// A deterministic generator, so "same seed, same password" can be asserted
    /// without depending on the system's entropy source.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testGeneratedPasswordHasFixedLengthAndUnambiguousAlphabet() {
        for _ in 0..<50 {
            let password = KeychainHelper.generateSharePassword()
            XCTAssertEqual(password.count, KeychainHelper.sharePasswordLength)
            XCTAssertTrue(password.allSatisfy { KeychainHelper.sharePasswordAlphabet.contains($0) })
            XCTAssertTrue(password.allSatisfy { !ambiguous.contains($0) })
        }
    }

    func testGenerationIsDeterministicForAGivenGenerator() {
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        let a = KeychainHelper.generateSharePassword(using: &first)
        let b = KeychainHelper.generateSharePassword(using: &second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, KeychainHelper.sharePasswordLength)
        XCTAssertTrue(a.allSatisfy { !ambiguous.contains($0) })
    }

    /// The username is a fixed, non-secret constant — not a credential.
    func testUsernameIsTheFixedConstant() {
        XCTAssertEqual(KeychainHelper.shareUsername, "turtle")
    }
}

// MARK: - Reconcile state machine

/// Drives ``EngineController/reconcileSharing()`` through the states that do
/// not require the engine to actually bind a shared listener.
@MainActor
final class ShareWithDeviceTests: XCTestCase {

    /// In-memory `SecretStore` so the tests never touch the login keychain, with
    /// switches for the failures the Keychain can produce.
    private final class FakeSecrets: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]
        private var _deleted: [String] = []

        /// What `lookup` answers; `nil` means "answer from the stored items".
        var forcedLookup: SecretLookup?
        /// When false, every write is reported as having failed.
        var storeSucceeds = true
        /// Called after a delete lands, so a test can see the order of events.
        var onDelete: (() -> Void)?
        private var _lookups = 0
        private var _stores = 0

        /// How often a password was read from / written to the store. A reset
        /// must not increase either: it deletes, it does not resolve.
        var lookups: Int {
            lock.lock(); defer { lock.unlock() }
            return _lookups
        }

        var stores: Int {
            lock.lock(); defer { lock.unlock() }
            return _stores
        }

        var deleted: [String] {
            lock.lock(); defer { lock.unlock() }
            return _deleted
        }

        var storedPassword: String? {
            lock.lock(); defer { lock.unlock() }
            return items[KeychainHelper.sharePasswordAccount]
        }

        func retrieve(account: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return items[account]
        }

        func store(password: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            _stores += 1
            items[account] = password
        }

        func delete(account: String) {
            lock.lock()
            items.removeValue(forKey: account)
            _deleted.append(account)
            lock.unlock()
            onDelete?()
        }

        func lookup(account: String) -> SecretLookup {
            lock.lock()
            _lookups += 1
            lock.unlock()
            if let forcedLookup { return forcedLookup }
            lock.lock(); defer { lock.unlock() }
            return items[account].map(SecretLookup.value) ?? .missing
        }

        func storeReportingFailure(password: String, account: String) -> Bool {
            guard storeSucceeds else { return false }
            store(password: password, account: account)
            return true
        }
    }

    /// Answers `networksetup` without shelling out.
    private final class SilentRunner: NetworkSetupRunning, @unchecked Sendable {
        func run(arguments: [String]) throws -> String {
            switch arguments.first {
            case "-listallnetworkservices":
                return "Wi-Fi\n"
            case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
                return "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n"
            default:
                return ""
            }
        }
    }

    private struct Harness {
        let controller: EngineController
        let manager: ProfileManager
        let settings: SettingsManager
        let tunnel: StubTunnelStatus
        let secrets: FakeSecrets
        let suiteName: String
    }

    /// Distinct high ports per harness so tests never fight each other (or a
    /// stray service) for a listener, the way the default `6153` did.
    private static var portCounter = 17100
    private static func nextPorts() -> (http: Int, socks: Int) {
        portCounter += 2
        return (portCounter, portCounter + 1)
    }

    private func makeHarness(
        lanAddress: @escaping ([String]) -> String?,
        httpDisabled: Bool = false
    ) -> Harness {
        let suiteName = "turtlediver.share.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let manager = ProfileManager(profilesDirectory: directory, defaults: defaults)
        let ports = Self.nextPorts()
        var profile = manager.activeProfile
        profile.general.httpListen = httpDisabled ? "" : "127.0.0.1:\(ports.http)"
        profile.general.socks5Listen = "127.0.0.1:\(ports.socks)"
        profile.general.systemProxy = false
        _ = manager.saveAndActivate(profile)

        let secrets = FakeSecrets()
        let settings = SettingsManager(preferences: .suite(suiteName), secrets: secrets)
        let systemProxy = SystemProxyManager(
            runner: SilentRunner(),
            defaults: defaults,
            snapshotURL: directory.appendingPathComponent("proxy-snapshot.json")
        )
        let tunnel = StubTunnelStatus()
        let controller = EngineController(
            profileManager: manager,
            settings: settings,
            systemProxy: systemProxy,
            secrets: secrets,
            tunnel: tunnel,
            lanAddress: lanAddress
        )
        return Harness(
            controller: controller,
            manager: manager,
            settings: settings,
            tunnel: tunnel,
            secrets: secrets,
            suiteName: suiteName
        )
    }

    /// Polls a main-actor condition while yielding so Combine-delivered changes
    /// (hops onto the main queue) can land.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(description)")
    }

    private func isFailed(_ state: ShareState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    // MARK: States

    /// Setting off → `.off`.
    func testOffWhenSettingIsOff() {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        XCTAssertFalse(h.settings.shareWithDevice)
        XCTAssertEqual(h.controller.shareState, .off)
    }

    /// Setting on, engine not running → `.waitingForEngine`.
    func testWaitingForEngineWhenEngineIsNotRunning() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        XCTAssertFalse(h.controller.engineRunning)

        h.settings.shareWithDevice = true

        await waitUntil("waitingForEngine") { h.controller.shareState == .waitingForEngine }
    }

    /// Engine up, tunnel down → `.waitingForTunnel` (never share the plain
    /// connection).
    func testWaitingForTunnelWhenTunnelIsDown() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        h.controller.setEngineEnabled(true)
        XCTAssertTrue(h.controller.engineRunning, h.controller.lastError ?? "")

        h.settings.shareWithDevice = true

        await waitUntil("waitingForTunnel") { h.controller.shareState == .waitingForTunnel }
    }

    /// Engine up, tunnel up, no LAN IPv4 → `.noNetwork`.
    func testNoNetworkWhenNoLANAddress() async {
        let h = makeHarness(lanAddress: { _ in nil })
        h.controller.setEngineEnabled(true)
        XCTAssertTrue(h.controller.engineRunning, h.controller.lastError ?? "")
        h.tunnel.set(.connected)

        h.settings.shareWithDevice = true

        await waitUntil("noNetwork") { h.controller.shareState == .noNetwork }
    }

    /// No running HTTP listener → `.failed`, rather than silently sharing
    /// nothing.
    func testFailedWhenHTTPListenerIsOff() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" }, httpDisabled: true)
        h.controller.setEngineEnabled(true)
        XCTAssertTrue(h.controller.engineRunning, h.controller.lastError ?? "")
        XCTAssertNil(h.controller.httpPort)
        h.tunnel.set(.connected)

        h.settings.shareWithDevice = true

        await waitUntil("failed") { self.isFailed(h.controller.shareState) }
        XCTAssertEqual(h.controller.shareState, .failed("The HTTP listener is off."))
    }

    /// The share must aim at the port the engine is *actually* listening on, not
    /// the one the profile now asks for: editing `http-listen` rewrites rules, it
    /// does not rebind the loopback listener. A share attempt that reaches
    /// `startSharing` proves the running port was used — the profile's empty
    /// `http-listen` would otherwise have stopped it at the guard.
    func testShareUsesTheRunningListenerWhenTheProfileNoLongerAsksForOne() async throws {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        h.controller.setEngineEnabled(true)
        let runningPort = try XCTUnwrap(h.controller.httpPort)

        var profile = h.manager.activeProfile
        profile.general.httpListen = ""
        _ = h.manager.saveAndActivate(profile)
        XCTAssertEqual(h.controller.httpPort, runningPort, "a profile edit must not unbind the listener")

        h.tunnel.set(.connected)
        h.settings.shareWithDevice = true

        // Whatever the bind to a non-local address does, it has to have been
        // attempted on the running listener's port.
        await waitUntil("a share attempt on the running listener") {
            switch h.controller.shareState {
            case .active:
                return true
            case .failed(let message):
                return message.contains("bind 192.168.1.50:\(runningPort)")
            default:
                return false
            }
        }
    }

    /// Dropping the tunnel moves a would-be share out of `noNetwork` (an
    /// already-on path) to `.waitingForTunnel` — the reconcile that stops the
    /// share runs on the disconnect.
    func testTunnelDropWaitsForTunnel() async {
        let h = makeHarness(lanAddress: { _ in nil })
        h.controller.setEngineEnabled(true)
        h.tunnel.set(.connected)
        h.settings.shareWithDevice = true
        await waitUntil("noNetwork") { h.controller.shareState == .noNetwork }

        h.tunnel.set(.disconnected)

        await waitUntil("waitingForTunnel after the drop") {
            h.controller.shareState == .waitingForTunnel
        }
    }

    /// Turning the setting back off returns to `.off`.
    func testTurningSettingOffReturnsToOff() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        h.controller.setEngineEnabled(true)
        h.settings.shareWithDevice = true
        await waitUntil("waitingForTunnel") { h.controller.shareState == .waitingForTunnel }

        h.settings.shareWithDevice = false

        await waitUntil("off") { h.controller.shareState == .off }
    }

    // MARK: Password

    /// Loaded once, persisted, and reused: the value on screen is the value the
    /// engine is given.
    func testSharePasswordIsGeneratedOnceAndStable() {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        XCTAssertNil(h.controller.sharePassword, "nothing is loaded until it is asked for")

        let first = h.controller.ensureSharePassword()

        XCTAssertEqual(first?.count, KeychainHelper.sharePasswordLength)
        XCTAssertEqual(h.controller.sharePassword, first)
        XCTAssertEqual(h.secrets.storedPassword, first, "the generated password must be persisted")
        XCTAssertNil(h.controller.sharePasswordError)
        XCTAssertEqual(h.controller.ensureSharePassword(), first, "the second ask must not regenerate")
    }

    /// The password is created as soon as the user turns sharing on, so the phone
    /// can be set up before the tunnel is up.
    func testTurningSharingOnLoadsThePassword() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        h.settings.shareWithDevice = true

        await waitUntil("the password to be loaded") { h.controller.sharePassword != nil }
    }

    func testRegenerateSharePasswordReplacesTheStoredOne() {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        let first = h.controller.ensureSharePassword()

        h.controller.regenerateSharePassword()

        let second = h.controller.sharePassword
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(h.secrets.storedPassword, second)
        XCTAssertNil(h.controller.sharePasswordError)
    }

    /// A Keychain that *refuses* to answer must never be answered with a freshly
    /// invented password: the phone would hold one nothing on the Mac agrees
    /// with.
    func testKeychainReadFailureSurfacesAndDoesNotInventAPassword() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        h.secrets.forcedLookup = .failed
        h.controller.setEngineEnabled(true)
        h.tunnel.set(.connected)

        h.settings.shareWithDevice = true

        await waitUntil("a share password failure") { self.isFailed(h.controller.shareState) }
        XCTAssertNil(h.controller.sharePassword)
        XCTAssertNil(h.secrets.storedPassword, "nothing may be written when the store cannot be read")
        XCTAssertEqual(h.controller.sharePasswordError, "Couldn't read the share password from the Keychain.")
    }

    /// A password that could not be persisted must not be handed out either.
    func testKeychainWriteFailureSurfaces() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        h.secrets.storeSucceeds = false
        h.controller.setEngineEnabled(true)
        h.tunnel.set(.connected)

        h.settings.shareWithDevice = true

        await waitUntil("a share password failure") { self.isFailed(h.controller.shareState) }
        XCTAssertNil(h.controller.sharePassword)
        XCTAssertNil(h.secrets.storedPassword)
        XCTAssertEqual(h.controller.sharePasswordError, "Couldn't save the share password to the Keychain.")
    }

    // MARK: Client approvals

    /// Approving a client records it in settings and stops being refused.
    func testAllowShareClientRecordsAddress() {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        h.controller.allowShareClient("192.168.1.77")
        XCTAssertEqual(h.settings.shareAllowedClients, ["192.168.1.77"])

        // Idempotent: approving twice does not duplicate.
        h.controller.allowShareClient("192.168.1.77")
        XCTAssertEqual(h.settings.shareAllowedClients, ["192.168.1.77"])

        h.controller.removeShareClient("192.168.1.77")
        XCTAssertEqual(h.settings.shareAllowedClients, [])
    }

    // MARK: Reset — the preference domain

    /// "Reset all settings" wipes the domain the manager was *built on*, and
    /// nothing else.
    ///
    /// The regression: a manager built on a disposable suite still called
    /// `removePersistentDomain(forName: AppIdentity.bundleIdentifier)`, so a
    /// test run deleted the real preferences of whoever ran it. The sentinel
    /// below lives in the application's own domain; it is snapshotted, written
    /// and restored around the reset, and must survive untouched.
    func testResetWipesOnlyTheDomainItWasBuiltOn() async throws {
        let suiteName = "turtlediver.reset.domain.\(UUID().uuidString)"
        let store = PreferenceStore.suite(suiteName)
        let defaults = store.defaults
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("wipe-me", forKey: "shareWithDevice")
        let settings = SettingsManager(preferences: store, secrets: FakeSecrets())

        // Sentinel in the application's domain, restored whatever happens.
        let appDomain = try XCTUnwrap(UserDefaults(suiteName: AppIdentity.bundleIdentifier))
        let sentinelKey = "turtlediver.test.resetSentinel.\(UUID().uuidString)"
        let previous = appDomain.object(forKey: sentinelKey)
        defer {
            if let previous = previous {
                appDomain.set(previous, forKey: sentinelKey)
            } else {
                appDomain.removeObject(forKey: sentinelKey)
            }
            appDomain.synchronize()
        }
        appDomain.set("keep-me", forKey: sentinelKey)
        appDomain.synchronize()

        await settings.resetAllSettings()

        XCTAssertNil(defaults.object(forKey: "shareWithDevice"),
                     "the suite the manager was built on must be wiped")
        XCTAssertEqual(appDomain.string(forKey: sentinelKey), "keep-me",
                       "a reset built on a disposable suite must not touch the app's own domain")
        XCTAssertFalse(settings.isResetting)
    }

    // MARK: Reset — a live share

    /// Reset on a share that is really running (engine up, tunnel connected,
    /// listener bound), with a stale "sharing is on" event landing in the middle
    /// of the awaited teardown.
    ///
    /// The race: while `resetAllSettings()` awaits its teardown hook, a queued
    /// `shareWithDevice == true` event can arrive and call `reconcileSharing()` /
    /// `ensureSharePassword()` — restarting the listener, or recreating the very
    /// password the reset is about to delete. Nothing may happen: the reset is
    /// marked in progress synchronously, before the first suspension.
    func testResetRevokesALiveShareAndCannotRestartOneMidTeardown() async throws {
        // A real listener needs a real local address to bind; without one there
        // is nothing to share over, and nothing to revoke.
        guard let lan = LANAddress.primaryLANIPv4() else {
            throw XCTSkip("this machine has no LAN IPv4, so a live share cannot bind")
        }

        let h = makeHarness(lanAddress: { _ in lan })
        h.controller.setEngineEnabled(true)
        XCTAssertTrue(h.controller.engineRunning, h.controller.lastError ?? "")
        h.tunnel.set(.connected)
        h.settings.shareWithDevice = true

        await waitUntil("an active share") {
            if case .active(let host, _) = h.controller.shareState { return host == lan }
            return false
        }
        let port = try XCTUnwrap(h.controller.httpPort)
        XCTAssertEqual(h.controller.shareState, .active(host: lan, port: port))
        XCTAssertNotNil(h.controller.engine.sharingAddress, "the share listener must really be up")
        let oldPassword = try XCTUnwrap(h.controller.sharePassword)
        XCTAssertEqual(h.secrets.storedPassword, oldPassword)

        // What the reset looks like at the moment the credentials are deleted.
        var stateAtDeletion: ShareState?
        var listenerAtDeletion: (host: String, port: Int)?
        var passwordAtDeletion: String?
        h.secrets.onDelete = {
            stateAtDeletion = h.controller.shareState
            listenerAtDeletion = h.controller.engine.sharingAddress
            passwordAtDeletion = h.controller.sharePassword
        }

        // What the mid-teardown interleave sees.
        var stateDuringTeardown: ShareState?
        var listenerDuringTeardown: (host: String, port: Int)?
        var ensuredDuringTeardown: String?
        var allowedDuringTeardown: [String] = []

        let lookupsBefore = h.secrets.lookups
        let storesBefore = h.secrets.stores

        // Wrap the app's own teardown hook rather than replacing it, so the
        // production wiring stays in place and the stale event lands *inside*
        // the window the reset awaits.
        let appTeardown = h.settings.onResetWillDeleteCredentials
        h.settings.onResetWillDeleteCredentials = { [weak controller = h.controller,
                                                   weak settings = h.settings] in
            await appTeardown?()

            // A stale event that captured `true` before the reset: it flips the
            // intent back on and drives a reconcile, mid-reset.
            settings?.shareWithDevice = true
            controller?.reconcileSharing()
            ensuredDuringTeardown = controller?.ensureSharePassword()
            controller?.allowShareClient("10.9.9.9")
            allowedDuringTeardown = settings?.shareAllowedClients ?? []

            stateDuringTeardown = controller?.shareState
            listenerDuringTeardown = controller?.engine.sharingAddress
        }

        await h.settings.resetAllSettings()

        // Mid-teardown: nothing restarted, nothing was read or written.
        XCTAssertEqual(stateDuringTeardown, ShareState.off)
        XCTAssertNil(listenerDuringTeardown, "a reconcile during the reset must not restart the share")
        XCTAssertNil(ensuredDuringTeardown, "the share password must not be resolved mid-reset")
        XCTAssertEqual(allowedDuringTeardown, [], "a client cannot be approved mid-reset")

        // At deletion time: the listener is already gone and so is the cached copy.
        XCTAssertEqual(stateAtDeletion, ShareState.off)
        XCTAssertNil(listenerAtDeletion, "no listener may be serving when the credential is deleted")
        XCTAssertNil(passwordAtDeletion, "the cached password must be gone before the credential is deleted")

        // The password was never read from or written to the store again.
        XCTAssertEqual(h.secrets.lookups, lookupsBefore, "a reset must not read the share password")
        XCTAssertEqual(h.secrets.stores, storesBefore, "a reset must not write the share password")

        // End state: disabled, empty, off — and the credential is gone.
        XCTAssertFalse(h.settings.shareWithDevice)
        XCTAssertEqual(h.settings.shareAllowedClients, [])
        XCTAssertEqual(h.controller.shareState, .off)
        XCTAssertNil(h.controller.sharePassword)
        XCTAssertNil(h.controller.engine.sharingAddress)
        XCTAssertFalse(h.settings.isResetting)
        XCTAssertNil(h.secrets.storedPassword, "the old password must be deleted")
        XCTAssertTrue(h.secrets.deleted.contains(KeychainHelper.sharePasswordAccount),
                      "the share password must be deleted: \(h.secrets.deleted)")
        XCTAssertFalse(UserDefaults(suiteName: h.suiteName)!
            .bool(forKey: "shareWithDevice"),
                       "the disposable suite is wiped too")
    }

    /// After a reset the next share gets a brand-new password, not the one the
    /// user had on their phone.
    func testResetAllSettingsForgetsTheOldPassword() async {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        let before = h.controller.ensureSharePassword()

        await h.settings.resetAllSettings()

        let after = h.controller.ensureSharePassword()
        XCTAssertNotNil(after)
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(h.secrets.storedPassword, after)
    }

    // MARK: PAC URL

    /// Derived here independently of the generator: the URL is part of the
    /// app/engine contract, not an implementation detail of one helper.
    private func pacToken(_ password: String) -> String {
        let digest = SHA256.hash(data: Data("turtlediver-pac:\(password)".utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
    }

    func testSharePACURLIsNilWhileSharingIsOff() {
        let h = makeHarness(lanAddress: { _ in "192.168.1.50" })
        XCTAssertNotNil(h.controller.ensureSharePassword(), "a password alone does not start a share")
        XCTAssertNil(h.controller.sharePACURL)
        XCTAssertEqual(h.controller.shareState, .off)
    }

    /// Active share → a URL carrying the listener and the password-derived
    /// token. Regenerating the password rotates it; turning sharing off clears
    /// it.
    func testSharePACURLFollowsTheActiveShareAndPassword() async throws {
        guard let lan = LANAddress.primaryLANIPv4() else {
            throw XCTSkip("this machine has no LAN IPv4, so a live share cannot bind")
        }

        let h = makeHarness(lanAddress: { _ in lan })
        h.controller.setEngineEnabled(true)
        XCTAssertTrue(h.controller.engineRunning, h.controller.lastError ?? "")
        h.tunnel.set(.connected)
        h.settings.shareWithDevice = true

        await waitUntil("an active share") {
            if case .active(let host, _) = h.controller.shareState { return host == lan }
            return false
        }
        let port = try XCTUnwrap(h.controller.httpPort)
        let password = try XCTUnwrap(h.controller.sharePassword)
        let expected = "http://\(lan):\(port)/\(pacToken(password))/proxy.pac"
        XCTAssertEqual(h.controller.sharePACURL, expected)

        h.controller.regenerateSharePassword()
        let newPassword = try XCTUnwrap(h.controller.sharePassword)
        XCTAssertNotEqual(newPassword, password)
        XCTAssertEqual(
            h.controller.sharePACURL,
            "http://\(lan):\(port)/\(pacToken(newPassword))/proxy.pac"
        )
        XCTAssertNotEqual(h.controller.sharePACURL, expected, "the old URL must be revoked")

        h.settings.shareWithDevice = false
        await waitUntil("off") { h.controller.shareState == .off }
        XCTAssertNil(h.controller.sharePACURL)
    }
}
