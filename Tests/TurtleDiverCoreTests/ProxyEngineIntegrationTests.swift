import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules
@testable import TurtleDiverEngine

final class ProxyEngineIntegrationTests: XCTestCase {

    // MARK: - Harness

    private var profile: Profile!
    /// Keeps engines alive for the duration of each test (a deallocated
    /// engine cancels its accept sources and stops serving).
    private var engines: [ProxyEngine] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        profile = Profile(name: "engine-test")
        profile.general.httpListen = "127.0.0.1:0"      // replaced per-test
        profile.general.socks5Listen = "127.0.0.1:0"
        profile.general.testInterval = 3600
    }

    override func tearDownWithError() throws {
        for engine in engines { engine.stop() }
        engines.removeAll()
        profile = nil
        try super.tearDownWithError()
    }

    /// Builds an engine with fresh loopback ports and starts it.
    private func makeEngine(
        rules: [ProfileRule],
        proxies: [ProxyDefinition] = [],
        groups: [ProxyGroup] = [],
        httpListen: String? = nil,
        socksListen: String? = nil
    ) throws -> (engine: ProxyEngine, httpPort: Int, socksPort: Int) {
        var profile = profile!
        profile.general.httpListen = httpListen ?? "127.0.0.1:0"
        profile.general.socks5Listen = socksListen ?? "127.0.0.1:0"
        profile.proxies = proxies
        profile.groups = groups
        profile.rules = rules
        let log = RequestLog()
        let engine = ProxyEngine(profile: profile, requestLog: log)
        // start() parses listeners; port 0 binds ephemeral — but start() uses
        // the configured port, so pick real free ports first.
        let httpPort = try freePort()
        let socksPort = try freePort()
        try engine.start(profile: withPorts(profile, http: httpPort, socks: socksPort))
        engines.append(engine)
        return (engine, httpPort, socksPort)
    }

    private func withPorts(_ profile: Profile, http: Int, socks: Int) -> Profile {
        var profile = profile
        profile.general.httpListen = "127.0.0.1:\(http)"
        profile.general.socks5Listen = "127.0.0.1:\(socks)"
        return profile
    }

    private func freePort() throws -> Int {
        let (fd, port) = TestSockets.listenOnEphemeralLoopback()
        TestSockets.closeFD(fd)
        return port
    }

    // MARK: - Engine lifecycle

    func testStartBindsBothListenersAndStopReleasesThem() throws {
        let (engine, httpPort, socksPort) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        XCTAssertEqual(engine.listeningPorts.http, httpPort)
        XCTAssertEqual(engine.listeningPorts.socks5, socksPort)
        XCTAssertTrue(engine.isRunning)

        engine.stop()
        XCTAssertFalse(engine.isRunning)
        // Ports are released: another bind to the same port must succeed.
        let fd = try ProxyEngine.makeListenerFD(host: "127.0.0.1", port: httpPort)
        TCPClient.closeSocket(fd)
    }

    func testParseListenFormats() {
        XCTAssertEqual(ProxyEngine.parseListen("127.0.0.1:6152")?.port, 6152)
        XCTAssertEqual(ProxyEngine.parseListen("0.0.0.0:8080")?.host, "0.0.0.0")
        XCTAssertEqual(ProxyEngine.parseListen("[::1]:6153")?.host, "::1")
        XCTAssertEqual(ProxyEngine.parseListen("[::1]:6153")?.port, 6153)
        XCTAssertNil(ProxyEngine.parseListen("no-port"))
        XCTAssertNil(ProxyEngine.parseListen("127.0.0.1:99999"))
        XCTAssertNil(ProxyEngine.parseListen(""))
    }

    // MARK: - HTTP CONNECT through the local listener

    func testHTTPConnectTunnelViaDirectPolicy() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n")
        let reply = try readSome(client, minBytes: 1)
        XCTAssertTrue(String(bytes: reply, encoding: .utf8)!.contains("200"), "expected 200, got: \(String(bytes: reply, encoding: .utf8)!)")

        // Tunnel open: echo round-trip must be byte-faithful.
        try send(client, "ping-through-tunnel")
        let echoed = try readSome(client, minBytes: "ping-through-tunnel".count)
        XCTAssertEqual(String(bytes: echoed, encoding: .utf8), "ping-through-tunnel")
        TCPClient.closeSocket(client)
        _ = engine
    }

    func testHTTPConnectRejectedByRule() throws {
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .domainSuffix, value: "blocked.example", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT blocked.example:443 HTTP/1.1\r\nHost: blocked.example:443\r\n\r\n")
        let reply = String(bytes: try readSome(client, minBytes: 1), encoding: .utf8) ?? ""
        XCTAssertTrue(reply.contains("403"), "expected 403 for REJECT, got: \(reply)")
        TCPClient.closeSocket(client)

        let entries = engine.requestLog.snapshot()
        XCTAssertTrue(entries.contains { $0.host == "blocked.example" && $0.policy == "REJECT" && $0.error == "rejected" })
    }

    func testHTTPConnectLogsRequestAndRule() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .domain, value: "127.0.0.1", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "REJECT")
        ])

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\n\r\n")
        _ = try readSome(client, minBytes: 1) // 200 reply
        try send(client, "x")
        _ = try readSome(client, minBytes: 1) // echo back
        TCPClient.closeSocket(client)

        // Wait for log finish (relays close asynchronously).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let entries = engine.requestLog.snapshot()
            if let entry = entries.first(where: { $0.host == "127.0.0.1" && $0.endedAt != nil }) {
                XCTAssertEqual(entry.policy, "DIRECT")
                XCTAssertEqual(entry.rule?.type, .domain)
                XCTAssertEqual(entry.transport, .http)
                XCTAssertNil(entry.error)
                XCTAssertGreaterThan(entry.bytesToDestination, 0)
                XCTAssertGreaterThan(entry.bytesToClient, 0)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("no finished request-log entry found for 127.0.0.1")
    }

    // MARK: - Absolute-form forwarding

    func testAbsoluteFormRequestForwardedInOriginForm() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: httpPort)
        let request = "GET http://127.0.0.1:\(origin.port)/some/path?q=1 HTTP/1.1\r\nHost: 127.0.0.1:\(origin.port)\r\nUser-Agent: Phase3Test/1.0\r\n\r\n"
        try send(client, request)
        let response = try readSome(client, minBytes: 1)
        let responseText = String(bytes: response, encoding: .utf8) ?? ""
        XCTAssertTrue(responseText.contains("200"), "expected 200 from origin, got: \(responseText)")
        XCTAssertTrue(responseText.contains("hello-from-origin"))
        TCPClient.closeSocket(client)

        // The origin must have seen an origin-form request line.
        let seen = origin.receivedRequests.first ?? ""
        XCTAssertTrue(seen.hasPrefix("GET /some/path?q=1 HTTP/1.1"), "origin saw: \(seen)")
        XCTAssertTrue(seen.lowercased().contains("user-agent: phase3test/1.0"), "origin saw: \(seen)")
        XCTAssertFalse(seen.contains("http://127.0.0.1"), "absolute-URI must be rewritten to origin-form")
        _ = engine
    }

    // MARK: - Upstream proxy (policy → HTTP CONNECT upstream)

    func testTrafficGoesThroughHTTPConnectUpstream() throws {
        let upstream = FakeHTTPConnectProxyServer()
        defer { upstream.stop() }
        var profile = profile!
        profile.proxies = [ProxyDefinition(name: "Up", type: .http, host: "127.0.0.1", port: upstream.port)]

        let (engine, httpPort, _) = try makeEngine(
            rules: [ProfileRule(type: .final, value: "", policy: "Up")],
            proxies: profile.proxies
        )

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT secret.example:443 HTTP/1.1\r\n\r\n")
        _ = try readSome(client, minBytes: 1) // 200 from local engine
        try send(client, "tunnel-payload")
        let echoed = try readSome(client, minBytes: "tunnel-payload".count)
        XCTAssertEqual(String(bytes: echoed, encoding: .utf8), "tunnel-payload")
        TCPClient.closeSocket(client)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !upstream.connectTargets.isEmpty {
                XCTAssertEqual(upstream.connectTargets.first, "secret.example:443")
                let entry = engine.requestLog.snapshot().first { $0.host == "secret.example" }
                XCTAssertEqual(entry?.policy, "Up")
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("upstream never saw the CONNECT")
    }

    func testUpstreamConnectRefusalSurfacesAs502() throws {
        let upstream = FakeHTTPConnectProxyServer(refusesConnects: true)
        defer { upstream.stop() }
        let (_, httpPort, _) = try makeEngine(
            rules: [ProfileRule(type: .final, value: "", policy: "Up")],
            proxies: [ProxyDefinition(name: "Up", type: .http, host: "127.0.0.1", port: upstream.port)]
        )

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT secret.example:443 HTTP/1.1\r\n\r\n")
        let reply = String(bytes: try readSome(client, minBytes: 1), encoding: .utf8) ?? ""
        XCTAssertTrue(reply.contains("502"), "expected 502 when upstream refuses, got: \(reply)")
        TCPClient.closeSocket(client)
    }

    // MARK: - SOCKS5 listener

    func testSOCKS5ConnectViaDirectPolicy() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, _, socksPort) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: socksPort)
        // Greeting: ver 5, 1 method, no-auth
        try send(client, [0x05, 0x01, 0x00])
        var greeting = try readSome(client, minBytes: 2)
        XCTAssertEqual(Array(greeting.prefix(2)), [0x05, 0x00])

        // CONNECT to loopback echo (IPv4 addressing)
        try send(client, [0x05, 0x01, 0x00, 0x01] + ipv4Bytes("127.0.0.1") + portBytes(echo.port))
        let reply = try readSome(client, minBytes: 2)
        XCTAssertEqual(Array(reply.prefix(2)), [0x05, 0x00], "SOCKS CONNECT should succeed")

        try send(client, Array("socks-payload".utf8))
        let echoed = try readSome(client, minBytes: "socks-payload".count)
        XCTAssertEqual(String(bytes: echoed, encoding: .utf8), "socks-payload")
        TCPClient.closeSocket(client)

        let entry = engine.requestLog.snapshot().first { $0.transport == .socks5 }
        XCTAssertNotNil(entry)
        XCTAssertEqual(entry?.policy, "DIRECT")
    }

    func testSOCKS5DomainAddressingAndReject() throws {
        let (engine, _, socksPort) = try makeEngine(rules: [
            ProfileRule(type: .domainKeyword, value: "telemetry", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: socksPort)
        try send(client, [0x05, 0x01, 0x00])
        _ = try readSome(client, minBytes: 2)

        let host = Array("telemetry.vendor.example".utf8)
        try send(client, [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host + portBytes(443))
        let reply = try readSome(client, minBytes: 2)
        XCTAssertEqual(Array(reply.prefix(2)), [0x05, 0x02], "REJECT → connection not allowed by ruleset (0x02)")
        TCPClient.closeSocket(client)

        let entries = engine.requestLog.snapshot()
        XCTAssertTrue(entries.contains { $0.transport == .socks5 && $0.policy == "REJECT" && $0.rule?.type == .domainKeyword })
    }

    func testSOCKS5RejectsUnsupportedCommand() throws {
        let (_, _, socksPort) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        let client = try connect(host: "127.0.0.1", port: socksPort)
        try send(client, [0x05, 0x01, 0x00])
        _ = try readSome(client, minBytes: 2)
        // BIND (0x02) is not supported
        try send(client, [0x05, 0x02, 0x00, 0x01] + ipv4Bytes("127.0.0.1") + portBytes(80))
        let reply = try readSome(client, minBytes: 2)
        XCTAssertEqual(Array(reply.prefix(2)), [0x05, 0x07], "BIND → command not supported")
        TCPClient.closeSocket(client)
    }

    func testSOCKS5NoSharedAuthMethodFails() throws {
        let (_, _, socksPort) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        let client = try connect(host: "127.0.0.1", port: socksPort)
        // Offer only GSSAPI (0x01) — we support no-auth only.
        try send(client, [0x05, 0x01, 0x01])
        let reply = try readSome(client, minBytes: 2)
        XCTAssertEqual(Array(reply.prefix(2)), [0x05, 0xFF])
        TCPClient.closeSocket(client)
    }

    // MARK: - Malformed input hardening

    func testGarbageRequestGets400AndClose() throws {
        let (_, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "NONSENSE\r\n\r\n")
        let reply = String(bytes: try readSome(client, minBytes: 1), encoding: .utf8) ?? ""
        XCTAssertTrue(reply.contains("400"), "expected 400 for garbage, got: \(reply)")
        TCPClient.closeSocket(client)
    }

    func testOriginFormRequestGets400() throws {
        let (_, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "GET /just-a-path HTTP/1.1\r\nHost: somewhere\r\n\r\n")
        let reply = String(bytes: try readSome(client, minBytes: 1), encoding: .utf8) ?? ""
        XCTAssertTrue(reply.contains("400"), "origin-form to a proxy is a client error, got: \(reply)")
        TCPClient.closeSocket(client)
    }

    // MARK: - Unreachable destination

    func testConnectToDeadPortReturns502() throws {
        let deadPort = try freePort() // bound then closed → nothing listening
        let (_, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT 127.0.0.1:\(deadPort) HTTP/1.1\r\n\r\n")
        let reply = String(bytes: try readSome(client, minBytes: 1), encoding: .utf8) ?? ""
        XCTAssertTrue(reply.contains("502"), "expected 502 for dead destination, got: \(reply)")
        TCPClient.closeSocket(client)
    }

    // MARK: - Request log capacity

    func testRequestLogRingBufferTrims() {
        let log = RequestLog(capacity: 5)
        for i in 0..<20 {
            log.append(RequestEntry(
                host: "h\(i)", port: 80, rule: nil, policy: "DIRECT",
                bytesToDestination: 0, bytesToClient: 0, transport: .http, error: nil
            ))
        }
        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.count, 5)
        XCTAssertEqual(snapshot.first?.host, "h15", "oldest entries must be trimmed")
        XCTAssertEqual(snapshot.last?.host, "h19")
    }

    // MARK: - Backpressure / relay resume probe

    /// Regression test for a crash in the relay's backpressure path.
    ///
    /// With a stalled origin the engine buffers the client's upload past its
    /// pause watermark, suspends the client read source and arms a write source
    /// on the origin's fd. When the origin starts draining, that write handler
    /// flushes the buffer empty and resumes the read source — whose lost-edge
    /// probe pumped a read **while the write handler still held an exclusive
    /// `inout` access to that same buffer**, trapping the Swift runtime's
    /// exclusivity check (`Simultaneous accesses to ...`) and aborting the app.
    /// Seen in the wild on `com.turtlediver.engine.relay` in
    /// `readFromOutbound()`.
    func testRelayResumeProbeSurvivesBackpressureWithoutExclusivityTrap() throws {
        // An origin that refuses to read for a beat (forcing backpressure, the
        // pause and the write source), then drains everything.
        let (originListener, originPort) = TestSockets.listenOnEphemeralLoopback()
        defer { TestSockets.closeFD(originListener) }
        let received = OriginByteCounter()
        let drained = DispatchSemaphore(value: 0)
        let expected = 2 * 1024 * 1024

        Thread.detachNewThread {
            defer { drained.signal() }
            guard let conn = TestSockets.acceptWithTimeout(fd: originListener, seconds: 5) else { return }
            defer { TestSockets.closeFD(conn) }
            Thread.sleep(forTimeInterval: 0.6) // stall: fill the engine's buffers
            // Drain exactly the payload — NOT until EOF: the client only closes
            // after this thread reports back, so waiting for EOF would deadlock.
            while received.count < expected {
                guard let chunk = TestSockets.readSome(fd: conn, max: 64 * 1024), !chunk.isEmpty else { return }
                received.add(chunk.count)
            }
        }

        let (_, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        let client = try connect(host: "127.0.0.1", port: httpPort)
        defer { TestSockets.closeFD(client) }

        try send(client, "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n")
        let established = String(decoding: try readSome(client, minBytes: 12), as: UTF8.self)
        XCTAssertTrue(established.contains("200"), "tunnel must be established, got: \(established.prefix(40))")

        let payload = [UInt8](repeating: 0x5A, count: expected)
        try send(client, payload)

        XCTAssertEqual(
            drained.wait(timeout: .now() + 20), .success,
            "the origin must drain the payload once it starts reading"
        )
        XCTAssertEqual(received.count, expected, "the relay must deliver every byte after the resume probe")
    }

    // MARK: - Request detail capture

    /// Polls the log until the newest entry for `transport` has a captured
    /// detail that satisfies `predicate` (capture happens on the relay queue).
    private func capturedDetail(
        _ engine: ProxyEngine,
        transport: RequestTransport,
        where predicate: (RequestDetail) -> Bool = { _ in true }
    ) -> RequestDetail? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let match = engine.requestLog.snapshot()
                .last { $0.transport == transport }?
                .detail
            if let match, predicate(match) { return match }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }

    func testPlainHTTPCapturesTheHeadAndWithholdsCookies() throws {
        let origin = FakeHTTPServer()!
        defer { origin.stop() }
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "GET http://127.0.0.1:\(origin.port)/generate_204 HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "User-Agent: turtle-test\r\n"
            + "Cookie: session=SUPERSECRET\r\n"
            + "Connection: close\r\n\r\n")
        _ = try readSome(client, minBytes: 1)
        TCPClient.closeSocket(client)

        let detail = try XCTUnwrap(capturedDetail(engine, transport: .http) { $0.statusLine != nil },
                                   "no captured detail for the plain HTTP request")
        XCTAssertEqual(detail.requestLine?.hasPrefix("GET "), true)
        XCTAssertEqual(detail.requestLine?.contains("/generate_204"), true)
        XCTAssertEqual(detail.requestHeaders.first { $0.name == "user-agent" }?.value, "turtle-test")

        // The cookie is the whole reason the switch exists: it is recorded as a
        // shape, never as a value, until the user asks otherwise.
        let cookie = try XCTUnwrap(detail.requestHeaders.first { $0.name == "cookie" })
        XCTAssertTrue(cookie.redacted)
        XCTAssertEqual(cookie.value, "•••• (19 chars)")
        XCTAssertFalse(detail.requestHeaders.contains { $0.value.contains("SUPERSECRET") })

        XCTAssertEqual(detail.statusLine, "HTTP/1.1 204 No Content")
        XCTAssertTrue(detail.responseHeaders.contains { $0.name == "content-length" })
        XCTAssertEqual(detail.resolvedAddress, "127.0.0.1")
    }

    func testATunnelCapturesTheClientHelloServerName() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        // The tunnel target is an address, which is exactly the case the SNI
        // parsing exists to fix up.
        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n\r\n")
        let reply = try readSome(client, minBytes: 1)
        XCTAssertTrue(String(decoding: reply, as: UTF8.self).contains("200"))

        try send(client, makeClientHello(serverName: "login.example.com", alpn: ["h2", "http/1.1"]))
        // Read the echo back so the relay has certainly seen the hello.
        _ = try readSome(client, minBytes: 4)

        let detail = try XCTUnwrap(capturedDetail(engine, transport: .http) { $0.serverName != nil },
                                   "the ClientHello was not parsed")
        XCTAssertEqual(detail.serverName, "login.example.com")
        XCTAssertEqual(detail.alpn, ["h2", "http/1.1"])
        XCTAssertEqual(detail.tlsVersion, "TLS 1.3")
        XCTAssertEqual(detail.resolvedAddress, "127.0.0.1")
        XCTAssertEqual(detail.requestLine, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1")
        TCPClient.closeSocket(client)
    }

    /// A tunnelled protocol that is not TLS (SSH, a database) never produces a
    /// ClientHello, so the head captured before the tunnel opened is all there
    /// is to show — it must be attached on its own, not only via the TLS merge.
    func testATunnelThatIsNotTLSKeepsItsRequestHead() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(echo.port)\r\n"
            + "Proxy-Connection: keep-alive\r\n\r\n")
        _ = try readSome(client, minBytes: 1)
        try send(client, Array("SSH-2.0-OpenSSH_9.0\r\n".utf8))
        _ = try readSome(client, minBytes: 4)

        let detail = try XCTUnwrap(capturedDetail(engine, transport: .http) { $0.requestLine != nil },
                                   "the CONNECT head was dropped")
        XCTAssertEqual(detail.requestLine, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1")
        XCTAssertEqual(detail.requestHeaders.first { $0.name == "proxy-connection" }?.value, "keep-alive")
        XCTAssertNil(detail.serverName, "an SSH banner is not a ClientHello")
        TCPClient.closeSocket(client)
    }

    func testSOCKS5CapturesTheClientHelloServerName() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, _, socksPort) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        let client = try connect(host: "127.0.0.1", port: socksPort)
        try send(client, [0x05, 0x01, 0x00])
        _ = try readSome(client, minBytes: 2)
        try send(client, [0x05, 0x01, 0x00, 0x01] + ipv4Bytes("127.0.0.1") + portBytes(echo.port))
        let reply = try readSome(client, minBytes: 2)
        XCTAssertEqual(Array(reply.prefix(2)), [0x05, 0x00])

        try send(client, makeClientHello(serverName: "socks.example.com"))
        _ = try readSome(client, minBytes: 4)

        let detail = try XCTUnwrap(capturedDetail(engine, transport: .socks5) { $0.serverName != nil },
                                   "the SOCKS5 ClientHello was not parsed")
        XCTAssertEqual(detail.serverName, "socks.example.com")
        TCPClient.closeSocket(client)
    }

    func testTurningCaptureOffStopsDetails() throws {
        let origin = FakeHTTPServer()!
        defer { origin.stop() }
        let (engine, httpPort, _) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])
        engine.requestLog.capturesDetails = false

        let client = try connect(host: "127.0.0.1", port: httpPort)
        try send(client, "GET http://127.0.0.1:\(origin.port)/generate_204 HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\nConnection: close\r\n\r\n")
        _ = try readSome(client, minBytes: 1)
        TCPClient.closeSocket(client)

        // The row must still be logged; only its detail is skipped.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && engine.requestLog.snapshot().isEmpty {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(engine.requestLog.snapshot().isEmpty)
        XCTAssertTrue(engine.requestLog.snapshot().allSatisfy { $0.detail == nil })
    }

    // MARK: - Socket helpers

    private func connect(host: String, port: Int) throws -> Int32 {
        let fd = try TCPClient.connect(host: host, port: port, timeoutSeconds: 5)
        return fd
    }

    private func send(_ fd: Int32, _ string: String) throws {
        try TCPClient.sendAll(fd: fd, Array(string.utf8), timeoutSeconds: 5)
    }

    private func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        try TCPClient.sendAll(fd: fd, bytes, timeoutSeconds: 5)
    }

    private func readSome(_ fd: Int32, minBytes: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(5)
        while out.count < minBytes && Date() < deadline {
            guard TCPClient.waitForReadable(fd: fd, timeoutSeconds: max(deadline.timeIntervalSinceNow, 0.1)) else { break }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 4096, 0) }
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                break
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }
        }
        return out
    }

    private func ipv4Bytes(_ text: String) -> [UInt8] {
        IPAddress.parseIPv4(text)!.bytes
    }

    private func portBytes(_ port: Int) -> [UInt8] {
        [UInt8((port >> 8) & 0xFF), UInt8(port & 0xFF)]
    }
}

/// Thread-safe byte tally shared with the harness servers.
final class OriginByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    var count: Int { lock.withLock { _count } }

    func add(_ n: Int) { lock.withLock { _count += n } }
}
