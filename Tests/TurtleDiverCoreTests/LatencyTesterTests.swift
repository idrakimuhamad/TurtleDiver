import XCTest
@testable import TurtleDiverCore

final class LatencyTesterTests: XCTestCase {

    private var servers: [(stop: () -> Void, label: String)] = []

    override func tearDown() {
        for server in servers { server.stop() }
        servers.removeAll()
        super.tearDown()
    }

    private func keepAlive(_ stop: @escaping () -> Void, label: String) {
        servers.append((stop, label))
    }

    // MARK: - URL parsing

    func testParseHTTPURL() {
        let a = LatencyTester.parseHTTPURL("http://cp.cloudflare.com/generate_204")
        XCTAssertEqual(a?.host, "cp.cloudflare.com")
        XCTAssertEqual(a?.port, 80)
        XCTAssertEqual(a?.path, "/generate_204")

        let b = LatencyTester.parseHTTPURL("http://10.0.0.1:8080/")
        XCTAssertEqual(b?.host, "10.0.0.1")
        XCTAssertEqual(b?.port, 8080)
        XCTAssertEqual(b?.path, "/")

        let c = LatencyTester.parseHTTPURL("http://user:pass@example.com/x")
        XCTAssertEqual(c?.host, "example.com", "userinfo stripped")
        XCTAssertEqual(c?.port, 80)
        XCTAssertEqual(c?.path, "/x")

        XCTAssertNil(LatencyTester.parseHTTPURL("https://example.com/"), "https not supported by prober")
        XCTAssertNil(LatencyTester.parseHTTPURL("not a url"))
    }

    // MARK: - DIRECT probing (real sockets, loopback)

    func testProbeDirectAgainstLocalServer() throws {
        guard let server = FakeHTTPServer() else { return XCTFail("server init") }
        keepAlive(server.stop, label: "http")

        let tester = LatencyTester()
        let target = ProbeTarget(policyName: "DIRECT", host: "127.0.0.1", port: server.port, proxyType: nil)
        let result = tester.measure(target, testURL: server.testURL, timeoutSeconds: 5)

        guard case .success(let ms) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertGreaterThan(ms, 0)
        XCTAssertLessThan(ms, 5000)
    }

    func testProbeDirectTimeoutOnDiscardPort() {
        let tester = LatencyTester()
        // Port 9 on loopback: nothing listens (RFC 863 discard rarely bound on macOS).
        let target = ProbeTarget(policyName: "DIRECT", host: "127.0.0.1", port: 9, proxyType: nil)
        let result = tester.measure(target, testURL: "http://127.0.0.1:9/generate_204", timeoutSeconds: 1)
        if case .success = result {
            XCTFail("should not succeed against discard port")
        }
    }

    func testProbeDirectConnectionRefused() {
        let tester = LatencyTester()
        // Bind to find a free port, then close the listener → connects refuse.
        let (fd, port) = TestSockets.listenOnEphemeralLoopback()
        TestSockets.closeFD(fd)

        let target = ProbeTarget(policyName: "DIRECT", host: "127.0.0.1", port: port, proxyType: nil)
        let result = tester.measure(target, testURL: "http://127.0.0.1:\(port)/", timeoutSeconds: 2)
        guard case .failure = result else {
            return XCTFail("expected failure, got \(result)")
        }
    }

    // MARK: - HTTP proxy probing

    func testProbeViaHTTPProxySendsAbsoluteFormRequest() throws {
        guard let proxy = FakeHTTPProxyServer() else { return XCTFail("proxy init") }
        keepAlive(proxy.stop, label: "http-proxy")

        let tester = LatencyTester()
        let target = ProbeTarget(policyName: "P", host: "127.0.0.1", port: proxy.port, proxyType: .http)
        let testURL = "http://origin.example.com/generate_204"
        let result = tester.measure(target, testURL: testURL, timeoutSeconds: 5)

        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        let requests = proxy.requestLines
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].hasPrefix("GET http://origin.example.com/generate_204 HTTP/1.1"),
                      "proxy must receive absolute-form request line, got: \(requests[0])")
    }

    // MARK: - SOCKS5 probing

    func testProbeViaSOCKS5NoAuth() throws {
        guard let proxy = FakeSOCKS5Server() else { return XCTFail("socks init") }
        keepAlive(proxy.stop, label: "socks")

        let tester = LatencyTester()
        let target = ProbeTarget(policyName: "S", host: "127.0.0.1", port: proxy.port, proxyType: .socks5)
        let result = tester.measure(target, testURL: "http://127.0.0.1:1/generate_204", timeoutSeconds: 5)

        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertGreaterThan(proxy.connectCount, 0)
    }

    func testProbeViaSOCKS5WithAuth() throws {
        guard let proxy = FakeSOCKS5AuthServer(user: "alice", pass: "s3cret") else { return XCTFail("socks-auth init") }
        keepAlive(proxy.stop, label: "socks-auth")

        let tester = LatencyTester()
        let target = ProbeTarget(
            policyName: "SA", host: "127.0.0.1", port: proxy.port,
            proxyType: .socks5, proxyUsername: "alice", proxyPassword: "s3cret"
        )
        let result = tester.measure(target, testURL: "http://127.0.0.1:1/generate_204", timeoutSeconds: 5)

        guard case .success = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(proxy.authOK, "server must have received correct credentials")
    }

    func testProbeViaSOCKS5WrongAuthFails() throws {
        guard let proxy = FakeSOCKS5AuthServer(user: "alice", pass: "s3cret") else { return XCTFail("socks-auth init") }
        keepAlive(proxy.stop, label: "socks-auth-wrong")

        let tester = LatencyTester()
        let target = ProbeTarget(
            policyName: "SA", host: "127.0.0.1", port: proxy.port,
            proxyType: .socks5, proxyUsername: "alice", proxyPassword: "wrong"
        )
        let result = tester.measure(target, testURL: "http://127.0.0.1:1/generate_204", timeoutSeconds: 5)
        guard case .failure(let reason) = result else {
            return XCTFail("expected failure, got \(result)")
        }
        XCTAssertTrue(reason.lowercased().contains("auth"), "failure should mention auth: \(reason)")
    }

    // MARK: - HTTPS proxy (TCP reachability semantics)

    func testProbeHTTPSProxyMeasuresTCPReachability() throws {
        guard let proxy = FakeHTTPServer() else { return XCTFail("server init") }
        keepAlive(proxy.stop, label: "https-target")

        let tester = LatencyTester()
        let target = ProbeTarget(policyName: "H", host: "127.0.0.1", port: proxy.port, proxyType: .https)
        let result = tester.measure(target, testURL: "http://elsewhere.example.com/", timeoutSeconds: 5)
        guard case .success = result else {
            return XCTFail("expected success (TCP reachable), got \(result)")
        }
    }

    // MARK: - Integration: PolicyStore drives real probes

    func testPolicyStoreEndToEndWithRealProber() throws {
        guard let server = FakeHTTPServer() else { return XCTFail("server init") }
        keepAlive(server.stop, label: "e2e-http")

        var profile = Profile(name: "E2E")
        profile.general.testURL = server.testURL
        profile.general.testTimeout = 3
        profile.proxies = [
            ProxyDefinition(name: "Loop", type: .http, host: "127.0.0.1", port: server.port)
        ]
        profile.groups = [
            ProxyGroup(name: "Auto", type: .urlTest, policies: ["Loop"])
        ]
        profile.rules = [ProfileRule(type: .final, value: "", policy: "Auto")]

        let store = PolicyStore(profile: profile, defaults: nil, measurer: LatencyTester(), autoStartTesting: false)
        store.testAllPolicies() // synchronous enough: waits for probes via group.notify? No — async.

        // testAllPolicies is async; poll for the result to land.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if store.health(for: "Loop")?.lastResult.isUsable == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let health = try XCTUnwrap(store.health(for: "Loop"))
        guard case .success(let ms) = health.lastResult else {
            return XCTFail("expected success, got \(health.lastResult)")
        }
        XCTAssertGreaterThan(ms, 0)
        XCTAssertEqual(try store.resolve("Auto"), .proxy(profile.proxies[0]))
    }
}
