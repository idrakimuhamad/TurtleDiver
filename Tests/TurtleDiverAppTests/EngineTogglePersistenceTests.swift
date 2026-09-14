import XCTest
import Foundation
@testable import TurtleDiverAppGlue
import TurtleDiverCore
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

    /// Builds a controller wired to a throwaway profile directory, a throwaway
    /// `UserDefaults` suite and a recording `networksetup` runner, so the tests
    /// never touch the user's profile, system proxy or real ports.
    private func makeController(
        httpPort: Int,
        socksPort: Int
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
            settings: .shared,
            systemProxy: systemProxy
        )
        return (controller, manager, runner)
    }

    override nonisolated func tearDown() {
        // Leave the process-wide singleton in its default state for other tests.
        MainActor.assumeIsolated { SettingsManager.shared.useProxyEngine = false }
        super.tearDown()
    }

    func testEnablingPersistsFlagAndStartsEngine() throws {
        let (controller, _, _) = makeController(httpPort: 16152, socksPort: 16153)
        let settings = SettingsManager.shared
        settings.useProxyEngine = false
        XCTAssertFalse(controller.engineRunning)

        controller.setEngineEnabled(true)

        // The regression: the toggle must persist its intent.
        XCTAssertTrue(settings.useProxyEngine, "enabling the engine must persist useProxyEngine")
        XCTAssertTrue(
            UserDefaults.standard.bool(forKey: "useProxyEngine"),
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
        let settings = SettingsManager.shared
        settings.useProxyEngine = true

        controller.setEngineEnabled(false)

        XCTAssertFalse(settings.useProxyEngine)
        XCTAssertFalse(controller.engineRunning)
        XCTAssertEqual(controller.httpPort, nil)
    }

    func testEngineResumesOnNextLaunchFromPersistedFlag() throws {
        let settings = SettingsManager.shared
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
        SettingsManager.shared.useProxyEngine = false
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
        SettingsManager.shared.useProxyEngine = false
        // Constructing the controller runs the one-shot legacy PAC retirement;
        // wait for it, then assert the *engine* never touches the system proxy.
        await controller.awaitLegacyPACCleanup()
        runner.reset()

        controller.setEngineEnabled(true)
        controller.setEngineEnabled(false)

        XCTAssertTrue(runner.commands.isEmpty, "the profile keeps systemProxy off, so networksetup must not run")
    }
}
