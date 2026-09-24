import XCTest
import Foundation
import Combine
@testable import TurtleDiverAppGlue
import TurtleDiverCore
import TurtleDiverSystem

/// A `networksetup` runner that records instead of executing. These tests
/// never enable the system proxy, so every answer is the neutral "nothing is
/// set" shape — copied in miniature from the engine-toggle tests rather than
/// shared, so this file stays self-contained.
private final class InertNetworkSetupRunner: NetworkSetupRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var commands: [[String]] = []

    var commandCount: Int {
        lock.lock(); defer { lock.unlock() }
        return commands.count
    }

    func run(arguments: [String]) throws -> String {
        lock.lock()
        commands.append(arguments)
        lock.unlock()
        switch arguments.first {
        case "-listallnetworkservices":
            return "Wi-Fi\n"
        case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
            return "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: No\n"
        default:
            return ""
        }
    }
}

/// The request table is fed by snapshots of the engine's request log, and the
/// log fires its change hook on every append/finish/attachDetail — dozens a
/// second while a page loads. Every uncoalesced push replaced the whole (up
/// to 1000-row) snapshot on the main actor, and the table re-diffed and
/// re-laid out its visible rows for each of them: scrolling the list fought
/// the engine's event rate for the main thread and crawled.
///
/// These tests pin the feed: a burst of log events produces at most one
/// refresh per 100 ms window, and the coalesced refresh still lands.
@MainActor
final class RequestLogCoalescingTests: XCTestCase {

    /// A controller wired to a throwaway profile directory, a throwaway
    /// `UserDefaults` suite and an inert `networksetup` runner, so the test
    /// never touches the user's profile or system proxy.
    private func makeController(
        httpPort: Int,
        socksPort: Int
    ) -> (controller: EngineController, manager: ProfileManager) {
        let suiteName = "turtlediver.log.coalescing.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engcoalesce-\(UUID().uuidString)", isDirectory: true)
        let snapshotURL = tempDir.appendingPathComponent("proxy-snapshot.json")

        let manager = ProfileManager(profilesDirectory: tempDir, defaults: defaults)
        var profile = manager.activeProfile
        profile.general.httpListen = "127.0.0.1:\(httpPort)"
        profile.general.socks5Listen = "127.0.0.1:\(socksPort)"
        profile.general.systemProxy = false
        _ = manager.saveAndActivate(profile)

        let systemProxy = SystemProxyManager(
            runner: InertNetworkSetupRunner(), defaults: defaults, snapshotURL: snapshotURL
        )
        let controller = EngineController(
            profileManager: manager,
            settings: .shared,
            systemProxy: systemProxy,
            tunnel: StubTunnelStatus()
        )
        return (controller, manager)
    }

    /// The regression: a page-load-sized burst of log events must not push a
    /// full table snapshot per event.
    func testABurstOfLogEventsProducesOneRefreshPerWindow() async {
        let (controller, _) = makeController(httpPort: 16164, socksPort: 16165)
        defer { controller.stopEngine() }
        controller.startEngine()
        guard controller.engineRunning else {
            XCTFail("the engine did not start: \(controller.lastError ?? "no error recorded")")
            return
        }

        var pushCount = 0
        let subscription = controller.$requests.sink { _ in pushCount += 1 }
        defer { subscription.cancel() }
        // The sink's immediate first value is the subscription baseline, not a
        // refresh.
        let baseline = pushCount

        // What a busy page load does to the log: dozens of change-hook firings
        // back to back. Firing the hook directly (rather than appending real
        // entries) isolates the bridge under test — the log's own bookkeeping
        // is covered by its own suite.
        for _ in 0..<30 {
            controller.engine.requestLog.onChange?()
        }

        // Mid-window the table must not have been re-fed per event.
        try? await Task.sleep(for: .milliseconds(40))
        let midWindow = pushCount - baseline
        XCTAssertLessThanOrEqual(
            midWindow, 2,
            "the 30-event burst had already produced \(midWindow) table refreshes inside the coalescing window"
        )

        // And the coalesced refresh still lands.
        let deadline = Date().addingTimeInterval(3)
        while pushCount - baseline < 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let total = pushCount - baseline
        XCTAssertGreaterThanOrEqual(total, 1, "the burst never produced a refresh")
        XCTAssertLessThan(
            total, 10,
            "30 log events produced \(total) table refreshes — the per-event feed is back"
        )
    }
}