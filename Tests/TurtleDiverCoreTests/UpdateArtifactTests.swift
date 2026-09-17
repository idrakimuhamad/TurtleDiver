import CryptoKit
import XCTest
@testable import TurtleDiverSystem

/// The download and the two gates that decide it offline, judged without a
/// network and without a disk image.
///
/// What matters here is not the happy path — that is one test — but the
/// refusals. Every gate in `UpdateDownloader` has a case that must not be
/// talked around: a file named for a different version, a plain-http address,
/// a redirect to one, bytes that disagree with the published digest, bytes that
/// disagree with GitHub's own digest, a release that published nothing to check
/// against, and a checksum file holding no digest. The transport is a stub, so
/// a failure in this file is always the app's own logic.
final class UpdateArtifactTests: XCTestCase {

    /// The bytes every fixture downloads, and the digest of exactly those bytes.
    /// The digest is the real SHA-256 of "hello\n" — computed outside this app
    /// (`shasum -a 256`) so the test cannot agree with a wrong implementation.
    private let imageBytes = Data("hello\n".utf8)
    private let imageDigest = "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"

    // MARK: - The digest of a file

    func testTheDigestOfAKnownFileIsTheOneEveryToolAgreesWith() throws {
        let file = try temporaryFile(containing: imageBytes)
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: file), imageDigest)
    }

    func testTheDigestOfAFileLargerThanOneReadIsStillCorrect() throws {
        // The chunked read must not stop at the first buffer. Ten times the
        // known bytes crosses the 1 MB boundary, and the expected value is the
        // digest of the whole thing computed in one piece.
        var whole = Data()
        for _ in 0..<200_000 { whole.append(imageBytes) }
        let file = try temporaryFile(containing: whole)
        XCTAssertGreaterThan(whole.count, 1 << 20)
        XCTAssertEqual(try FileDigest.sha256(ofFileAt: file),
                       FileDigest.hex(SHA256.hash(data: whole)))
    }

    // MARK: - Reading a published checksum

    func testAPublishedChecksumIsReadFromShasumsOwnOutput() {
        XCTAssertEqual(FileDigest.published(in: "\(imageDigest)  TurtleDiver-2.1.0.dmg\n"),
                       imageDigest)
    }

    func testABareDigestIsAcceptedAndUppercaseIsNormalised() {
        XCTAssertEqual(FileDigest.published(in: imageDigest), imageDigest)
        XCTAssertEqual(FileDigest.published(in: imageDigest.uppercased()), imageDigest)
    }

    func testAChecksumFileWithACarriageReturnIsStillReadable() {
        XCTAssertEqual(FileDigest.published(in: "\(imageDigest)  TurtleDiver-2.1.0.dmg\r\n"),
                       imageDigest)
    }

    func testAChecksumFileThatHoldsNoDigestIsRefused() {
        XCTAssertNil(FileDigest.published(in: ""))
        XCTAssertNil(FileDigest.published(in: "not a checksum at all\n"))
        // 63 characters: the right alphabet, the wrong length. Guessing here
        // would mean accepting a digest no tool would produce.
        XCTAssertNil(FileDigest.published(in: String(imageDigest.dropLast())))
        // 64 characters, one of them not hexadecimal.
        XCTAssertNil(FileDigest.published(in: String(imageDigest.dropLast()) + "z"))
    }

    func testAFullWidthHexStringIsNotADigest() {
        // `isHexDigit` is true for the full-width forms, so the length and the
        // alphabet alone would let this through. Nothing else here would.
        let fullWidth = String(repeating: "\u{FF21}", count: 64)
        XCTAssertFalse(FileDigest.isHexDigest(fullWidth))
        XCTAssertNil(FileDigest.published(in: fullWidth))
    }

    // MARK: - The size limit

    func testTheSizeLimitIsADecisionThatCanBeAskedDirectly() {
        XCTAssertNil(UpdateArtifactLimit.refusal(size: 5_000_000, limit: 256 * 1024 * 1024))
        XCTAssertNil(UpdateArtifactLimit.refusal(size: 64, limit: 64))
        guard case .tooLarge(let bytes, let limit)? =
            UpdateArtifactLimit.refusal(size: 65, limit: 64) else {
            return XCTFail("a file one byte over the limit has to be refused")
        }
        XCTAssertEqual(bytes, 65)
        XCTAssertEqual(limit, 64)
    }

    func testAFileOverTheInjectedLimitIsRefusedAndNotKept() throws {
        let directory = temporaryDirectory()
        let downloader = UpdateDownloader(files: StubFileTransport(body: Data(repeating: 0x41,
                                                                             count: 100)),
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: directory,
                                         maxBytes: 64)
        XCTAssertThrowsError(try downloader.fetch(offer())) { error in
            guard case .tooLarge(let bytes, let limit)? = error as? UpdateArtifactError else {
                return XCTFail("expected a size refusal, got \(error)")
            }
            XCTAssertEqual(bytes, 100)
            XCTAssertEqual(limit, 64)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL(in: directory).path),
                       "an oversized download must not be left in the app's directory")
    }

    // MARK: - The happy path

    func testAFileThatIsWhatTheReleasePublishedIsAccepted() throws {
        let directory = temporaryDirectory()
        let file = StubFileTransport(body: imageBytes)
        let downloader = UpdateDownloader(files: file,
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: directory,
                                         maxBytes: 1024)
        let downloaded = try downloader.fetch(offer(byteCount: imageBytes.count,
                                                   apiDigest: imageDigest))
        XCTAssertEqual(downloaded.version, ReleaseVersion("2.1.0"))
        XCTAssertEqual(downloaded.byteCount, imageBytes.count)
        XCTAssertEqual(downloaded.sha256, imageDigest)
        XCTAssertEqual(downloaded.publishedChecksum, imageDigest)
        XCTAssertEqual(downloaded.apiDigest, imageDigest)
        XCTAssertEqual(downloaded.imageURL, imageURL(in: directory))
        XCTAssertEqual(try Data(contentsOf: downloaded.imageURL), imageBytes)
        XCTAssertEqual(file.requestedURLs.map(\.lastPathComponent),
                       ["TurtleDiver-2.1.0.dmg"])
    }

    func testTheReleaseMayPublishOnlyOneOfTheTwoDigests() throws {
        // The API's digest alone is enough; so is the published file alone.
        let onlyAPI = (offer: offer(apiDigest: imageDigest, publishedChecksum: false), body: "")
        let onlyPublished = (offer: offer(), body: checksumFile())
        for fixture in [onlyAPI, onlyPublished] {
            let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                             feed: StubChecksumFeed(body: fixture.body),
                                             directory: temporaryDirectory(),
                                             maxBytes: 1024)
            let downloaded = try downloader.fetch(fixture.offer)
            XCTAssertEqual(downloaded.sha256, imageDigest)
        }
    }

    // MARK: - Gate 1: where the file comes from

    func testAnImageNamedForAnotherVersionIsRefusedBeforeAnyDownload() throws {
        let file = StubFileTransport(body: imageBytes)
        let downloader = UpdateDownloader(files: file,
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: temporaryDirectory())
        let wrong = offer(imageName: "TurtleDiver-9.9.9.dmg")
        XCTAssertThrowsError(try downloader.fetch(wrong)) { error in
            guard case .wrongName(let expected, let actual)? = error as? UpdateArtifactError else {
                return XCTFail("expected a name refusal, got \(error)")
            }
            XCTAssertEqual(expected, "TurtleDiver-2.1.0.dmg")
            XCTAssertEqual(actual, "TurtleDiver-9.9.9.dmg")
        }
        // The point of deciding provenance first: nothing was fetched at all.
        XCTAssertTrue(file.requestedURLs.isEmpty,
                      "a file named for another version must not be downloaded, even to reject it")
    }

    func testAPlainHTTPAddressIsNeverDownloaded() throws {
        let file = StubFileTransport(body: imageBytes)
        let downloader = UpdateDownloader(files: file,
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: temporaryDirectory())
        let insecure = offer(imageURL: "http://example.com/TurtleDiver-2.1.0.dmg")
        XCTAssertThrowsError(try downloader.fetch(insecure)) { error in
            guard case .insecureURL? = error as? UpdateArtifactError else {
                return XCTFail("expected an https refusal, got \(error)")
            }
        }
        XCTAssertTrue(file.requestedURLs.isEmpty)
    }

    func testAnAddressWithoutAHostIsRefusedRatherThanParsed() throws {
        // `URL(string:)` is lenient: "not a url" becomes a relative URL with no
        // host. Scheme alone would let that through, so both are checked.
        let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: temporaryDirectory())
        let relative = offer(imageURL: "TurtleDiver-2.1.0.dmg")
        XCTAssertThrowsError(try downloader.fetch(relative)) { error in
            guard case .insecureURL? = error as? UpdateArtifactError else {
                return XCTFail("expected an https refusal, got \(error)")
            }
        }
    }

    func testARedirectToPlainHTTPIsRefusedAfterTheDownload() throws {
        let directory = temporaryDirectory()
        let file = StubFileTransport(body: imageBytes,
                                     finalURL: URL(string: "http://mirror.example.com/x.dmg"))
        let downloader = UpdateDownloader(files: file,
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: directory,
                                         maxBytes: 1024)
        XCTAssertThrowsError(try downloader.fetch(offer())) { error in
            guard case .redirectedToInsecureURL? = error as? UpdateArtifactError else {
                return XCTFail("expected a redirect refusal, got \(error)")
            }
        }
        XCTAssertEqual(file.requestedURLs.count, 1, "the address itself was https; the hop was not")
    }

    // MARK: - Gate 2: the bytes

    func testBytesThatDisagreeWithThePublishedChecksumAreRefused() throws {
        let other = String(repeating: "ab", count: 32)
        let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                         feed: StubChecksumFeed(body: "\(other)  \(imageName)\n"),
                                         directory: temporaryDirectory())
        XCTAssertThrowsError(try downloader.fetch(offer())) { error in
            guard case .checksumMismatch(let source, let expected, let actual)? =
                error as? UpdateArtifactError else {
                return XCTFail("expected a digest refusal, got \(error)")
            }
            XCTAssertEqual(source, "the release's published checksum")
            XCTAssertEqual(expected, other)
            XCTAssertEqual(actual, imageDigest)
        }
    }

    func testBytesThatDisagreeWithTheFeedsOwnDigestAreRefused() throws {
        let other = String(repeating: "cd", count: 32)
        let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: temporaryDirectory())
        XCTAssertThrowsError(try downloader.fetch(offer(apiDigest: other))) { error in
            guard case .checksumMismatch(let source, _, _)? = error as? UpdateArtifactError else {
                return XCTFail("expected a digest refusal, got \(error)")
            }
            XCTAssertEqual(source, "the release feed's digest")
        }
    }

    func testAReleaseThatPublishesNothingToCheckAgainstIsRefused() throws {
        let file = StubFileTransport(body: imageBytes)
        let downloader = UpdateDownloader(files: file,
                                         feed: StubChecksumFeed(body: ""),
                                         directory: temporaryDirectory())
        XCTAssertThrowsError(try downloader.fetch(offer(publishedChecksum: false))) { error in
            guard case .noPublishedChecksum(let name)? = error as? UpdateArtifactError else {
                return XCTFail("expected a refusal, got \(error)")
            }
            XCTAssertEqual(name, imageName, "the refusal has to say which file it could not check")
        }
        XCTAssertTrue(file.requestedURLs.isEmpty,
                      "a release with no digest to check against must not be downloaded")
    }

    func testAChecksumFileWithNoDigestInItIsRefused() throws {
        let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                         feed: StubChecksumFeed(body: "<?xml version=\"1.0\"?>\n"),
                                         directory: temporaryDirectory())
        XCTAssertThrowsError(try downloader.fetch(offer())) { error in
            guard case .malformed? = error as? UpdateArtifactError else {
                return XCTFail("expected a malformed refusal, got \(error)")
            }
        }
    }

    func testTheChecksumIsReadBeforeTheImageIsDownloaded() throws {
        // The order is deliberate: a release that cannot be checked should not
        // cost the user six megabytes to find out. A broken checksum file proves
        // it — the image's transport must never have been called.
        let file = StubFileTransport(body: imageBytes)
        let downloader = UpdateDownloader(files: file,
                                         feed: StubChecksumFeed(body: "no digest here\n"),
                                         directory: temporaryDirectory())
        XCTAssertThrowsError(try downloader.fetch(offer()))
        XCTAssertTrue(file.requestedURLs.isEmpty,
                      "the image is fetched only once there is something to check it against")
    }

    func testAFileWhoseSizeDisagreesWithTheFeedIsRefused() throws {
        let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: temporaryDirectory())
        XCTAssertThrowsError(try downloader.fetch(offer(byteCount: imageBytes.count + 1))) { error in
            guard case .sizeDisagrees(let expected, let actual)? = error as? UpdateArtifactError else {
                return XCTFail("expected a size refusal, got \(error)")
            }
            XCTAssertEqual(expected, imageBytes.count + 1)
            XCTAssertEqual(actual, imageBytes.count)
        }
    }

    // MARK: - Where the file is kept

    func testTheDownloadDirectoryIsCreatedPrivate() throws {
        let directory = temporaryDirectory()
        let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: directory)
        _ = try downloader.fetch(offer())
        let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions]
        XCTAssertEqual(mode as? Int, 0o700, "the directory the update will run from is nobody else's")
    }

    func testAnEarlierDownloadIsNotLeftBehind() throws {
        // The previous release's image has no purpose and six megabytes of it is
        // worth reclaiming. Everything except the file just fetched goes.
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stale = directory.appendingPathComponent("TurtleDiver-2.0.0.dmg")
        try Data("old".utf8).write(to: stale)

        let downloader = UpdateDownloader(files: StubFileTransport(body: imageBytes),
                                         feed: StubChecksumFeed(body: checksumFile()),
                                         directory: directory)
        let downloaded = try downloader.fetch(offer())
        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(kept, [downloaded.imageURL.lastPathComponent])
    }

    func testTheTransportRefusesAnythingThatIsNotHTTPSBeforeItAsksForIt() {
        // The real transport, asked for a plain-http URL: the guard runs before
        // any session is used, so this test never reaches the network.
        let transport = URLSessionUpdateFileTransport(timeout: 1)
        XCTAssertThrowsError(try transport.fetch(URL(string: "http://example.com/x.dmg")!,
                                                 to: temporaryDirectory()
                                                     .appendingPathComponent("x.dmg"))) { error in
            guard case .insecureURL? = error as? UpdateArtifactError else {
                return XCTFail("expected an https refusal, got \(error)")
            }
        }
    }

    func testATransportFailureIsReportedAsASentenceRatherThanACode() {
        let wrapped = UpdateArtifactError.wrap(URLError(.notConnectedToInternet))
        guard case .transport(let sentence) = wrapped else {
            return XCTFail("a network failure has to arrive as a transport refusal")
        }
        XCTAssertEqual(sentence, "No internet connection",
                       "the sentence is the feed's own, not a UserInfo dump")
    }

    // MARK: - Fixtures

    private let imageName = "TurtleDiver-2.1.0.dmg"
    private let checksumName = "TurtleDiver-2.1.0.sha256"

    private func checksumFile() -> String { "\(imageDigest)  \(imageName)\n" }

    private func offer(version: String = "2.1.0",
                       imageName: String? = nil,
                       imageURL: String? = nil,
                       byteCount: Int? = nil,
                       apiDigest: String? = nil,
                       publishedChecksum: Bool = true) -> UpdateOffer {
        let name = imageName ?? "TurtleDiver-\(version).dmg"
        let image = UpdateAsset(name: name,
                                url: URL(string: imageURL
                                    ?? "https://github.com/idrakimuhamad/TurtleDiver/releases/download/v\(version)/\(name)")!,
                                byteCount: byteCount,
                                digest: apiDigest.map { "sha256:\($0)" })
        let checksum = publishedChecksum
            ? UpdateAsset(name: "TurtleDiver-\(version).sha256",
                          url: URL(string: "https://github.com/idrakimuhamad/TurtleDiver/releases/download/v\(version)/TurtleDiver-\(version).sha256")!,
                          byteCount: nil,
                          digest: nil)
            : nil
        return UpdateOffer(version: ReleaseVersion(version)!,
                           tag: "v\(version)",
                           pageURL: nil,
                           installer: image,
                           checksum: checksum)
    }

    private func imageURL(in directory: URL) -> URL {
        directory.appendingPathComponent(imageName)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("turtle-update-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryFile(containing bytes: Data) throws -> URL {
        let url = temporaryDirectory().appendingPathComponent("blob")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try bytes.write(to: url)
        return url
    }

    private final class StubFileTransport: UpdateFileTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let body: Data
        private let finalURL: URL?
        private var requests: [URL] = []

        init(body: Data, finalURL: URL? = nil) {
            self.body = body
            self.finalURL = finalURL
        }

        var requestedURLs: [URL] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }

        func fetch(_ url: URL, to destination: URL) throws -> URL? {
            lock.lock(); requests.append(url); lock.unlock()
            try body.write(to: destination)
            return finalURL ?? url
        }
    }

    private struct StubChecksumFeed: UpdateFeedTransport {
        let body: String

        func get(_ url: URL) throws -> (data: Data, finalURL: URL?) {
            (Data(body.utf8), url)
        }
    }
}
