import XCTest
import Foundation
@testable import TurtleDiverAppGlue
import TurtleDiverCore
import TurtleDiverRules
import TurtleDiverSystem

/// Records `networksetup` invocations instead of touching real system settings.
private final class RecordingNetworkSetupRunner: NetworkSetupRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []

    var commands: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }

    /// Drops the recorded calls (e.g. after the launch-time legacy PAC sweep).
    func reset() {
        lock.lock(); _commands = []; lock.unlock()
    }

    func run(arguments: [String]) throws -> String {
        lock.lock(); _commands.append(arguments); lock.unlock()
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

/// Regression tests for the engine's enable toggle.
///
/// The toggle is the only writer of `SettingsManager.useProxyEngine`, which
/// `EngineController.init` reads to decide whether to auto-start. It used to
/// start/stop the engine without persisting, so the engine silently came back
/// up disabled after every relaunch.
@MainActor
final class EngineTogglePersistenceTests: XCTestCase {

    private var settingsSuite = ""
    private var settings: SettingsManager!

    override func setUp() async throws {
        settingsSuite = "turtlediver.engine.toggle.settings.\(UUID().uuidString)"
        settings = SettingsManager(preferences: .suite(settingsSuite))
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: settingsSuite)?.removePersistentDomain(forName: settingsSuite)
        settings = nil
    }

    /// Builds a controller wired to a throwaway profile directory, a throwaway
    /// `UserDefaults` suite and a recording `networksetup` runner, so the tests
    /// never touch the user's profile, system proxy or real ports.
    private func makeController(
        httpPort: Int,
        socksPort: Int,
        tunnel: StubTunnelStatus = StubTunnelStatus()
    ) -> (controller: EngineController, manager: ProfileManager, runner: RecordingNetworkSetupRunner) {
        let suiteName = "turtlediver.engine.toggle.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engtoggle-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = tempDir.appendingPathComponent("proxy-snapshot.json")

        let manager = ProfileManager(profilesDirectory: tempDir, defaults: defaults)
        var profile = manager.activeProfile
        profile.general.httpListen = "127.0.0.1:\(httpPort)"
        profile.general.socks5Listen = "127.0.0.1:\(socksPort)"
        profile.general.systemProxy = false
        _ = manager.saveAndActivate(profile)

        let runner = RecordingNetworkSetupRunner()
        let systemProxy = SystemProxyManager(runner: runner, defaults: defaults, snapshotURL: snapshotURL)
        let controller = EngineController(
            profileManager: manager,
            settings: settings,
            systemProxy: systemProxy,
            tunnel: tunnel
        )
        return (controller, manager, runner)
    }

    func testEnablingPersistsFlagAndStartsEngine() throws {
        let (controller, _, _) = makeController(httpPort: 16152, socksPort: 16153)
        settings.useProxyEngine = false
        XCTAssertFalse(controller.engineRunning)

        controller.setEngineEnabled(true)

        // The regression: the toggle must persist its intent.
        XCTAssertTrue(settings.useProxyEngine, "enabling the engine must persist useProxyEngine")
        XCTAssertTrue(
            UserDefaults(suiteName: settingsSuite)!.bool(forKey: "useProxyEngine"),
            "the persisted flag must be readable from UserDefaults"
        )
        XCTAssertTrue(controller.engineRunning)
        XCTAssertEqual(controller.httpPort, 16152)
        XCTAssertNil(controller.lastError)

        controller.setEngineEnabled(false)
        XCTAssertFalse(settings.useProxyEngine, "disabling the engine must persist too")
        XCTAssertFalse(controller.engineRunning)
        XCTAssertNil(controller.httpPort)
        XCTAssertEqual(controller.httpPort, nil)
    }

    func testDisablingPersistsFlagWithoutEngineEverRunning() throws {
        let (controller, _, _) = makeController(httpPort: 16162, socksPort: 16163)
        settings.useProxyEngine = true

        controller.setEngineEnabled(false)

        XCTAssertFalse(settings.useProxyEngine)
        XCTAssertFalse(controller.engineRunning)
        XCTAssertEqual(controller.httpPort, nil)
    }

    func testEngineResumesOnNextLaunchFromPersistedFlag() throws {
        settings.useProxyEngine = false

        // First launch: the user turns the engine on.
        let (first, _, _) = makeController(httpPort: 16172, socksPort: 16173)
        first.setEngineEnabled(true)
        XCTAssertTrue(settings.useProxyEngine)
        XCTAssertTrue(first.engineRunning)

        // App termination stops the listeners without changing the preference.
        first.stopEngine()
        XCTAssertTrue(settings.useProxyEngine, "stopEngine must not rewrite the user's preference")

        // Second launch: a fresh controller auto-starts from the persisted flag.
        let (second, _, _) = makeController(httpPort: 16172, socksPort: 16173)
        XCTAssertTrue(second.engineRunning, "engine must auto-start on relaunch")
        XCTAssertEqual(second.httpPort, 16172)

        second.setEngineEnabled(false)
    }

    func testStartingTheEnginePublishesPoliciesImmediately() throws {
        // Regression: `policySummaries` was only refreshed by the policy store's
        // change hook, so a freshly started engine showed "No policies in the
        // active profile" on the dashboard even though routing worked.
        let (controller, _, _) = makeController(httpPort: 16192, socksPort: 16193)
        settings.useProxyEngine = false
        XCTAssertTrue(controller.policySummaries.isEmpty)

        controller.setEngineEnabled(true)

        let names = Set(controller.policySummaries.map(\.name))
        XCTAssertFalse(names.isEmpty, "the dashboard needs the profile's policies at start")
        XCTAssertTrue(names.contains("DIRECT"), "built-ins are always routable, got \(names)")
        XCTAssertTrue(names.contains("REJECT"))

        controller.setEngineEnabled(false)
    }

    func testDisablingNeverTouchesTheSystemProxy() async throws {
        let (controller, _, runner) = makeController(httpPort: 16182, socksPort: 16183)
        settings.useProxyEngine = false
        // Constructing the controller runs the one-shot legacy PAC retirement;
        // wait for it, then assert the *engine* never touches the system proxy.
        await controller.awaitLegacyPACCleanup()
        runner.reset()

        controller.setEngineEnabled(true)
        controller.setEngineEnabled(false)

        XCTAssertTrue(runner.commands.isEmpty, "the profile keeps systemProxy off, so networksetup must not run")
    }

    // MARK: Profile isolation and the runtime-only VPN overlay

    /// `EngineController` used to observe through `ProfileModelBridge.shared`,
    /// which installs itself on `ProfileManager.shared` — so every test that
    /// built a controller also created the real profiles and backups
    /// directories. Observation is instance-scoped now.
    func testBuildingControllerNeverInitialisesSharedProfileManager() {
        let before = ProfileManager.sharedInstantiationCountForTests
        _ = makeController(httpPort: 16612, socksPort: 16613)
        XCTAssertEqual(
            ProfileManager.sharedInstantiationCountForTests, before,
            "EngineController must observe its injected manager, not ProfileManager.shared"
        )
    }

    /// The vpn-slice DIRECT overlay is merged into the profile handed to the
    /// engine only. The saved file, the backups and `activeProfile` (what the
    /// rules editor shows) stay untouched.
    func testVPNOverlayIsRuntimeOnly() async throws {
        settings.useTunneling = true
        settings.vpnSliceURLs = ["10.42.0.0/16", "*.corp.example.com"]
        settings.useProxyEngine = false
        let tunnel = StubTunnelStatus()
        let (controller, manager, _) = makeController(
            httpPort: 16622, socksPort: 16623, tunnel: tunnel
        )
        controller.setEngineEnabled(true)

        let fileURL = manager.fileURL(for: "Main")
        let before = try String(contentsOf: fileURL, encoding: .utf8)
        let backupsBefore = manager.listBackups(forProfile: "Main").count

        tunnel.set(.connected)
        await settle()

        let applied = controller.engine.matcher.expandedRules
        XCTAssertTrue(
            applied.contains { $0.type == .ipCIDR && $0.value == "10.42.0.0/16" },
            "the engine should run the overlay while the tunnel is connected"
        )
        XCTAssertTrue(applied.contains { $0.type == .domainSuffix && $0.value == "corp.example.com" })
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before,
                       "the overlay must not be written to the profile")
        XCTAssertEqual(manager.listBackups(forProfile: "Main").count, backupsBefore,
                       "a runtime overlay must not create backups")
        XCTAssertFalse(
            manager.activeProfile.rules.contains { $0.type == .ipCIDR && $0.value == "10.42.0.0/16" },
            "activeProfile is what the rules editor reads; it stays as saved"
        )

        tunnel.set(.disconnected)
        await settle()

        XCTAssertFalse(
            controller.engine.matcher.expandedRules.contains {
                $0.type == .ipCIDR && $0.value == "10.42.0.0/16"
            },
            "disconnecting must drop the overlay"
        )
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), before)
    }

    /// Builds that used to save the overlay left it at the top of the file.
    /// Restoring a backup that contains it is cleaned on the spot, and the
    /// cleanup converges instead of looping.
    func testRestoringABackupWithLegacyOverlayIsCleanedWithoutLooping() async throws {
        settings.useTunneling = true
        settings.vpnSliceURLs = ["10.42.0.0/16"]
        settings.useProxyEngine = false

        let suiteName = "turtlediver.overlay.restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overlay-restore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let manager = ProfileManager(profilesDirectory: directory, defaults: defaults)
        let clean = manager.activeProfile
        let overlay = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs).rules
        XCTAssertFalse(overlay.isEmpty)
        var legacy = clean
        legacy.rules.insert(contentsOf: overlay, at: 0)
        _ = manager.saveAndActivate(legacy)   // backs up `clean`
        _ = manager.saveAndActivate(clean)    // backs up `legacy`

        let overlayBackup = try XCTUnwrap(
            manager.listBackups(forProfile: clean.name).first {
                (try? String(contentsOf: $0.url, encoding: .utf8))?.contains("10.42.0.0/16") == true
            }
        )

        let controller = EngineController(
            profileManager: manager,
            settings: settings,
            systemProxy: SystemProxyManager(
                runner: RecordingNetworkSetupRunner(),
                defaults: defaults,
                snapshotURL: directory.appendingPathComponent("proxy-snapshot.json")
            ),
            tunnel: StubTunnelStatus()
        )
        XCTAssertFalse(controller.engineRunning)

        XCTAssertTrue(manager.restoreBackup(overlayBackup))
        await settle()
        let settledCount = manager.listBackups(forProfile: clean.name).count
        await settle()

        XCTAssertFalse(
            manager.activeProfile.rules.contains { $0.value == "10.42.0.0/16" },
            "a restored overlay is stripped from the active profile"
        )
        let text = try String(contentsOf: manager.fileURL(for: clean.name), encoding: .utf8)
        XCTAssertFalse(text.contains("10.42.0.0/16"), text)
        XCTAssertEqual(manager.listBackups(forProfile: clean.name).count, settledCount,
                       "the strip must converge in one save, not loop")
        XCTAssertTrue(
            try String(contentsOf: manager.listBackups(forProfile: clean.name)[0].url, encoding: .utf8)
                .contains("10.42.0.0/16"),
            "the stripped version is kept so the cleanup is undoable"
        )
    }

    /// Only an exact prefix is the legacy overlay. A user rule first means it
    /// is treated as ordinary rules and left alone.
    func testPersistedOverlayIsLeftAloneWhenItIsNotThePrefix() throws {
        settings.useTunneling = true
        settings.vpnSliceURLs = ["10.42.0.0/16"]
        settings.useProxyEngine = false

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overlay-not-prefix-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "turtlediver.overlay.notprefix.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ProfileManager(profilesDirectory: directory, defaults: defaults)
        let overlay = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs).rules
        var profile = manager.activeProfile
        profile.rules.insert(
            contentsOf: overlay,
            at: min(1, profile.rules.count)
        )
        _ = manager.saveAndActivate(profile)

        let controller = EngineController(
            profileManager: manager,
            settings: settings,
            systemProxy: SystemProxyManager(
                runner: RecordingNetworkSetupRunner(),
                defaults: defaults,
                snapshotURL: directory.appendingPathComponent("proxy-snapshot.json")
            ),
            tunnel: StubTunnelStatus()
        )
        XCTAssertFalse(controller.engineRunning)
        XCTAssertTrue(
            manager.activeProfile.rules.contains { $0.value == "10.42.0.0/16" },
            "rules that are not the leading overlay are ordinary rules"
        )
    }

    /// With split tunneling off there is no overlay to compare against.
    func testPersistedOverlayIsLeftAloneWhenTunnelingIsOff() throws {
        settings.useTunneling = false
        settings.vpnSliceURLs = ["10.42.0.0/16"]
        settings.useProxyEngine = false

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("overlay-tunneling-off-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "turtlediver.overlay.off.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let manager = ProfileManager(profilesDirectory: directory, defaults: defaults)
        let overlay = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs).rules
        var profile = manager.activeProfile
        profile.rules.insert(contentsOf: overlay, at: 0)
        _ = manager.saveAndActivate(profile)

        let controller = EngineController(
            profileManager: manager,
            settings: settings,
            systemProxy: SystemProxyManager(
                runner: RecordingNetworkSetupRunner(),
                defaults: defaults,
                snapshotURL: directory.appendingPathComponent("proxy-snapshot.json")
            ),
            tunnel: StubTunnelStatus()
        )
        XCTAssertFalse(controller.engineRunning)
        XCTAssertTrue(
            manager.activeProfile.rules.contains { $0.value == "10.42.0.0/16" },
            "no overlay is generated when split tunneling is off"
        )
    }

    /// A profile switch is a load too: a legacy prefix on the new profile is
    /// stripped without waiting for the next launch.
    func testSwitchingToAProfileWithLegacyOverlayCleansIt() async throws {
        settings.useTunneling = true
        settings.vpnSliceURLs = ["10.42.0.0/16"]
        settings.useProxyEngine = false
        let (controller, manager, _) = makeController(httpPort: 16632, socksPort: 16633)
        XCTAssertFalse(controller.engineRunning)

        let overlay = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs).rules
        var work = manager.activeProfile
        work.name = "Work"
        work.rules.insert(contentsOf: overlay, at: 0)
        _ = manager.saveProfile(work)

        XCTAssertTrue(manager.activateProfile(named: "Work"))
        await settle()

        XCTAssertEqual(manager.activeProfile.name, "Work")
        XCTAssertFalse(
            manager.activeProfile.rules.contains { $0.value == "10.42.0.0/16" },
            "the new active profile is stripped on switch"
        )
    }

    /// The runtime overlay must precede a user rule that matches the same
    /// host, or an earlier REJECT would shadow the DIRECT rule for a target
    /// that has to go through the tunnel.
    func testOverlayPrecedesAnEarlierIdenticalRuleWhileConnected() async throws {
        settings.useTunneling = true
        settings.vpnSliceURLs = ["*.corp.example.com"]
        settings.useProxyEngine = false
        let tunnel = StubTunnelStatus()
        let (controller, manager, _) = makeController(
            httpPort: 16642, socksPort: 16643, tunnel: tunnel
        )

        var profile = manager.activeProfile
        profile.rules = [
            ProfileRule(type: .domainSuffix, value: "corp.example.com", policy: "REJECT"),
            ProfileRule(type: .domain, value: "vpn.corp.example.com", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        _ = manager.saveAndActivate(profile)
        controller.setEngineEnabled(true)

        tunnel.set(.connected)
        await settle()

        let outcome = try controller.engine.matcher.match(
            MatchContext(host: "vpn.corp.example.com")
        )
        XCTAssertEqual(outcome.policy, "DIRECT",
                       "the generated DIRECT suffix must beat the earlier REJECT")

        controller.setEngineEnabled(false)
    }

    /// A cached-rule load started for profile A must not land on profile B
    /// when it finishes later (nor record A's signature).
    func testStaleRuleSetLoadDoesNotOverwriteANewerProfile() async throws {
        settings.useTunneling = false
        settings.useProxyEngine = false
        let tunnel = StubTunnelStatus()
        let (controller, manager, _) = makeController(
            httpPort: 16652, socksPort: 16653, tunnel: tunnel
        )
        controller.setEngineEnabled(true)

        let loader = GatedRuleSetLoader()
        controller.ruleSetLoaderOverride = { loader.load(profile: $0) }

        var a = manager.activeProfile
        a.name = "A"
        a.rules = [
            ProfileRule(type: .ruleSet, value: "seta", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        a.ruleSets = [RemoteRuleSet(name: "seta", url: "https://a.example.com/list")]
        _ = manager.saveProfile(a)

        var b = a
        b.name = "B"
        b.rules = [
            ProfileRule(type: .ruleSet, value: "setb", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        b.ruleSets = [RemoteRuleSet(name: "setb", url: "https://b.example.com/list")]
        _ = manager.saveProfile(b)

        XCTAssertTrue(manager.activateProfile(named: "A"))
        await waitUntil("A's rule-set load to start") { loader.started }

        XCTAssertTrue(manager.activateProfile(named: "B"))
        await waitUntil("B's cached rule set to be applied") {
            controller.engine.matcher.expandedRules.contains { $0.value == "b.example.com" }
        }

        // Let A's late load finish. It must be dropped, not applied over B.
        loader.release.signal()
        await settle()

        let applied = controller.engine.matcher.expandedRules.map(\.value)
        XCTAssertTrue(applied.contains("b.example.com"), "B's rules stay applied: \(applied)")
        XCTAssertFalse(applied.contains("a.example.com"), "A's late load must not land: \(applied)")

        controller.setEngineEnabled(false)
    }

    /// A same-named set pointing at a different URL has different contents.
    /// The immediate install after a switch must drop the old expansion, or a
    /// host that only A's list contains would keep matching under B until the
    /// cache load finishes.
    func testSwitchingToASameNamedSetWithANewURLDropsOldContentsImmediately() async throws {
        settings.useTunneling = false
        settings.useProxyEngine = false
        let tunnel = StubTunnelStatus()
        let (controller, manager, _) = makeController(
            httpPort: 16662, socksPort: 16663, tunnel: tunnel
        )
        controller.setEngineEnabled(true)

        let loader = TwoGateRuleSetLoader()
        controller.ruleSetLoaderOverride = { loader.load(profile: $0) }

        var a = manager.activeProfile
        a.name = "A"
        a.rules = [
            ProfileRule(type: .ruleSet, value: "shared", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        a.ruleSets = [RemoteRuleSet(name: "shared", url: "https://a.example.com/list")]
        _ = manager.saveProfile(a)

        var b = a
        b.name = "B"
        b.rules = [
            ProfileRule(type: .ruleSet, value: "shared", policy: "DIRECT"),
            ProfileRule(type: .domainSuffix, value: "a-only.example.com", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        b.ruleSets = [RemoteRuleSet(name: "shared", url: "https://b.example.com/list")]
        _ = manager.saveProfile(b)

        XCTAssertTrue(manager.activateProfile(named: "A"))
        await waitUntil("A's load to start") { loader.startedA }
        loader.releaseA.signal()
        await waitUntil("A's set to be applied") {
            controller.engine.matcher.expandedRules.contains {
                $0.value == "a-only.example.com" && $0.policy == "DIRECT"
            }
        }

        XCTAssertTrue(manager.activateProfile(named: "B"))
        await waitUntil("B's load to start") { loader.startedB }

        // B's load is still parked. Its `shared` points at a different URL, so
        // A's contents must already be gone: the host has to fall through to
        // B's REJECT rule rather than match A's stale DIRECT entry.
        let outcome = try controller.engine.matcher.match(
            MatchContext(host: "a-only.example.com")
        )
        XCTAssertEqual(
            outcome.policy, "REJECT",
            "a same-named set with a different URL must not reuse the old contents"
        )

        loader.releaseB.signal()
        await waitUntil("B's set to be applied") {
            controller.engine.matcher.expandedRules.contains { $0.value == "b-only.example.com" }
        }
        controller.setEngineEnabled(false)
    }

    /// Lets the main-actor profile/VPN sinks (and their coalescing tick) run.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

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
}

/// A rule-set loader whose load for profile A parks until the test releases
/// it, so a late load can be raced deterministically.
private final class GatedRuleSetLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    let release = DispatchSemaphore(value: 0)

    var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return _started
    }

    func load(profile: Profile) -> [String: [ProfileRule]] {
        switch profile.name {
        case "A":
            lock.lock(); _started = true; lock.unlock()
            release.wait()
            return ["seta": [ProfileRule(type: .domain, value: "a.example.com", policy: "DIRECT")]]
        case "B":
            return ["setb": [ProfileRule(type: .domain, value: "b.example.com", policy: "DIRECT")]]
        default:
            return [:]
        }
    }
}

/// Like ``GatedRuleSetLoader``, but both loads park so the window between a
/// profile switch and the new cache load is observable.
private final class TwoGateRuleSetLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var _startedA = false
    private var _startedB = false
    let releaseA = DispatchSemaphore(value: 0)
    let releaseB = DispatchSemaphore(value: 0)

    var startedA: Bool {
        lock.lock(); defer { lock.unlock() }
        return _startedA
    }

    var startedB: Bool {
        lock.lock(); defer { lock.unlock() }
        return _startedB
    }

    func load(profile: Profile) -> [String: [ProfileRule]] {
        switch profile.name {
        case "A":
            lock.lock(); _startedA = true; lock.unlock()
            releaseA.wait()
            return ["shared": [ProfileRule(type: .domain, value: "a-only.example.com", policy: "DIRECT")]]
        case "B":
            lock.lock(); _startedB = true; lock.unlock()
            releaseB.wait()
            return ["shared": [ProfileRule(type: .domain, value: "b-only.example.com", policy: "DIRECT")]]
        default:
            return [:]
        }
    }
}
