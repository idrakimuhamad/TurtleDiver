import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules
@testable import TurtleDiverEngine

/// "Share with a device": a second, authenticated HTTP listener on the LAN that
/// feeds the same rule engine. A real LAN address cannot be bound in a test, so
/// the share listener runs on loopback — and, by design, loopback is treated as
/// an ordinary client there (no special case), which is exactly what these tests
/// exercise.
final class ProxyShareTests: XCTestCase {

    private var engines: [ProxyEngine] = []

    override func tearDownWithError() throws {
        for engine in engines { engine.stop() }
        engines.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Harness

    private func makeEngine(
        rules: [ProfileRule],
        proxies: [ProxyDefinition] = [],
        groups: [ProxyGroup] = []
    ) throws -> (engine: ProxyEngine, httpPort: Int) {
        var profile = Profile(name: "share-test")
        profile.general.testInterval = 3600
        profile.rules = rules
        profile.proxies = proxies
        profile.groups = groups
        let httpPort = try freePort()
        let socksPort = try freePort()
        profile.general.httpListen = "127.0.0.1:\(httpPort)"
        profile.general.socks5Listen = "127.0.0.1:\(socksPort)"
        let engine = ProxyEngine(profile: profile, requestLog: RequestLog())
        try engine.start(profile: profile)
        engines.append(engine)
        return (engine, httpPort)
    }

    @discardableResult
    private func startShare(
        _ engine: ProxyEngine,
        host: String = "127.0.0.1",
        user: String = "phone",
        pass: String = "secret",
        allowed: Set<String> = [],
        tunnelMode: SharePACGenerator.TunnelMode = .fullTunnel
    ) throws -> Int {
        let sharePort = try freePort()
        try engine.startSharing(ShareConfiguration(
            host: host, port: sharePort, username: user, password: pass,
            allowedClients: allowed, tunnelMode: tunnelMode
        ))
        return sharePort
    }

    private func basic(_ user: String, _ pass: String) -> String {
        "Basic " + Data("\(user):\(pass)".utf8).base64EncodedString()
    }

    private func get(_ port: Int, originPort: Int, path: String, auth: String? = nil) throws -> String {
        let client = try connect(host: "127.0.0.1", port: port)
        defer { TCPClient.closeSocket(client) }
        var request = "GET http://127.0.0.1:\(originPort)\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n"
        if let auth { request += "Proxy-Authorization: \(auth)\r\n" }
        request += "\r\n"
        try send(client, request)
        return String(bytes: try readSome(client, minBytes: 1), encoding: .utf8) ?? ""
    }

    // MARK: - Authentication

    func testSharedListenerRefusesWithoutCredentialsAndRecordsTheClient() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine)

        let notified = AddressRecorder()
        engine.onRefusedClient = { address in notified.record(address) }

        let first = try get(sharePort, originPort: origin.port, path: "/x")
        XCTAssertTrue(first.contains("407"), "expected 407 without credentials, got: \(first)")
        XCTAssertTrue(first.contains("Proxy-Authenticate: Basic realm=\"TurtleDiver\""), "got: \(first)")

        let recorded = try XCTUnwrap(waitForRefusal(engine, attempts: 1), "the refused client was not recorded")
        XCTAssertEqual(recorded.address, "127.0.0.1")
        XCTAssertTrue(origin.receivedRequests.isEmpty, "the origin must not be contacted before auth")

        // A repeat bumps the attempt count and keeps a single entry.
        let second = try get(sharePort, originPort: origin.port, path: "/x")
        XCTAssertTrue(second.contains("407"))
        let bumped = try XCTUnwrap(waitForRefusal(engine, attempts: 2))
        XCTAssertEqual(bumped.address, "127.0.0.1")
        XCTAssertEqual(engine.refusedClients.count, 1)

        XCTAssertEqual(notified.addresses, ["127.0.0.1", "127.0.0.1"])

        // The record is forgettable.
        engine.forgetRefusedClient("127.0.0.1")
        XCTAssertTrue(engine.refusedClients.isEmpty)
    }

    func testSharedListenerRefusesWrongCredentials() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")

        let reply = try get(sharePort, originPort: origin.port, path: "/x", auth: basic("phone", "wrong"))
        XCTAssertTrue(reply.contains("407"), "wrong password must be refused, got: \(reply)")
        XCTAssertEqual(waitForRefusal(engine, attempts: 1)?.address, "127.0.0.1")
        XCTAssertTrue(origin.receivedRequests.isEmpty)
    }

    func testSharedListenerAdmitsCorrectCredentialsForGETAndCONNECT() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")

        // Plain GET via the shared listener, routed through the rule engine.
        let reply = try get(sharePort, originPort: origin.port, path: "/hello", auth: basic("phone", "secret"))
        XCTAssertTrue(reply.contains("200"), "expected 200 with credentials, got: \(reply)")
        XCTAssertTrue(reply.contains("hello-from-origin"))
        XCTAssertTrue(engine.refusedClients.isEmpty)

        // CONNECT tunnel through the shared listener.
        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(echo.port)\r\n"
            + "Proxy-Authorization: \(basic("phone", "secret"))\r\n\r\n")
        let established = String(bytes: try readSome(client, minBytes: 1), encoding: .utf8) ?? ""
        XCTAssertTrue(established.contains("200"), "expected tunnel, got: \(established)")
        try send(client, "through-share")
        let echoed = try readSome(client, minBytes: "through-share".count)
        XCTAssertEqual(String(bytes: echoed, encoding: .utf8), "through-share")
    }

    func testAllowedClientsAreAdmittedWithoutCredentials() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, allowed: ["127.0.0.1"])

        let reply = try get(sharePort, originPort: origin.port, path: "/allowed")
        XCTAssertTrue(reply.contains("200"), "an allow-listed client needs no credentials, got: \(reply)")
        XCTAssertTrue(engine.refusedClients.isEmpty)
    }

    func testUpdateShareAccessTakesEffectWithoutRebinding() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "oldpass", allowed: ["127.0.0.1"])

        XCTAssertTrue(try get(sharePort, originPort: origin.port, path: "/x",
                              auth: basic("phone", "oldpass")).contains("200"))

        let before = try XCTUnwrap(engine.sharingAddress)
        engine.updateShareAccess(username: "phone", password: "newpass", allowedClients: [])
        let after = try XCTUnwrap(engine.sharingAddress)
        XCTAssertEqual(before.host, after.host)
        XCTAssertEqual(before.port, after.port, "the swap must not rebind")

        XCTAssertTrue(try get(sharePort, originPort: origin.port, path: "/x",
                              auth: basic("phone", "oldpass")).contains("407"),
                      "the old password must stop working")
        XCTAssertTrue(try get(sharePort, originPort: origin.port, path: "/x",
                              auth: basic("phone", "newpass")).contains("200"),
                      "the new password must work on the same listener")

        // The allow-list swap takes effect too: no credentials, admitted by address.
        engine.updateShareAccess(username: "phone", password: "newpass", allowedClients: ["127.0.0.1"])
        XCTAssertTrue(try get(sharePort, originPort: origin.port, path: "/x").contains("200"))
    }

    // MARK: - Credential hygiene

    func testProxyAuthorizationIsNeverForwardedToTheOrigin() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, httpPort) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")

        // Loopback listener: unauthenticated, but the header is still stripped.
        let loopbackReply = try get(httpPort, originPort: origin.port, path: "/loop",
                                    auth: basic("foo", "bar"))
        XCTAssertTrue(loopbackReply.contains("200"), "got: \(loopbackReply)")

        // Shared listener: the credential authenticates us and must not travel on.
        let sharedReply = try get(sharePort, originPort: origin.port, path: "/shared",
                                  auth: basic("phone", "secret"))
        XCTAssertTrue(sharedReply.contains("200"), "got: \(sharedReply)")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && origin.receivedRequests.count < 2 { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(origin.receivedRequests.count, 2)
        for seen in origin.receivedRequests {
            XCTAssertFalse(seen.lowercased().contains("proxy-authorization"),
                           "credentials leaked to the origin: \(seen)")
        }
        XCTAssertTrue(origin.receivedRequests.contains { $0.hasPrefix("GET /loop ") })
        XCTAssertTrue(origin.receivedRequests.contains { $0.hasPrefix("GET /shared ") })
    }

    // MARK: - Teardown

    func testStopSharingClosesTheListenerAndSharedRelaysButNotLoopback() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, httpPort) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, allowed: ["127.0.0.1"])

        // One in-flight tunnel on each listener.
        let shared = try connect(host: "127.0.0.1", port: sharePort)
        try send(shared, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\n\r\n")
        _ = try readSome(shared, minBytes: 1)

        let loopback = try connect(host: "127.0.0.1", port: httpPort)
        try send(loopback, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\n\r\n")
        _ = try readSome(loopback, minBytes: 1)

        XCTAssertNotNil(engine.sharingAddress)
        engine.stopSharing()
        XCTAssertNil(engine.sharingAddress)

        // The shared relay is torn down: the client's tunnel hits EOF.
        XCTAssertTrue(waitForEOF(shared), "the in-flight shared relay must be closed")
        TCPClient.closeSocket(shared)

        // The listener is gone: a fresh connect cannot land.
        XCTAssertThrowsError(try TCPClient.connect(host: "127.0.0.1", port: sharePort, timeoutSeconds: 2))

        // The loopback tunnel survives.
        try send(loopback, "still-alive")
        let echoed = try readSome(loopback, minBytes: "still-alive".count)
        XCTAssertEqual(String(bytes: echoed, encoding: .utf8), "still-alive")
        TCPClient.closeSocket(loopback)
    }

    // MARK: - Request log / display

    func testRequestEntryCarriesTheSharedClientButNotTheLoopbackPeer() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, httpPort) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, allowed: ["127.0.0.1"])

        XCTAssertTrue(try get(httpPort, originPort: origin.port, path: "/loop").contains("200"))
        XCTAssertTrue(try get(sharePort, originPort: origin.port, path: "/shared").contains("200"))

        let sharedEntry = try XCTUnwrap(waitForEntry(engine) { $0.detail?.requestLine?.contains("/shared") == true })
        XCTAssertEqual(sharedEntry.client, "127.0.0.1")
        XCTAssertTrue(generalRows(sharedEntry).contains { $0.name == "Client" && $0.value == "127.0.0.1" })

        let loopEntry = try XCTUnwrap(waitForEntry(engine) { $0.detail?.requestLine?.contains("/loop") == true })
        XCTAssertNil(loopEntry.client, "the loopback peer is always this Mac — leave it blank")
        XCTAssertFalse(generalRows(loopEntry).contains { $0.name == "Client" })
    }

    // MARK: - One message per shared connection

    /// Oracle evidence: two authenticated GETs written back-to-back used to send
    /// the second one — credentials and all — to the origin, because only the
    /// first head was authenticated and then everything after it was piped
    /// through. The shared listener now forwards exactly one framed message.
    func testAPipelinedSecondRequestNeverReachesTheOrigin() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "GET http://127.0.0.1:\(origin.port)/first HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n\r\n"
            + "GET http://127.0.0.1:\(origin.port)/second HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n\r\n")

        let response = readAll(client, timeout: 5)
        XCTAssertTrue(response.contains("200"), "the first request must be served, got: \(response)")

        let seen = originText(origin)
        XCTAssertTrue(seen.contains("GET /first "), "the origin must see the first request, got: \(seen)")
        XCTAssertFalse(seen.contains("/second"), "a pipelined second request must never be forwarded: \(seen)")
        XCTAssertEqual(occurrences(of: "GET ", in: seen), 1, "exactly one request may reach the origin: \(seen)")
        XCTAssertFalse(seen.lowercased().contains("proxy-authorization"), "credentials leaked: \(seen)")
    }

    /// Same rule, but the second request is written *after* the first response.
    /// The proxy closes the connection once the exchange is over, so the write
    /// may fail — that is the point: there is no second exchange to ride on.
    func testASecondRequestSentLaterNeverReachesTheOrigin() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "GET http://127.0.0.1:\(origin.port)/first HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n\r\n")
        XCTAssertTrue(readAll(client, timeout: 5).contains("200"))

        // The proxy must have closed its side by now: either the write fails or
        // it lands on a socket the proxy is done reading.
        try? send(client, "GET http://127.0.0.1:\(origin.port)/second HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n\r\n")
        Thread.sleep(forTimeInterval: 0.2)

        let seen = originText(origin)
        XCTAssertFalse(seen.contains("/second"), "a later request on the same connection must not be forwarded: \(seen)")
        XCTAssertEqual(occurrences(of: "GET ", in: seen), 1, "got: \(seen)")
    }

    /// A Content-Length body is relayed exactly once, and the request that a
    /// client pipelined behind it is dropped rather than appended to the body.
    func testAContentLengthBodyReachesTheOriginOnceAndNothingFollowsIt() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/upload HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Content-Length: 5\r\n\r\n"
            + "hello"
            + "GET http://127.0.0.1:\(origin.port)/second HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n\r\n")

        XCTAssertTrue(readAll(client, timeout: 5).contains("200"))
        let seen = originText(origin)
        XCTAssertTrue(seen.contains("POST /upload "), "got: \(seen)")
        XCTAssertTrue(seen.lowercased().contains("content-length: 5"), "framing must be forwarded: \(seen)")
        XCTAssertEqual(occurrences(of: "hello", in: seen), 1, "the body must arrive once: \(seen)")
        XCTAssertFalse(seen.contains("/second"), "the pipelined request must be dropped: \(seen)")
        XCTAssertFalse(seen.lowercased().contains("proxy-authorization"), "credentials leaked: \(seen)")
    }

    /// A chunked body is relayed through its terminating chunk and trailers.
    func testAChunkedBodyReachesTheOriginOnceAndNothingFollowsIt() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/chunked HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n6\r\n world\r\n0\r\nX-Trailer: yes\r\n\r\n"
            + "GET http://127.0.0.1:\(origin.port)/second HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n\r\n")

        XCTAssertTrue(readAll(client, timeout: 5).contains("200"))
        let seen = originText(origin)
        XCTAssertTrue(seen.contains("POST /chunked "), "got: \(seen)")
        XCTAssertTrue(seen.contains("5\r\nhello\r\n6\r\n world\r\n0\r\n"), "the chunk stream must be intact: \(seen)")
        XCTAssertTrue(seen.contains("X-Trailer: yes"), "trailers belong to the message: \(seen)")
        XCTAssertFalse(seen.contains("/second"), "the pipelined request must be dropped: \(seen)")
        XCTAssertFalse(seen.lowercased().contains("proxy-authorization"), "credentials leaked: \(seen)")
    }

    /// Ambiguous framing (both `Content-Length` and chunked) cannot be framed
    /// safely, so the shared listener fails the request closed and never
    /// contacts the origin.
    func testAmbiguousRequestFramingFailsClosed() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/smuggle HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Content-Length: 5\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "0\r\n\r\n")

        let response = readAll(client, timeout: 5)
        XCTAssertTrue(response.contains("502"), "ambiguous framing must fail closed, got: \(response)")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(origin.receivedRequests.isEmpty, "the origin must not be contacted: \(origin.receivedRequests)")
    }

    // MARK: - Stop fences pending work

    /// Oracle evidence: a CONNECT head left incomplete, then `stopSharing()`, then
    /// the terminator — the old code answered `200 Connection established` and
    /// relayed data. Admission is now fenced before the head can complete.
    func testStopSharingRefusesARequestThatCompletesAfterTheStop() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, allowed: ["127.0.0.1"])

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        // Head without its terminating CRLF: accepted, parked in readRequestHead.
        try send(client, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\nHost: 127.0.0.1:\(echo.port)\r\n")
        XCTAssertTrue(
            waitUntil { engine.sharedPendingConnectionCount == 1 },
            "the connection must be accepted (and therefore fenced) before the stop"
        )

        engine.stopSharing()

        // stop() shuts the pending socket down; completing the head must not
        // produce a tunnel (and must not even produce a reply).
        try? send(client, "\r\n")
        let afterStop = readAll(client, timeout: 2)
        XCTAssertFalse(afterStop.contains("200"), "no tunnel may open after the stop: \(afterStop)")

        // Data must not flow even if the client keeps talking.
        try? send(client, "ping")
        let echoed = readAll(client, timeout: 1)
        XCTAssertFalse(echoed.contains("ping"), "no data may be relayed after the stop: \(echoed)")

        XCTAssertEqual(engine.relayRegistry.activeCount, 0, "a stopped listener must not register a relay")
        XCTAssertTrue(engine.requestLog.snapshot().isEmpty, "nothing may be logged for a refused connection")
    }

    /// Oracle evidence: the relay's completion hook captured the server weakly,
    /// so releasing the server (stopSharing) skipped the registry release and the
    /// request-log finish — `activeCount` stayed 1 and the row never ended.
    func testRelayCleanupSurvivesTheSharedServerBeingReleased() throws {
        let echo = FakeEchoServer()!
        defer { echo.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, allowed: ["127.0.0.1"])

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\n\r\n")
        XCTAssertTrue(String(bytes: try readSome(client, minBytes: 1), encoding: .utf8)?.contains("200") == true)
        try send(client, "hi")
        XCTAssertEqual(try readSome(client, minBytes: 2), Array("hi".utf8))
        XCTAssertEqual(engine.relayRegistry.activeCount, 1)

        engine.stopSharing()

        XCTAssertTrue(
            waitUntil { engine.relayRegistry.activeCount == 0 },
            "the completion hook must release the registry even with the server gone"
        )
        let entry = try XCTUnwrap(engine.requestLog.snapshot().first { $0.transport == .http && $0.port == echo.port })
        XCTAssertNotNil(entry.endedAt, "the request row must be finished, not left in flight")
        XCTAssertNotNil(entry.error, "a torn-down relay finished with an error")
    }

    // MARK: - SRC-IP

    /// The shared listener hands the accepted peer address to the matcher, so
    /// `SRC-IP` rules can target the device. The loopback listener passes nil and
    /// stays unaffected.
    func testSourceIPRulesApplyToTheSharedListenerOnly() throws {
        let origin = RecordingHTTPOrigin()
        defer { origin.stop() }
        let (engine, httpPort) = try makeEngine(rules: [
            ProfileRule(type: .srcIP, value: "127.0.0.1/32", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ])
        let sharePort = try startShare(engine, allowed: ["127.0.0.1"])

        let shared = try get(sharePort, originPort: origin.port, path: "/from-phone")
        XCTAssertTrue(shared.contains("403"), "SRC-IP must reject the shared client, got: \(shared)")
        XCTAssertTrue(origin.receivedRequests.isEmpty, "a rejected request must not reach the origin")

        let loopback = try get(httpPort, originPort: origin.port, path: "/from-mac")
        XCTAssertTrue(loopback.contains("200"), "the loopback listener has no source IP, got: \(loopback)")
        XCTAssertTrue(originText(origin).contains("GET /from-mac "))
    }

    // MARK: - Stop / rebind under load

    /// Repeated stop-and-rebind on the same port while connections are open (and
    /// some are left mid-head) must never wedge the listener or leak a relay.
    func testRepeatedStopAndRebindOnTheSamePort() throws {
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let port = try freePort()

        // Every descriptor in `clients` is closed exactly once: the loop empties
        // the array after its own close, so the scope guard below has nothing
        // left to close (closing a number twice can hit a recycled fd).
        var clients: [Int32] = []
        defer {
            for client in clients { TCPClient.closeSocket(client) }
            clients.removeAll()
        }

        for iteration in 0..<8 {
            try engine.startSharing(ShareConfiguration(
                host: "127.0.0.1", port: port,
                username: "phone", password: "secret", allowedClients: ["127.0.0.1"]
            ))
            XCTAssertEqual(engine.sharingAddress?.port, port, "iteration \(iteration)")

            for _ in 0..<2 { clients.append(try connect(host: "127.0.0.1", port: port)) }
            // One complete request (which will race the stop) and one half-head.
            try? send(clients[0], "GET http://127.0.0.1:\(port)/x HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            try? send(clients[1], "CONNECT 127.0.0.1:1 HTTP/1.1\r\n")

            engine.stopSharing()
            XCTAssertNil(engine.sharingAddress, "iteration \(iteration)")
            for client in clients { TCPClient.closeSocket(client) }
            clients.removeAll()
            XCTAssertThrowsError(
                try TCPClient.connect(host: "127.0.0.1", port: port, timeoutSeconds: 1),
                "iteration \(iteration): the listener must be gone"
            )
        }
        XCTAssertTrue(waitUntil { engine.relayRegistry.activeCount == 0 })
    }

    // MARK: - Request body framing (one message, relayed exactly once)

    /// A Content-Length body that arrives in two TCP segments: the budget path
    /// used to call back into `clientToOutbound` while `read` held it as `inout`,
    /// which is a Swift exclusivity trap on the relay queue.
    func testFragmentedContentLengthBodyIsRelayedWithoutCrash() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/frag HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Content-Length: 5\r\n\r\n"
            + "he")
        Thread.sleep(forTimeInterval: 0.2)
        try send(client, "llo")

        XCTAssertTrue(readAll(client, timeout: 5).contains("200"))
        let seen = originText(origin)
        XCTAssertEqual(origin.requests.count, 1, "one request, got: \(origin.requests)")
        XCTAssertTrue(seen.contains("POST /frag "), "got: \(seen)")
        XCTAssertTrue(seen.hasSuffix("hello"), "the whole body must arrive, in order: \(seen)")
    }

    /// A response that arrives faster than the client reads it used to be closed
    /// the moment both EOFs were seen — while the tail was still in the relay's
    /// buffer — and the client got a truncated body.
    func testLargeResponseUnderBackpressureIsNotTruncated() throws {
        let bodyByteCount = 16 << 20 // past every kernel socket buffer, so the relay really backs up
        let origin = StreamingOrigin(bodyByteCount: bodyByteCount)
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        // A small receive buffer plus a deliberate stall makes the relay's
        // outbound→client buffer back up, which is where the tail was lost.
        var receiveBuffer = Int32(16 * 1024)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))

        try send(client, "GET http://127.0.0.1:\(origin.port)/big HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n\r\n")
        // Stall first, then read slowly: the relay's outbound→client buffer stays
        // backed up right through the origin's EOF, which is where the tail used
        // to be dropped on close.
        Thread.sleep(forTimeInterval: 0.5)

        let response = readSlowly(client, timeout: 90, chunkSize: 16 * 1024, delay: 0.002)
        let headEnd = try XCTUnwrap(findHeadEnd(response), "no response head was received")
        let head = String(bytes: response[..<headEnd], encoding: .utf8) ?? ""
        XCTAssertTrue(head.contains("200"), "got: \(head)")
        let body = response.count - (headEnd + 4)
        XCTAssertEqual(body, bodyByteCount, "the whole response body must arrive")
    }

    /// A chunk size of `Int.max`-ish magnitude must be rejected before it reaches
    /// any arithmetic that could wrap. It is over the cap, so it is refused as
    /// too-large rather than "malformed" — either way: no crash, no origin.
    func testChunkSizeThatWouldOverflowFailsClosed() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        for (label, sizeLine) in [("saturating", "7FFFFFFFFFFFFFFF"), ("non-hex", "ZZZZ")] {
            let client = try connect(host: "127.0.0.1", port: sharePort)
            defer { TCPClient.closeSocket(client) }
            try send(client, "POST http://127.0.0.1:\(origin.port)/huge HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(origin.port)\r\n"
                + "Proxy-Authorization: \(auth)\r\n"
                + "Transfer-Encoding: chunked\r\n\r\n"
                + "\(sizeLine)\r\n")

            let response = readAll(client, timeout: 5)
            XCTAssertTrue(
                response.contains("413") || response.contains("502"),
                "\(label): an unframeable chunk must fail closed, got: \(response)"
            )
            XCTAssertFalse(response.contains("200"), "\(label): got: \(response)")
        }
        XCTAssertTrue(origin.requests.isEmpty, "the origin must not be contacted: \(origin.requests)")
    }

    /// Chunk data not followed by CRLF is a framing error, not "wait for more".
    func testChunkDataWithoutTrailingCRLFailsClosed() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/badcrlf HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhelloXX\r\n0\r\n\r\n")

        let response = readAll(client, timeout: 5)
        XCTAssertTrue(response.contains("502"), "malformed chunk framing must fail closed, got: \(response)")
        XCTAssertTrue(origin.requests.isEmpty, "the origin must not be contacted: \(origin.requests)")
    }

    /// A declared chunk larger than the body cap is refused immediately (413)
    /// without buffering it or contacting the origin.
    func testOversizedChunkedBodyIsRejected() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/bigchunk HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "900000\r\n")

        let response = readAll(client, timeout: 5)
        XCTAssertTrue(response.contains("413"), "an oversized chunk must be refused, got: \(response)")
        XCTAssertTrue(origin.requests.isEmpty, "the origin must not be contacted: \(origin.requests)")
    }

    /// Framing rejection must retire the request-log row it already appended.
    func testFramingRejectionFinishesItsRequestLogEntry() throws {
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:9/ambiguous HTTP/1.1\r\n"
            + "Host: 127.0.0.1:9\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Content-Length: 1\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n")
        XCTAssertTrue(readAll(client, timeout: 5).contains("502"))

        let entry = try XCTUnwrap(engine.requestLog.snapshot().first)
        XCTAssertNotNil(entry.endedAt, "a rejected request must not stay in flight")
        XCTAssertNotNil(entry.error)
    }

    /// Every malformed `Content-Length` / `Transfer-Encoding` shape is refused
    /// before the origin is contacted, and its request-log row is retired.
    ///
    /// These are exactly the values a permissive parse would "repair": Swift's
    /// `Int(_:)` accepts `+5`, `split` silently drops empty members (`5,`, `,5`,
    /// an empty field), and a coding list could keep `gzip, chunked` because
    /// `chunked` happens to be last.
    func testMalformedFramingValuesFailClosedBeforeTheOrigin() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let chunkTerminator = "0\r\n\r\n"
        let cases: [(label: String, headerLines: [String], body: String)] = [
            ("cl plus sign", ["Content-Length: +5"], "hello"),
            ("cl negative", ["Content-Length: -1"], ""),
            ("cl empty field", ["Content-Length:"], ""),
            ("cl trailing comma", ["Content-Length: 5,"], "hello"),
            ("cl leading comma", ["Content-Length: ,5"], "hello"),
            ("cl whitespace inside", ["Content-Length: 5 5"], ""),
            ("cl duplicate disagree", ["Content-Length: 5", "Content-Length: 6"], "hello"),
            ("cl overflow", ["Content-Length: 99999999999999999999"], ""),
            ("te empty field", ["Transfer-Encoding:"], ""),
            ("te leading comma", ["Transfer-Encoding: ,chunked"], chunkTerminator),
            ("te trailing comma", ["Transfer-Encoding: chunked,"], chunkTerminator),
            ("te duplicate chunked one field", ["Transfer-Encoding: chunked, chunked"], chunkTerminator),
            ("te duplicate chunked two fields", ["Transfer-Encoding: chunked", "Transfer-Encoding: chunked"], chunkTerminator),
            ("te with another coding", ["Transfer-Encoding: gzip, chunked"], chunkTerminator),
            ("te parameter", ["Transfer-Encoding: chunked;foo=bar"], chunkTerminator),
            ("te unknown coding", ["Transfer-Encoding: gzip"], ""),
            ("te with content length", ["Transfer-Encoding: chunked", "Content-Length: 0"], chunkTerminator),
        ]

        for testCase in cases {
            let client = try connect(host: "127.0.0.1", port: sharePort)
            defer { TCPClient.closeSocket(client) }
            try send(client, "POST http://127.0.0.1:\(origin.port)/bad HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(origin.port)\r\n"
                + "Proxy-Authorization: \(auth)\r\n"
                + testCase.headerLines.map { $0 + "\r\n" }.joined()
                + "\r\n"
                + testCase.body)

            let response = readAll(client, timeout: 5)
            XCTAssertTrue(
                response.hasPrefix("HTTP/1.1 502"),
                "\(testCase.label): must fail closed, got: \(response)"
            )
        }

        XCTAssertTrue(origin.requests.isEmpty, "no malformed message may reach the origin: \(origin.requests)")
        let entries = engine.requestLog.snapshot()
        XCTAssertEqual(entries.count, cases.count, "one log row per refused request")
        XCTAssertTrue(entries.allSatisfy { $0.endedAt != nil }, "every refused request must be retired")
        XCTAssertTrue(entries.allSatisfy { $0.error != nil }, "every refused request must record why")
    }

    /// The RFC-compatible shapes stay accepted: duplicate `Content-Length`
    /// fields that agree, and exactly `Transfer-Encoding: chunked`.
    func testEquivalentFramingValuesAreStillAccepted() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        // Two identical Content-Length fields, one of them a one-member list.
        let contentLengthClient = try connect(host: "127.0.0.1", port: sharePort)
        try send(contentLengthClient, "POST http://127.0.0.1:\(origin.port)/agree HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Content-Length: 5\r\n"
            + "Content-Length: 5\r\n\r\n"
            + "hello")
        XCTAssertTrue(readAll(contentLengthClient, timeout: 5).contains("200"))
        TCPClient.closeSocket(contentLengthClient)

        let first = try XCTUnwrap(origin.requests.first)
        XCTAssertTrue(first.contains("POST /agree "), "got: \(first)")
        XCTAssertTrue(first.hasSuffix("\r\n\r\nhello"), "the body must be forwarded once: \(first)")

        // Exactly `chunked`, with the OWS a header value may carry.
        let chunkedClient = try connect(host: "127.0.0.1", port: sharePort)
        try send(chunkedClient, "POST http://127.0.0.1:\(origin.port)/chunked HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n0\r\n\r\n")
        XCTAssertTrue(readAll(chunkedClient, timeout: 5).contains("200"))
        TCPClient.closeSocket(chunkedClient)

        XCTAssertEqual(origin.requests.count, 2, "got: \(origin.requests)")
        let second = try XCTUnwrap(origin.requests.last)
        XCTAssertTrue(second.contains("POST /chunked "), "got: \(second)")
        XCTAssertTrue(second.hasSuffix("5\r\nhello\r\n0\r\n\r\n"), "got: \(second)")
    }

    // MARK: - Expect: 100-continue

    /// A client that waits for `100 Continue` must not deadlock against the
    /// proxy's own body read.
    func testExpectContinueIsAnsweredBeforeAChunkedBody() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/continue HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Expect: 100-continue\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n")

        // The interim response must arrive without the body having been sent.
        let interim = String(bytes: try readSome(client, minBytes: 25), encoding: .utf8) ?? ""
        XCTAssertTrue(interim.contains("100 Continue"), "the client is waiting for 100, got: \(interim)")

        try send(client, "5\r\nhello\r\n0\r\n\r\n")
        XCTAssertTrue(readAll(client, timeout: 5).contains("200"))

        let seen = originText(origin)
        XCTAssertEqual(origin.requests.count, 1, "got: \(origin.requests)")
        XCTAssertTrue(seen.contains("POST /continue "), "got: \(seen)")
        XCTAssertTrue(seen.contains("5\r\nhello\r\n0\r\n\r\n"), "the chunk stream must reach the origin: \(seen)")
        XCTAssertEqual(occurrences(of: "POST ", in: seen), 1, "got: \(seen)")
        XCTAssertFalse(seen.lowercased().contains("proxy-authorization"), "credentials leaked: \(seen)")
        XCTAssertFalse(seen.lowercased().contains("expect:"), "the answered expectation must not be forwarded: \(seen)")
        XCTAssertFalse(seen.contains("100 Continue"), "no second interim response may be forwarded: \(seen)")
    }

    // MARK: - Stop wakes a body read

    /// A chunked body read parks the io thread; `stopSharing()` must wake it
    /// immediately (the descriptor stays in the pending set for exactly this)
    /// instead of letting it sit out its own 15 s deadline.
    func testStopSharingWakesAChunkBodyReaderImmediately() throws {
        let origin = FramedOrigin()
        defer { origin.stop() }
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let auth = basic("phone", "secret")

        let client = try connect(host: "127.0.0.1", port: sharePort)
        defer { TCPClient.closeSocket(client) }
        try send(client, "POST http://127.0.0.1:\(origin.port)/stalled HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(origin.port)\r\n"
            + "Proxy-Authorization: \(auth)\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhe")

        // Wait until the request has been routed (the log row is appended just
        // before the body is read), then check that the descriptor is still
        // owned by the pending set: that is what gives `stop()` something to
        // wake while the body read is parked.
        XCTAssertTrue(
            waitUntil { !engine.requestLog.snapshot().isEmpty },
            "the request must be routed before the body stalls"
        )
        XCTAssertEqual(
            engine.sharedPendingConnectionCount, 1,
            "the descriptor must stay pending while its body is read"
        )

        let started = Date()
        engine.stopSharing()
        let after = readAll(client, timeout: 3)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 2.5, "stop must wake the body read, not wait out its deadline")
        XCTAssertFalse(after.contains("200"), "no tunnel or forward may start: \(after)")
        XCTAssertTrue(origin.requests.isEmpty, "the origin must not be contacted: \(origin.requests)")
        XCTAssertEqual(engine.sharedPendingConnectionCount, 0)
        XCTAssertEqual(engine.relayRegistry.activeCount, 0)
    }

    // MARK: - PAC file

    private func pacToken(_ password: String) -> String {
        SharePACGenerator.token(password: password)
    }

    private func rawResponse(_ port: Int, _ request: String) throws -> String {
        let client = try connect(host: "127.0.0.1", port: port)
        defer { TCPClient.closeSocket(client) }
        try send(client, request)
        return readAll(client, timeout: 5)
    }

    private func responseBody(_ response: String) -> String {
        guard let range = response.range(of: "\r\n\r\n") else { return "" }
        return String(response[range.upperBound...])
    }

    private func header(_ name: String, in response: String) -> String? {
        let head = response.components(separatedBy: "\r\n\r\n").first ?? response
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// A phone's PAC fetch carries no proxy credentials. The token path is what
    /// authorises it, and it is served before the 407 gate.
    func testSharedListenerServesThePACWithoutCredentials() throws {
        let (engine, _) = try makeEngine(rules: [
            ProfileRule(type: .domainSuffix, value: "example.com", policy: "DIRECT"),
        ])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let token = pacToken("secret")

        let response = try rawResponse(
            sharePort,
            "GET /\(token)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\nConnection: close\r\n\r\n"
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), "got: \(response)")
        XCTAssertEqual(header("Content-Type", in: response), "application/x-ns-proxy-autoconfig")
        XCTAssertEqual(header("Cache-Control", in: response), "no-store")
        XCTAssertEqual(header("Connection", in: response), "close")

        let body = responseBody(response)
        XCTAssertTrue(body.contains("function FindProxyForURL(url, host)"), body)
        XCTAssertTrue(body.contains("\"PROXY \" + \"127.0.0.1\" + \":\(sharePort)\""), body)
        XCTAssertEqual(header("Content-Length", in: response), String(body.utf8.count))
        XCTAssertTrue(engine.refusedClients.isEmpty, "a PAC fetch is not a refused client")
    }

    func testSharedListenerAnswersHEADForThePACWithoutABody() throws {
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, pass: "secret")
        let token = pacToken("secret")

        let response = try rawResponse(
            sharePort,
            "HEAD /\(token)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\nConnection: close\r\n\r\n"
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), "got: \(response)")
        XCTAssertEqual(header("Content-Type", in: response), "application/x-ns-proxy-autoconfig")
        XCTAssertEqual(responseBody(response), "", "HEAD must not carry the PAC body")
        let length = try XCTUnwrap(Int(try XCTUnwrap(header("Content-Length", in: response))))
        XCTAssertGreaterThan(length, 0, "Content-Length describes the GET body")
    }

    /// The token is the only thing standing between the LAN and the PAC; a wrong
    /// one is an ordinary unauthenticated proxy request and gets 407.
    func testPACWithAWrongTokenIsRefused() throws {
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")

        let response = try rawResponse(
            sharePort,
            "GET /\(String(repeating: "0", count: 24))/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"
        )

        XCTAssertTrue(response.contains("407"), "got: \(response)")
        XCTAssertEqual(waitForRefusal(engine, attempts: 1)?.address, "127.0.0.1")
    }

    /// Only the shared listener serves a PAC; the loopback listener stays a
    /// proxy, so an origin-form request there is still a 400.
    func testLoopbackListenerDoesNotServeThePAC() throws {
        let (engine, httpPort) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let token = pacToken("secret")

        let response = try rawResponse(
            httpPort,
            "GET /\(token)/proxy.pac HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )

        XCTAssertTrue(response.contains("400"), "got: \(response)")
        XCTAssertFalse(response.contains("FindProxyForURL"))
    }

    /// Rotating the password rotates the URL on the same listener, and the VPN
    /// targets hot-swap with it.
    func testPACFollowsUpdateShareAccess() throws {
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "oldpass")
        let oldToken = pacToken("oldpass")

        let old = try rawResponse(
            sharePort,
            "GET /\(oldToken)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"
        )
        XCTAssertTrue(old.contains("200"), "got: \(old)")

        engine.updateShareAccess(
            username: "phone",
            password: "newpass",
            allowedClients: [],
            tunnelMode: .split(targets: ["vpn.corp.example.com", "10.20.0.0/16"])
        )

        let stale = try rawResponse(
            sharePort,
            "GET /\(oldToken)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"
        )
        XCTAssertTrue(stale.contains("407"), "the old token must stop working, got: \(stale)")

        let newToken = pacToken("newpass")
        let fresh = try rawResponse(
            sharePort,
            "GET /\(newToken)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"
        )
        XCTAssertTrue(fresh.contains("200"), "got: \(fresh)")
        let body = responseBody(fresh)
        XCTAssertTrue(body.contains("vpn.corp.example.com"), body)
        XCTAssertTrue(body.contains("var VNET = [[169082880,16]];"), body)
    }

    /// The document is rebuilt on every fetch, so a profile reload is visible
    /// without restarting the listener.
    func testPACIsRegeneratedFromTheCurrentProfile() throws {
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, pass: "secret")
        let token = pacToken("secret")
        let request = "GET /\(token)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"

        let before = responseBody(try rawResponse(sharePort, request))
        XCTAssertFalse(before.contains("new.example.com"))

        var updated = Profile(name: "pac-live")
        updated.rules = [
            ProfileRule(type: .domain, value: "new.example.com", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        engine.reload(profile: updated)

        let after = responseBody(try rawResponse(sharePort, request))
        XCTAssertTrue(after.contains("new.example.com"), after)
    }

    /// A rule the PAC cannot evaluate must stop the scan instead of being
    /// silently skipped: the Mac may reject or proxy what follows it.
    func testPACFailsOpenForAnUnsupportedRule() throws {
        let (engine, _) = try makeEngine(rules: [
            ProfileRule(type: .destPort, value: "443", policy: "REJECT"),
            ProfileRule(type: .domain, value: "later.example.com", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ])
        let sharePort = try startShare(engine, pass: "secret")
        let token = pacToken("secret")

        let body = responseBody(try rawResponse(
            sharePort,
            "GET /\(token)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"
        ))
        XCTAssertTrue(body.contains("[\"b\",\"\",0,1]"), body)
        XCTAssertTrue(body.contains("later.example.com"), body)
    }

    /// Building the PAC must not consume a load-balance round-robin slot: the
    /// phone's fetch is not a routed request.
    func testPACGenerationDoesNotAdvanceLoadBalanceCounters() throws {
        let first = ProxyDefinition(name: "first-upstream", type: .http, host: "10.0.0.1", port: 8080)
        let second = ProxyDefinition(name: "second-upstream", type: .http, host: "10.0.0.2", port: 8080)
        let group = ProxyGroup(name: "spread", type: .loadBalance, policies: [first.name, second.name])
        let (engine, _) = try makeEngine(
            rules: [
                ProfileRule(type: .domain, value: "example.com", policy: group.name),
                ProfileRule(type: .final, value: "", policy: "DIRECT"),
            ],
            proxies: [first, second],
            groups: [group]
        )
        let sharePort = try startShare(engine, pass: "secret")
        let token = pacToken("secret")

        XCTAssertTrue(try rawResponse(
            sharePort,
            "GET /\(token)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"
        ).contains("200"))

        XCTAssertEqual(try engine.policyStore.resolve(group.name), .proxy(first))
        XCTAssertEqual(try engine.policyStore.resolve(group.name), .proxy(second),
                       "the counter must start where it would have without the PAC fetch")
    }

    /// The token authorises the PAC fetch; it must not end up in the request
    /// log, whichever request form a client uses.
    func testPACFetchIsServedButNeverLogged() throws {
        let (engine, _) = try makeEngine(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let sharePort = try startShare(engine, user: "phone", pass: "secret")
        let token = pacToken("secret")

        let originForm = try rawResponse(
            sharePort,
            "GET /\(token)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n"
        )
        XCTAssertTrue(originForm.contains("200"), originForm)

        let absoluteForm = try rawResponse(
            sharePort,
            "GET http://192.168.1.20:\(sharePort)/\(token)/proxy.pac HTTP/1.1\r\n"
                + "Host: 192.168.1.20:\(sharePort)\r\n"
                + "Proxy-Authorization: \(basic("phone", "secret"))\r\n\r\n"
        )
        XCTAssertTrue(absoluteForm.contains("200"), absoluteForm)

        let post = try rawResponse(
            sharePort,
            "POST /\(token)/proxy.pac HTTP/1.1\r\nHost: 192.168.1.20\r\nContent-Length: 0\r\n\r\n"
        )
        XCTAssertTrue(post.contains("400"), post)

        XCTAssertTrue(engine.requestLog.snapshot().isEmpty,
                      "a PAC fetch is not a proxied request: \(engine.requestLog.snapshot())")
    }

    // MARK: - Helpers

    private func generalRows(_ entry: RequestEntry) -> [RequestFormat.DetailSection.Row] {
        RequestFormat.detailSections(entry).first { $0.id == "general" }?.rows ?? []
    }

    private func waitForRefusal(_ engine: ProxyEngine, attempts: Int, timeout: TimeInterval = 5) -> RefusedClient? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = engine.refusedClients.first, first.attempts == attempts { return first }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return engine.refusedClients.first
    }

    private func waitForEntry(_ engine: ProxyEngine, _ predicate: (RequestEntry) -> Bool, timeout: TimeInterval = 5) -> RequestEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = engine.requestLog.snapshot().first(where: predicate) { return match }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    private func waitForEOF(_ fd: Int32, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard TCPClient.waitForReadable(fd: fd, timeoutSeconds: max(deadline.timeIntervalSinceNow, 0.05)) else {
                continue
            }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 1024, 0) }
            if n == 0 { return true }
            if n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return true }
        }
        return false
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// Reads until the peer closes (or the timeout), returning the text.
    private func readAll(_ fd: Int32, timeout: TimeInterval) -> String {
        String(bytes: readUntilEOF(fd, timeout: timeout), encoding: .utf8) ?? ""
    }

    /// Reads until EOF or the deadline, returning every byte received.
    private func readUntilEOF(_ fd: Int32, timeout: TimeInterval) -> [UInt8] {
        readSlowly(fd, timeout: timeout, chunkSize: 65536, delay: 0)
    }

    /// Reads at a deliberately throttled pace, so a proxy that is still holding
    /// response bytes internally cannot finish quietly behind the client's back.
    private func readSlowly(
        _ fd: Int32, timeout: TimeInterval, chunkSize: Int, delay: TimeInterval
    ) -> [UInt8] {
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let slice = max(min(deadline.timeIntervalSinceNow, 0.2), 0.01)
            guard TCPClient.waitForReadable(fd: fd, timeoutSeconds: slice) else { continue }
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, chunkSize, 0) }
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            } else if n == 0 {
                break
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }
        }
        return out
    }

    /// Index of the `\r\n\r\n` that ends a response head.
    private func findHeadEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    /// Everything a harness origin recorded as one string (reads may split, so
    /// tests assert on the concatenation rather than per-read entries).
    private func originText(_ origin: RecordingHTTPOrigin) -> String {
        origin.receivedRequests.joined()
    }

    private func originText(_ origin: FramedOrigin) -> String {
        origin.requests.joined()
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }

    private func freePort() throws -> Int {        let (fd, port) = TestSockets.listenOnEphemeralLoopback()
        TestSockets.closeFD(fd)
        return port
    }

    private func connect(host: String, port: Int) throws -> Int32 {
        try TCPClient.connect(host: host, port: port, timeoutSeconds: 5)
    }

    private func send(_ fd: Int32, _ string: String) throws {
        try TCPClient.sendAll(fd: fd, Array(string.utf8), timeoutSeconds: 5)
    }

    private func readSome(_ fd: Int32, minBytes: Int) throws -> [UInt8] {        var out: [UInt8] = []
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
}

/// Thread-safe collector for `onRefusedClient` notifications.
final class AddressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _addresses: [String] = []
    var addresses: [String] { lock.withLock { _addresses } }
    func record(_ address: String) { lock.withLock { _addresses.append(address) } }
}

// MARK: - Harness origins

/// HTTP origin that records the bytes of one *complete* request before replying,
/// so assertions see a body that arrived in several TCP segments.
final class FramedOrigin: @unchecked Sendable {
    let loop = TestListenerLoop()
    var port: Int { loop.port }
    private let queue = DispatchQueue(label: "framed-origin")
    private let lock = NSLock()
    private var _requests: [String] = []
    var requests: [String] { lock.withLock { _requests } }
    private let responseBody: String

    init(responseBody: String = "ok") {
        self.responseBody = responseBody
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client)
            loop.release(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { TestSockets.closeFD(client) }
        var buffer: [UInt8] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !Self.requestIsComplete(buffer) {
            guard TestSockets.waitForReadable(fd: client, timeoutSeconds: 0.1) else { continue }
            guard let more = TestSockets.readSome(fd: client), !more.isEmpty else { break }
            buffer.append(contentsOf: more)
        }
        lock.withLock { _requests.append(String(bytes: buffer, encoding: .utf8) ?? "") }
        let response = "HTTP/1.1 200 OK\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
        _ = TestSockets.sendAll(fd: client, Array(response.utf8))
    }

    /// Head, then exactly the framed body (Content-Length or a terminated chunk
    /// stream, or nothing for a bodyless request).
    private static func requestIsComplete(_ bytes: [UInt8]) -> Bool {
        guard let range = OutboundConnector.headTerminatorRange(bytes) else { return false }
        let head = Array(bytes[..<range.lowerBound])
        let body = Array(bytes[range.upperBound...])
        guard let text = String(bytes: head, encoding: .utf8) else { return false }
        var contentLength: Int?
        var chunked = false
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { contentLength = Int(value) }
            if name == "transfer-encoding", value.lowercased().contains("chunked") { chunked = true }
        }
        if chunked {
            if case .complete = HTTPRequestRouter.parseChunkedBody(body, maxBody: 64 * 1024 * 1024) {
                return true
            }
            return false
        }
        guard let length = contentLength else { return true }
        return body.count >= length
    }

    func stop() { loop.stop() }
}

/// HTTP origin that answers with a large fixed-size body, written in chunks.
/// Used to back up the relay's outbound→client direction.
final class StreamingOrigin: @unchecked Sendable {
    let loop = TestListenerLoop()
    var port: Int { loop.port }
    private let queue = DispatchQueue(label: "streaming-origin")
    private let bodyByteCount: Int
    private let lock = NSLock()
    private var _received: [String] = []
    var received: [String] { lock.withLock { _received } }

    init(bodyByteCount: Int) {
        self.bodyByteCount = bodyByteCount
        queue.async { [weak self] in self?.serve() }
    }

    private func serve() {
        loop.noteLoopStarted()
        defer { loop.noteLoopFinished() }
        while let client = loop.acceptOne() {
            handle(client)
            loop.release(client)
        }
    }

    private func handle(_ client: Int32) {
        defer { TestSockets.closeFD(client) }
        guard let data = TestSockets.readSome(fd: client), !data.isEmpty else { return }
        lock.withLock { _received.append(String(bytes: data, encoding: .utf8) ?? "") }
        let head = "HTTP/1.1 200 OK\r\nContent-Length: \(bodyByteCount)\r\nConnection: close\r\n\r\n"
        guard TestSockets.sendAll(fd: client, Array(head.utf8)) else { return }
        let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 16 * 1024)
        var sent = 0
        while sent < bodyByteCount {
            let size = min(chunk.count, bodyByteCount - sent)
            guard TestSockets.sendAll(fd: client, Array(chunk[0..<size])) else { return }
            sent += size
        }
    }

    func stop() { loop.stop() }
}
