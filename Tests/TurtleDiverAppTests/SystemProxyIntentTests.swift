import XCTest
import Foundation
@testable import TurtleDiverAppGlue
import TurtleDiverCore
import TurtleDiverSystem

/// Records `networksetup` invocations instead of touching real system settings.
///
/// Optionally blocks the first call so a test can enqueue a second request
/// while one is genuinely in flight, and records which thread each call ran on
/// (the whole point of the async rework: `networksetup` must never block the
/// main thread).
private final class SystemProxyTestRunner: NetworkSetupRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [[String]] = []
    private var _mainThreadFlags: [Bool] = []
    private var _blockFirst = false
    private var _entered = false

    /// Released by the test to unblock the gated call.
    let release = DispatchSemaphore(value: 0)

    var commands: [[String]] {
        lock.lock(); defer { lock.unlock() }
        return _commands
    }

    var mainThreadFlags: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _mainThreadFlags
    }

    /// True once the gated call has been entered (and is parked on `release`).
    var enteredGatedCall: Bool {
        lock.lock(); defer { lock.unlock() }
        return _entered
    }

    /// Parks the next `run(arguments:)` call until `release` is signalled.
    func blockNextCall() {
        lock.lock(); _blockFirst = true; lock.unlock()
    }

    func reset() {
        lock.lock()
        _commands = []
        _mainThreadFlags = []
        lock.unlock()
    }

    func run(arguments: [String]) throws -> String {
        lock.lock()
        let gateThisCall = _blockFirst
        _blockFirst = false
        if gateThisCall { _entered = true }
        _commands.append(arguments)
        _mainThreadFlags.append(Thread.isMainThread)
        lock.unlock()

        if gateThisCall { release.wait() }

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

/// Regression tests for the "Use as System Proxy" toggle.
///
/// The active profile is the source of truth: `EngineController.handleProfileChange()`
/// re-applies `profile.general.systemProxy` on every profile change. Enabling the
/// system proxy used to only flip in-memory state, so the very next profile
/// change — and connecting the VPN always rewrites the profile with the
/// vpn-slice DIRECT rules — turned the proxy straight back off, silently
/// leaving every app unproxied.
///
/// Two follow-up complaints are covered too:
/// - stopping/quitting the engine (which must turn the proxy *off*, macOS must
///   not be left pointing at a dead listener) also erased the stored intent, so
///   every relaunch needed the toggle flipped by hand;
/// - the `networksetup` work ran inline on the main thread, freezing the UI for
///   seconds on every toggle.
@MainActor
final class SystemProxyIntentTests: XCTestCase {

    private struct Harness {
        let controller: EngineController
        let manager: ProfileManager
        let runner: SystemProxyTestRunner
        let systemProxy: SystemProxyManager
        let directory: URL
    }

    /// The suite drives `EngineController`, which reads the engine on/off flag
    /// from the shared `SettingsManager` (backed by the real `UserDefaults`).
    /// Flip it off for the duration so no test inherits the user's setting, and
    /// restore it afterwards so running tests never changes app state.
    private var originalEngineEnabled = false

    override func setUp() async throws {
        originalEngineEnabled = SettingsManager.shared.useProxyEngine
        SettingsManager.shared.useProxyEngine = false
    }

    override func tearDown() async throws {
        SettingsManager.shared.useProxyEngine = originalEngineEnabled
    }

    /// Throwaway profile directory, `UserDefaults` suite and recording runner —
    /// the tests never touch the user's profile, system proxy or real ports.
    private func makeHarness(httpPort: Int, socksPort: Int) -> Harness {
        let suiteName = "turtlediver.sysproxy.intent.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sysproxyintent-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let manager = ProfileManager(profilesDirectory: directory, defaults: defaults)
        var profile = manager.activeProfile
        profile.general.httpListen = "127.0.0.1:\(httpPort)"
        profile.general.socks5Listen = "127.0.0.1:\(socksPort)"
        profile.general.systemProxy = false
        _ = manager.saveAndActivate(profile)

        let runner = SystemProxyTestRunner()
        let systemProxy = SystemProxyManager(
            runner: runner,
            defaults: defaults,
            snapshotURL: directory.appendingPathComponent("proxy-snapshot.json")
        )
        let controller = EngineController(
            profileManager: manager, settings: .shared, systemProxy: systemProxy,
            tunnel: StubTunnelStatus()
        )
        return Harness(
            controller: controller,
            manager: manager,
            runner: runner,
            systemProxy: systemProxy,
            directory: directory
        )
    }

    private func profileText(_ h: Harness) throws -> String {
        try String(contentsOf: h.manager.fileURL(for: h.manager.activeProfile.name), encoding: .utf8)
    }

    /// Polls a main-actor condition while yielding the main actor so the
    /// background proxy work can land.
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

    // MARK: Intent persistence while enabled

    func testEnablingSystemProxyPersistsIntentToActiveProfile() async throws {
        let h = makeHarness(httpPort: 16452, socksPort: 16453)
        h.controller.setEngineEnabled(true)

        await h.controller.setSystemProxyEnabled(true)

        XCTAssertTrue(h.controller.systemProxyOn, h.controller.lastError ?? "")
        XCTAssertTrue(h.manager.activeProfile.general.systemProxy)

        let text = try profileText(h)
        XCTAssertTrue(text.contains("system-proxy = true"), text)
    }

    func testDisablingSystemProxyClearsIntentInProfile() async throws {
        let h = makeHarness(httpPort: 16462, socksPort: 16463)
        h.controller.setEngineEnabled(true)
        await h.controller.setSystemProxyEnabled(true)
        XCTAssertTrue(h.controller.systemProxyOn)

        await h.controller.setSystemProxyEnabled(false)

        XCTAssertFalse(h.controller.systemProxyOn)
        XCTAssertFalse(h.manager.activeProfile.general.systemProxy)
        let text = try profileText(h)
        XCTAssertTrue(text.contains("system-proxy = false"), text)
    }

    /// The exact regression: a profile rewrite after enabling (the VPN connect
    /// injects vpn-slice DIRECT rules and saves) must not disable the proxy.
    func testProfileRewriteAfterVPNOverlayKeepsSystemProxyOn() async throws {
        let h = makeHarness(httpPort: 16472, socksPort: 16473)
        h.controller.setEngineEnabled(true)
        await h.controller.setSystemProxyEnabled(true)
        h.runner.reset()

        // Simulate what VPNRuleGenerator does on connect: insert DIRECT rules
        // at the top of the profile and save.
        var profile = h.manager.activeProfile
        profile.rules.insert(
            ProfileRule(type: .ipCIDR, value: "172.30.0.0/12", policy: "DIRECT"),
            at: 0
        )
        h.manager.saveAndActivate(profile)

        // handleProfileChange() is driven by the profile-change bridge.
        let applied = expectation(description: "profile change handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { applied.fulfill() }
        await fulfillment(of: [applied], timeout: 3)

        XCTAssertTrue(h.controller.systemProxyOn, "profile rewrite must not disable the system proxy")
        XCTAssertFalse(
            h.runner.commands.contains { $0.first == "-setwebproxystate" && $0.last == "off" },
            "system proxy was turned off by the profile rewrite: \(h.runner.commands)"
        )
        XCTAssertTrue(h.manager.activeProfile.general.systemProxy)
    }

    // MARK: Intent persistence across stop / quit / relaunch

    /// Stopping the engine must point macOS away from the (now dead) listener,
    /// but it must not erase the user's choice — that is what made the toggle
    /// necessary after every quit.
    func testStoppingEngineTurnsProxyOffButKeepsIntent() async throws {
        let h = makeHarness(httpPort: 16482, socksPort: 16483)
        h.controller.setEngineEnabled(true)
        await h.controller.setSystemProxyEnabled(true)
        XCTAssertTrue(h.controller.systemProxyOn)
        h.runner.reset()

        h.controller.setEngineEnabled(false)

        XCTAssertFalse(h.controller.systemProxyOn, "engine stop must clear the proxy")
        XCTAssertTrue(h.manager.activeProfile.general.systemProxy, "engine stop must keep the intent")
        XCTAssertTrue(try profileText(h).contains("system-proxy = true"))
        XCTAssertTrue(
            h.runner.commands.contains { $0.first == "-setwebproxystate" && $0.last == "off" },
            "macOS must be un-proxied when the engine stops: \(h.runner.commands)"
        )
    }

    /// Same for app termination.
    func testShutdownTurnsProxyOffButKeepsIntent() async throws {
        let h = makeHarness(httpPort: 16484, socksPort: 16485)
        h.controller.setEngineEnabled(true)
        await h.controller.setSystemProxyEnabled(true)
        h.runner.reset()

        h.controller.shutdown()

        XCTAssertFalse(h.controller.systemProxyOn)
        XCTAssertFalse(h.controller.engineRunning)
        XCTAssertNil(h.controller.httpPort)
        XCTAssertTrue(h.manager.activeProfile.general.systemProxy, "quitting must keep the intent")
        XCTAssertTrue(try profileText(h).contains("system-proxy = true"))
    }

    /// The user's report: kill the app, relaunch, and the proxy is off again.
    /// A profile storing `system-proxy = true` must re-arm on the next launch.
    func testRelaunchReEnablesSystemProxyFromStoredIntent() async throws {
        let h = makeHarness(httpPort: 16492, socksPort: 16493)
        h.controller.setEngineEnabled(true)
        await h.controller.setSystemProxyEnabled(true)
        h.controller.shutdown()
        h.runner.reset()

        // Same profile directory, defaults and snapshot = a relaunch.
        let relaunched = EngineController(
            profileManager: h.manager,
            settings: .shared,
            systemProxy: h.systemProxy,
            tunnel: StubTunnelStatus()
        )
        if !relaunched.engineRunning { relaunched.startEngine() }
        XCTAssertTrue(relaunched.engineRunning, relaunched.lastError ?? "")

        await waitUntil("system proxy re-applied on launch") { relaunched.systemProxyOn }
        XCTAssertTrue(h.runner.commands.contains { $0.first == "-setwebproxystate" && $0.last == "on" })
    }

    // MARK: Responsiveness of the toggle

    /// Every `networksetup` invocation is a subprocess; running them inline
    /// froze the UI for seconds. They must all be dispatched off the main thread.
    func testProxyWorkNeverRunsOnMainThread() async {
        let h = makeHarness(httpPort: 16494, socksPort: 16495)
        // The launch-time legacy PAC retirement shells out as well; wait for it
        // and drop its calls so this assertion is about the toggle only.
        await h.controller.awaitLegacyPACCleanup()
        h.runner.reset()
        h.controller.setEngineEnabled(true)

        await h.controller.setSystemProxyEnabled(true)
        await h.controller.setSystemProxyEnabled(false)

        XCTAssertFalse(h.runner.commands.isEmpty, "expected networksetup work")
        XCTAssertEqual(
            h.runner.mainThreadFlags.filter { $0 }.count, 0,
            "networksetup ran on the main thread"
        )
    }

    /// The launch-time legacy PAC retirement also shells out to `networksetup`
    /// (turning off a PAC left pointing at the retired server), so it must stay
    /// off the main thread too — launch must not stutter.
    func testLegacyPACRetirementRunsOffMainThread() async {
        let h = makeHarness(httpPort: 16510, socksPort: 16511)

        await h.controller.awaitLegacyPACCleanup()

        XCTAssertFalse(h.runner.commands.isEmpty, "expected the retirement sweep to query the services")
        XCTAssertEqual(
            h.runner.mainThreadFlags.filter { $0 }.count, 0,
            "legacy PAC retirement ran on the main thread"
        )
    }

    /// The busy flag drives the Dashboard spinner and disables the toggle; if it
    /// leaks, the toggle is stuck disabled forever.
    func testBusyFlagClearsAfterChangeCompletes() async {
        let h = makeHarness(httpPort: 16496, socksPort: 16497)
        h.controller.setEngineEnabled(true)

        XCTAssertFalse(h.controller.systemProxyBusy)
        await h.controller.setSystemProxyEnabled(true)
        XCTAssertFalse(h.controller.systemProxyBusy)
        await h.controller.setSystemProxyEnabled(false)
        XCTAssertFalse(h.controller.systemProxyBusy)
    }

    /// Flipping the toggle while the previous change is still running must not
    /// drop the request: the last one wins.
    func testRequestDuringInFlightChangeIsAppliedAfterwards() async throws {
        let h = makeHarness(httpPort: 16498, socksPort: 16499)
        h.controller.setEngineEnabled(true)
        h.runner.blockNextCall()

        let inFlight = Task { await h.controller.setSystemProxyEnabled(true) }
        await waitUntil("first proxy call entered") { h.runner.enteredGatedCall }
        XCTAssertTrue(h.controller.systemProxyBusy)

        // Arrives while busy — queued instead of dropped.
        await h.controller.setSystemProxyEnabled(false)

        h.runner.release.signal()
        await inFlight.value

        // The queued request runs in its own task once the gated call returns,
        // so poll for the settled state instead of racing it (this used to fail
        // intermittently when the assertion won the race).
        await waitUntil("the queued off request to be applied") { !h.controller.systemProxyOn }
        XCTAssertFalse(h.controller.systemProxyOn, "the last request (off) must win")
        XCTAssertFalse(h.controller.systemProxyBusy)
        XCTAssertFalse(h.manager.activeProfile.general.systemProxy)
    }

    /// Enabling without a running engine must fail loudly instead of writing a
    /// `networksetup`-free "success" into the profile.
    func testEnableWithoutEngineReportsErrorAndKeepsIntentOff() async {
        let h = makeHarness(httpPort: 16502, socksPort: 16503)
        await h.controller.awaitLegacyPACCleanup()
        h.runner.reset()

        await h.controller.setSystemProxyEnabled(true)

        XCTAssertFalse(h.controller.systemProxyOn)
        XCTAssertNotNil(h.controller.lastError)
        XCTAssertFalse(h.manager.activeProfile.general.systemProxy)
        XCTAssertTrue(h.runner.commands.isEmpty)
    }
}
