import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TurtleDiverCore

/// Guards for the *test harness* itself.
///
/// The fakes in `TestServers.swift` accept connections by descriptor **number**.
/// If a serve loop is still polling that number when `stop()` closes the
/// listener, the kernel is free to recycle the number into an unrelated socket
/// and the stale loop then accepts a connection that belongs to somebody else:
/// it answers with its own canned response (a 204 where a different origin's
/// 200 was expected) or, for a server whose first byte must be a SOCKS5
/// greeting, closes it outright — which a test observes as an intermittent
/// *empty* reply. These tests pin the property that removes the whole class:
/// `stop()` does not close the listener until the loop has left it alone.
///
/// The first test below is the deterministic part of the guard (it fails on the
/// close-first `stop()` regardless of scheduling); the second reproduces the
/// original scenario behaviourally.
final class TestHarnessLifecycleTests: XCTestCase {

    // MARK: - The invariant

    func testStopWaitsForTheServeLoopToExitBeforeTheListenerIsClosed() {
        for (name, make) in Self.serverFactories {
            let server = make()
            // The serve loop is parked in accept/poll when stop() arrives, so a
            // close-first stop() returns while the loop still owns the number.
            server.stop()
            XCTAssertTrue(
                server.loop.isLoopFinished,
                "\(name).stop() returned while its serve loop was still using the listener fd"
            )
        }
    }

    func testStopClosesTheListenerOnlyOnceItIsNoLongerInUse() {
        let server = FakeHTTPServer()!
        server.stop()
        // A descriptor that is genuinely closed can be reused; if the loop were
        // still polling it, this listener would inherit a stale accept loop.
        let reused = TestSockets.listenOnEphemeralLoopback()
        defer { TestSockets.closeFD(reused.fd) }
        XCTAssertEqual(server.requestCount, 0)
        XCTAssertTrue(server.loop.isLoopFinished)
    }

    // MARK: - The original failure scenario

    /// Stop a server, hand its descriptor number to a listener of our own, and
    /// then connect. The connection must belong to us: a stopped server must
    /// not count it and must not answer it.
    func testAStoppedServerCannotAcceptOnARecycledDescriptor() throws {
        for _ in 0..<5 {
            let victim = FakeHTTPServer()!
            let victimFD = victim.fd
            victim.stop()

            guard let replacement = listenerReusing(victimFD) else { continue }
            defer { TestSockets.closeFD(replacement.fd) }

            let client = try TCPClient.connect(host: "127.0.0.1", port: replacement.port, timeoutSeconds: 5)
            defer { TCPClient.closeSocket(client) }

            // Whoever accepts this must be us. If a stale loop on the recycled
            // number wins, the victim answers 204 and counts a request.
            let served = TestSockets.acceptWithTimeout(fd: replacement.fd, seconds: 2)
            XCTAssertNotNil(
                served,
                "a stopped server stole a connection that now belongs to descriptor \(victimFD)"
            )
            if let served { TestSockets.closeFD(served) }
            XCTAssertEqual(
                victim.requestCount, 0,
                "a stopped server answered a connection that no longer belongs to it"
            )
        }
    }

    // MARK: - Joining must not be a hang

    /// The join only works if `stop()` can unblock a handler parked on a client
    /// that is still connected and silent: `shutdown()` makes its `recv` return
    /// 0 while the handler keeps ownership of the close.
    func testStopUnblocksAHandlerWaitingOnAQuietClient() throws {
        let echo = FakeEchoServer()!
        let client = try TCPClient.connect(host: "127.0.0.1", port: echo.port, timeoutSeconds: 5)
        defer { TCPClient.closeSocket(client) }

        // Real condition, no sleep: wait until the serve loop has taken it.
        let attached = Date().addingTimeInterval(2)
        while echo.loop.activeClientCount == 0, Date() < attached { usleep(1000) }
        XCTAssertEqual(echo.loop.activeClientCount, 1, "the echo server must have accepted the client")

        let started = Date()
        echo.stop()
        XCTAssertTrue(echo.loop.isLoopFinished, "stop() must have joined the serve loop")
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 3,
            "stop() must unblock a handler waiting on a quiet client, not wait for the client"
        )
    }

    // MARK: - Helpers

    /// Opens loopback listeners until one lands on `target`. The kernel hands
    /// out the lowest free descriptor, so this normally succeeds on the first
    /// attempt.
    private func listenerReusing(_ target: Int32) -> (fd: Int32, port: Int)? {
        for _ in 0..<64 {
            let candidate = TestSockets.listenOnEphemeralLoopback()
            if candidate.fd == target { return candidate }
            TestSockets.closeFD(candidate.fd)
            if candidate.fd > target { return nil }
        }
        return nil
    }

    private static var serverFactories: [(String, () -> LoopBacked)] {
        [
            ("FakeHTTPServer", { FakeHTTPServer()! }),
            ("FakeSOCKS5Server", { FakeSOCKS5Server()! }),
            ("FakeSOCKS5AuthServer", { FakeSOCKS5AuthServer(user: "u", pass: "p")! }),
            ("FakeHTTPProxyServer", { FakeHTTPProxyServer()! }),
            ("FakeEchoServer", { FakeEchoServer()! }),
            ("RecordingHTTPOrigin", { RecordingHTTPOrigin() }),
            ("FakeHTTPConnectProxyServer", { FakeHTTPConnectProxyServer() }),
        ]
    }
}

/// The shape every fake in `TestServers.swift` shares: a listener loop and a
/// stop that must join it.
private protocol LoopBacked: AnyObject {
    var loop: TestListenerLoop { get }
    func stop()
}

extension FakeHTTPServer: LoopBacked {}
extension FakeSOCKS5Server: LoopBacked {}
extension FakeSOCKS5AuthServer: LoopBacked {}
extension FakeHTTPProxyServer: LoopBacked {}
extension FakeEchoServer: LoopBacked {}
extension RecordingHTTPOrigin: LoopBacked {}
extension FakeHTTPConnectProxyServer: LoopBacked {}
