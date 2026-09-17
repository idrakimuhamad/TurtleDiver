import XCTest
@testable import TurtleDiverSystem

/// The release feed, judged offline.
///
/// Every test here is deterministic and none reaches GitHub: the transport is a
/// stub, and the feed's own shape is a canned body. The three answers the check
/// can give — up to date, an offer, a refusal with a reason — are the whole
/// contract, so what is pinned here is mostly the *refusals*: an unparsable tag,
/// a draft, and a release whose installer is named for a different version are
/// all cases where a guess would be worse than saying nothing.
final class UpdateFeedTests: XCTestCase {

    // MARK: - Version parsing

    func testAPlainOrVPrefixedVersionParses() {
        XCTAssertEqual(ReleaseVersion("2.1.0")?.fields, [2, 1, 0])
        XCTAssertEqual(ReleaseVersion("v2.1.0")?.fields, [2, 1, 0])
        XCTAssertEqual(ReleaseVersion("V2.1.0")?.fields, [2, 1, 0])
        XCTAssertEqual(ReleaseVersion("1.1.0")?.fields, [1, 1, 0])
        XCTAssertEqual(ReleaseVersion("2")?.fields, [2])
        XCTAssertEqual(ReleaseVersion("2.1.0.1")?.fields, [2, 1, 0, 1])
        XCTAssertEqual(ReleaseVersion(" 2.1.0\n")?.fields, [2, 1, 0])
    }

    func testATagThatIsNotAVersionDoesNotParse() {
        for text in ["", "v", "V", "nightly", "latest", "2.x", "2..1", ".2", "2.",
                     "2.1.0-beta.1", "-1.2", "+1.2", "vv2.1.0", "2.1.0 (9)"] {
            XCTAssertNil(ReleaseVersion(text), "\(text) should not parse as a version")
        }
    }

    func testAVersionFieldWithMoreDigitsThanAnIntIsRefused() {
        XCTAssertNil(ReleaseVersion("99999999999999999999999.0"))
    }

    func testVersionsCompareNumericallyRatherThanAsText() {
        XCTAssertTrue(ReleaseVersion("2.10.0")! > ReleaseVersion("2.9.0")!)
        XCTAssertTrue(ReleaseVersion("3.0.0")! > ReleaseVersion("2.99.99")!)
        XCTAssertTrue(ReleaseVersion("2.0.1")! > ReleaseVersion("2.0.0")!)
        XCTAssertTrue(ReleaseVersion("v1.2.0")! > ReleaseVersion("1.1.0")!)
    }

    func testAShorterVersionIsPaddedRatherThanSorted() {
        XCTAssertEqual(ReleaseVersion("2.0"), ReleaseVersion("2.0.0"))
        XCTAssertEqual(ReleaseVersion("2"), ReleaseVersion("2.0.0.0"))
        XCTAssertFalse(ReleaseVersion("2.0")! < ReleaseVersion("2.0.0")!)
        XCTAssertFalse(ReleaseVersion("2.0.0")! < ReleaseVersion("2.0")!)
        XCTAssertTrue(ReleaseVersion("2.0")! < ReleaseVersion("2.0.1")!)
    }

    func testSortingARangeOfTagsGivesTheReleaseOrder() {
        let tags = ["v1.1.0", "v2.0.0", "1.0.0", "v2.0.0", "v1.10.0", "v2.10.1", "v2.9.0"]
        let sorted = tags.compactMap(ReleaseVersion.init).sorted().map(\.description)
        XCTAssertEqual(sorted, ["1.0.0", "1.1.0", "1.10.0", "2.0.0", "2.0.0", "2.9.0", "2.10.1"])
    }

    func testTheDescriptionKeepsTheFieldsAsWritten() {
        XCTAssertEqual(ReleaseVersion("v2.10.0")?.description, "2.10.0")
        XCTAssertEqual(ReleaseVersion("2.0")?.description, "2.0")
        XCTAssertEqual(ReleaseVersion("2")?.description, "2")
    }

    // MARK: - Decoding

    func testAReleaseDecodesTheFieldsTheAppUses() throws {
        let release = try UpdateFeed.release(fromJSON: Data(feed(
            tag: "v2.1.0",
            page: "https://example.com/releases/tag/v2.1.0",
            assets: [
                ("TurtleDiver-2.1.0.dmg", "https://example.com/dl/TurtleDiver-2.1.0.dmg", 5_786_026,
                 "sha256:aa11bb22"),
                ("TurtleDiver-2.1.0.sha256", "https://example.com/dl/TurtleDiver-2.1.0.sha256", 176, nil),
                ("TurtleDiver-2.1.0.pkg", "https://example.com/dl/TurtleDiver-2.1.0.pkg", 5_746_571, nil),
            ]).utf8))

        XCTAssertEqual(release.tag, "v2.1.0")
        XCTAssertEqual(release.version, ReleaseVersion("2.1.0"))
        XCTAssertEqual(release.pageURL?.absoluteString, "https://example.com/releases/tag/v2.1.0")
        XCTAssertFalse(release.isDraft)
        XCTAssertFalse(release.isPrerelease)
        XCTAssertEqual(release.assets.map(\.name),
                       ["TurtleDiver-2.1.0.dmg", "TurtleDiver-2.1.0.sha256", "TurtleDiver-2.1.0.pkg"])
        XCTAssertEqual(release.assets.first?.byteCount, 5_786_026)
        // The API's own digest is kept, and read back as bare hex.
        XCTAssertEqual(release.assets.first?.sha256, "aa11bb22")
        XCTAssertNil(release.assets.last?.sha256)
    }

    func testADigestThatIsNotSHA256IsNotPresentedAsOne() throws {
        let release = try UpdateFeed.release(fromJSON: Data(feed(
            tag: "v2.1.0",
            assets: [("TurtleDiver-2.1.0.dmg", "https://example.com/dl/a.dmg", nil, "md5:deadbeef")]).utf8))
        XCTAssertEqual(release.assets.first?.digest, "md5:deadbeef")
        XCTAssertNil(release.assets.first?.sha256)
    }

    func testAReleaseWithNoAssetsDecodes() throws {
        let release = try UpdateFeed.release(fromJSON: Data(#"{"tag_name":"v2.1.0"}"#.utf8))
        XCTAssertEqual(release.version, ReleaseVersion("2.1.0"))
        XCTAssertTrue(release.assets.isEmpty)
        XCTAssertNil(release.pageURL)
    }

    func testAnAssetAddressThatIsNotHTTPSIsDroppedRatherThanOffered() throws {
        // Foundation parses almost anything — `URL(string: "not a url")` becomes
        // the relative URL `not%20a%20url` — so an address is only kept when it
        // is absolute and secure. Otherwise the app would offer a download it
        // cannot make over a channel it does not trust.
        let json = """
        {"tag_name":"v2.1.0","assets":[
          {"name":"TurtleDiver-2.1.0.dmg","browser_download_url":"http://example.com/a.dmg"},
          {"name":"TurtleDiver-2.1.0.pkg","browser_download_url":"not a url"},
          {"name":"TurtleDiver-2.1.0.sha256","browser_download_url":"https://example.com/a.sha256"}
        ]}
        """
        let release = try UpdateFeed.release(fromJSON: Data(json.utf8))
        XCTAssertEqual(release.assets.map(\.name), ["TurtleDiver-2.1.0.sha256"])

        // And the decision that follows is an offer with nothing to download,
        // not an offer of an insecure download.
        guard case .available(let offer) = UpdateFeed.decide(
            running: ReleaseVersion("2.0.0")!, release: release) else {
            return XCTFail("expected an offer")
        }
        XCTAssertFalse(offer.canInstall)
        XCTAssertEqual(offer.withheldReason, "That release has no disk image this app will download")
    }

    func testAFeedThatChangedShapeIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(try UpdateFeed.release(fromJSON: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError,
                           .malformed("The update feed's reply was not in the expected shape"))
        }
        XCTAssertThrowsError(try UpdateFeed.release(fromJSON: Data("{}".utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError,
                           .malformed("The update feed's reply was not in the expected shape"))
        }
        XCTAssertThrowsError(try UpdateFeed.release(fromJSON: Data(#"{"tag_name":""}"#.utf8))) { error in
            XCTAssertEqual(error as? UpdateFeedError,
                           .malformed("The update feed's reply carried no version tag"))
        }
    }

    func testTheFeedAddressIsHTTPS() throws {
        let url = try UpdateFeed.latestReleaseURL()
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.github.com")
        // The `latest` endpoint skips drafts and prereleases by definition, which
        // is why no prerelease filter exists anywhere in this file.
        XCTAssertTrue(url.path.hasSuffix("/releases/latest"), url.path)
    }

    func testTheInstallerAndChecksumNamesAreTheOnesPublishScriptWrites() {
        let version = ReleaseVersion("2.0.0")!
        XCTAssertEqual(UpdateFeed.installerName(for: version), "TurtleDiver-2.0.0.dmg")
        // Beside the installer, not appended to it.
        XCTAssertEqual(UpdateFeed.checksumName(for: version), "TurtleDiver-2.0.0.sha256")
    }

    // MARK: - The decision

    func testTheSameVersionOrAnOlderOneIsUpToDate() {
        let running = ReleaseVersion("2.0.0")!
        XCTAssertEqual(UpdateFeed.decide(running: running, release: release(tag: "v2.0.0")),
                       .upToDate(running: running))
        XCTAssertEqual(UpdateFeed.decide(running: running, release: release(tag: "v1.9.0")),
                       .upToDate(running: running))
    }

    func testARunningVersionAheadOfTheFeedIsStillUpToDate() {
        // A pre-release build or a hand-built bundle can be ahead; the feed
        // having nothing newer is the answer, not an offer of an older release.
        let running = ReleaseVersion("3.0.0")!
        XCTAssertEqual(UpdateFeed.decide(running: running, release: release(tag: "v2.9.0")),
                       .upToDate(running: running))
    }

    func testANewerReleaseWithItsInstallerIsOffered() throws {
        let running = ReleaseVersion("2.0.0")!
        let decision = UpdateFeed.decide(running: running, release: release(
            tag: "v2.1.0",
            page: "https://example.com/releases/tag/v2.1.0",
            assets: [
                ("TurtleDiver-2.1.0.dmg", "https://example.com/dl/TurtleDiver-2.1.0.dmg", 5_786_026,
                 "sha256:aa11bb22"),
                ("TurtleDiver-2.1.0.sha256", "https://example.com/dl/TurtleDiver-2.1.0.sha256", 176, nil),
            ]))

        guard case .available(let offer) = decision else {
            return XCTFail("expected an offer, got \(decision)")
        }
        XCTAssertEqual(offer.version, ReleaseVersion("2.1.0"))
        XCTAssertEqual(offer.installer?.url.absoluteString, "https://example.com/dl/TurtleDiver-2.1.0.dmg")
        XCTAssertEqual(offer.installer?.sha256, "aa11bb22")
        XCTAssertEqual(offer.checksum?.name, "TurtleDiver-2.1.0.sha256")
        XCTAssertEqual(offer.pageURL?.absoluteString, "https://example.com/releases/tag/v2.1.0")
        XCTAssertTrue(offer.canInstall)
        XCTAssertNil(offer.withheldReason)
    }

    func testAChecksumNamedLikeTheInstallerIsNotAcceptedAsTheChecksum() throws {
        // `TurtleDiver-2.1.0.dmg.sha256` is a plausible-looking name that
        // publish.sh does not write, and accepting it would silently disable the
        // download's checksum gate.
        let decision = UpdateFeed.decide(running: ReleaseVersion("2.0.0")!, release: release(
            tag: "v2.1.0",
            assets: [
                ("TurtleDiver-2.1.0.dmg", "https://example.com/dl/a.dmg", nil, nil),
                ("TurtleDiver-2.1.0.dmg.sha256", "https://example.com/dl/a.dmg.sha256", nil, nil),
            ]))
        guard case .available(let offer) = decision else {
            return XCTFail("expected an offer, got \(decision)")
        }
        XCTAssertNotNil(offer.installer)
        XCTAssertNil(offer.checksum)
    }

    func testANewerReleaseWithNoDiskImageIsReportedButNotInstallable() {
        let decision = UpdateFeed.decide(running: ReleaseVersion("2.0.0")!, release: release(
            tag: "v2.1.0",
            assets: [("TurtleDiver-2.1.0.pkg", "https://example.com/dl/a.pkg", nil, nil)]))

        guard case .available(let offer) = decision else {
            return XCTFail("expected an offer, got \(decision)")
        }
        XCTAssertEqual(offer.version, ReleaseVersion("2.1.0"))
        XCTAssertFalse(offer.canInstall)
        XCTAssertEqual(offer.withheldReason, "That release has no disk image this app will download")
    }

    func testAnInstallerNamedForAnotherVersionIsNotDownloaded() {
        let decision = UpdateFeed.decide(running: ReleaseVersion("2.0.0")!, release: release(
            tag: "v2.1.0",
            assets: [("TurtleDiver-2.2.0.dmg", "https://example.com/dl/a.dmg", nil, nil)]))

        guard case .available(let offer) = decision else {
            return XCTFail("expected an offer, got \(decision)")
        }
        XCTAssertFalse(offer.canInstall)
        XCTAssertEqual(offer.withheldReason,
                       "That release's disk image is named TurtleDiver-2.2.0.dmg rather than "
                       + "TurtleDiver-2.1.0.dmg, so the app will not download it")
    }

    func testAnUnparsableTagIsReportedRatherThanGuessed() {
        let decision = UpdateFeed.decide(running: ReleaseVersion("2.0.0")!, release: release(tag: "nightly"))
        XCTAssertEqual(decision, .withheld(
            reason: "The newest release is tagged “nightly”, which is not a version this app can compare"))
    }

    func testADraftIsNeverOffered() {
        let decision = UpdateFeed.decide(running: ReleaseVersion("2.0.0")!, release: release(
            tag: "v9.0.0",
            draft: true,
            assets: [("TurtleDiver-9.0.0.dmg", "https://example.com/dl/a.dmg", nil, nil)]))
        XCTAssertEqual(decision, .withheld(reason: "The newest release is still a draft"))
    }

    // MARK: - The running version

    func testTheRunningVersionComesFromTheBundleString() {
        XCTAssertEqual(UpdateFeed.runningVersion(fromShortVersionString: "2.0.0"),
                       ReleaseVersion("2.0.0"))
        XCTAssertEqual(UpdateFeed.runningVersion(fromShortVersionString: "v2.0.0"),
                       ReleaseVersion("2.0.0"))
        XCTAssertNil(UpdateFeed.runningVersion(fromShortVersionString: nil))
        XCTAssertNil(UpdateFeed.runningVersion(fromShortVersionString: ""))
        XCTAssertNil(UpdateFeed.runningVersion(fromShortVersionString: "unknown"))
    }

    // MARK: - The checker

    func testTheCheckerJudgesWhatTheFeedReturned() throws {
        let feed = StubFeed(body: self.feed(tag: "v2.1.0", assets: [
            ("TurtleDiver-2.1.0.dmg", "https://example.com/dl/a.dmg", 10, "sha256:aa11bb22"),
        ]))
        let decision = try UpdateChecker(transport: feed).check(running: ReleaseVersion("2.0.0")!)

        guard case .available(let offer) = decision else {
            return XCTFail("expected an offer, got \(decision)")
        }
        XCTAssertEqual(offer.installer?.sha256, "aa11bb22")
        XCTAssertEqual(feed.requested, [try UpdateFeed.latestReleaseURL()])
    }

    func testTheCheckerPassesAFailureOnRatherThanInventingAnAnswer() {
        let feed = StubFeed(error: UpdateFeedError.httpStatus(403))
        XCTAssertThrowsError(try UpdateChecker(transport: feed).check(running: ReleaseVersion("2.0.0")!)) { error in
            XCTAssertEqual(error as? UpdateFeedError, .httpStatus(403))
        }
    }

    func testTheCheckerRefusesAnUnreadableReply() {
        let feed = StubFeed(body: "<html>not a release</html>")
        XCTAssertThrowsError(try UpdateChecker(transport: feed).check(running: ReleaseVersion("2.0.0")!)) { error in
            XCTAssertEqual(error as? UpdateFeedError,
                           .malformed("The update feed's reply was not in the expected shape"))
        }
    }

    func testTheTransportRefusesAFeedThatIsNotHTTPS() {
        // The scheme guard runs before any request is built, so this proves both
        // the refusal and that no connection is attempted.
        let transport = URLSessionUpdateFeedTransport()
        XCTAssertThrowsError(try transport.get(URL(string: "http://api.github.com/repos/x/y")!)) { error in
            XCTAssertEqual(error as? UpdateFeedError,
                           .insecureURL("http://api.github.com/repos/x/y"))
        }
    }

    // MARK: - The sentences

    func testEveryRefusalReadsAsOneShortLine() {
        let errors: [UpdateFeedError] = [
            .insecureURL("http://example.com"),
            .redirectedToInsecureURL("http://example.com"),
            .tooLarge(bytes: 2_097_152, limit: 524_288),
            .httpStatus(404),
            .httpStatus(403),
            .malformed("The update feed's reply was not in the expected shape"),
            .transport("No internet connection"),
        ]
        for error in errors {
            guard let sentence = error.errorDescription else {
                return XCTFail("\(error) has no description")
            }
            XCTAssertFalse(sentence.isEmpty, "\(error) describes itself as nothing")
            XCTAssertFalse(sentence.contains("\n"), "\(error) is not one line: \(sentence)")
            // A raw `Optional(…)` or a bridged `NSError` dump in a settings row is
            // the failure this file exists to prevent.
            XCTAssertFalse(sentence.contains("Optional("), "\(error) leaks an optional: \(sentence)")
            XCTAssertLessThanOrEqual(sentence.count, 120, "\(error) will not fit a row: \(sentence)")
        }
    }

    func testARateLimitIsExplainedRatherThanJustNumbered() {
        XCTAssertEqual(UpdateFeedError.httpStatus(403).errorDescription,
                       "The update feed answered HTTP 403, which is how GitHub reports "
                       + "its unauthenticated rate limit")
        XCTAssertEqual(UpdateFeedError.httpStatus(429).errorDescription,
                       "The update feed answered HTTP 429, which is how GitHub reports "
                       + "its unauthenticated rate limit")
        XCTAssertEqual(UpdateFeedError.httpStatus(500).errorDescription,
                       "The update feed answered HTTP 500")
    }

    func testAFailureNeverPrintsTheBridgedFoundationError() {
        // `URLError` arrives as an `NSError` whose `UserInfo` holds the whole
        // CFStream dictionary and the session-task UUID. None of that may reach a
        // settings row, so the codes with a known meaning get their own sentence.
        XCTAssertEqual(UpdateFeedError.describe(URLError(.cannotFindHost)),
                       "Could not find the update feed's host")
        XCTAssertEqual(UpdateFeedError.describe(URLError(.notConnectedToInternet)),
                       "No internet connection")
        XCTAssertEqual(UpdateFeedError.describe(URLError(.timedOut)),
                       "The update feed took too long to answer")
        XCTAssertEqual(UpdateFeedError.describe(URLError(.secureConnectionFailed)),
                       "Could not establish a secure connection to the update feed")

        let sentence = UpdateFeedError.describe(URLError(.cannotLoadFromNetwork))
        XCTAssertFalse(sentence.contains("_kCFStreamErrorDomainKey"), sentence)
        XCTAssertFalse(sentence.contains("NSError"), sentence)
        XCTAssertFalse(sentence.contains("Optional("), sentence)
    }

    // MARK: - Fixtures

    /// A release payload in the shape GitHub answers with, with the keys this app
    /// reads. Everything unknown to the app is deliberately absent: the decoder
    /// must not need it.
    private func feed(tag: String,
                      page: String? = nil,
                      draft: Bool = false,
                      prerelease: Bool = false,
                      assets: [(name: String, url: String, size: Int?, digest: String?)] = []) -> String {
        let assetJSON = assets.map { asset -> String in
            let size = asset.size.map(String.init) ?? "null"
            let digest = asset.digest.map { "\"\($0)\"" } ?? "null"
            return """
            {"name":"\(asset.name)","browser_download_url":"\(asset.url)","size":\(size),"digest":\(digest)}
            """
        }.joined(separator: ",")
        let pageJSON = page.map { "\"\($0)\"" } ?? "null"
        return """
        {"tag_name":"\(tag)","html_url":\(pageJSON),"draft":\(draft),"prerelease":\(prerelease),\
        "assets":[\(assetJSON)]}
        """
    }

    private func release(tag: String,
                         page: String? = nil,
                         draft: Bool = false,
                         prerelease: Bool = false,
                         assets: [(name: String, url: String, size: Int?, digest: String?)] = []) -> UpdateRelease {
        // Built through the decoder rather than by hand, so a test asserting on
        // the decision cannot pass against a release the feed could not produce.
        (try? UpdateFeed.release(fromJSON: Data(feed(tag: tag, page: page, draft: draft,
                                                    prerelease: prerelease, assets: assets).utf8)))
            ?? UpdateRelease(tag: tag, version: ReleaseVersion(tag))
    }

    private final class StubFeed: UpdateFeedTransport, @unchecked Sendable {
        private let body: String
        private let error: Error?
        private(set) var requested: [URL] = []

        init(body: String = "", error: Error? = nil) {
            self.body = body
            self.error = error
        }

        func get(_ url: URL) throws -> (data: Data, finalURL: URL?) {
            requested.append(url)
            if let error { throw error }
            return (Data(body.utf8), url)
        }
    }
}
