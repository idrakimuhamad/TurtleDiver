import XCTest

#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif
#if canImport(TurtleDiverRules)
import TurtleDiverRules
#endif
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

// MARK: - Fake Runner

/// Records networksetup invocations and returns scripted output.
final class FakeNetworkSetupRunner: NetworkSetupRunning, @unchecked Sendable {
    /// Arguments → stdout (exact match). Unmatched commands throw.
    var scripted: [[String]: String] = [:]
    /// Arguments → thrown error.
    var failures: [[String]: Error] = [:]
    /// Every invocation, in order.
    private(set) var calls: [[String]] = []

    /// Clears the recorded calls (between test phases).
    func resetCalls() {
        calls = []
    }

    func run(arguments: [String]) throws -> String {
        calls.append(arguments)
        if let error = failures[arguments] { throw error }
        if let output = scripted[arguments] { return output }
        return ""
    }

    func didRun(_ command: String, _ args: [String]) -> Bool {
        calls.contains { $0.first == command && Array($0.dropFirst()) == args }
    }

    func count(_ command: String, _ args: [String]) -> Int {
        calls.filter { $0.first == command && Array($0.dropFirst()) == args }.count
    }
}

// MARK: - Fixtures

private let serviceListOutput = """
An asterisk (*) denotes that a network service is disabled.
Wi-Fi
Ethernet
*Thunderbolt Bridge

"""

private func getProxyOutput(enabled: Bool, server: String = "1.2.3.4", port: String = "8080") -> String {
    """
    Enabled: \(enabled ? "Yes" : "No")
    Server: \(server)
    Port: \(port)
    Authenticated Proxy Enabled: 0

    """
}

/// The PAC URL the retired legacy proxy mode installed (dead server since 1.3).
private let legacyPAC = "http://127.0.0.1:8765/proxy.pac"

private func getAutoProxyOutput(enabled: Bool, url: String = "http://pac.corp.example/proxy.pac") -> String {
    """
    URL: \(url)
    Enabled: \(enabled ? "Yes" : "No")

    """
}

// MARK: - Tests

final class SystemProxyManagerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SystemProxyManagerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Sandbox-safe manager: snapshot file lives in a unique temp directory.
    private func makeManager(runner: FakeNetworkSetupRunner) -> SystemProxyManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SysProxyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SystemProxyManager(runner: runner, defaults: defaults, snapshotURL: dir.appendingPathComponent("snapshot.json"))
    }

    // MARK: Service list parsing

    func testParseServiceList() {
        let services = SystemProxyManager.parseServiceList(serviceListOutput)
        XCTAssertEqual(services, [
            NetworkService(name: "Wi-Fi", enabled: true),
            NetworkService(name: "Ethernet", enabled: true),
            NetworkService(name: "Thunderbolt Bridge", enabled: false),
        ])
    }

    func testParseServiceListEmpty() {
        XCTAssertTrue(SystemProxyManager.parseServiceList("").isEmpty)
    }

    // MARK: Enable

    func testEnableSetsProxyOnAllEnabledServices() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        let manager = makeManager(runner: runner)

        try manager.enable(
            httpHost: "127.0.0.1", httpPort: 6152,
            socksHost: "127.0.0.1", socksPort: 6153,
            skipProxy: ["192.168.0.0/16", "localhost"]
        )

        for service in ["Wi-Fi", "Ethernet"] {
            XCTAssertTrue(runner.didRun("-setwebproxy", [service, "127.0.0.1", "6152"]), service)
            XCTAssertTrue(runner.didRun("-setsecurewebproxy", [service, "127.0.0.1", "6152"]), service)
            XCTAssertTrue(runner.didRun("-setsocksfirewallproxy", [service, "127.0.0.1", "6153"]), service)
            XCTAssertTrue(runner.didRun("-setproxybypassdomains", [service, "192.168.0.0/16", "localhost"]), service)
        }
        // Disabled services untouched.
        XCTAssertFalse(runner.calls.contains { $0.contains("Thunderbolt Bridge") })
        XCTAssertTrue(manager.isEnabled)
    }

    func testEnableSnapshotsOnlyServicesWithExistingProxies() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getwebproxy", "Wi-Fi"]] = getProxyOutput(enabled: true, server: "10.9.8.7", port: "3128")
        runner.scripted[["-getsecurewebproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsocksfirewallproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        // Ethernet has no proxy configured.
        runner.scripted[["-getwebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsecurewebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsocksfirewallproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        let manager = makeManager(runner: runner)

        try manager.enable(
            httpHost: "127.0.0.1", httpPort: 6152,
            socksHost: "127.0.0.1", socksPort: 6153,
            skipProxy: []
        )

        let snapshot = try XCTUnwrap(manager.snapshotForTesting)
        XCTAssertEqual(snapshot.states.map(\.service), ["Wi-Fi"])
        XCTAssertEqual(snapshot.states.first?.web, getProxyOutput(enabled: true, server: "10.9.8.7", port: "3128"))
    }

    func testEnableIsIdempotentDoesNotOverwriteSnapshot() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getwebproxy", "Wi-Fi"]] = getProxyOutput(enabled: true, server: "10.9.8.7", port: "3128")
        runner.scripted[["-getsecurewebproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsocksfirewallproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getwebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsecurewebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsocksfirewallproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])
        let first = try XCTUnwrap(manager.snapshotForTesting)

        // Second enable (already enabled): the original snapshot must survive.
        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])
        XCTAssertEqual(manager.snapshotForTesting, first)
    }

    // MARK: Disable & restore

    func testDisableClearsAllServicesAndRestoresSnapshot() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getwebproxy", "Wi-Fi"]] = getProxyOutput(enabled: true, server: "10.9.8.7", port: "3128")
        runner.scripted[["-getsecurewebproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsocksfirewallproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getwebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsecurewebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner.scripted[["-getsocksfirewallproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])
        runner.resetCalls()
        try manager.disable()

        // All enabled services get cleared (restore may re-assert off).
        for service in ["Wi-Fi", "Ethernet"] {
            XCTAssertGreaterThanOrEqual(runner.count("-setwebproxystate", [service, "off"]), 1, service)
            XCTAssertGreaterThanOrEqual(runner.count("-setsecurewebproxystate", [service, "off"]), 1, service)
            XCTAssertGreaterThanOrEqual(runner.count("-setsocksfirewallproxystate", [service, "off"]), 1, service)
        }
        // And the snapshotted pre-existing proxy is restored on Wi-Fi.
        XCTAssertTrue(runner.didRun("-setwebproxy", ["Wi-Fi", "10.9.8.7", "3128"]))
        XCTAssertTrue(runner.didRun("-setwebproxystate", ["Wi-Fi", "on"]))
        XCTAssertFalse(manager.isEnabled)
    }

    func testDisableWithoutEnableStillClearsAndSucceeds() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        let manager = makeManager(runner: runner)

        try manager.disable()
        XCTAssertFalse(manager.isEnabled)
    }

    func testEnableFailureWhenServiceListingFails() {
        let runner = FakeNetworkSetupRunner()
        runner.failures[["-listallnetworkservices"]] = SystemProxyError.restoreFailed("boom")
        let manager = makeManager(runner: runner)

        XCTAssertThrowsError(try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: []))
        XCTAssertFalse(manager.isEnabled)
    }

    // MARK: Stale snapshot repair

    func testStaleSnapshotSurvivesAcrossManagersAndRepairs() throws {
        // First manager enables the proxy (writes snapshot to disk).
        let runner1 = FakeNetworkSetupRunner()
        runner1.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner1.scripted[["-getwebproxy", "Wi-Fi"]] = getProxyOutput(enabled: true, server: "10.9.8.7", port: "3128")
        runner1.scripted[["-getsecurewebproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        runner1.scripted[["-getsocksfirewallproxy", "Wi-Fi"]] = getProxyOutput(enabled: false)
        runner1.scripted[["-getwebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner1.scripted[["-getsecurewebproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        runner1.scripted[["-getsocksfirewallproxy", "Ethernet"]] = getProxyOutput(enabled: false)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SysProxyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let snapshotURL = dir.appendingPathComponent("snapshot.json")

        let first = SystemProxyManager(runner: runner1, defaults: defaults, snapshotURL: snapshotURL)
        try first.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])

        // Second manager instance (as after a crash + relaunch) finds it.
        let runner2 = FakeNetworkSetupRunner()
        let second = SystemProxyManager(runner: runner2, defaults: defaults, snapshotURL: snapshotURL)
        XCTAssertTrue(second.hasStaleSnapshot)

        XCTAssertTrue(second.restoreFromSnapshot())
        XCTAssertTrue(runner2.didRun("-setwebproxy", ["Wi-Fi", "10.9.8.7", "3128"]))
        XCTAssertTrue(runner2.didRun("-setwebproxystate", ["Wi-Fi", "on"]))
        // Snapshot removed after repair.
        XCTAssertFalse(second.hasStaleSnapshot)
    }

    // MARK: get-proxy output parsing

    func testParseGetProxyOutputEnabled() {
        let state = SystemProxyManager.parseGetProxyOutput(
            """
            Enabled: Yes
            Server: 127.0.0.1
            Port: 6152
            Authenticated Proxy Enabled: 0
            """
        )
        XCTAssertEqual(state.enabled, true)
        XCTAssertEqual(state.host, "127.0.0.1")
        XCTAssertEqual(state.port, "6152")
    }

    func testParseGetProxyOutputDisabled() {
        let state = SystemProxyManager.parseGetProxyOutput(
            """
            Enabled: No
            Server: 
            Port: 0
            Authenticated Proxy Enabled: 0
            """
        )
        XCTAssertEqual(state.enabled, false)
        XCTAssertEqual(state.host, "")
        XCTAssertEqual(state.port, "0")
    }

    // MARK: PAC (legacy `Use Proxy`) interaction

    /// CFNetwork prefers a PAC over explicit proxies, so an enabled PAC
    /// silently shadows the engine. enable() has to turn it off.
    func testEnableTurnsOffPACOnAllEnabledServices() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: true)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])

        for service in ["Wi-Fi", "Ethernet"] {
            XCTAssertTrue(runner.didRun("-setautoproxystate", [service, "off"]), service)
        }
    }

    /// A PAC alone (no explicit proxies) still has to be snapshotted, otherwise
    /// disable() cannot put it back.
    func testSnapshotCapturesEnabledPACEvenWithoutExplicitProxies() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: true)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])

        let snapshot = try XCTUnwrap(manager.snapshotForTesting)
        XCTAssertEqual(snapshot.states.map(\.service), ["Wi-Fi"])
        XCTAssertEqual(snapshot.states.first?.autoProxy, getAutoProxyOutput(enabled: true))
    }

    func testDisableRestoresPACFromSnapshot() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: true)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])
        runner.resetCalls()
        try manager.disable()

        XCTAssertTrue(runner.didRun("-setautoproxyurl", ["Wi-Fi", "http://pac.corp.example/proxy.pac"]))
        XCTAssertTrue(runner.didRun("-setautoproxystate", ["Wi-Fi", "on"]))
    }

    func testDisableRestoresPACOffWhenSnapshotHadPACDisabled() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getwebproxy", "Wi-Fi"]] = getProxyOutput(enabled: true, server: "10.9.8.7", port: "3128")
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: false)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])
        runner.resetCalls()
        try manager.disable()

        XCTAssertFalse(runner.didRun("-setautoproxyurl", ["Wi-Fi", "http://pac.corp.example/proxy.pac"]))
        XCTAssertTrue(runner.didRun("-setautoproxystate", ["Wi-Fi", "off"]))
    }

    /// Snapshots written before PAC capture existed must still decode.
    func testLegacySnapshotWithoutAutoProxyFieldStillDecodes() throws {
        let json = """
        {"states":[{"service":"Wi-Fi","web":"Enabled: Yes\\nServer: 10.9.8.7\\nPort: 3128\\n","secureWeb":"Enabled: No\\n","socks":"Enabled: No\\n"}],"capturedAt":0}
        """
        let snapshot = try JSONDecoder().decode(ProxySettingsSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.states.count, 1)
        XCTAssertNil(snapshot.states.first?.autoProxy)
    }

    func testParseGetAutoProxyOutputEnabled() {
        let pac = SystemProxyManager.parseGetAutoProxyOutput(
            """
            URL: http://pac.corp.example/proxy.pac
            Enabled: Yes

            """
        )
        XCTAssertTrue(pac.enabled)
        XCTAssertEqual(pac.url, "http://pac.corp.example/proxy.pac")
    }

    func testParseGetAutoProxyOutputDisabledStillKeepsURL() {
        let pac = SystemProxyManager.parseGetAutoProxyOutput(
            """
            URL: http://pac.corp.example/proxy.pac
            Enabled: No

            """
        )
        XCTAssertFalse(pac.enabled)
        XCTAssertEqual(pac.url, "http://pac.corp.example/proxy.pac")
    }

    func testParseGetAutoProxyOutputEmptyIsDisabled() {
        let pac = SystemProxyManager.parseGetAutoProxyOutput("")
        XCTAssertFalse(pac.enabled)
        XCTAssertEqual(pac.url, "")
    }

    // MARK: Legacy PAC retirement

    /// The legacy PAC server (a `python3 -m http.server` on 8765) is gone with
    /// `ProxyManager`. A PAC still pointing at it must be turned off, or every
    /// request it used to proxy fails against a closed port.
    func testClearLegacyPACTurnsOffOnlyTheLegacyPAC() {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: true, url: legacyPAC)
        runner.scripted[["-getautoproxyurl", "Ethernet"]] = getAutoProxyOutput(enabled: true, url: "http://pac.corp.example/proxy.pac")
        let manager = makeManager(runner: runner)

        XCTAssertEqual(manager.clearLegacyPAC(), ["Wi-Fi"])

        XCTAssertTrue(runner.didRun("-setautoproxystate", ["Wi-Fi", "off"]))
        XCTAssertFalse(
            runner.didRun("-setautoproxystate", ["Ethernet", "off"]),
            "a real corporate PAC must be left alone"
        )
    }

    /// One-time sweep: no `networksetup` traffic on every later launch.
    func testClearLegacyPACRunsOnlyOnce() {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: true, url: legacyPAC)
        let manager = makeManager(runner: runner)

        XCTAssertEqual(manager.clearLegacyPAC(), ["Wi-Fi"])
        runner.resetCalls()

        XCTAssertEqual(manager.clearLegacyPAC(), [])
        XCTAssertTrue(runner.calls.isEmpty, "second run must not touch the system: \(runner.calls)")
    }

    /// A snapshot taken while the legacy PAC was armed must not resurrect it.
    func testClearLegacyPACScrubsPersistedSnapshot() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: true, url: legacyPAC)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])
        XCTAssertEqual(manager.snapshotForTesting?.states.first?.autoProxy, getAutoProxyOutput(enabled: true, url: legacyPAC))

        manager.clearLegacyPAC()

        XCTAssertNil(manager.snapshotForTesting?.states.first?.autoProxy, "legacy PAC was not scrubbed from the snapshot")
    }

    /// Backstop for a snapshot captured before the cleanup ran: restoring must
    /// never re-arm a PAC whose server no longer exists.
    func testRestoreNeverReArmsLegacyPAC() throws {
        let runner = FakeNetworkSetupRunner()
        runner.scripted[["-listallnetworkservices"]] = serviceListOutput
        runner.scripted[["-getautoproxyurl", "Wi-Fi"]] = getAutoProxyOutput(enabled: true, url: legacyPAC)
        let manager = makeManager(runner: runner)

        try manager.enable(httpHost: "127.0.0.1", httpPort: 6152, socksHost: "127.0.0.1", socksPort: 6153, skipProxy: [])
        runner.resetCalls()

        XCTAssertTrue(manager.restoreFromSnapshot())

        XCTAssertFalse(runner.didRun("-setautoproxyurl", ["Wi-Fi", legacyPAC]))
        XCTAssertFalse(runner.didRun("-setautoproxystate", ["Wi-Fi", "on"]))
        XCTAssertTrue(runner.didRun("-setautoproxystate", ["Wi-Fi", "off"]))
    }

    func testIsLegacyPACMatchesOnlyTheRetiredServer() {
        XCTAssertTrue(SystemProxyManager.isLegacyPAC("http://127.0.0.1:8765/proxy.pac"))
        XCTAssertFalse(SystemProxyManager.isLegacyPAC("http://pac.corp.example/proxy.pac"))
        XCTAssertFalse(SystemProxyManager.isLegacyPAC(""))
    }
}

// MARK: - The real runner

/// `NetworkSetupRunner` was the second unbounded elevation path in the app: it
/// pipes the administrator password to `networksetup`, which does not use PAM —
/// for a set-command it goes through Authorization Services, which *can* raise a
/// GUI dialog. An unanswered dialog blocked the child forever behind a
/// `semaphore.wait()` with no deadline.
///
/// These drive a fake executable, because no test may touch real proxy settings.
final class BoundedNetworkSetupRunnerTests: XCTestCase {

    func testTheInjectedExecutableIsWhatActuallyRuns() throws {
        let sandbox = try makeSandbox()
        let marker = sandbox.appendingPathComponent("ran")
        let script = try makeScript("echo hello; : > '\(marker.path)'", in: sandbox)

        let runner = NetworkSetupRunner(adminPasswordProvider: { "hunter2" },
                                        executableURL: script,
                                        timeout: 10)
        XCTAssertEqual(try runner.run(arguments: ["-listallnetworkservices"]), "hello\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the injected executable must be the one that runs")
    }

    /// The administrator password travels on stdin, never in argv — this is the
    /// same rule the VPN launch follows, and it must survive the bounding.
    func testTheAdminPasswordGoesToStdinAndNeverIntoTheCommandLine() throws {
        let sandbox = try makeSandbox()
        let capture = sandbox.appendingPathComponent("stdin")
        let script = try makeScript("cat > '\(capture.path)'", in: sandbox)

        let secret = "correct horse battery staple"
        let runner = NetworkSetupRunner(adminPasswordProvider: { secret },
                                        executableURL: script,
                                        timeout: 10)
        _ = try runner.run(arguments: ["-setwebproxy", "Wi-Fi"])

        XCTAssertEqual(try String(contentsOf: capture, encoding: .utf8), secret)
        XCTAssertFalse(script.path.contains(secret))
    }

    /// A command that never answers must be killed and reported, not waited on.
    func testACommandThatNeverAnswersIsKilledAndReportedAsATimeout() throws {
        let runner = NetworkSetupRunner(adminPasswordProvider: { "hunter2" },
                                        executableURL: URL(fileURLWithPath: "/bin/sleep"),
                                        timeout: 0.5)

        let started = Date()
        XCTAssertThrowsError(try runner.run(arguments: ["30"])) { error in
            guard case SystemProxyError.authorizationTimedOut(let detail)? = error as? SystemProxyError else {
                return XCTFail("expected a timeout, got \(error)")
            }
            XCTAssertTrue(detail.contains("sleep"), "the message must name what did not answer: \(detail)")
            XCTAssertTrue(detail.contains("authorization dialog"))
        }
        // 30 s of `sleep` minus a 0.5 s deadline: it has to come back quickly.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// A real failure is still a failure — the timeout must not swallow it.
    func testANonZeroExitIsStillReportedAsAFailure() throws {
        let sandbox = try makeSandbox()
        let script = try makeScript("echo 'no such service' >&2; exit 3", in: sandbox)

        let runner = NetworkSetupRunner(adminPasswordProvider: { "hunter2" },
                                        executableURL: script,
                                        timeout: 10)
        XCTAssertThrowsError(try runner.run(arguments: ["-setwebproxy", "Wi-Fi"])) { error in
            guard case SystemProxyError.restoreFailed(let detail)? = error as? SystemProxyError else {
                return XCTFail("expected a failure, got \(error)")
            }
            XCTAssertTrue(detail.contains("no such service"), detail)
        }
    }

    // MARK: Helpers

    private func makeSandbox() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("netrunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeScript(_ body: String, in sandbox: URL) throws -> URL {
        let url = sandbox.appendingPathComponent("fake-\(UUID().uuidString)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
