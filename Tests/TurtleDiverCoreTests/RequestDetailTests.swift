import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverEngine

final class RequestDetailTests: XCTestCase {

    // MARK: Redaction

    func testCredentialHeadersAreSensitiveAndOrdinaryOnesAreNot() {
        for name in ["Authorization", "authorization", "Cookie", "Set-Cookie",
                     "Proxy-Authorization", "X-Api-Key", "X-Amz-Security-Token",
                     "X-Csrf-Token", "x-session-id"] {
            XCTAssertTrue(HeaderRedaction.isSensitive(name), "\(name) should be sensitive")
        }
        for name in ["User-Agent", "Accept", "Content-Type", "Host",
                     "Content-Length", "Referer", "Accept-Encoding", "Cache-Control"] {
            XCTAssertFalse(HeaderRedaction.isSensitive(name), "\(name) should not be sensitive")
        }
    }

    func testAWithheldValueReportsItsShapeAndNotItsContent() {
        let fields = RequestDetail.fields(
            [("cookie", "session=SUPERSECRETVALUE")],
            revealSensitive: false
        )
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0].value, "•••• (24 chars)")
        XCTAssertTrue(fields[0].redacted)
        XCTAssertFalse(fields[0].value.contains("SUPERSECRETVALUE"))
    }

    /// Opting in must keep the value; the whole point of the switch is to read
    /// a cookie you cannot reproduce otherwise.
    func testRevealingKeepsTheValue() {
        let fields = RequestDetail.fields([("cookie", "a=b")], revealSensitive: true)
        XCTAssertEqual(fields[0].value, "a=b")
        XCTAssertFalse(fields[0].redacted)
    }

    // MARK: Caps

    func testHeaderCountIsCappedAndReported() {
        let headers = (0..<40).map { ("x-header-\($0)", "value") }
        var detail = RequestDetail()
        detail.captureRequestHeaders(headers, revealSensitive: false)

        XCTAssertEqual(detail.requestHeaders.count, RequestDetail.maxHeadersPerMessage)
        XCTAssertTrue(detail.notes.contains { $0.contains("8 more request headers") })
    }

    func testAVeryLongValueIsTruncatedAtTheCap() {
        let value = String(repeating: "x", count: RequestDetail.maxValueLength + 100)
        let fields = RequestDetail.fields([("user-agent", value)], revealSensitive: false)

        XCTAssertEqual(fields[0].value.count, RequestDetail.maxValueLength + 1) // + the ellipsis
        XCTAssertTrue(fields[0].value.hasSuffix("…"))
        XCTAssertFalse(fields[0].redacted)
    }

    /// A withheld value is short by construction, so a huge secret cannot blow
    /// the cap it was supposed to be protected by.
    func testAWithheldHugeValueStaysShort() {
        let fields = RequestDetail.fields(
            [("authorization", "Bearer " + String(repeating: "t", count: 5000))],
            revealSensitive: false
        )
        XCTAssertEqual(fields[0].value, "•••• (5007 chars)")
    }

    // MARK: Merge

    /// The two legs report independently and race with teardown, so a merge
    /// must fill gaps without clearing anything already known.
    func testMergeFillsGapsAndKeepsWhatIsAlreadyThere() {
        var first = RequestDetail()
        first.requestLine = "GET /a HTTP/1.1"
        first.serverName = "example.com"

        var second = RequestDetail()
        second.serverName = "other.example.com"
        second.tlsVersion = "TLS 1.3"
        second.notes = ["truncated"]

        let merged = first.merged(with: second)
        XCTAssertEqual(merged.requestLine, "GET /a HTTP/1.1")
        XCTAssertEqual(merged.serverName, "example.com")
        XCTAssertEqual(merged.tlsVersion, "TLS 1.3")
        XCTAssertEqual(merged.notes, ["truncated"])
    }

    func testMergingTheSameNoteTwiceKeepsOneCopy() {
        var detail = RequestDetail()
        detail.notes = ["truncated"]
        let merged = detail.merged(with: detail)
        XCTAssertEqual(merged.notes, ["truncated"])
    }

    func testAnEmptyDetailIsRecognised() {
        XCTAssertTrue(RequestDetail().isEmpty)
        var detail = RequestDetail()
        detail.tlsVersion = "TLS 1.3"
        XCTAssertFalse(detail.isEmpty)
    }

    func testStatusCodeIsExtractedFromAStatusLine() {
        XCTAssertEqual(RequestDetail.statusCode(in: "HTTP/1.1 204 No Content"), "204 No Content")
        XCTAssertEqual(RequestDetail.statusCode(in: "HTTP/1.1 403"), "403")
        XCTAssertNil(RequestDetail.statusCode(in: "nonsense"))
    }

    // MARK: HTTP response head

    func testAFullResponseHeadIsParsed() {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 12\r\n\r\n"
        guard case .parsed(let statusLine, let headers) = HTTPResponseHead.probe(Array(raw.utf8)) else {
            return XCTFail("expected a parsed head")
        }
        XCTAssertEqual(statusLine, "HTTP/1.1 200 OK")
        XCTAssertEqual(headers.map(\.0), ["content-type", "content-length"])
        XCTAssertEqual(headers.first?.1, "text/html")
    }

    func testAPartialResponseHeadAsksForMore() {
        XCTAssertEqual(HTTPResponseHead.probe(Array("HTTP/1.1 200 OK\r\nContent-Type:".utf8)), .incomplete)
        XCTAssertEqual(HTTPResponseHead.probe(Array("HTT".utf8)), .incomplete)
    }

    /// Anything on this leg that is not HTTP is a TLS ServerHello, which must
    /// not be buffered waiting for a `\r\n\r\n` that will never come.
    func testANonHTTPStreamIsRejected() {
        XCTAssertEqual(HTTPResponseHead.probe([0x16, 0x03, 0x03, 0x00, 0x2a, 0x02]), .notHTTP)
    }

    func testAFoldedHeaderValueIsJoinedRatherThanLost() {
        let raw = "HTTP/1.1 200 OK\r\nSet-Cookie: a=b\r\n  ; Path=/\r\n\r\n"
        guard case .parsed(_, let headers) = HTTPResponseHead.probe(Array(raw.utf8)) else {
            return XCTFail("expected a parsed head")
        }
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers[0].0, "set-cookie")
        XCTAssertEqual(headers[0].1, "a=b ; Path=/")
    }

    // MARK: Request log

    func testADetailIsAttachedToItsEntry() {
        let log = RequestLog()
        let entry = log.append(RequestEntry(
            host: "example.com", port: 443, rule: nil, policy: "DIRECT",
            bytesToDestination: 0, bytesToClient: 0, transport: .http, error: nil
        ))
        var detail = RequestDetail()
        detail.serverName = "example.com"
        log.attachDetail(id: entry.id, detail: detail)

        XCTAssertEqual(log.snapshot().first?.detail?.serverName, "example.com")
    }

    func testAnEmptyDetailIsNotStored() {
        let log = RequestLog()
        let entry = log.append(RequestEntry(
            host: "example.com", port: 443, rule: nil, policy: "DIRECT",
            bytesToDestination: 0, bytesToClient: 0, transport: .http, error: nil
        ))
        log.attachDetail(id: entry.id, detail: RequestDetail())
        XCTAssertNil(log.snapshot().first?.detail)
    }

    /// Turning capture off must stop new details, whatever the caller does.
    func testCaptureCanBeTurnedOff() {
        let log = RequestLog()
        log.capturesDetails = false
        let entry = log.append(RequestEntry(
            host: "example.com", port: 443, rule: nil, policy: "DIRECT",
            bytesToDestination: 0, bytesToClient: 0, transport: .http, error: nil
        ))
        var detail = RequestDetail()
        detail.serverName = "example.com"
        log.attachDetail(id: entry.id, detail: detail)

        XCTAssertNil(log.snapshot().first?.detail)
    }

    func testTheSensitiveHeaderSwitchDefaultsToOff() {
        XCTAssertTrue(RequestLog().capturesDetails)
        XCTAssertFalse(RequestLog().revealsSensitiveHeaders)
    }

    /// Details are the expensive part of a row, so only the most recent ones
    /// are kept — the rows themselves survive until the ring turns them over.
    func testOnlyTheMostRecentDetailsAreKept() {
        let log = RequestLog(capacity: 500)
        var ids: [UUID] = []
        for index in 0..<(RequestLog.detailCapacity + 25) {
            let entry = log.append(RequestEntry(
                host: "host\(index)", port: 443, rule: nil, policy: "DIRECT",
                bytesToDestination: 0, bytesToClient: 0, transport: .http, error: nil
            ))
            ids.append(entry.id)
            var detail = RequestDetail()
            detail.serverName = "host\(index)"
            log.attachDetail(id: entry.id, detail: detail)
        }

        let snapshot = log.snapshot()
        XCTAssertEqual(snapshot.count, RequestLog.detailCapacity + 25)
        XCTAssertEqual(snapshot.filter { $0.detail != nil }.count, RequestLog.detailCapacity)
        XCTAssertNil(snapshot.first?.detail)
        XCTAssertEqual(snapshot.last?.detail?.serverName, "host\(RequestLog.detailCapacity + 24)")
    }

    func testADetailForATrimmedEntryIsDropped() {
        let log = RequestLog(capacity: 2)
        var firstID: UUID?
        for index in 0..<5 {
            let entry = log.append(RequestEntry(
                host: "host\(index)", port: 443, rule: nil, policy: "DIRECT",
                bytesToDestination: 0, bytesToClient: 0, transport: .http, error: nil
            ))
            if index == 0 { firstID = entry.id }
        }
        var detail = RequestDetail()
        detail.serverName = "late"
        log.attachDetail(id: firstID!, detail: detail)

        XCTAssertEqual(log.count, 2)
        XCTAssertTrue(log.snapshot().allSatisfy { $0.detail == nil })
    }
}
