import XCTest
@testable import TurtleDiverEngine

/// The engine used to run every outbound connect on one *serial* queue. A
/// single unreachable upstream (a corporate proxy group while the VPN is down)
/// then blocked for its full timeout and took every unrelated connection down
/// with it: dials for hosts that had nothing to do with the dead proxy sat in
/// line until the client gave up. These tests pin the property that made the
/// engine look dead rather than slow.
final class ConnectSchedulerTests: XCTestCase {

    /// The point of the scheduler: a dial that hangs must not hold up the dials
    /// behind it. With a serial queue the fast body cannot start until the slow
    /// one finishes, so this test is exactly the regression.
    func testASlowConnectDoesNotHoldUpTheOnesBehindIt() {
        let scheduler = ConnectScheduler(limit: 4)
        let slow = expectation(description: "slow connect finished")
        let fast = expectation(description: "fast connect finished")

        let started = Date()
        scheduler.run {
            Thread.sleep(forTimeInterval: 1.0)
            slow.fulfill()
        }

        var fastDelay = TimeInterval.infinity
        scheduler.run {
            fastDelay = Date().timeIntervalSince(started)
            fast.fulfill()
        }

        wait(for: [fast], timeout: 0.5)
        XCTAssertLessThan(fastDelay, 0.4, "the second connect waited for the first one")
        wait(for: [slow], timeout: 5)
    }

    /// The cap bounds how many blocking dials hold a thread at once.
    func testNoMoreThanTheLimitRunAtOnce() {
        let limit = 2
        let scheduler = ConnectScheduler(limit: limit)
        let done = expectation(description: "all connects finished")
        done.expectedFulfillmentCount = 6

        let lock = NSLock()
        var inFlight = 0
        var peak = 0

        for _ in 0..<6 {
            scheduler.run {
                lock.lock()
                inFlight += 1
                peak = max(peak, inFlight)
                lock.unlock()

                Thread.sleep(forTimeInterval: 0.15)

                lock.lock()
                inFlight -= 1
                lock.unlock()
                done.fulfill()
            }
        }

        wait(for: [done], timeout: 10)
        XCTAssertLessThanOrEqual(peak, limit, "more connects blocked at once than the cap allows")
        XCTAssertGreaterThan(peak, 1, "the connects never overlapped — the scheduler is serial")
    }

    /// A slot must be handed back when the body finishes, including when the
    /// body is the one that failed.
    func testASlotIsReleasedSoLaterConnectsStillRun() {
        let scheduler = ConnectScheduler(limit: 1)
        let done = expectation(description: "queued connect ran")
        done.expectedFulfillmentCount = 3

        for _ in 0..<3 {
            scheduler.run { done.fulfill() }
        }

        wait(for: [done], timeout: 5)
    }

    /// A limit of 0 would deadlock a semaphore-based scheduler; it is clamped.
    func testANonPositiveLimitStillRunsWork() {
        let scheduler = ConnectScheduler(limit: 0)
        let done = expectation(description: "clamped scheduler ran the body")
        scheduler.run { done.fulfill() }
        wait(for: [done], timeout: 5)
    }
}
