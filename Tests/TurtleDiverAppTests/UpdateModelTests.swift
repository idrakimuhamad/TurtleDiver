import XCTest
@testable import TurtleDiverAppGlue
@testable import TurtleDiverSystem

/// The Updates pane's model: the check, the four things it can report, and the
/// two rules it exists to keep — that the request never runs on the main actor,
/// and that the launch check is silent when the user has switched it off.
///
/// Nothing here reaches GitHub. The transport is a stub, so the feed's shape is
/// canned and the only thing under test is what the app does with an answer.
@MainActor
final class UpdateModelTests: XCTestCase {

    // MARK: - Fixtures

    /// A release payload in the shape GitHub sends, built the way the feed's own
    /// tests build one: through the decoder, so a test cannot assert against a
    /// release the feed could never produce.
    private func feed(tag: String,
                      assets: [(name: String, url: String, size: Int?, digest: String?)] = []) -> String {
        let assetJSON = assets.map { asset -> String in
            let size = asset.size.map(String.init) ?? "null"
            let digest = asset.digest.map { "\"\($0)\"" } ?? "null"
            return """
            {"name":"\(asset.name)","browser_download_url":"\(asset.url)","size":\(size),"digest":\(digest)}
            """
        }.joined(separator: ",")
        return """
        {"tag_name":"\(tag)","html_url":"https://example.com/releases/\(tag)","draft":false,\
        "prerelease":false,"assets":[\(assetJSON)]}
        """
    }

    /// The two assets a real release carries, named for the version they install.
    private func installable(_ version: String) -> [(name: String, url: String, size: Int?, digest: String?)] {
        [
            (name: "TurtleDiver-\(version).dmg", url: "https://example.com/\(version).dmg",
             size: 5_786_026, digest: "sha256:aa11bb22"),
            (name: "TurtleDiver-\(version).sha256", url: "https://example.com/\(version).sha256",
             size: 176, digest: "sha256:cc33dd44"),
        ]
    }

    private func makeModel(feed stub: StubFeed,
                           running: ReleaseVersion? = ReleaseVersion("2.0.0"),
                           now: Date = Date(timeIntervalSince1970: 1_000_000)) -> UpdateModel {
        UpdateModel(checker: UpdateChecker(transport: stub), runningVersion: running, now: { now })
    }

    // MARK: - What each answer becomes

    func testAnUpToDateBuildSaysSoAndRecordsWhenItAsked() async {
        let stub = StubFeed(body: feed(tag: "v2.0.0"))
        let model = makeModel(feed: stub)

        await model.check()

        XCTAssertEqual(model.phase, .upToDate(ReleaseVersion("2.0.0")!))
        XCTAssertEqual(model.statusText, "Up to date")
        XCTAssertEqual(model.statusTone, .ok)
        XCTAssertEqual(model.summary, "TurtleDiver 2.0.0 is the newest release")
        XCTAssertEqual(model.lastChecked, Date(timeIntervalSince1970: 1_000_000))
        XCTAssertEqual(model.checkedText, "Checked just now")
        XCTAssertNil(model.offer, "nothing to show a banner about")
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testANewerReleaseBecomesAnOfferTheInterfaceCanActOn() async {
        let stub = StubFeed(body: feed(tag: "v2.1.0", assets: installable("2.1.0")))
        let model = makeModel(feed: stub)

        await model.check()

        guard let offer = model.offer else { return XCTFail("expected an offer, got \(model.phase)") }
        XCTAssertEqual(offer.version, ReleaseVersion("2.1.0"))
        XCTAssertTrue(offer.canInstall)
        XCTAssertEqual(offer.installer?.name, "TurtleDiver-2.1.0.dmg")
        XCTAssertEqual(offer.pageURL?.absoluteString, "https://example.com/releases/v2.1.0")
        XCTAssertEqual(model.statusText, "Available")
        XCTAssertEqual(model.statusTone, .attention)
        XCTAssertEqual(model.summary, "Version 2.1.0 is available")
    }

    /// A newer release that carries nothing this app would download is still
    /// worth reading about — but it must not read as something it can install.
    func testANewerReleaseWithNoInstallerIsOfferedToReadAndSaysWhy() async {
        let stub = StubFeed(body: feed(tag: "v2.1.0"))
        let model = makeModel(feed: stub)

        await model.check()

        XCTAssertEqual(model.offer?.canInstall, false)
        XCTAssertEqual(model.offer?.withheldReason,
                       "That release has no disk image this app will download")
        XCTAssertEqual(model.summary, "Version 2.1.0 is available, but not as a download")
        XCTAssertEqual(model.statusTone, .attention)
    }

    /// Every release must bump the marketing version, so a tag the app cannot
    /// order is a stated refusal rather than a guess at "newer".
    func testATagThatIsNotAVersionIsRefusedWithItsReason() async {
        let stub = StubFeed(body: feed(tag: "nightly"))
        let model = makeModel(feed: stub)

        await model.check()

        guard case .withheld(let reason) = model.phase else {
            return XCTFail("expected a refusal, got \(model.phase)")
        }
        XCTAssertTrue(reason.contains("nightly"), reason)
        XCTAssertTrue(reason.contains("not a version this app can compare"), reason)
        XCTAssertEqual(model.summary, reason)
        XCTAssertEqual(model.statusText, "No update")
        XCTAssertEqual(model.statusTone, .neutral)
        XCTAssertNil(model.offer)
    }

    // MARK: - Failure

    func testAnUnreachableFeedIsOneLineAndIsNotRecordedAsASuccess() async {
        let stub = StubFeed(failure: .transport("No internet connection"))
        let model = makeModel(feed: stub)

        await model.check()

        XCTAssertEqual(model.phase, .failed("No internet connection"))
        XCTAssertEqual(model.summary, "No internet connection")
        XCTAssertEqual(model.statusText, "Not checked")
        XCTAssertEqual(model.statusTone, .neutral)
        XCTAssertNil(model.lastChecked, "a failed check must not be remembered as a check")
        XCTAssertNil(model.offer)
    }

    func testAnOverlongReplyIsReportedAsTooLarge() async {
        let stub = StubFeed(failure: .tooLarge(bytes: 2_097_152, limit: 524_288))
        let model = makeModel(feed: stub)

        await model.check()

        XCTAssertEqual(model.phase, .failed("The update feed's reply is 2048 KB, over the 512 KB limit"))
        XCTAssertNil(model.lastChecked)
    }

    func testABuildThatDoesNotSayItsVersionRefusesRatherThanGuessing() async {
        let stub = StubFeed(body: feed(tag: "v2.1.0", assets: installable("2.1.0")))
        let model = makeModel(feed: stub, running: nil)

        await model.check()

        guard case .failed(let reason) = model.phase else {
            return XCTFail("expected a refusal, got \(model.phase)")
        }
        XCTAssertTrue(reason.contains("nothing to compare"), reason)
        XCTAssertEqual(stub.requestCount, 0, "there is nothing to ask about")
    }

    // MARK: - Where the request runs

    /// The transport waits on a semaphore around a socket, so on the main actor
    /// it would freeze the window for as long as the request takes. This is the
    /// whole reason `check()` hands the work to a detached task.
    func testTheRequestDoesNotRunOnTheMainActor() async {
        let stub = StubFeed(body: feed(tag: "v2.0.0"))
        let model = makeModel(feed: stub)

        await model.check()

        XCTAssertEqual(stub.requestCount, 1)
        XCTAssertFalse(stub.ranOnMainThread,
                       "the update request must not run on the main actor")
    }

    /// A second press while the first check is in flight is ignored rather than
    /// queued — and, importantly, the first one still finishes.
    func testASecondCheckWhileOneIsInFlightIsIgnored() async {
        let entered = expectation(description: "the transport was entered")
        let release = DispatchSemaphore(value: 0)
        let stub = StubFeed(body: feed(tag: "v2.1.0", assets: installable("2.1.0")),
                            gate: (entered, release))
        let model = makeModel(feed: stub)

        let first = Task { await model.check() }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertTrue(model.isChecking)

        await model.check()
        XCTAssertEqual(stub.requestCount, 1, "the second press must not become a second request")

        release.signal()
        await first.value
        XCTAssertEqual(model.offer?.version, ReleaseVersion("2.1.0"))
    }

    // MARK: - The launch gate

    func testTheLaunchCheckAsksNothingWhenItIsSwitchedOff() async {
        let stub = StubFeed(body: feed(tag: "v2.1.0", assets: installable("2.1.0")))
        let model = makeModel(feed: stub)

        await model.checkIfEnabled(false)

        XCTAssertEqual(stub.requestCount, 0)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.lastChecked)
        XCTAssertEqual(model.statusText, "Not checked")
    }

    func testTheLaunchCheckAsksWhenItIsSwitchedOn() async {
        let stub = StubFeed(body: feed(tag: "v2.1.0", assets: installable("2.1.0")))
        let model = makeModel(feed: stub)

        await model.checkIfEnabled(true)

        XCTAssertEqual(stub.requestCount, 1)
        XCTAssertEqual(model.offer?.version, ReleaseVersion("2.1.0"))
    }

    // MARK: - House style

    /// Everything the pane and the status-item row print comes from these two
    /// strings, so they are held to the pane's shape: a pill that does not wrap
    /// and a caption that is one line.
    func testThePillWordAndTheSummaryLineStayShort() async {
        let cases: [(StubFeed, ReleaseVersion?)] = [
            (StubFeed(body: feed(tag: "v2.0.0")), ReleaseVersion("2.0.0")),
            (StubFeed(body: feed(tag: "v2.1.0", assets: installable("2.1.0"))), ReleaseVersion("2.0.0")),
            (StubFeed(body: feed(tag: "v2.1.0")), ReleaseVersion("2.0.0")),
            (StubFeed(body: feed(tag: "nightly")), ReleaseVersion("2.0.0")),
            (StubFeed(failure: .httpStatus(404)), ReleaseVersion("2.0.0")),
            (StubFeed(body: feed(tag: "v2.0.0")), nil),
        ]
        for (stub, running) in cases {
            let model = makeModel(feed: stub, running: running)
            await model.check()
            XCTAssertLessThanOrEqual(model.statusText.count, 12, model.statusText)
            XCTAssertFalse(model.statusText.contains("\n"), model.statusText)
            XCTAssertLessThanOrEqual(model.summary.count, 120, model.summary)
            XCTAssertFalse(model.summary.contains("\n"), model.summary)
            XCTAssertFalse(model.summary.contains("Optional("), model.summary)
        }
    }

    func testAFreshModelHasNotAskedAnythingYet() {
        let model = makeModel(feed: StubFeed())

        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isChecking)
        XCTAssertNil(model.offer)
        XCTAssertNil(model.lastChecked)
        XCTAssertEqual(model.checkedText, "Never checked")
        XCTAssertEqual(model.statusText, "Not checked")
        XCTAssertEqual(model.statusTone, .neutral)
        XCTAssertEqual(model.summary, "This build has not asked GitHub yet")
    }
}

// MARK: - Transport stub

/// Answers with a canned body, a canned failure, or a gate that parks the call
/// until the test lets it go — which is the only way to prove that a second
/// press while the first is in flight is ignored.
private final class StubFeed: UpdateFeedTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: String?
    private let failure: UpdateFeedError?
    private let gate: (entered: XCTestExpectation, release: DispatchSemaphore)?
    private var requests = 0
    private var onMainThread = false

    init(body: String? = nil,
         failure: UpdateFeedError? = nil,
         gate: (entered: XCTestExpectation, release: DispatchSemaphore)? = nil) {
        self.body = body
        self.failure = failure
        self.gate = gate
    }

    func get(_ url: URL) throws -> (data: Data, finalURL: URL?) {
        lock.lock()
        requests += 1
        onMainThread = Thread.isMainThread
        lock.unlock()

        if let gate {
            gate.entered.fulfill()
            _ = gate.release.wait(timeout: .now() + 10)
        }
        if let failure { throw failure }
        return (Data((body ?? "").utf8), url)
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var ranOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return onMainThread
    }
}
