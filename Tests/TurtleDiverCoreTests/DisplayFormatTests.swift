import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules
@testable import TurtleDiverEngine

/// Covers the "0 bytes / still running" cases that used to render as if the UI
/// were broken: the Size column printed "Zero KB", the Duration column an orange
/// ellipsis, and the Rule column repeated what the host subtitle already said.
final class DisplayFormatTests: XCTestCase {

    // MARK: - Helpers

    private func entry(
        host: String = "example.com",
        port: Int = 443,
        policy: String = "DIRECT",
        rule: ProfileRule? = nil,
        transport: RequestTransport = .http,
        bytesToDestination: Int = 0,
        bytesToClient: Int = 0,
        error: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil
    ) -> RequestEntry {
        var entry = RequestEntry(
            startedAt: startedAt,
            host: host,
            port: port,
            rule: rule,
            policy: policy,
            bytesToDestination: bytesToDestination,
            bytesToClient: bytesToClient,
            transport: transport,
            error: error
        )
        entry.endedAt = endedAt
        return entry
    }

    // MARK: - Size

    func testZeroBytesRendersAsDashNotZeroKB() {
        XCTAssertEqual(RequestFormat.size(0), "—")
        XCTAssertFalse(RequestFormat.size(0).lowercased().contains("zero"))
    }

    func testNegativeBytesRendersAsDash() {
        // Defensive: a counter should never go negative, but if it does the
        // column must not print "-1 bytes".
        XCTAssertEqual(RequestFormat.size(-5), "—")
    }

    func testNonZeroBytesUseTheByteFormatter() {
        XCTAssertFalse(RequestFormat.size(24 * 1024).isEmpty)
        XCTAssertNotEqual(RequestFormat.size(24 * 1024), "—")
        XCTAssertEqual(RequestFormat.size(1024), RequestFormat.bytes(1024))
    }

    func testSessionTotalsSpellZeroAsAUnitNotAWord() {
        // "Zero KB ↑" in a card header read like a bug.
        XCTAssertEqual(RequestFormat.totalBytes(0), "0 KB")
        XCTAssertEqual(RequestFormat.totalBytes(-1), "0 KB")
        XCTAssertEqual(RequestFormat.totalBytes(1024), RequestFormat.bytes(1024))
    }

    // MARK: - Duration

    func testFinishedRequestShowsTotalTimeWithTwoDecimals() {
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = entry(startedAt: start, endedAt: start.addingTimeInterval(0.42))
        XCTAssertEqual(RequestFormat.durationText(entry), "0.42s")
        XCTAssertFalse(RequestFormat.isLive(entry))
    }

    func testInFlightRequestShowsElapsedTimeNotAWarning() {
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = entry(startedAt: start)
        XCTAssertTrue(RequestFormat.isLive(entry))
        // 1.6s after start, still running.
        XCTAssertEqual(
            RequestFormat.durationText(entry, now: start.addingTimeInterval(1.64)),
            "1.6s"
        )
    }

    func testInFlightRequestNeverShowsANegativeDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        let entry = entry(startedAt: start)
        // A clock adjustment must not produce "-3.0s".
        XCTAssertEqual(RequestFormat.durationText(entry, now: start.addingTimeInterval(-3)), "0.0s")
    }

    // MARK: - Rule column

    func testRuleTextJoinsTypeAndValue() {
        let rule = ProfileRule(type: .domainSuffix, value: "microsoft.com", policy: "PAC Fallback")
        XCTAssertEqual(RequestFormat.ruleText(rule), "DOMAIN-SUFFIX microsoft.com")
        XCTAssertEqual(RequestFormat.ruleTypeText(rule), "DOMAIN-SUFFIX")
    }

    func testFinalRuleShowsOnlyItsType() {
        let rule = ProfileRule(type: .final, value: "", policy: "DIRECT")
        XCTAssertEqual(RequestFormat.ruleText(rule), "FINAL")
    }

    func testMissingRuleAndRuleType() {
        XCTAssertEqual(RequestFormat.ruleText(nil), "—")
        XCTAssertNil(RequestFormat.ruleTypeText(nil))
    }

    // MARK: - Subtitle

    func testSubtitleIsTheTransportWhenThereIsNoError() {
        let entry = entry(rule: ProfileRule(type: .final, value: "", policy: "DIRECT"))
        XCTAssertEqual(RequestFormat.subtitle(entry), "HTTP")
        XCTAssertFalse(RequestFormat.subtitle(entry).contains("FINAL"), "the rule has its own column")
    }

    func testSubtitlePrefersTheError() {
        let entry = entry(error: "connection refused")
        XCTAssertEqual(RequestFormat.subtitle(entry), "connection refused")
    }

    // MARK: - Timestamp

    func testTimeIsWallClockWithoutTheDate() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(RequestFormat.time(date).count, 8)
        XCTAssertEqual(RequestFormat.time(date).filter { $0 == ":" }.count, 2)
    }

    // MARK: - Debug log lines

    func testLogLineSplitsTimestampTagAndBody() {
        let line = DebugLogParser.parse(
            "[2026-09-14T11:58:14Z] [stdout] Connected to VPN",
            id: 3
        )
        XCTAssertEqual(line.id, 3)
        XCTAssertEqual(line.time, "11:58:14")
        XCTAssertEqual(line.tag, "stdout")
        XCTAssertEqual(line.body, "Connected to VPN")
        XCTAssertEqual(line.severity, .highlight)
    }

    func testLogLineWithoutTimestampOrTag() {
        let line = DebugLogParser.parse("Starting VPN connection...")
        XCTAssertEqual(line.time, "")
        XCTAssertEqual(line.tag, "")
        XCTAssertEqual(line.body, "Starting VPN connection...")
        XCTAssertEqual(line.severity, .normal)
    }

    func testOnlyTimestampShapedBracketsBecomeTheTime() {
        // The first bracket is a timestamp only when it looks like one; anything
        // else is a tag, which is how the debug writer emits `[SEND]`/`[HANDLER]`.
        let line = DebugLogParser.parse("[Error] tunnel setup failed")
        XCTAssertEqual(line.time, "")
        XCTAssertEqual(line.tag, "Error")
        XCTAssertEqual(line.body, "tunnel setup failed")
        XCTAssertEqual(line.severity, .error)
    }

    func testClockTimeIsExtractedFromAnISOStamp() {
        XCTAssertEqual(DebugLogParser.clockTime("2026-09-14T11:58:14Z"), "11:58:14")
        XCTAssertEqual(DebugLogParser.clockTime("not-a-stamp"), "not-a-stamp")
    }

    func testSeverityComesFromContentNotTheStream() {
        // openconnect writes progress to stderr; tagging the stream would paint
        // the whole log amber.
        XCTAssertEqual(DebugLogParser.parse("[2026-09-14T11:58:14Z] [stderr] CSTP connected").severity, .highlight)
        XCTAssertEqual(DebugLogParser.parse("[2026-09-14T11:58:14Z] [stdout] FATAL error: no route").severity, .error)
        XCTAssertEqual(DebugLogParser.parse("[2026-09-14T11:58:14Z] [stdout] warning: weak cipher").severity, .warning)
        XCTAssertEqual(DebugLogParser.parse("[2026-09-14T11:58:14Z] [SEND] Password: •••• (8 chars)").severity, .highlight)
        XCTAssertEqual(DebugLogParser.parse("[2026-09-14T11:58:14Z] [stdout] POST /foo").severity, .normal)
    }

    func testParserKeepsOnlyTheTailAndNumbersLinesFromZero() {
        let output = (1...10).map { "[2026-09-14T11:58:14Z] [stdout] line \($0)" }.joined(separator: "\n")
        let lines = DebugLogParser.lines(from: output, limit: 3)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
        XCTAssertEqual(lines.last?.body, "line 10")
    }

    func testParserIgnoresBlankLinesAndHandlesEmptyOutput() {
        XCTAssertTrue(DebugLogParser.lines(from: "").isEmpty)
        let lines = DebugLogParser.lines(from: "one\n\n\ntwo", limit: 0)
        XCTAssertTrue(lines.isEmpty, "a zero limit means nothing is rendered")
        XCTAssertEqual(DebugLogParser.lines(from: "one\n\n\ntwo").count, 2)
    }
}
