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

    // MARK: - Request detail

    private func detailed(
        host: String = "example.com",
        serverName: String? = nil,
        requestLine: String? = nil,
        statusLine: String? = nil,
        alpn: [String] = [],
        tlsVersion: String? = nil,
        resolvedAddress: String? = nil,
        notes: [String] = []
    ) -> RequestEntry {
        var entry = entry(host: host, policy: "Proxy A", bytesToDestination: 2048, bytesToClient: 512)
        var detail = RequestDetail()
        detail.requestLine = requestLine
        detail.statusLine = statusLine
        detail.serverName = serverName
        detail.alpn = alpn
        detail.tlsVersion = tlsVersion
        detail.resolvedAddress = resolvedAddress
        detail.notes = notes
        entry.detail = detail
        return entry
    }

    private func section(_ entry: RequestEntry, _ id: String) -> RequestFormat.DetailSection? {
        RequestFormat.detailSections(entry).first { $0.id == id }
    }

    func testSubtitleAddsTheDetailSummaryAndSkipsARepeatedName() {
        XCTAssertEqual(RequestFormat.subtitle(entry()), "HTTP")

        // A CONNECT row whose ClientHello name matches the host does not gain a
        // second copy of it, but does gain the response status and protocol.
        let sameName = detailed(serverName: "example.com", statusLine: "HTTP/1.1 204 No Content", alpn: ["h2"])
        XCTAssertEqual(RequestFormat.subtitle(sameName), "HTTP · 204 No Content · h2")

        // When the row only had an address, the name is exactly what it needed.
        let named = detailed(host: "1.2.3.4", serverName: "login.example.com")
        XCTAssertEqual(RequestFormat.subtitle(named), "HTTP · login.example.com")
    }

    /// Two ALPN protocols joined with "/" read as "h2/http/1.1" — i.e. as a
    /// single misspelled protocol. The row and the sheet must agree.
    func testTheOfferedProtocolsAreJoinedUnambiguously() {
        let both = detailed(alpn: ["h2", "http/1.1"])
        XCTAssertEqual(RequestFormat.detailSummary(both), "h2, http/1.1")
        XCTAssertFalse(RequestFormat.detailSummary(both)?.contains("h2/http") == true)
        XCTAssertEqual(section(both, "tls")?.rows.last?.value, "h2, http/1.1")
    }

    func testTheSheetShowsTheLiveRowAndFallsBackToTheSnapshot() {
        var live = detailed(serverName: "example.com")
        var detail = live.detail!
        detail.tlsVersion = "TLS 1.3"
        live.detail = detail
        let snapshot = detailed(serverName: "example.com") // as captured at click time
        XCTAssertNotEqual(snapshot, live)

        XCTAssertEqual(
            RequestFormat.selectedEntry(in: [live], id: live.id, fallback: snapshot)?.detail?.tlsVersion,
            "TLS 1.3",
            "the open sheet must pick up a detail that arrived after the click"
        )
        XCTAssertEqual(
            RequestFormat.selectedEntry(in: [], id: live.id, fallback: snapshot),
            snapshot,
            "a row trimmed out of the log keeps showing what was last seen"
        )
        XCTAssertNil(RequestFormat.selectedEntry(in: [], id: live.id, fallback: nil))
    }

    func testSubtitleKeepsAnErrorAheadOfEverything() {
        var entry = detailed(serverName: "example.com")
        entry.error = "connection reset"
        XCTAssertEqual(RequestFormat.subtitle(entry), "connection reset")
    }

    func testResolvedAddressIsShownOnlyWhenItDiffersFromTheHost() {
        XCTAssertNil(RequestFormat.detailSummary(detailed(resolvedAddress: "example.com")))
        XCTAssertEqual(RequestFormat.detailSummary(detailed(host: "example.com", resolvedAddress: "93.184.216.34")), "→ 93.184.216.34")

        let rows = section(detailed(host: "example.com", resolvedAddress: "93.184.216.34"), "general")?.rows ?? []
        XCTAssertTrue(rows.contains { $0.name == "Connected to" && $0.value == "93.184.216.34" })
        let same = section(detailed(resolvedAddress: "example.com"), "general")?.rows ?? []
        XCTAssertFalse(same.contains { $0.name == "Connected to" })
    }

    func testGeneralSectionCarriesTheRowAndTheCaptureNotes() {
        let general = section(detailed(notes: ["8 more request headers not shown"]), "general")
        XCTAssertEqual(general?.note, "8 more request headers not shown")
        let rows = general?.rows ?? []
        XCTAssertTrue(rows.contains { $0.name == "Rule" })
        XCTAssertTrue(rows.contains { $0.name == "Policy" && $0.value == "Proxy A" })
        XCTAssertTrue(rows.contains { $0.name == "Size" })
        XCTAssertTrue(rows.contains { $0.name == "Duration" })
    }

    /// An empty section must explain itself, or it reads as a bug rather than
    /// as "that data is encrypted".
    func testEmptySectionsExplainWhyTheyAreEmpty() {
        let plain = entry()
        XCTAssertEqual(section(plain, "request")?.note, "No request head was captured.")
        XCTAssertTrue(section(plain, "response")?.note?.contains("encrypted") == true)
        XCTAssertTrue(section(plain, "tls")?.note?.contains("not TLS") == true)
    }

    /// A SOCKS5 tunnel never has a request head to capture, so "no request head
    /// was captured" would read as a failure on every SOCKS5 row.
    func testTheEmptyRequestNoteKnowsThatSocks5HasNoHeadAtAll() {
        let socks = entry(host: "1.2.3.4", port: 443, transport: .socks5)
        XCTAssertEqual(section(socks, "request")?.title, "CONNECT request")
        XCTAssertTrue(section(socks, "request")?.note?.contains("destination") == true)
        XCTAssertNotEqual(section(socks, "request")?.note, section(entry(), "request")?.note)
    }

    func testCapturedRowsAppearWithTheirTitles() {
        var entry = detailed(
            serverName: "example.com",
            requestLine: "CONNECT example.com:443 HTTP/1.1",
            statusLine: "HTTP/1.1 200 OK",
            alpn: ["h2"],
            tlsVersion: "TLS 1.3",
            resolvedAddress: "93.184.216.34"
        )
        var detail = entry.detail!
        detail.captureRequestHeaders([("user-agent", "curl/8.0"), ("cookie", "a=b")], revealSensitive: false)
        detail.captureResponseHeaders([("content-type", "text/html")], revealSensitive: false)
        entry.detail = detail

        XCTAssertEqual(section(entry, "request")?.title, "Request")
        let requestRows = section(entry, "request")?.rows ?? []
        XCTAssertEqual(requestRows.first?.value, "CONNECT example.com:443 HTTP/1.1")
        XCTAssertTrue(requestRows.contains { $0.name == "user-agent" && $0.value == "curl/8.0" })
        XCTAssertTrue(requestRows.contains { $0.name == "cookie" && $0.redacted })

        let responseRows = section(entry, "response")?.rows ?? []
        XCTAssertEqual(responseRows.first?.name, "Status")
        XCTAssertTrue(responseRows.contains { $0.name == "content-type" })

        let tlsRows = section(entry, "tls")?.rows ?? []
        XCTAssertEqual(tlsRows.map { $0.name }, ["Server name", "Version", "ALPN"])
        XCTAssertTrue(section(entry, "tls")?.note?.contains("unencrypted by design") == true)
    }

    /// A SOCKS5 row is an address; calling its head an HTTP request would be
    /// simply false.
    func testASOCKS5RequestSectionIsNotCalledARequestLine() {
        var entry = detailed(requestLine: "CONNECT 1.2.3.4:443")
        entry = RequestEntry(
            host: entry.host, port: entry.port, rule: nil, policy: "Proxy A",
            bytesToDestination: 0, bytesToClient: 0, transport: .socks5, error: nil
        )
        XCTAssertEqual(section(entry, "request")?.title, "CONNECT request")
    }

    func testCopyableTextCarriesEverySectionAndRow() {
        let entry = detailed(serverName: "example.com", requestLine: "GET / HTTP/1.1", statusLine: "HTTP/1.1 204 No Content")
        let text = RequestFormat.detailText(entry)

        XCTAssertTrue(text.contains("== General =="))
        XCTAssertTrue(text.contains("== Request =="))
        XCTAssertTrue(text.contains("== Response =="))
        XCTAssertTrue(text.contains("== TLS handshake =="))
        XCTAssertTrue(text.contains("Request line: GET / HTTP/1.1"))
        XCTAssertTrue(text.contains("Status: HTTP/1.1 204 No Content"))
        XCTAssertFalse(text.hasSuffix("\n"))
    }

    /// The sheet is the place where a withheld value could leak by accident, so
    /// it must show what the redactor produced and never a raw header.
    func testTheSheetNeverShowsAWithheldValue() {
        var entry = entry()
        var detail = RequestDetail()
        detail.captureRequestHeaders([("authorization", "Bearer TOPSECRET")], revealSensitive: false)
        entry.detail = detail

        let rendered = RequestFormat.detailSections(entry)
            .flatMap { $0.rows }
            .map { $0.value }
            .joined(separator: " ")
        XCTAssertFalse(rendered.contains("TOPSECRET"))
        XCTAssertTrue(rendered.contains("••••"))
        XCTAssertFalse(RequestFormat.detailText(entry).contains("TOPSECRET"))
    }
}
