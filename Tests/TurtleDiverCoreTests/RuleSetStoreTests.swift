import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules

/// The rule-set cache: conditional GET, size caps, atomic writes, and the rule
/// that a failed refresh never destroys a good copy.
final class RuleSetStoreTests: XCTestCase {

    // MARK: - Stub transport

    private final class StubTransport: RuleSetTransport, @unchecked Sendable {
        var responses: [Result<RuleSetResponse, Error>] = []
        private(set) var requests: [RuleSetRequest] = []
        /// Bodies handed out in order; wrapped into 200 responses.
        var bodies: [String] = []
        var etag: String?
        var lastModified: String?
        var statusCode = 200

        func send(_ request: RuleSetRequest) throws -> RuleSetResponse {
            requests.append(request)
            if !responses.isEmpty { return try responses.removeFirst().get() }
            let body = bodies.isEmpty ? "" : bodies.removeFirst()
            return RuleSetResponse(
                statusCode: statusCode,
                body: statusCode == 304 ? nil : Data(body.utf8),
                etag: etag,
                lastModified: lastModified,
                finalURL: request.url
            )
        }
    }

    private var directory: URL!
    private var transport: StubTransport!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ruleset-tests-\(UUID().uuidString)", isDirectory: true)
        transport = StubTransport()
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var store: RuleSetStore {
        RuleSetStore(directory: directory, transport: transport)
    }

    private func set(_ name: String = "Ads", url: String = "https://example.com/ads.conf", interval: Int? = nil) -> RemoteRuleSet {
        RemoteRuleSet(name: name, url: url, interval: interval)
    }

    // MARK: - Refresh

    func testRefreshWritesBodyAndSidecar() throws {
        transport.bodies = ["DOMAIN,a.com\nDOMAIN-SUFFIX,ads.example"]
        transport.etag = "\"v1\""

        let outcome = store.refresh(set())

        guard case .updated(let entry) = outcome else { return XCTFail("expected updated, got \(outcome)") }
        XCTAssertEqual(entry.ruleCount, 2)
        XCTAssertEqual(entry.etag, "\"v1\"")
        XCTAssertEqual(entry.url, "https://example.com/ads.conf")
        XCTAssertEqual(store.cachedRules(for: set())?.map(\.value), ["a.com", "ads.example"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.bodyURL(for: set()).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.entryURL(for: set()).path))
    }

    func testCacheFilesAreOwnerOnly() throws {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())
        for url in [store.bodyURL(for: set()), store.entryURL(for: set())] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600, "\(url.lastPathComponent) must not be world-readable")
        }
    }

    func testSecondRefreshSendsConditionalHeaders() {
        transport.bodies = ["DOMAIN,a.com"]
        transport.etag = "\"v1\""
        transport.lastModified = "Wed, 21 Oct 2015 07:28:00 GMT"
        _ = store.refresh(set())
        transport.bodies = ["DOMAIN,a.com"]

        _ = store.refresh(set())

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertNil(transport.requests[0].etag)
        XCTAssertEqual(transport.requests[1].etag, "\"v1\"")
        XCTAssertEqual(transport.requests[1].lastModified, "Wed, 21 Oct 2015 07:28:00 GMT")
    }

    func testNotModifiedKeepsTheCopyAndTouchesTheFetchTime() throws {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())
        let first = try XCTUnwrap(store.entry(for: set()))

        transport.statusCode = 304
        let outcome = store.refresh(set())

        guard case .notModified(let entry) = outcome else { return XCTFail("expected notModified, got \(outcome)") }
        XCTAssertEqual(entry.ruleCount, first.ruleCount)
        XCTAssertEqual(store.cachedRules(for: set())?.count, 1)
        XCTAssertGreaterThanOrEqual(entry.fetchedAt, first.fetchedAt)
    }

    func testFailedRefreshKeepsTheLastGoodCopy() throws {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())

        transport.responses = [.failure(RuleSetStoreError.transport("offline"))]
        let outcome = store.refresh(set())

        guard case .unavailable(let message) = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
        XCTAssertEqual(message, "offline")
        XCTAssertEqual(store.cachedRules(for: set())?.map(\.value), ["a.com"], "the good copy must survive")
    }

    func testNon200KeepsTheLastGoodCopy() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())

        transport.statusCode = 500
        let outcome = store.refresh(set())

        XCTAssertEqual(outcome, .unavailable(message: "Server returned HTTP 500"))
        XCTAssertEqual(store.cachedRules(for: set())?.count, 1)
    }

    func testEmptyBodyIsAcceptedAndReplacesTheCopy() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())
        transport.statusCode = 200
        transport.bodies = [""]

        let outcome = store.refresh(set())

        guard case .updated(let entry) = outcome else { return XCTFail("expected updated, got \(outcome)") }
        XCTAssertEqual(entry.ruleCount, 0)
        XCTAssertEqual(store.cachedRules(for: set()), [])
    }

    func testOversizeBodyIsRefused() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())

        transport.responses = [.success(RuleSetResponse(
            statusCode: 200,
            body: Data(repeating: 0x61, count: RuleSetStore.maxBytes + 1),
            finalURL: URL(string: "https://example.com/ads.conf")
        ))]
        let outcome = store.refresh(set())

        guard case .unavailable(let message) = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
        XCTAssertTrue(message.contains("over the"), message)
        XCTAssertEqual(store.cachedRules(for: set())?.count, 1, "the good copy must survive")
    }

    func testNonUTF8BodyIsRefused() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())

        transport.responses = [.success(RuleSetResponse(
            statusCode: 200,
            body: Data([0xFF, 0xFE, 0x00]),
            finalURL: URL(string: "https://example.com/ads.conf")
        ))]
        XCTAssertEqual(store.refresh(set()), .unavailable(message: "Rule set is not valid UTF-8 text"))
        XCTAssertEqual(store.cachedRules(for: set())?.count, 1)
    }

    func testHTTPURLIsNeverFetched() {
        transport.bodies = ["DOMAIN,a.com"]
        let outcome = store.refresh(set(url: "http://example.com/ads.conf"))

        XCTAssertEqual(outcome, .unavailable(message: "Refusing to fetch http://example.com/ads.conf: rule sets must use https"))
        XCTAssertTrue(transport.requests.isEmpty, "no request may leave the machine")
    }

    func testRedirectToHTTPIsRefused() {
        transport.responses = [.success(RuleSetResponse(
            statusCode: 200,
            body: Data("DOMAIN,a.com".utf8),
            finalURL: URL(string: "http://example.com/ads.conf")
        ))]
        let outcome = store.refresh(set())

        guard case .unavailable(let message) = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
        XCTAssertTrue(message.contains("redirect to http://"), message)
        XCTAssertNil(store.cachedRules(for: set()))
    }

    func testTooManyRulesIsRefused() {
        let body = (0..<(RuleSetParser.maxRules + 1))
            .map { "DOMAIN,host\($0).example" }
            .joined(separator: "\n")
        transport.responses = [.success(RuleSetResponse(
            statusCode: 200,
            body: Data(body.utf8),
            finalURL: URL(string: "https://example.com/ads.conf")
        ))]

        guard case .unavailable(let message) = store.refresh(set()) else { return XCTFail("expected unavailable") }
        XCTAssertTrue(message.contains("more than \(RuleSetParser.maxRules) rules"), message)
        XCTAssertNil(store.cachedRules(for: set()))
    }

    // MARK: - Cache identity

    func testChangingTheURLInvalidatesTheCache() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set(url: "https://example.com/one.conf"))

        let moved = set(url: "https://example.com/two.conf")
        XCTAssertNil(store.cachedRules(for: moved), "a retargeted set must not serve the old list")
        XCTAssertNil(store.entry(for: moved))
    }

    func testRemoveCacheDropsBothFiles() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())
        store.removeCache(for: set())

        XCTAssertNil(store.entry(for: set()))
        XCTAssertNil(store.cachedRules(for: set()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.bodyURL(for: set()).path))
    }

    func testCorruptSidecarIsTreatedAsNotCached() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())
        try? Data("not json".utf8).write(to: store.entryURL(for: set()))

        XCTAssertNil(store.entry(for: set()))
        XCTAssertNil(store.cachedRules(for: set()))
    }

    func testMissingBodyIsTreatedAsNotCached() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(set())
        try? FileManager.default.removeItem(at: store.bodyURL(for: set()))

        XCTAssertNil(store.cachedRules(for: set()))
    }

    // MARK: - Profile helpers

    private var profile: Profile {
        Profile(name: "T", rules: [], ruleSets: [
            set("Ads", url: "https://example.com/ads.conf"),
            set("Missing", url: "https://example.com/missing.conf"),
        ])
    }

    func testRulesBySetOnlyReturnsCachedSets() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(RemoteRuleSet(name: "Ads", url: "https://example.com/ads.conf"))

        let bySet = store.rulesBySet(for: profile)
        XCTAssertEqual(bySet.keys.sorted(), ["ads"])
        XCTAssertEqual(bySet["ads"]?.count, 1)
    }

    func testEntriesAndStaleSets() {
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(RemoteRuleSet(name: "Ads", url: "https://example.com/ads.conf"))

        let entries = store.entries(for: profile)
        XCTAssertEqual(entries.keys.sorted(), ["ads"])

        let stale = store.staleSets(in: profile)
        XCTAssertEqual(stale.map(\.name), ["Missing"], "never fetched counts as stale; only manual intervals apply here")
    }

    func testStaleSetsHonoursTheInterval() {
        let interval = set("Ads", url: "https://example.com/ads.conf", interval: 3600)
        transport.bodies = ["DOMAIN,a.com"]
        _ = store.refresh(interval)

        XCTAssertTrue(store.staleSets(in: Profile(name: "T", ruleSets: [interval]), now: Date().addingTimeInterval(7200)).isEmpty == false)
        XCTAssertTrue(store.staleSets(in: Profile(name: "T", ruleSets: [interval])).isEmpty)
    }

    // MARK: - End-to-end through the matcher

    func testRefreshedRulesDriveTheMatcher() throws {
        transport.bodies = [
            """
            # ads
            DOMAIN-SUFFIX,doubleclick.net
            IP-CIDR,203.0.113.0/24,no-resolve
            """
        ]
        let ads = set("Ads", url: "https://example.com/ads.conf")
        _ = store.refresh(ads)

        let profile = Profile(
            name: "T",
            rules: [
                ProfileRule(type: .ruleSet, value: "Ads", policy: "REJECT"),
                ProfileRule(type: .final, value: "", policy: "DIRECT"),
            ],
            ruleSets: [ads]
        )
        let matcher = RuleMatcher(profile: profile, resolver: FakeDNSResolver(table: [:]), ruleSets: store.rulesBySet(for: profile))

        XCTAssertEqual(try matcher.match(MatchContext(host: "ads.doubleclick.net", port: 443)).policy, "REJECT")
        XCTAssertEqual(try matcher.match(MatchContext(host: "example.org", port: 443)).policy, "DIRECT")
        XCTAssertEqual(matcher.expandedRuleCount, 3)
    }
}
