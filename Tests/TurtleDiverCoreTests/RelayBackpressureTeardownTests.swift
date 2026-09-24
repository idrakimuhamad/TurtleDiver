import XCTest
import Darwin
@testable import TurtleDiverCore
@testable import TurtleDiverEngine

/// Regression tests for tearing down a relay whose read side is suspended by
/// backpressure.
///
/// `pauseRead` suspends a `DispatchSourceRead` while the opposite buffer sits
/// above the pause watermark, and `finish` used to drop the source's last
/// reference without balancing that suspend. Releasing the last reference to
/// a *suspended* libdispatch object aborts the process:
/// `_dispatch_queue_xref_dispose` traps with "Release of a suspended object"
/// (a source's own xref dispose runs that check on the source's state). A
/// disconnect is exactly that shape — the engine's `closeAll` force-finishes
/// every in-flight relay, and a relay mid-backpressure (a large transfer in
/// flight) has a suspended read source — so the process died inside
/// `RelayConnection.finish`'s teardown block on the relay queue, right after
/// the user clicked disconnect.
final class RelayBackpressureTeardownTests: XCTestCase {

    // MARK: - Tests

    /// The crash shape, driven for real: a relay paused by backpressure is
    /// force-finished the way a disconnect does it. Before the fix the process
    /// aborted inside the source teardown (this suite would die, not fail);
    /// after it, the relay finishes cleanly and reports the bytes it carried.
    func testFinishingAPausedRelayFinishesInsteadOfTrapping() throws {
        // Reuse the half-close harness: real relay, real socketpair client
        // leg, loopback origin that the test accepts but never reads — the
        // "origin is not draining" half of backpressure.
        guard let harness = RelayHalfCloseTests().startRelay(queueLabel: "backpressure.finish") else {
            XCTFail("could not start the relay harness")
            return
        }
        defer {
            harness.client.close()
            harness.origin.close()
            harness.listener.close()
        }
        XCTAssertNil(
            harness.connectError, "relay connect failed: \(String(describing: harness.connectError))"
        )

        let client = harness.client.descriptor
        // Non-blocking: once the kernel buffers are full the test must be able
        // to stop pushing instead of blocking forever behind a paused relay.
        let flags = fcntl(client, F_GETFL)
        XCTAssertEqual(fcntl(client, F_SETFL, flags | O_NONBLOCK), 0, "fcntl failed: errno \(errno)")

        // Push far past the 256 KB pause watermark. The relay's
        // client→outbound buffer crosses the watermark, `pauseRead` suspends
        // the client read source, and everything after parks in the kernel
        // socket buffers until the test's sends keep failing with EAGAIN.
        let chunk = [UInt8](repeating: 0x42, count: 64 * 1024)
        var sent = 0
        var stalledRounds = 0
        let sendDeadline = Date().addingTimeInterval(10)
        while Date() < sendDeadline {
            let n = chunk.withUnsafeBytes { send(client, $0.baseAddress, chunk.count, Int32(MSG_NOSIGNAL)) }
            if n > 0 {
                sent += n
                stalledRounds = 0
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                stalledRounds += 1
                if stalledRounds >= 50 { break } // 500 ms with no kernel progress
                usleep(10_000)
            } else {
                break
            }
        }

        // The pause is asynchronous — the relay reads at its own pace on its
        // queue. Wait until it stops reading: `bytesToDestination` plateauing
        // while the origin never reads means the buffer is pinned far past the
        // watermark and the client read source is suspended. Only then has the
        // test actually reached the paused state the fix guards.
        let relay = harness.relay
        var lastSeen = relay.metrics.bytesToDestination
        var stableRounds = 0
        let plateauDeadline = Date().addingTimeInterval(5)
        while Date() < plateauDeadline {
            usleep(50_000)
            let now = relay.metrics.bytesToDestination
            if now == lastSeen { stableRounds += 1 } else { stableRounds = 0; lastSeen = now }
            if stableRounds >= 3, lastSeen >= RelayConnection.pauseWatermark { break }
        }
        XCTAssertGreaterThanOrEqual(
            relay.metrics.bytesToDestination, RelayConnection.pauseWatermark,
            "the relay never buffered past the pause watermark (sent \(sent) bytes) — "
                + "the test did not reach the paused state, so it proves nothing"
        )

        // The disconnect shape: force-finish the paused relay.
        let finished = expectation(description: "paused relay finished")
        var finalMetrics: RelayMetrics?
        relay.onFinished = { metrics, _ in
            finalMetrics = metrics
            finished.fulfill()
        }
        relay.finish(with: RelayError.upstreamConnectFailed("engine stopped"))
        wait(for: [finished], timeout: 5)

        // The finish went through with the data it had counted.
        let metrics = try XCTUnwrap(finalMetrics, "the relay never reported its finish")
        XCTAssertGreaterThanOrEqual(metrics.bytesToDestination, RelayConnection.pauseWatermark)
    }

    /// The pause flag must be consumed by the teardown: after a finish the
    /// relay holds no sources at all, so a second finish (idempotent) and the
    /// object's eventual release must not touch a suspended source either.
    func testFinishIsStillIdempotentOnAPausedRelay() throws {
        guard let harness = RelayHalfCloseTests().startRelay(queueLabel: "backpressure.idempotent") else {
            XCTFail("could not start the relay harness")
            return
        }
        defer {
            harness.client.close()
            harness.origin.close()
            harness.listener.close()
        }
        XCTAssertNil(harness.connectError, "relay connect failed")

        // Drive the relay into the paused state, same as the crash test.
        let client = harness.client.descriptor
        let flags = fcntl(client, F_GETFL)
        XCTAssertEqual(fcntl(client, F_SETFL, flags | O_NONBLOCK), 0, "fcntl failed: errno \(errno)")
        let chunk = [UInt8](repeating: 0x41, count: 64 * 1024)
        var stalledRounds = 0
        let sendDeadline = Date().addingTimeInterval(10)
        while Date() < sendDeadline {
            let n = chunk.withUnsafeBytes { send(client, $0.baseAddress, chunk.count, Int32(MSG_NOSIGNAL)) }
            if n > 0 {
                stalledRounds = 0
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                stalledRounds += 1
                if stalledRounds >= 50 { break }
                usleep(10_000)
            } else {
                break
            }
        }
        let relay = harness.relay
        var lastSeen = relay.metrics.bytesToDestination
        var stableRounds = 0
        let plateauDeadline = Date().addingTimeInterval(5)
        while Date() < plateauDeadline {
            usleep(50_000)
            let now = relay.metrics.bytesToDestination
            if now == lastSeen { stableRounds += 1 } else { stableRounds = 0; lastSeen = now }
            if stableRounds >= 3, lastSeen >= RelayConnection.pauseWatermark { break }
        }
        guard relay.metrics.bytesToDestination >= RelayConnection.pauseWatermark else {
            return // did not reach the paused state; nothing to prove here
        }

        let finished = expectation(description: "first finish reported")
        relay.onFinished = { _, _ in finished.fulfill() }
        relay.finish(with: RelayError.upstreamConnectFailed("engine stopped"))
        wait(for: [finished], timeout: 5)

        // A second finish must be a silent no-op — and must not re-touch the
        // (already released) sources.
        var secondFires = false
        relay.onFinished = { _, _ in secondFires = true }
        relay.finish(with: RelayError.upstreamConnectFailed("again"))
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(secondFires, "a second finish must not re-report")
    }
}