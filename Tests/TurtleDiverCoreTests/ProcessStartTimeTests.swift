import XCTest
@testable import TurtleDiverSystem

/// `processStartTime` used to spawn `ps` and wait on it with `waitUntilExit()` —
/// no deadline at all — on the main thread, on the launch path. It also asked
/// for `lstart`, a *formatted* date whose day and month names follow the
/// machine's `LC_TIME`: measured, `LC_ALL=de_DE.UTF-8 ps -o lstart=` answers
/// `Mi. 16 Sep. 19:34:34 2026`, which no fixed-format parser can read. The
/// elapsed field cannot be localised, and the read is bounded.
final class ProcessStartTimeTests: XCTestCase {

    // MARK: - The field, parsed

    func testAnElapsedFieldUnderAnHourIsMinutesAndSeconds() {
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "00:00"), 0)
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "12:34"), 754)
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "59:59"), 3_599)
    }

    func testAnElapsedFieldUnderADayIsHoursMinutesSeconds() {
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "00:00:01"), 1)
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "01:02:03"), 3_723)
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "23:59:59"), 86_399)
    }

    func testAnElapsedFieldOverADayCarriesTheDay() {
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "1-00:00:00"), 86_400)
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "06-05:48:13"), 539_293)
    }

    /// `ps` pads its column, and a line read from a pipe can end in CRLF.
    func testTheFieldIsTrimmedBeforeItIsParsed() {
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: " 12:34"), 754)
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "12:34\n"), 754)
        XCTAssertEqual(ProcessStartTime.elapsedSeconds(fromETime: "  12:34\r\n"), 754)
    }

    func testAFieldInAnUnknownShapeIsNil() {
        for field in [
            "",
            "   ",
            "\n",
            // The two `lstart` shapes, English and German: this parser reads the
            // elapsed field, and must not be asked to make sense of a date.
            "Wed Sep 16 19:34:34 2026",
            "Mi. 16 Sep. 19:34:34 2026",
            "12",
            "1:2:3:4",
            "1-2-3:4",
            "1e3:00",
            "-1:00",
            "12:ab",
            "12:34:",
            ":34",
            "12:34:56:78",
        ] {
            XCTAssertNil(ProcessStartTime.elapsedSeconds(fromETime: field), "expected nil for \(field.debugDescription)")
        }
    }

    func testTheStartDateIsTheClockMinusTheElapsed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ProcessStartTime.startDate(now: now, elapsed: 0), now)
        XCTAssertEqual(ProcessStartTime.startDate(now: now, elapsed: 754),
                       Date(timeIntervalSince1970: 1_800_000_000 - 754))
    }

    // MARK: - The read, bounded

    /// The field that is asked for is the whole point: `lstart` is the one that
    /// answers in the machine's locale.
    func testTheReadAsksForTheElapsedFieldAndNothingElse() throws {
        let sandbox = try makeSandbox()
        let recorded = sandbox.appendingPathComponent("argv")
        let script = try makeScript("""
        printf '%s\\n' "$*" > '\(recorded.path)'
        printf '%s\\n' '12:34'
        """, in: sandbox)

        let clock = Date(timeIntervalSince1970: 1_800_000_000)
        let reader = ProcessStartTimeReader(executableURL: script, timeout: 10)
        let start = try XCTUnwrap(reader.startTime(pid: 4_242, now: clock))

        XCTAssertEqual(start, Date(timeIntervalSince1970: 1_800_000_000 - 754))
        let arguments = try String(contentsOf: recorded, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(arguments, "-o etime= -p 4242")
        XCTAssertFalse(arguments.contains("lstart"), "lstart follows LC_TIME; the elapsed field does not")
    }

    /// A real `ps`, on our own process: proves the field name and the shape the
    /// machine actually prints for something under an hour old.
    func testARealReadOfOurOwnProcessIsInTheRecentPast() throws {
        let clock = Date()
        let start = try XCTUnwrap(ProcessStartTimeReader().startTime(pid: getpid()),
                                  "a real `ps -o etime=` read of our own process must parse")
        let elapsed = clock.timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0)
        XCTAssertLessThan(elapsed, 120)
    }

    /// A command that never answers must be abandoned, not waited on.
    ///
    /// Through a script on purpose: `sleep` handed `ps`'s arguments exits
    /// immediately, so it would satisfy the assertions below without ever
    /// exercising the deadline.
    func testAHungReadIsAbandonedAtItsDeadline() throws {
        let sandbox = try makeSandbox()
        let script = try makeScript("exec /bin/sleep 30", in: sandbox)

        let reader = ProcessStartTimeReader(executableURL: script, timeout: 0.5)
        let started = Date()
        XCTAssertNil(reader.startTime(pid: 4_242, now: Date()))
        // 30 s of `sleep` against a 0.5 s deadline: it has to come back quickly.
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// Including a child that ignores `SIGTERM`: the runner escalates, and the
    /// call still returns.
    func testAReadThatIgnoresSigtermIsStillBounded() throws {
        let sandbox = try makeSandbox()
        let script = try makeScript("trap '' TERM\nexec /bin/sleep 30", in: sandbox)

        let reader = ProcessStartTimeReader(executableURL: script, timeout: 0.5)
        let started = Date()
        XCTAssertNil(reader.startTime(pid: 4_242, now: Date()))
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    }

    func testAFailedOrMissingReadIsNil() throws {
        let sandbox = try makeSandbox()
        let failing = try makeScript("printf '%s\\n' '12:34'; exit 3", in: sandbox)

        XCTAssertNil(ProcessStartTimeReader(executableURL: failing, timeout: 10)
            .startTime(pid: 4_242, now: Date()))
        XCTAssertNil(ProcessStartTimeReader(executableURL: sandbox.appendingPathComponent("absent"), timeout: 10)
            .startTime(pid: 4_242, now: Date()))
    }

    /// A pid that is not a candidate for anything this app does is refused
    /// *before* anything is spawned.
    func testAPidThatIsNeverACandidateIsRefusedWithoutSpawning() throws {
        let sandbox = try makeSandbox()
        let marker = sandbox.appendingPathComponent("ran")
        let script = try makeScript(": > '\(marker.path)'\nprintf '%s\\n' '12:34'", in: sandbox)

        let reader = ProcessStartTimeReader(executableURL: script, timeout: 10)
        for pid: Int32 in [1, 0, -1] {
            XCTAssertNil(reader.startTime(pid: pid, now: Date()), "pid \(pid) must be refused")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "nothing should have been spawned for a pid that cannot be a tunnel")
    }

    // MARK: Helpers

    private func makeSandbox() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("starttime-\(UUID().uuidString)", isDirectory: true)
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
