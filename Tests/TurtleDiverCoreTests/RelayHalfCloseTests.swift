import XCTest
import Darwin
@testable import TurtleDiverCore
@testable import TurtleDiverRules
@testable import TurtleDiverEngine

/// Regression tests for the relay's EOF path.
///
/// A socket that has reached EOF is *permanently* readable, so a
/// `DispatchSourceRead` left armed on it re-fires immediately, forever: the
/// handler re-reads, gets 0, and is requeued. Measured live, that was ~94% of
/// one core spent inside `sawEOF` on `com.turtlediver.engine.relay`, one
/// `read` per iteration, for as long as the *other* direction stayed open —
/// e.g. a browser that keeps its connection to the proxy alive after an origin
/// sent `Connection: close`.
///
/// Each test here drives a real connection through a real `RelayConnection`
/// (real socketpair for the client leg, a real loopback origin for the
/// outbound leg), half-closes exactly one direction, and then measures this
/// process's own CPU time while the connection sits idle. They also pin the
/// semantics the fix must not break: an EOF is a *half*-close, so the
/// direction that is still open must still carry bytes in the direction the
/// peer did not close, and the relay is finished only when both sides are.
final class RelayHalfCloseTests: XCTestCase {

    /// Wall-clock window for the CPU measurement. The defect burns ~100% of a
    /// core, so a short window separates it from noise with a wide margin.
    private static let window: TimeInterval = 0.4
    /// Fraction of a core the relay may burn while idle at EOF. Idle is ~0;
    /// the defect is ~1.0.
    private static let allowedCPUFraction = 0.3

    // MARK: - Harness

    /// CPU time charged to this process (all threads), in seconds.
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Fails when the process burned a core while the relay was idle.
    private func assertRelayIsNotSpinning(
        _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let before = cpuSeconds()
        Thread.sleep(forTimeInterval: Self.window)
        let burned = cpuSeconds() - before
        let percent = Int((burned / Self.window * 100).rounded())
        XCTAssertLessThan(
            burned, Self.window * Self.allowedCPUFraction,
            "\(label): this process burned \(percent)% of a core while the relay was idle at EOF — "
                + "a read source is still armed on a socket that will never become readable again",
            file: file, line: line
        )
    }

    /// Closes a descriptor at most once. Tests both close explicitly (to drive
    /// the relay's second EOF) and clean up in `defer`; a second `close` could
    /// close a descriptor the kernel has already recycled.
    private final class CloseOnce {
        private var fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        var descriptor: Int32 { fd }
        func close() {
            guard fd >= 0 else { return }
            TestSockets.closeFD(fd)
            fd = -1
        }
    }

    /// Starts a relay against a fresh loopback origin.
    ///
    /// The client leg is a socketpair standing in for the accepted client
    /// socket: the relay only reads, sends, shuts down and closes it, all of
    /// which a socketpair supports. The relay owns `relayEnd` and closes it
    /// exactly once in `finish`, so the test must not close it too.
    private func startRelay(
        queueLabel: String
    ) -> (
        relay: RelayConnection, client: CloseOnce, origin: CloseOnce, listener: CloseOnce,
        connectError: (Error?)
    )? {
        let listening = TestSockets.listenOnEphemeralLoopback()
        let listener = CloseOnce(listening.fd)

        var fds = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            listener.close()
            XCTFail("socketpair failed: errno \(errno)")
            return nil
        }
        let relayEnd = fds[0]
        let client = CloseOnce(fds[1])
        // The engine puts accepted client sockets in non-blocking mode; the
        // relay's read/write paths assume it.
        TCPClient.setNonBlocking(relayEnd)

        let relay = RelayConnection(clientFD: relayEnd, queue: DispatchQueue(label: queueLabel))
        var connectError: Error?
        let connected = DispatchSemaphore(value: 0)
        relay.start(
            decision: .direct,
            destination: RelayDestination(host: "127.0.0.1", port: listening.port),
            timeoutSeconds: 5
        ) { error in
            connectError = error
            connected.signal()
        }
        guard connected.wait(timeout: .now() + 10) == .success else {
            listener.close()
            client.close()
            XCTFail("the relay never reported its connect outcome")
            return nil
        }
        // The outbound connect is reported on the relay queue; the origin is
        // accepted here on the test thread.
        guard let accepted = TestSockets.acceptWithTimeout(fd: listening.fd, seconds: 5) else {
            listener.close()
            client.close()
            XCTFail("the relay never connected to the test origin")
            return nil
        }
        return (
            relay: relay, client: client, origin: CloseOnce(accepted), listener: listener,
            connectError: connectError
        )
    }

    // MARK: - Descriptor accounting

    /// Open descriptors in this process. A finished relay must hold none: the
    /// HTTP server hands the client fd to the relay and never closes it, and
    /// the outbound fd is the relay's own.
    private func openFileDescriptorCount() -> Int {
        let needed = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return -1 }
        var buffer = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(needed) / MemoryLayout<proc_fdinfo>.stride + 8
        )
        let written = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &buffer, needed)
        guard written > 0 else { return -1 }
        return Int(written) / MemoryLayout<proc_fdinfo>.stride
    }

    /// Runs one relay through a complete lifecycle — connect, then both sides
    /// close — and reports whether it finished. Descriptors are only released
    /// by `finish`.
    private func runOneRelayCycle() -> Bool {
        guard let harness = startRelay(queueLabel: "half-close.fd-count") else { return false }
        defer {
            harness.client.close()
            harness.origin.close()
            harness.listener.close()
        }
        guard harness.connectError == nil else { return false }
        let done = DispatchSemaphore(value: 0)
        harness.relay.onFinished = { _, _ in done.signal() }
        harness.client.close()
        harness.origin.close()
        return done.wait(timeout: .now() + 5) == .success
    }

    // MARK: - Tests

    /// Each finished relay must give both descriptors back. The relay closes
    /// its fds in `finish` rather than in a read source's cancel handler, so
    /// this pins that the close still happens for *both* sides — including the
    /// side whose source was cancelled early at EOF.
    func testAFinishedRelayGivesBothDescriptorsBack() {
        // Warm-up: the first cycles also create the dispatch machinery, so the
        // baseline is taken once the relay path has run.
        for _ in 0..<4 { XCTAssertTrue(runOneRelayCycle()) }
        let baseline = openFileDescriptorCount()
        XCTAssertGreaterThan(baseline, 0, "could not count descriptors")

        let rounds = 24
        for _ in 0..<rounds { XCTAssertTrue(runOneRelayCycle()) }

        let growth = openFileDescriptorCount() - baseline
        XCTAssertLessThan(
            growth, 8,
            "\(rounds) completed relays left \(growth) more descriptors open than before "
                + "(leaking both would be \(rounds * 2))"
        )
    }

    /// An origin that answers and then stops *sending* (`Connection: close`)
    /// while its socket stays open: the relay's outbound read source hits EOF.
    func testAnOriginThatOnlyStopsSendingDoesNotSpinTheRelay() throws {
        guard let harness = startRelay(queueLabel: "half-close.origin-eof") else { return }
        defer {
            harness.client.close()
            harness.origin.close()
            harness.listener.close()
        }
        XCTAssertNil(
            harness.connectError, "relay connect failed: \(String(describing: harness.connectError))"
        )
        let client = harness.client.descriptor
        let origin = harness.origin.descriptor

        XCTAssertTrue(TestSockets.sendAll(fd: origin, Array("answer".utf8)))
        XCTAssertEqual(shutdown(origin, SHUT_WR), 0, "origin shutdown failed: errno \(errno)")
        let answer: [UInt8]? = TestSockets.readSome(fd: client)
        XCTAssertEqual(answer, Array("answer".utf8), "the client did not get the origin's answer")

        assertRelayIsNotSpinning("origin half-close")

        // An EOF is a half-close: the origin only stopped sending, so bytes the
        // client sends must still reach it.
        XCTAssertTrue(TestSockets.sendAll(fd: client, Array("still here".utf8)))
        let echoed: [UInt8]? = TestSockets.readSome(fd: origin)
        XCTAssertEqual(
            echoed, Array("still here".utf8),
            "the relay stopped forwarding the direction the origin never closed"
        )

        // Closing the client is the second EOF: now, and only now, the relay is
        // done (and it owns closing both fds).
        let finished = expectation(description: "relay finished")
        harness.relay.onFinished = { _, _ in finished.fulfill() }
        harness.client.close()
        wait(for: [finished], timeout: 5)
    }

    /// The mirror case: the client stops *sending* while the origin's socket
    /// stays open, so the relay's client read source hits EOF.
    func testAClientThatOnlyStopsSendingDoesNotSpinTheRelay() throws {
        guard let harness = startRelay(queueLabel: "half-close.client-eof") else { return }
        defer {
            harness.client.close()
            harness.origin.close()
            harness.listener.close()
        }
        XCTAssertNil(
            harness.connectError, "relay connect failed: \(String(describing: harness.connectError))"
        )
        let client = harness.client.descriptor
        let origin = harness.origin.descriptor

        XCTAssertTrue(TestSockets.sendAll(fd: client, Array("request".utf8)))
        let request: [UInt8]? = TestSockets.readSome(fd: origin)
        XCTAssertEqual(request, Array("request".utf8), "the origin did not get the request")
        XCTAssertEqual(shutdown(client, SHUT_WR), 0, "client shutdown failed: errno \(errno)")

        assertRelayIsNotSpinning("client half-close")

        // The client only stopped sending: the origin's reply must still reach
        // it, which is only true while the relay leaves that fd open.
        XCTAssertTrue(TestSockets.sendAll(fd: origin, Array("late reply".utf8)))
        let reply: [UInt8]? = TestSockets.readSome(fd: client)
        XCTAssertEqual(
            reply, Array("late reply".utf8),
            "the relay closed the client fd when it hit EOF instead of half-closing"
        )

        // Origin closes: both sides now at EOF, so the relay finishes.
        let finished = expectation(description: "relay finished")
        harness.relay.onFinished = { _, _ in finished.fulfill() }
        harness.origin.close()
        wait(for: [finished], timeout: 5)
    }

    // MARK: - Structural invariants

    /// Reading the trace flag must not cost an environment rebuild per event.
    ///
    /// `ProcessInfo.environment` builds a fresh dictionary from the process
    /// environment on every access (the sample that diagnosed the spin found
    /// 1940 of 1943 samples inside `_ProcessInfo.environment.getter`), so the
    /// flag has to be read once into a stored constant rather than consulted
    /// on a path that runs per relay event, per read event, or per accepted
    /// connection. Four files carry those paths; exactly one of them may name
    /// the environment, and only to store it.
    func testTheFdTraceFlagIsReadOnceRatherThanPerEvent() throws {
        let hotPaths = [
            "Profile/TCPClient.swift",
            "Engine/RelayConnection.swift",
            "Engine/HTTPProxyServer.swift",
            "Engine/SOCKS5Server.swift",
        ]
        var lookups: [(file: String, line: String)] = []
        for file in hotPaths {
            let text = try String(contentsOf: sourceURL(file), encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("processInfo.environment") {
                lookups.append((file, String(line)))
            }
        }
        XCTAssertEqual(
            lookups.count, 1,
            "the trace flag is looked up \(lookups.count) times on per-event paths "
                + "(\(lookups.map(\.file).joined(separator: ", "))); it must be read once into a "
                + "stored constant, because every lookup rebuilds the environment dictionary"
        )
        let only = try XCTUnwrap(lookups.first)
        XCTAssertEqual(
            only.file, "Profile/TCPClient.swift",
            "the stored flag belongs on `TCPClient`, next to the fd helpers it guards"
        )
        XCTAssertTrue(
            only.line.contains("static let fdTraceEnabled"),
            "the single environment lookup must be the stored flag, not an inline event-path check: "
                + "\(only.line.trimmingCharacters(in: .whitespaces))"
        )
    }

    private func sourceURL(_ relativePath: String) -> URL {
        // …/Tests/TurtleDiverCoreTests/RelayHalfCloseTests.swift -> VPNConnect/<relativePath>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VPNConnect")
            .appendingPathComponent(relativePath)
    }
}
