import XCTest
@testable import TurtleDiverAppGlue

/// The tunnel's debug log is appended to on every line `openconnect` or
/// `vpn-slice` emits, and a copy of it is written with every connection-history
/// row. A tunnel can run for days — with the server dropping DTLS and
/// reconnecting every so often — so neither the live string nor the copy left
/// in UserDefaults may grow without bound.
final class DebugLogBoundingTests: XCTestCase {

    // MARK: - BoundedLog.tail

    func testAShortLogIsReturnedUnchanged() {
        let text = "line one\nline two\n"
        XCTAssertEqual(BoundedLog.tail(text, maxBytes: 1024), text)
    }

    func testALongLogKeepsOnlyItsTailAndFitsTheBudget() {
        let text = makeLines(count: 4000, lineBytes: 32) // ~132 KB
        let limit = 4096
        let capped = BoundedLog.tail(text, maxBytes: limit)

        XCTAssertLessThanOrEqual(capped.utf8.count, limit)
        XCTAssertTrue(capped.hasPrefix(BoundedLog.truncationMarker))
        XCTAssertTrue(capped.contains("line03999"), "the newest line must survive")
        XCTAssertFalse(capped.contains("line00000"), "the oldest line must be dropped")
    }

    func testTheKeptTextStartsOnAWholeLine() {
        let text = makeLines(count: 4000, lineBytes: 32)
        let capped = BoundedLog.tail(text, maxBytes: 4096)
        let kept = capped.dropFirst(BoundedLog.truncationMarker.count)
        let firstLine = kept.prefix(while: { $0 != "\n" })

        XCTAssertTrue(kept.hasPrefix("line"), "the kept slice must begin at a line, not mid-line")
        XCTAssertEqual(firstLine.count, 32, "the first kept line must be whole")
    }

    func testMultibyteTextIsCutOnACharacterBoundary() {
        // 'é' and '☕' are multi-byte, so a byte-based cut can land mid-scalar.
        let text = String(repeating: "café ☕\n", count: 4000)
        let limit = 4096
        let capped = BoundedLog.tail(text, maxBytes: limit)

        XCTAssertLessThanOrEqual(capped.utf8.count, limit)
        XCTAssertFalse(capped.contains("\u{FFFD}"), "a multi-byte scalar must not be split")
    }

    // MARK: - The live log

    @MainActor
    func testTheLiveDebugLogIsTrimmedAsItGrows() {
        let manager = VPNManager.shared

        manager.debugOutput = String(repeating: "x", count: VPNManager.debugOutputByteLimit + 10)
        XCTAssertLessThanOrEqual(manager.debugOutput.utf8.count, VPNManager.debugOutputByteLimit)

        // Appending past the limit must trim again and then settle: a
        // re-entrant `didSet` that keeps shrinking would spin here.
        manager.debugOutput += String(repeating: "y", count: 1024)
        XCTAssertLessThanOrEqual(manager.debugOutput.utf8.count, VPNManager.debugOutputByteLimit)
        XCTAssertTrue(manager.debugOutput.hasSuffix(String(repeating: "y", count: 1024)),
                      "the most recent output must be the part that is kept")
    }

    // MARK: - The persisted copy

    func testAHistoryRowBoundsTheLogItPersists() {
        let huge = makeLines(count: 8000, lineBytes: 64) // ~576 KB
        let attempt = ConnectionAttempt(host: "vpn.example", status: "Connected", logOutput: huge)

        XCTAssertLessThanOrEqual(attempt.logOutput.utf8.count, ConnectionAttempt.logOutputByteLimit)
        XCTAssertTrue(attempt.logOutput.hasPrefix(BoundedLog.truncationMarker))
        XCTAssertTrue(attempt.logOutput.contains("line07999"))
    }

    // MARK: - Helpers

    /// `count` lines of exactly `lineBytes` characters ending in a newline,
    /// labelled `line00000`… so a test can tell which part survived.
    private func makeLines(count: Int, lineBytes: Int) -> String {
        var out = ""
        for index in 0..<count {
            let label = "line" + String(format: "%05d", index)
            let padding = String(repeating: ".", count: max(0, lineBytes - label.count))
            out += label + padding + "\n"
        }
        return out
    }
}
