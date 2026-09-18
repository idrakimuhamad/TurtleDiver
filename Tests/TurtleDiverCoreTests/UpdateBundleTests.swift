import XCTest
import Foundation
@testable import TurtleDiverSystem

/// Gate 4 and gate 5, and the install decision.
///
/// Nothing here reaches the machine's own `hdiutil` or `codesign`: both are
/// injected, and the runner below answers from a script and performs the three
/// file operations the real tools would (attach copies the app into the mount
/// point, `ditto` copies it beside the destination, detach does nothing). What
/// is *not* faked is the file system — the swaps, the staging names, the copy
/// cleanup and the mount-point cleanup all happen for real, in a temporary
/// directory.
final class UpdateBundleTests: XCTestCase {

    // MARK: - The scripted runner

    /// Answers commands from a script, and records what it was asked.
    final class ScriptedRunner: BoundedProcessRunning, @unchecked Sendable {
        struct Call: Equatable {
            let tool: String
            let arguments: [String]
            var last: String { arguments.last ?? "" }
        }

        private let lock = NSLock()
        private var recorded: [Call] = []
        private let respond: (Call) -> BoundedProcessResult

        init(respond: @escaping (Call) -> BoundedProcessResult) {
            self.respond = respond
        }

        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return recorded
        }

        func calls(to tool: String) -> [Call] { calls.filter { $0.tool == tool } }

        func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult {
            let call = Call(tool: executable.lastPathComponent, arguments: arguments)
            lock.lock(); recorded.append(call); lock.unlock()
            return respond(call)
        }

        static func ok(_ out: String = "", err: String = "") -> BoundedProcessResult {
            BoundedProcessResult(terminationStatus: 0, timedOut: false, stdout: out, stderr: err)
        }

        static func failed(_ err: String, status: Int32 = 1) -> BoundedProcessResult {
            BoundedProcessResult(terminationStatus: status, timedOut: false, stdout: "", stderr: err)
        }

        static func stalled() -> BoundedProcessResult {
            BoundedProcessResult(terminationStatus: -1, timedOut: true, stdout: "", stderr: "")
        }
    }

    // MARK: - Fixtures

    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A read-only directory cannot be removed while it is read-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    /// Writes an app bundle whose `Info.plist` says what it is.
    @discardableResult
    private func makeApp(named name: String = "TurtleDiver.app",
                         in directory: URL,
                         identifier: String? = AppIdentity.bundleIdentifier,
                         version: String? = "2.1.0",
                         build: String? = "12") throws -> URL {
        let app = directory.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        var plist: [String: Any] = [:]
        if let identifier { plist["CFBundleIdentifier"] = identifier }
        if let version { plist["CFBundleShortVersionString"] = version }
        if let build { plist["CFBundleVersion"] = build }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return app
    }

    private func makeImage(version: String = "2.1.0") throws -> URL {
        let image = root.appendingPathComponent("TurtleDiver-\(version).dmg")
        try Data("not really a disk image".utf8).write(to: image)
        return image
    }

    private func downloaded(version: String = "2.1.0", image: URL) throws -> DownloadedUpdate {
        DownloadedUpdate(version: try XCTUnwrap(ReleaseVersion(version)),
                         imageURL: image,
                         byteCount: 6_000_000,
                         sha256: String(repeating: "a", count: 64),
                         publishedChecksum: String(repeating: "a", count: 64),
                         apiDigest: "sha256:" + String(repeating: "a", count: 64))
    }

    /// The scripted machine: attach drops `appInImage` into the mount point,
    /// `ditto` copies for real, and both `codesign` calls answer per the fixture.
    private func makeRunner(
        appInImage: URL? = nil,
        verify: @escaping (String) -> BoundedProcessResult = { _ in ScriptedRunner.ok() },
        team: String = "TeamIdentifier=KT7QU923S8",
        attach: BoundedProcessResult = ScriptedRunner.ok(),
        ditto: BoundedProcessResult = ScriptedRunner.ok()
    ) -> ScriptedRunner {
        ScriptedRunner { call in
            switch call.tool {
            case "hdiutil":
                if call.arguments.first == "attach" {
                    guard attach.terminationStatus == 0, !attach.timedOut else { return attach }
                    guard let source = appInImage,
                          let flag = call.arguments.firstIndex(of: "-mountpoint"),
                          call.arguments.count > flag + 1 else { return ScriptedRunner.ok() }
                    let mountPoint = URL(fileURLWithPath: call.arguments[flag + 1])
                    if let entries = try? FileManager.default.contentsOfDirectory(at: source,
                                                                                  includingPropertiesForKeys: nil) {
                        for entry in entries {
                            try? FileManager.default.copyItem(
                                at: entry,
                                to: mountPoint.appendingPathComponent(entry.lastPathComponent))
                        }
                    }
                    return ScriptedRunner.ok("created")
                }
                if call.arguments.first == "detach" { return ScriptedRunner.ok() }
                return ScriptedRunner.failed("hdiutil: unknown request")

            case "codesign":
                if call.arguments.contains("--verify") { return verify(call.last) }
                return ScriptedRunner.ok(err: team + "\nIdentifier=com.xvii.kurakura.vpn\n")

            case "ditto":
                guard ditto.terminationStatus == 0, !ditto.timedOut else { return ditto }
                let source = URL(fileURLWithPath: call.arguments[0])
                let destination = URL(fileURLWithPath: call.arguments[1])
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    return ScriptedRunner.ok()
                } catch {
                    return ScriptedRunner.failed("ditto: \(error.localizedDescription)")
                }

            default:
                return ScriptedRunner.failed("nothing here runs \(call.tool)")
            }
        }
    }

    /// The app the image contains, in its own little tree.
    private func makeImageContents(identifier: String? = AppIdentity.bundleIdentifier,
                                  version: String? = "2.1.0") throws -> URL {
        let contents = root.appendingPathComponent("image", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try makeApp(in: contents, identifier: identifier, version: version)
        return contents
    }

    /// Where the running app lives, in a directory the user owns.
    private func makeRunningBundle(version: String = "2.0.0") throws -> URL {
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        return try makeApp(in: applications, version: version, build: "9")
    }

    private func installedVersion(of app: URL) throws -> String? {
        try BundleFacts.read(at: app).shortVersion
    }

    // MARK: - What a bundle says about itself

    func testABundlesIdentityIsReadFromItsPlist() throws {
        let app = try makeApp(in: root, identifier: "com.example.thing", version: "3.4.5", build: "77")
        let facts = try BundleFacts.read(at: app)
        XCTAssertEqual(facts.identifier, "com.example.thing")
        XCTAssertEqual(facts.shortVersion, "3.4.5")
        XCTAssertEqual(facts.build, "77")
        XCTAssertEqual(facts.version, ReleaseVersion("3.4.5"))
    }

    func testAPlistThatIsNotAPlistIsRefusedRatherThanGuessed() {
        XCTAssertThrowsError(try BundleFacts.parse(Data("hello, not a plist".utf8))) { error in
            guard case UpdateBundleError.unreadable? = error as? UpdateBundleError else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testABundleWithNoReadablePlistIsRefused() throws {
        let empty = root.appendingPathComponent("Empty.app", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BundleFacts.read(at: empty)) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .unreadable("Empty.app has no Info.plist this app can read"))
        }
    }

    func testAVersionThatCannotBeOrderedIsNotAVersion() throws {
        let app = try makeApp(in: root, version: "nightly")
        let facts = try BundleFacts.read(at: app)
        XCTAssertEqual(facts.shortVersion, "nightly")
        XCTAssertNil(facts.version, "a version this app cannot order must not become one")
    }

    func testABundleWithNoVersionAtAllSaysSo() throws {
        let app = try makeApp(in: root, version: nil)
        let facts = try BundleFacts.read(at: app)
        XCTAssertNil(facts.shortVersion)
        XCTAssertNil(facts.version)
    }

    // MARK: - Reading the signature

    func testTheTeamIsReadFromTheLineCodesignWrites() {
        let output = """
        Executable=/Volumes/x/TurtleDiver.app/Contents/MacOS/TurtleDiver
        Identifier=com.xvii.kurakura.vpn
        TeamIdentifier=KT7QU923S8
        """
        XCTAssertEqual(CodeSignature.teamIdentifier(in: output), "KT7QU923S8")
    }

    func testTheTeamLineIsMatchedOnItsKeyAndNotOnTheWord() {
        // A remark in a log, and a differently named key, are not the answer.
        // The certificate id in the `Authority` line is a placeholder: this
        // project's own is a personal identifier, and `RepoPrivacyGuardTests`
        // is right to refuse it in a fixture that does not need it.
        let output = """
        note: TeamIdentifier=WRONGTEAM
        Authority=Apple Development: someone (ABCDE12345)
        """
        XCTAssertNil(CodeSignature.teamIdentifier(in: output),
                     "only a line that *starts* with the key is the signature's own answer")
    }

    func testAnAdHocSignatureHasNoTeam() {
        let output = "Identifier=com.xvii.kurakura.vpn\nSignature=adhoc\n"
        XCTAssertNil(CodeSignature.teamIdentifier(in: output))
        XCTAssertNil(CodeSignature.teamIdentifier(in: "TeamIdentifier=\n"),
                     "an empty value is not a team")
    }

    /// The reason the parse reads stderr as well: this is where `codesign -d`
    /// puts everything it knows, and a stdout-only read would see nothing.
    func testTheSignatureDetailIsReadFromStderrBecauseThatIsWhereItGoes() throws {
        let runner = ScriptedRunner { call in
            call.arguments.contains("--verify")
                ? ScriptedRunner.ok()
                : ScriptedRunner.ok(err: "TeamIdentifier=KT7QU923S8\n")
        }
        let signature = CodeSignature(runner: runner)
        XCTAssertEqual(try signature.teamIdentifier(of: root), "KT7QU923S8")
    }

    func testAVerifyThatFailsCarriesTheReasonAndNothingIsInstalled() throws {
        let runner = makeRunner(verify: { _ in
            ScriptedRunner.failed("code object is not signed at all\nIn subcomponent: /x/y")
        })
        let signature = CodeSignature(runner: runner)
        XCTAssertThrowsError(try signature.verify(root)) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .signatureInvalid("In subcomponent: /x/y"),
                           "the reason is the last line codesign wrote")
        }
    }

    func testAVerifyThatTimesOutIsNotAPass() {
        let runner = makeRunner(verify: { _ in ScriptedRunner.stalled() })
        XCTAssertThrowsError(try CodeSignature(runner: runner).verify(root)) { error in
            XCTAssertEqual(error as? UpdateBundleError, .signatureInvalid("checking it took too long"))
        }
    }

    func testASignatureCheckThatCannotEvenRunIsARefusal() {
        let runner = ScriptedRunner { _ in ScriptedRunner.failed("no such file") }
        // A runner that throws is the launch-failure path.
        let throwing = ThrowingRunner()
        XCTAssertThrowsError(try CodeSignature(runner: throwing).verify(root)) { error in
            guard case .signatureInvalid? = error as? UpdateBundleError else {
                return XCTFail("expected .signatureInvalid, got \(error)")
            }
        }
        XCTAssertThrowsError(try CodeSignature(runner: runner).verify(root))
    }

    /// A runner that cannot start the command at all.
    private struct ThrowingRunner: BoundedProcessRunning {
        func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> BoundedProcessResult {
            throw BoundedProcessError.launchFailed("permission denied")
        }
    }

    func testAnUnsignedBundleIsNotAnErrorToRead_ItSimplyHasNoTeam() throws {
        // `codesign -dv` fails on an unsigned bundle; that is an answer (no
        // team), not a reason to stop with a different complaint.
        let runner = makeRunner(verify: { _ in
            ScriptedRunner.failed("code object is not signed at all")
        }, team: "")
        let signature = CodeSignature(runner: runner)
        XCTAssertNil(try signature.teamIdentifier(of: root))
    }

    // MARK: - Mounting

    func testAnImageIsMountedReadOnlyAndOutOfTheWay() {
        let image = URL(fileURLWithPath: "/tmp/TurtleDiver-2.1.0.dmg")
        let mountPoint = URL(fileURLWithPath: "/tmp/mount-here")
        let arguments = DiskImage.attachArguments(image: image, mountPoint: mountPoint)
        XCTAssertEqual(arguments, ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                   "-mountpoint", mountPoint.path, image.path])
        XCTAssertFalse(arguments.contains("-autoopen"), "the Finder must not open anything")
    }

    func testAnAttachThatFailsRefusesInsteadOfLookingAtNothing() throws {
        let runner = makeRunner(attach: ScriptedRunner.failed("hdiutil: attach failed - no mountable file systems"))
        let installer = UpdateInstaller(runner: runner, runningBundle: try makeRunningBundle())
        let image = try makeImage()
        XCTAssertThrowsError(try installer.install(try downloaded(image: image),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .mountFailed("hdiutil: attach failed - no mountable file systems"))
        }
    }

    func testAnAttachThatTimesOutRefuses() throws {
        let runner = makeRunner(attach: ScriptedRunner.stalled())
        let installer = UpdateInstaller(runner: runner, runningBundle: try makeRunningBundle())
        let image = try makeImage()
        XCTAssertThrowsError(try installer.install(try downloaded(image: image),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError, .mountFailed("opening it took too long"))
        }
    }

    func testAnAttachThatSucceedsWithoutMountingAnythingRefuses() throws {
        // The runner never creates a directory at the mount point, so the file
        // system's answer is the one that counts.
        let runner = makeRunner(appInImage: nil)
        let installer = UpdateInstaller(runner: runner, runningBundle: try makeRunningBundle())
        let image = try makeImage()
        XCTAssertThrowsError(try installer.install(try downloaded(image: image),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            // The mount point exists (the installer made it), so this lands on
            // "no application inside" rather than on the mount check.
            XCTAssertEqual(error as? UpdateBundleError, .noAppInImage)
        }
    }

    /// An attach that reports success and mounts nothing must not be taken on
    /// trust: the mount point is checked, not the exit status.
    func testAnAttachThatLeavesNoMountPointBehindRefuses() throws {
        let runner = makeRunner()
        let missing = root.appendingPathComponent("not-created", isDirectory: true)
        XCTAssertThrowsError(try DiskImage(runner: runner).mount(try makeImage(), at: missing)) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .mountFailed("the image did not appear where it was mounted"))
        }
    }

    func testTheMountPointIsAPrivateDirectory() throws {
        let mountPoint = try UpdateInstaller.makeMountPoint()
        defer { try? FileManager.default.removeItem(at: mountPoint) }
        let attributes = try FileManager.default.attributesOfItem(atPath: mountPoint.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700,
                       "a mount point in a shared temporary directory is still the app's own")
    }

    func testADetachThatFailsIsRetriedWithForce() throws {
        let runner = ScriptedRunner { call in
            guard call.tool == "hdiutil" else { return ScriptedRunner.ok() }
            if call.arguments.first == "detach" {
                return call.arguments.contains("-force")
                    ? ScriptedRunner.ok()
                    : ScriptedRunner.failed("hdiutil: couldn't unmount, resource busy")
            }
            return ScriptedRunner.ok()
        }
        DiskImage(runner: runner).detach(URL(fileURLWithPath: "/tmp/mount-here"))
        let detaches = runner.calls(to: "hdiutil").filter { $0.arguments.first == "detach" }
        XCTAssertEqual(detaches.count, 2)
        XCTAssertEqual(detaches.last?.arguments, ["detach", "-force", "/tmp/mount-here"])
    }

    func testADetachThatWorksIsNotTriedTwice() {
        let runner = makeRunner()
        DiskImage(runner: runner).detach(URL(fileURLWithPath: "/tmp/mount-here"))
        let detaches = runner.calls(to: "hdiutil").filter { $0.arguments.first == "detach" }
        XCTAssertEqual(detaches.count, 1)
        XCTAssertFalse(detaches[0].arguments.contains("-force"))
    }

    // MARK: - Which app in the image

    func testTheOneApplicationInTheImageIsFound() throws {
        try makeApp(in: root)
        XCTAssertEqual(try UpdateInstaller.appInside(root).lastPathComponent, "TurtleDiver.app")
    }

    func testAnImageWithNoApplicationIsRefused() throws {
        try Data("readme".utf8).write(to: root.appendingPathComponent("Read Me.txt"))
        XCTAssertThrowsError(try UpdateInstaller.appInside(root)) { error in
            XCTAssertEqual(error as? UpdateBundleError, .noAppInImage)
        }
    }

    func testAnImageWithTwoApplicationsIsRefusedRatherThanGuessedAt() throws {
        try makeApp(named: "Zeta.app", in: root)
        try makeApp(named: "Alpha.app", in: root)
        XCTAssertThrowsError(try UpdateInstaller.appInside(root)) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .severalAppsInImage(["Alpha.app", "Zeta.app"]),
                           "the names are listed so the refusal can be read")
        }
    }

    // MARK: - Whether the app may replace itself

    func testAnAppInADirectoryTheUserOwnsMayReplaceItself() throws {
        let app = try makeRunningBundle()
        XCTAssertTrue(UpdateInstaller.canReplaceBundle(at: app))
    }

    func testAnAppInADirectoryTheUserDoesNotOwnIsNotReplaced() throws {
        let applications = root.appendingPathComponent("System", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try makeApp(in: applications)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path) }

        XCTAssertFalse(UpdateInstaller.canReplaceBundle(at: applications.appendingPathComponent("TurtleDiver.app")))
    }

    /// A `.pkg` install is not replaced, and — this was the bug — it is not
    /// *attempted* either.
    ///
    /// The gate asked only about the containing directory, which an
    /// administrator can write in `/Applications`, so a `root`-owned bundle
    /// sailed past it and `replaceItemAt` then threw "You don't have permission
    /// to save the file “TurtleDiver” in the folder “Applications”". That is a
    /// failed install where the reveal path was the answer — on the one install
    /// shape most users have. The bundle's own write bit is what
    /// `replaceItemAt` needs, and what a `root`-owned bundle does not give this
    /// user. Measured here: `/Applications` `W_OK` true,
    /// `/Applications/TurtleDiver.app` `W_OK` false.
    func testABundleTheUserCannotWriteIsRevealedRatherThanFailedHalfway() throws {
        try XCTSkipIf(geteuid() == 0, "a root runner can write anything; the assertion means nothing")
        let running = try makeRunningBundle(version: "2.0.0")
        // Read-only, the way a root-owned install is to the user running it.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: running.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: running.path) }

        XCTAssertFalse(FileManager.default.isWritableFile(atPath: running.path),
                       "the fixture is not writable, which is the whole point")
        XCTAssertTrue(FileManager.default.isWritableFile(atPath: running.deletingLastPathComponent().path),
                      "and its directory is: the directory alone is not the test")
        XCTAssertFalse(UpdateInstaller.canReplaceBundle(at: running),
                       "a writable directory does not make an unwritable bundle replaceable")

        let image = try makeImage()
        let installer = UpdateInstaller(runner: makeRunner(appInImage: try makeImageContents()),
                                        runningBundle: running)
        let outcome = try installer.install(try downloaded(image: image),
                                            running: try XCTUnwrap(ReleaseVersion("2.0.0")))

        XCTAssertEqual(outcome, .revealed(version: try XCTUnwrap(ReleaseVersion("2.1.0")), imageURL: image),
                       "the verified image is pointed out instead of a permission error")
        XCTAssertEqual(try installedVersion(of: running), "2.0.0", "nothing was replaced")
    }

    // MARK: - The gates, end to end through install()

    func testAVerifiedNewerReleaseReplacesTheRunningApp() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle(version: "2.0.0")
        let image = try makeImage()
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        let outcome = try installer.install(try downloaded(image: image),
                                            running: try XCTUnwrap(ReleaseVersion("2.0.0")))

        XCTAssertEqual(outcome, .replaced(version: try XCTUnwrap(ReleaseVersion("2.1.0"))))
        XCTAssertEqual(try installedVersion(of: running), "2.1.0", "the running bundle is the new one")
        // The staging copy is gone, and so is the mount.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: running.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix(".") }, [], "no staging directory may be left behind")
    }

    func testTheMountIsDetachedAndItsDirectoryRemovedEvenOnSuccess() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        _ = try installer.install(try downloaded(image: try makeImage()),
                                  running: try XCTUnwrap(ReleaseVersion("2.0.0")))

        let detaches = runner.calls(to: "hdiutil").filter { $0.arguments.first == "detach" }
        XCTAssertEqual(detaches.count, 1, "a volume this app mounted is never left mounted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: detaches[0].last),
                       "and its mount point does not stay behind either")
    }

    func testTheMountIsCleanedUpEvenWhenAVerificationFails() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents, verify: { _ in
            ScriptedRunner.failed("code object is not signed at all")
        })
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0"))))
        let detaches = runner.calls(to: "hdiutil").filter { $0.arguments.first == "detach" }
        XCTAssertEqual(detaches.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: detaches[0].last))
        XCTAssertEqual(try installedVersion(of: running), "2.0.0", "nothing was replaced")
    }

    func testAnAppSignedByAnotherTeamIsRefused() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents, team: "TeamIdentifier=SOMEONELSE")
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .wrongTeam(expected: AppIdentity.updateTeamIdentifier, actual: "SOMEONELSE"))
        }
        XCTAssertTrue(runner.calls(to: "ditto").isEmpty, "a refused release is never copied")
        XCTAssertEqual(try installedVersion(of: running), "2.0.0")
    }

    func testAnAppWithAnAdHocSignatureIsRefused() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents, team: "")
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .wrongTeam(expected: AppIdentity.updateTeamIdentifier, actual: nil))
        }
    }

    func testAnAppThatIsNotThisAppIsRefused() throws {
        let contents = try makeImageContents(identifier: "com.example.somethingelse")
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .wrongBundleIdentifier(expected: AppIdentity.bundleIdentifier,
                                                  actual: "com.example.somethingelse"))
        }
        XCTAssertTrue(runner.calls(to: "ditto").isEmpty)
    }

    /// The release's tag and the app inside it have to agree. Without this, a
    /// release titled 2.1.0 could deliver a 2.2.0 bundle and only the tag would
    /// ever have said otherwise.
    func testAnImageWhoseAppDisagreesWithTheReleaseIsRefused() throws {
        let contents = try makeImageContents(version: "2.2.0")
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)
        let release = try XCTUnwrap(ReleaseVersion("2.1.0"))
        let inside = try XCTUnwrap(ReleaseVersion("2.2.0"))

        XCTAssertThrowsError(try installer.install(try downloaded(version: "2.1.0", image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .versionMismatch(release: release, bundle: inside))
        }
        XCTAssertTrue(runner.calls(to: "ditto").isEmpty)
    }

    func testAnImageWhoseAppCannotSayWhatVersionItIsIsRefused() throws {
        let contents = try makeImageContents(version: nil)
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)
        let release = try XCTUnwrap(ReleaseVersion("2.1.0"))

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError, .versionMismatch(release: release, bundle: nil))
        }
    }

    func testAReleaseThatIsNotNewerThanTheRunningAppIsRefused() throws {
        let contents = try makeImageContents(version: "2.0.0")
        let running = try makeRunningBundle(version: "2.0.0")
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)
        let both = try XCTUnwrap(ReleaseVersion("2.0.0"))

        XCTAssertThrowsError(try installer.install(try downloaded(version: "2.0.0", image: try makeImage()),
                                                   running: both)) { error in
            XCTAssertEqual(error as? UpdateBundleError, .notNewer(downloaded: both, running: both))
        }
        XCTAssertTrue(runner.calls(to: "ditto").isEmpty, "nothing is written for a version already installed")
    }

    func testTheAppInsideTheImageIsVerifiedBeforeAnythingIsCopied() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        _ = try installer.install(try downloaded(image: try makeImage()),
                                  running: try XCTUnwrap(ReleaseVersion("2.0.0")))

        // The verification is of the app *in the image*, and it happens before
        // the copy: gate 4 has to be answered before anything is on disk.
        let verifies = runner.calls(to: "codesign").filter { $0.arguments.contains("--verify") }
        XCTAssertGreaterThanOrEqual(verifies.count, 2, "the image's app and the copy are both checked")
        XCTAssertTrue(verifies[0].last.hasSuffix("TurtleDiver.app"),
                      "the first check is of the app inside the image, got \(verifies[0].last)")
        XCTAssertFalse(verifies[0].last.contains("/private/var/folders") && verifies[0].last.contains(".TurtleDiver.app."))

        let order = runner.calls.map(\.tool)
        let firstVerify = try XCTUnwrap(order.firstIndex(of: "codesign"))
        let firstCopy = try XCTUnwrap(order.firstIndex(of: "ditto"))
        XCTAssertLessThan(firstVerify, firstCopy, "gate 4 comes before gate anything-else")
    }

    func testAnAppTheUserCannotReplaceIsRevealedInstead() throws {
        let contents = try makeImageContents()
        let applications = root.appendingPathComponent("System", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let running = try makeApp(in: applications, version: "2.0.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: applications.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: applications.path) }

        let image = try makeImage()
        let runner = makeRunner(appInImage: contents)
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        let outcome = try installer.install(try downloaded(image: image),
                                            running: try XCTUnwrap(ReleaseVersion("2.0.0")))

        XCTAssertEqual(outcome, .revealed(version: try XCTUnwrap(ReleaseVersion("2.1.0")), imageURL: image),
                       "an app it cannot replace is still verified, and the verified image is what is offered")
        XCTAssertTrue(runner.calls(to: "ditto").isEmpty)
        XCTAssertEqual(try installedVersion(of: running), "2.0.0", "and it is not touched")
        XCTAssertEqual(outcome.version, ReleaseVersion("2.1.0"))
    }

    /// The copy that will be the app is verified as it sits on disk. A copy that
    /// did not survive the trip does not get installed, and neither does the
    /// original: the swap never happens.
    func testTheStagedCopyIsCheckedBeforeItIsSwappedIn() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle(version: "2.0.0")
        let runner = makeRunner(appInImage: contents, verify: { path in
            path.contains(".TurtleDiver.app.")
                ? ScriptedRunner.failed("resource fork, Finder information, or similar detritus not allowed")
                : ScriptedRunner.ok()
        })
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError,
                           .signatureInvalid("resource fork, Finder information, or similar detritus not allowed"))
        }
        XCTAssertEqual(try installedVersion(of: running), "2.0.0", "the running app is not replaced by an unverified copy")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: running.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix(".") }, [], "the bad copy is cleaned up")
    }

    func testACopyThatFailsIsARefusalAndLeavesNothingBehind() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents,
                                ditto: ScriptedRunner.failed("ditto: /not permitted"))
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError, .installFailed("ditto: /not permitted"))
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: running.deletingLastPathComponent().path)
        XCTAssertEqual(leftovers.filter { $0.hasPrefix(".") }, [])
    }

    func testACopyThatTimesOutIsARefusal() throws {
        let contents = try makeImageContents()
        let running = try makeRunningBundle()
        let runner = makeRunner(appInImage: contents, ditto: ScriptedRunner.stalled())
        let installer = UpdateInstaller(runner: runner, runningBundle: running)

        XCTAssertThrowsError(try installer.install(try downloaded(image: try makeImage()),
                                                   running: try XCTUnwrap(ReleaseVersion("2.0.0")))) { error in
            XCTAssertEqual(error as? UpdateBundleError, .installFailed("copying it took too long"))
        }
    }

    /// Every refusal reads as a sentence, because each one is rendered beside a
    /// status pill rather than logged and forgotten.
    func testEveryRefusalHasASentenceToShowTheUser() {
        let errors: [UpdateBundleError] = [
            .mountFailed("hdiutil: nope"),
            .noAppInImage,
            .severalAppsInImage(["A.app", "B.app"]),
            .unreadable("nothing to read"),
            .signatureInvalid("not signed"),
            .wrongTeam(expected: "KT7QU923S8", actual: "OTHER"),
            .wrongTeam(expected: "KT7QU923S8", actual: nil),
            .wrongBundleIdentifier(expected: "com.xvii.kurakura.vpn", actual: "com.other"),
            .wrongBundleIdentifier(expected: "com.xvii.kurakura.vpn", actual: nil),
            .versionMismatch(release: ReleaseVersion("2.1.0")!, bundle: ReleaseVersion("2.0.0")!),
            .versionMismatch(release: ReleaseVersion("2.1.0")!, bundle: nil),
            .notNewer(downloaded: ReleaseVersion("2.0.0")!, running: ReleaseVersion("2.0.0")!),
            .installFailed("ditto: nope"),
        ]
        for error in errors {
            let sentence = error.errorDescription
            XCTAssertNotNil(sentence, "\(error) has no sentence")
            XCTAssertFalse(sentence?.isEmpty ?? true, "\(error) has an empty sentence")
            XCTAssertFalse(sentence?.hasSuffix(" ") ?? true, "\(error) ends in a space")
        }
    }
}
