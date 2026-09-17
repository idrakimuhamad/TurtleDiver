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
                           now: Date = Date(timeIntervalSince1970: 1_000_000),
                           downloader: UpdateDownloader? = nil,
                           installer: (any UpdateInstalling)? = nil) -> UpdateModel {
        UpdateModel(checker: UpdateChecker(transport: stub),
                    // A directory of its own even when the test never downloads:
                    // the app's real one belongs to the user.
                    downloader: downloader ?? UpdateDownloader(directory: temporaryDirectory()),
                    installer: installer ?? StubInstaller(),
                    runningVersion: running,
                    now: { now })
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

    // MARK: - How old the answer is

    /// The age line speaks about the instant it is given, because the pane
    /// hands it a `TimelineView` tick. An accessor that read the clock itself
    /// would pass every test here and still leave the pane frozen.
    func testTheAgeLineSpeaksAboutTheInstantItIsGiven() async {
        let stub = StubFeed(body: feed(tag: "v2.0.0"))
        let model = makeModel(feed: stub)

        await model.check()
        let checkedAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(model.lastChecked, checkedAt)

        XCTAssertEqual(model.checkedText(at: checkedAt.addingTimeInterval(30)), "Checked just now")
        XCTAssertEqual(model.checkedText(at: checkedAt.addingTimeInterval(2 * 60)), "Checked 2 min ago")
        XCTAssertEqual(model.checkedText(at: checkedAt.addingTimeInterval(5 * 60)), "Checked 5 min ago")
        XCTAssertEqual(model.checkedText(at: checkedAt.addingTimeInterval(3 * 3600)), "Checked 3 h ago")
        XCTAssertEqual(model.checkedText(at: checkedAt.addingTimeInterval(50 * 3600)), "Checked 2 days ago")
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
        XCTAssertEqual(model.installPhase, .idle)
        XCTAssertFalse(model.isInstalling)
        XCTAssertNil(model.installStatusText, "nothing has been installed, so there is no pill")
        XCTAssertNil(model.installMessage, "and nothing to say either")
    }

    // MARK: - Installing

    /// The promise this whole feature is built around: installing means quitting,
    /// quitting ends the tunnel, and a connected app therefore never installs.
    /// Nothing is even downloaded — the refusal comes first.
    func testAnInstallIsRefusedWhileTheTunnelIsUp() async {
        let files = StubFiles(body: payload)
        let installer = StubInstaller(answer: .replaced, version: ReleaseVersion("2.1.0")!)
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: installable("2.1.0"))),
                              downloader: downloader(files: files),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: true)

        XCTAssertEqual(model.installPhase,
                       .refused("Disconnect the VPN first: installing quits the app, "
                                + "and quitting ends the tunnel"))
        XCTAssertEqual(model.installStatusText, "Not installed")
        XCTAssertEqual(model.installStatusTone, .attention)
        XCTAssertEqual(files.requestCount, 0, "a refusal must not reach the network")
        XCTAssertEqual(installer.calls, 0)
    }

    /// The second click is what makes the disconnect a decision; this is the path
    /// it takes, and it is the same call with the tunnel state the click implies.
    func testTheDisconnectPathDownloadsAndInstalls() async {
        let files = StubFiles(body: payload)
        let installer = StubInstaller(answer: .replaced, version: ReleaseVersion("2.1.0")!)
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              downloader: downloader(files: files),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: false)

        XCTAssertEqual(model.installPhase, .installed(ReleaseVersion("2.1.0")!))
        XCTAssertEqual(files.requestCount, 1)
        XCTAssertEqual(installer.calls, 1)
    }

    func testAnInstallWithNoOfferSaysSo() async {
        let files = StubFiles(body: payload)
        let model = makeModel(feed: StubFeed(), downloader: downloader(files: files))

        await model.install(isTunnelUp: false)

        XCTAssertEqual(model.installPhase, .refused("There is no release to install"))
        XCTAssertEqual(files.requestCount, 0)
    }

    /// A newer release that carries nothing this app would download keeps its
    /// own explanation, and there is still no install to run.
    func testAReleaseWithNothingToInstallIsRefusedWithItsOwnReason() async {
        let files = StubFiles(body: payload)
        let installer = StubInstaller()
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0")),
                              downloader: downloader(files: files),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: false)

        XCTAssertEqual(model.installPhase,
                       .refused("That release has no disk image this app will download"))
        XCTAssertEqual(files.requestCount, 0)
        XCTAssertEqual(installer.calls, 0)
    }

    func testABuildThatDoesNotSayItsVersionIsNotInstalledOver() async {
        let installer = StubInstaller()
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              running: nil,
                              downloader: downloader(files: StubFiles(body: payload)),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: false)

        guard case .failed(let reason) = model.installPhase else {
            return XCTFail("expected a refusal, got \(model.installPhase)")
        }
        XCTAssertTrue(reason.contains("nothing to install over it"), reason)
        XCTAssertEqual(installer.calls, 0)
    }

    /// The whole verified download, end to end: the real `UpdateDownloader` with
    /// a stubbed transport, so the gate that compares digests is the shipped one.
    func testAVerifiedDownloadIsInstalledAndWaitsForARestart() async {
        let files = StubFiles(body: payload)
        let installer = StubInstaller(answer: .replaced, version: ReleaseVersion("2.1.0")!)
        let directory = temporaryDirectory()
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              downloader: downloader(files: files, directory: directory),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: false)

        XCTAssertEqual(model.installPhase, .installed(ReleaseVersion("2.1.0")!))
        XCTAssertEqual(model.waitingVersion, ReleaseVersion("2.1.0"))
        XCTAssertNil(model.revealedImage, "the app replaced itself, so there is nothing to point at")
        XCTAssertEqual(model.installStatusText, "Ready to restart")
        XCTAssertEqual(model.installStatusTone, .ok)
        XCTAssertFalse(model.isInstalling)
        let message = model.installMessage ?? ""
        XCTAssertTrue(message.contains("takes effect when the app restarts"), message)

        // What the installer was handed is what the gates approved, not merely
        // whatever the transport wrote.
        XCTAssertEqual(installer.lastSeen?.sha256, payloadDigest)
        XCTAssertEqual(installer.lastSeen?.byteCount, payload.count)
        XCTAssertEqual(installer.lastSeen?.version, ReleaseVersion("2.1.0"))
    }

    func testAnAppThatCannotReplaceItselfPointsAtTheVerifiedInstaller() async {
        let files = StubFiles(body: payload)
        let installer = StubInstaller(answer: .revealed, version: ReleaseVersion("2.1.0")!)
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              downloader: downloader(files: files),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: false)

        XCTAssertEqual(model.waitingVersion, nil, "nothing was installed, so there is no restart")
        XCTAssertEqual(model.revealedImage?.lastPathComponent, "TurtleDiver-2.1.0.dmg")
        XCTAssertEqual(model.installStatusText, "Installer ready")
        let message = model.installMessage ?? ""
        XCTAssertTrue(message.contains("Finder"), message)
        XCTAssertTrue(message.contains("TurtleDiver-2.1.0.dmg"), message)
    }

    /// A download that fails a gate never reaches the installer, and the sentence
    /// the interface shows is the gate's own.
    func testADownloadThatFailsAGateIsNeverInstalled() async {
        let files = StubFiles(body: payload)
        let installer = StubInstaller()
        // Every other gate is satisfied, so the digest is the one that answers.
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              downloader: UpdateDownloader(files: files,
                                                          feed: StubChecksum(body: wrongDigestFile),
                                                          directory: temporaryDirectory(),
                                                          maxBytes: 1 << 20),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: false)

        guard case .failed(let reason) = model.installPhase else {
            return XCTFail("expected a failure, got \(model.installPhase)")
        }
        XCTAssertTrue(reason.contains("not the file"), reason)
        XCTAssertEqual(installer.calls, 0)
        XCTAssertEqual(model.installStatusText, "Not installed")
        XCTAssertNil(model.waitingVersion)
        // The check's own answer is untouched by a failed install.
        XCTAssertEqual(model.offer?.version, ReleaseVersion("2.1.0"))
    }

    func testAnInstallerThatRefusesExplainsItself() async {
        let installer = StubInstaller(answer: .refuse(.wrongTeam(expected: "KT7QU923S8",
                                                                 actual: "OTHERTEAM")))
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              downloader: downloader(files: StubFiles(body: payload)),
                              installer: installer)
        await model.check()

        await model.install(isTunnelUp: false)

        guard case .failed(let reason) = model.installPhase else {
            return XCTFail("expected a failure, got \(model.installPhase)")
        }
        XCTAssertTrue(reason.contains("OTHERTEAM"), reason)
        XCTAssertTrue(reason.contains("KT7QU923S8"), reason)
    }

    /// A second press while the first install is running is ignored rather than
    /// queued — a download started twice is two files and two installs.
    func testASecondPressWhileAnInstallIsRunningIsIgnored() async {
        let entered = expectation(description: "the download was entered")
        let release = DispatchSemaphore(value: 0)
        let files = StubFiles(body: payload, gate: (entered, release))
        let installer = StubInstaller(answer: .replaced, version: ReleaseVersion("2.1.0")!)
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              downloader: downloader(files: files),
                              installer: installer)
        await model.check()

        let first = Task { await model.install(isTunnelUp: false) }
        await fulfillment(of: [entered], timeout: 10)
        XCTAssertTrue(model.isInstalling)
        XCTAssertEqual(model.installStatusText, "Downloading")

        await model.install(isTunnelUp: false)
        XCTAssertEqual(files.requestCount, 1, "the second press must not become a second download")

        release.signal()
        await first.value
        XCTAssertEqual(installer.calls, 1)
        XCTAssertEqual(model.installPhase, .installed(ReleaseVersion("2.1.0")!))
    }

    /// The check and the install are two questions with two answers: installing
    /// does not rewrite what the release list said.
    func testTheInstallDoesNotRewriteTheCheck() async {
        let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                              downloader: downloader(files: StubFiles(body: payload)),
                              installer: StubInstaller(answer: .replaced,
                                                       version: ReleaseVersion("2.1.0")!))
        await model.check()
        let checked = model.lastChecked

        await model.install(isTunnelUp: false)

        XCTAssertEqual(model.phase, .available(model.offer!), "still the newest release known")
        XCTAssertEqual(model.lastChecked, checked)
        XCTAssertEqual(model.statusText, "Available")
    }

    /// Everything the pane prints for an install is held to the pane's shape.
    func testTheInstallLinesStayShortAndNeverPrintAnOptional() async {
        let cases: [any UpdateInstalling] = [
            StubInstaller(answer: .replaced, version: ReleaseVersion("2.1.0")!),
            StubInstaller(answer: .revealed, version: ReleaseVersion("2.1.0")!),
            StubInstaller(answer: .refuse(.noAppInImage)),
        ]
        for installer in cases {
            let model = makeModel(feed: StubFeed(body: feed(tag: "v2.1.0", assets: offerable())),
                                  downloader: downloader(files: StubFiles(body: payload)),
                                  installer: installer)
            await model.check()
            await model.install(isTunnelUp: false)

            let text = model.installStatusText ?? ""
            XCTAssertLessThanOrEqual(text.count, 20, text)
            XCTAssertFalse(text.contains("\n"), text)
            let message = model.installMessage ?? ""
            XCTAssertFalse(message.isEmpty, "an install always has something to say")
            XCTAssertLessThanOrEqual(message.count, 200, message)
            XCTAssertFalse(message.contains("Optional("), message)
        }
    }

    // MARK: - Install fixtures

    /// The bytes every install fixture downloads, and the real SHA-256 of those
    /// bytes — computed outside this app (`shasum -a 256`), so a test cannot
    /// agree with a wrong implementation.
    private var payload: Data { Data("hello\n".utf8) }
    private var payloadDigest: String {
        "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
    }
    private var checksumFile: String { "\(payloadDigest)  TurtleDiver-2.1.0.dmg\n" }
    private var wrongDigestFile: String {
        "\(String(repeating: "a", count: 64))  TurtleDiver-2.1.0.dmg\n"
    }

    /// An offer whose installer the downloader will approve: the right name, the
    /// right size, and GitHub's own digest of the same bytes.
    private func offerable() -> [(name: String, url: String, size: Int?, digest: String?)] {
        [
            (name: "TurtleDiver-2.1.0.dmg", url: "https://example.com/2.1.0.dmg",
             size: payload.count, digest: "sha256:\(payloadDigest)"),
            (name: "TurtleDiver-2.1.0.sha256", url: "https://example.com/2.1.0.sha256",
             size: 176, digest: nil),
        ]
    }

    private func downloader(files: StubFiles,
                            directory: URL? = nil) -> UpdateDownloader {
        UpdateDownloader(files: files,
                         feed: StubChecksum(body: checksumFile),
                         directory: directory ?? temporaryDirectory(),
                         maxBytes: 1 << 20)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("turtle-model-\(UUID().uuidString)", isDirectory: true)
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

/// Writes the bytes a release publishes into the file the downloader asked for —
/// the same contract the real transport keeps — optionally parking the call so a
/// test can press the button twice while the first one is in flight.
private final class StubFiles: UpdateFileTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let body: Data
    private let gate: (entered: XCTestExpectation, release: DispatchSemaphore)?
    private var requests = 0

    init(body: Data, gate: (entered: XCTestExpectation, release: DispatchSemaphore)? = nil) {
        self.body = body
        self.gate = gate
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func fetch(_ url: URL, to destination: URL) throws -> URL? {
        lock.lock(); requests += 1; lock.unlock()
        if let gate {
            gate.entered.fulfill()
            _ = gate.release.wait(timeout: .now() + 10)
        }
        try body.write(to: destination)
        return url
    }
}

/// The release's tiny `.sha256` file.
private struct StubChecksum: UpdateFeedTransport {
    let body: String

    func get(_ url: URL) throws -> (data: Data, finalURL: URL?) {
        (Data(body.utf8), url)
    }
}

/// The install, answered from a decision instead of from a disk image.
private final class StubInstaller: UpdateInstalling, @unchecked Sendable {
    enum Answer {
        case replaced
        case revealed
        case refuse(UpdateBundleError)
    }

    private let lock = NSLock()
    private let answer: Answer
    private let version: ReleaseVersion
    private var seen: [DownloadedUpdate] = []

    init(answer: Answer = .replaced, version: ReleaseVersion = ReleaseVersion("2.1.0")!) {
        self.answer = answer
        self.version = version
    }

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.count
    }

    var lastSeen: DownloadedUpdate? {
        lock.lock()
        defer { lock.unlock() }
        return seen.last
    }

    func install(_ downloaded: DownloadedUpdate, running: ReleaseVersion) throws -> InstallOutcome {
        lock.lock(); seen.append(downloaded); lock.unlock()
        switch answer {
        case .replaced: return .replaced(version: version)
        case .revealed: return .revealed(version: version, imageURL: downloaded.imageURL)
        case .refuse(let error): throw error
        }
    }
}
