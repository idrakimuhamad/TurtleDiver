import Foundation

// MARK: - Errors

/// Why an application inside a downloaded image was not installed.
///
/// The same shape as `UpdateArtifactError`: one line beside a pill, and the
/// detail (a `codesign` message, a path) kept for whoever reads the log.
public enum UpdateBundleError: LocalizedError, Equatable {
    case mountFailed(String)
    case noAppInImage
    case severalAppsInImage([String])
    case unreadable(String)
    case signatureInvalid(String)
    case wrongTeam(expected: String, actual: String?)
    case wrongBundleIdentifier(expected: String, actual: String?)
    case versionMismatch(release: ReleaseVersion, bundle: ReleaseVersion?)
    case notNewer(downloaded: ReleaseVersion, running: ReleaseVersion)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .mountFailed(let detail):
            return "Could not open the downloaded disk image: \(detail)"
        case .noAppInImage:
            return "The downloaded disk image holds no application"
        case .severalAppsInImage(let names):
            return "The disk image holds more than one application (\(names.joined(separator: ", "))), "
                + "so the app will not guess which to install"
        case .unreadable(let detail):
            return detail
        case .signatureInvalid(let detail):
            return "The application inside the disk image is not signed in a way this Mac accepts: \(detail)"
        case .wrongTeam(let expected, let actual):
            return "The application inside the disk image is signed by \(actual ?? "no team"), "
                + "and this app only installs releases signed by \(expected)"
        case .wrongBundleIdentifier(let expected, let actual):
            return "The application inside the disk image is \(actual ?? "unnamed"), not \(expected)"
        case .versionMismatch(let release, let bundle):
            return "The release says \(release), and the application inside it says "
                + "\(bundle.map(String.init(describing:)) ?? "nothing")"
        case .notNewer(let downloaded, let running):
            return "\(downloaded) is not newer than the running \(running)"
        case .installFailed(let detail):
            return "Could not replace the app: \(detail)"
        }
    }
}

// MARK: - What a bundle says about itself

/// A bundle's own identity, read straight from its `Info.plist`.
///
/// Not through `Bundle`: the interesting bundle is a copy on a mounted image,
/// not this process's own, and `Bundle(url:)` would cache it process-wide. This
/// reads bytes, so it is testable from a fixture with no bundle on disk at all.
public struct BundleFacts: Equatable, Sendable {
    public let identifier: String?
    public let shortVersion: String?
    public let build: String?

    /// `CFBundleShortVersionString`, as a version this app can order.
    public var version: ReleaseVersion? { shortVersion.flatMap(ReleaseVersion.init) }

    public static let infoPlistPath = "Contents/Info.plist"

    public init(identifier: String?, shortVersion: String?, build: String?) {
        self.identifier = identifier
        self.shortVersion = shortVersion
        self.build = build
    }

    /// From the plist's bytes.
    public static func parse(_ data: Data) throws -> BundleFacts {
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = plist as? [String: Any] else {
            throw UpdateBundleError.unreadable("That application's Info.plist is not a property list")
        }
        return BundleFacts(identifier: dictionary["CFBundleIdentifier"] as? String,
                           shortVersion: dictionary["CFBundleShortVersionString"] as? String,
                           build: dictionary["CFBundleVersion"] as? String)
    }

    public static func read(at appURL: URL) throws -> BundleFacts {
        let plist = appURL.appendingPathComponent(infoPlistPath)
        guard let data = try? Data(contentsOf: plist) else {
            throw UpdateBundleError.unreadable(
                "\(appURL.lastPathComponent) has no Info.plist this app can read")
        }
        return try parse(data)
    }
}

// MARK: - The signature

/// Asks `codesign` what it makes of a bundle.
///
/// This is gate 4, and it is the update path's trust anchor: the project has no
/// Developer ID certificate and notarizes nothing, so Gatekeeper's own verdict
/// (`spctl`) refuses every build this app could publish. What can be insisted on
/// is that the application inside a downloaded image was signed by the same team
/// as the running app — see `AppIdentity.updateTeamIdentifier`.
public struct CodeSignature: Sendable {
    public static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
    /// A signature check reads a few megabytes and answers in well under a
    /// second; the bound exists so a wedged `codesign` cannot hold the app.
    public static let timeout: TimeInterval = 60

    public let runner: any BoundedProcessRunning

    public init(runner: any BoundedProcessRunning = SystemBoundedProcessRunner()) {
        self.runner = runner
    }

    /// `codesign --verify --deep --strict`: fails on a modified bundle, a broken
    /// seal, or a signature this Mac cannot validate.
    public func verify(_ url: URL) throws {
        let result = try run(["--verify", "--deep", "--strict", url.path])
        guard !result.timedOut else {
            throw UpdateBundleError.signatureInvalid("checking it took too long")
        }
        guard result.terminationStatus == 0 else {
            throw UpdateBundleError.signatureInvalid(Self.lastLine(of: result))
        }
    }

    /// The team that signed it, or `nil` for an ad-hoc signature, which has no
    /// team at all — and an ad-hoc signature is not a reason to install.
    public func teamIdentifier(of url: URL) throws -> String? {
        let result = try run(["-dv", "--verbose=4", url.path])
        guard !result.timedOut else {
            throw UpdateBundleError.signatureInvalid("reading it took too long")
        }
        return Self.teamIdentifier(in: Self.output(of: result))
    }

    /// The `TeamIdentifier=` line, matched on the key rather than on the word.
    public static func teamIdentifier(in output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let value = value(of: "TeamIdentifier", in: line) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// The value of `key=` at the start of a line, as `codesign` writes it.
    static func value(of key: String, in line: some StringProtocol) -> String? {
        let prefix = key + "="
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// `codesign -d` prints everything it knows to stderr, so a parse that read
    /// only stdout would see nothing at all.
    private static func output(of result: BoundedProcessResult) -> String {
        result.stdout + "\n" + result.stderr
    }

    private static func lastLine(of result: BoundedProcessResult) -> String {
        let text = output(of: result).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").last.map(String.init) ?? "no reason given"
    }

    private func run(_ arguments: [String]) throws -> BoundedProcessResult {
        do {
            return try runner.run(executable: Self.codesign,
                                  arguments: arguments,
                                  timeout: Self.timeout)
        } catch {
            throw UpdateBundleError.signatureInvalid(error.localizedDescription)
        }
    }
}

// MARK: - Mounting

/// Attaches a downloaded image, read-only and out of the way.
///
/// An update image is looked at and thrown away, never browsed: `-nobrowse`
/// keeps it out of `/Volumes` and the Finder, and the mount point is a private
/// directory rather than anything in the user's path.
public struct DiskImage: Sendable {
    public static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
    /// Attaching verifies the image's own checksum, which takes a moment; a
    /// 6 MB image does it in well under a second.
    public static let attachTimeout: TimeInterval = 120
    public static let detachTimeout: TimeInterval = 60

    public let runner: any BoundedProcessRunning

    public init(runner: any BoundedProcessRunning = SystemBoundedProcessRunner()) {
        self.runner = runner
    }

    public func mount(_ image: URL, at mountPoint: URL) throws {
        let result: BoundedProcessResult
        do {
            result = try runner.run(executable: Self.hdiutil,
                                    arguments: Self.attachArguments(image: image, mountPoint: mountPoint),
                                    timeout: Self.attachTimeout)
        } catch {
            throw UpdateBundleError.mountFailed(error.localizedDescription)
        }
        guard !result.timedOut else {
            throw UpdateBundleError.mountFailed("opening it took too long")
        }
        guard result.terminationStatus == 0 else {
            throw UpdateBundleError.mountFailed(Self.detail(of: result))
        }
        // Trust the file system, not the exit status: an image that reports
        // success and is not there is not something to go on to read.
        var isDirectory: ObjCBool = false
        let there = FileManager.default.fileExists(atPath: mountPoint.path, isDirectory: &isDirectory)
        guard there, isDirectory.boolValue else {
            throw UpdateBundleError.mountFailed("the image did not appear where it was mounted")
        }
    }

    public static func attachArguments(image: URL, mountPoint: URL) -> [String] {
        ["attach", "-nobrowse", "-readonly", "-noautoopen",
         "-mountpoint", mountPoint.path, image.path]
    }

    /// Detaching is best-effort and twice-tried: `-force` deals with an image
    /// something still holds open. A volume this app mounted is never left on
    /// the machine.
    public func detach(_ mountPoint: URL) {
        if runQuietly(["detach", mountPoint.path]) { return }
        _ = runQuietly(["detach", "-force", mountPoint.path])
    }

    private func runQuietly(_ arguments: [String]) -> Bool {
        guard let result = try? runner.run(executable: Self.hdiutil,
                                           arguments: arguments,
                                           timeout: Self.detachTimeout) else { return false }
        return !result.timedOut && result.terminationStatus == 0
    }

    static func detail(of result: BoundedProcessResult) -> String {
        let text = (result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n").last.map(String.init) ?? "no reason given"
    }
}

// MARK: - Installing

/// What an install attempt did.
public enum InstallOutcome: Equatable, Sendable {
    /// The running app was replaced in place. It has to be relaunched before any
    /// of it is the new version.
    case replaced(version: ReleaseVersion)
    /// The app cannot replace itself where it lives, so a verified installer was
    /// pointed out in the Finder and the user finishes the job.
    case revealed(version: ReleaseVersion, imageURL: URL)

    public var version: ReleaseVersion {
        switch self {
        case .replaced(let version): return version
        case .revealed(let version, _): return version
        }
    }
}

/// The two gates that need to look inside the image, and the install itself.
///
/// Gate 4 — the application is signed, and by this app's own team. Gate 5 — it
/// is *this* app (`CFBundleIdentifier`), its own version agrees with the release
/// that offered it, and it is newer than what is running. Only then is anything
/// written: nothing here replaces a working app on the strength of a file name.
///
/// It replaces the app **only if the running bundle is the user's to replace**.
/// Anywhere else — the system `/Applications`, an administrator's directory —
/// the installer is handed to the Finder instead, because this app never
/// elevates on its own initiative.
/// Swapping the app for a downloaded one.
///
/// A seam rather than a direct call: the model owns the *decision* to install,
/// and a test asserting that decision — that it is refused while the tunnel is
/// up, that a download failure never reaches the installer — should not have to
/// build a disk image first.
public protocol UpdateInstalling: Sendable {
    func install(_ downloaded: DownloadedUpdate, running: ReleaseVersion) throws -> InstallOutcome
}

public struct UpdateInstaller: Sendable, UpdateInstalling {
    public static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    /// Copying a 6 MB app on the same volume is a moment's work.
    public static let copyTimeout: TimeInterval = 120

    public let runner: any BoundedProcessRunning
    /// The bundle to replace. Defaults to this process's own.
    public let runningBundle: URL

    public init(runner: any BoundedProcessRunning = SystemBoundedProcessRunner(),
                runningBundle: URL? = nil) {
        self.runner = runner
        self.runningBundle = runningBundle ?? URL(fileURLWithPath: Bundle.main.bundlePath)
    }

    /// Whether the running app can be replaced where it is.
    ///
    /// Two write permissions, and the second is the one that is easy to miss.
    /// Replacing a bundle is a rename into the directory it already sits in, so
    /// that directory has to be writable — but `replaceItemAt` additionally
    /// refuses a bundle that is not itself writable, with "You don't have
    /// permission to save the file …", even when the directory would allow the
    /// rename. Measured both ways on a fixture: a `0555` bundle in a writable
    /// directory fails at `replaceItemAt` and succeeds under
    /// `renamex_np(RENAME_SWAP)`.
    ///
    /// The swap is deliberately *not* used. Exchanging the two entries leaves the
    /// old bundle at the staging path, and a bundle the user could not write is
    /// a bundle the user cannot delete either ("Old couldn't be removed because
    /// you don't have permission to access it"), so a swapped install would
    /// leave a hidden, `root`-owned directory in `/Applications` that only an
    /// administrator could clean up. Refusing up front and revealing the
    /// verified image is the honest trade.
    ///
    /// A build tree and `~/Applications` qualify. A `.pkg` install does not: it
    /// is `root:wheel 0755` inside a `/Applications` that is `root:admin` —
    /// writable by an administrator, which the directory check alone would have
    /// accepted, and the bundle is not.
    public static func canReplaceBundle(at appURL: URL) -> Bool {
        let manager = FileManager.default
        let parent = appURL.deletingLastPathComponent().path
        return manager.isWritableFile(atPath: parent) && manager.isWritableFile(atPath: appURL.path)
    }

    /// Verifies, then either replaces the running app or reveals the installer.
    ///
    /// Synchronous and meant for a background task: mounting, `codesign` and the
    /// copy are all things the main thread must not be doing.
    public func install(_ downloaded: DownloadedUpdate, running: ReleaseVersion) throws -> InstallOutcome {
        let mountPoint = try Self.makeMountPoint()
        defer { try? tearDown(mountPoint) }

        try DiskImage(runner: runner).mount(downloaded.imageURL, at: mountPoint)
        let app = try Self.appInside(mountPoint)

        // Gate 3 — the signature, both halves.
        let signature = CodeSignature(runner: runner)
        try signature.verify(app)
        let team = try signature.teamIdentifier(of: app)
        guard team == AppIdentity.updateTeamIdentifier else {
            throw UpdateBundleError.wrongTeam(expected: AppIdentity.updateTeamIdentifier, actual: team)
        }

        // Gate 4 — the bundle's own identity, and that it is newer.
        let facts = try BundleFacts.read(at: app)
        guard facts.identifier == AppIdentity.bundleIdentifier else {
            throw UpdateBundleError.wrongBundleIdentifier(expected: AppIdentity.bundleIdentifier,
                                                         actual: facts.identifier)
        }
        guard let version = facts.version else {
            throw UpdateBundleError.versionMismatch(release: downloaded.version, bundle: nil)
        }
        // The release's tag and the app inside it have to agree. Without this,
        // a release offering 2.2.0 could deliver a 2.1.1 bundle and the tag
        // would be the only thing that ever said otherwise.
        guard version == downloaded.version else {
            throw UpdateBundleError.versionMismatch(release: downloaded.version, bundle: version)
        }
        guard version > running else {
            throw UpdateBundleError.notNewer(downloaded: version, running: running)
        }

        guard Self.canReplaceBundle(at: runningBundle) else {
            return .revealed(version: version, imageURL: downloaded.imageURL)
        }
        try replaceRunningBundle(with: app, version: version, signature: signature)
        return .replaced(version: version)
    }

    /// Copies the verified app beside its destination, verifies the copy, and
    /// swaps it in.
    ///
    /// `ditto` rather than `FileManager.copyItem`: a bundle's signature covers
    /// extended attributes and resource forks, and a copy that quietly drops one
    /// produces a bundle that fails its own signature check.
    private func replaceRunningBundle(with staged: URL,
                                     version: ReleaseVersion,
                                     signature: CodeSignature) throws {
        let parent = runningBundle.deletingLastPathComponent()
        // Beside the target, so the swap is a rename on one volume, and named
        // with a leading dot so a failed attempt is never mistaken for an
        // installed app.
        let destination = parent.appendingPathComponent(".\(runningBundle.lastPathComponent).\(version)")

        try? FileManager.default.removeItem(at: destination)
        let copied: BoundedProcessResult
        do {
            copied = try runner.run(executable: Self.ditto,
                                    arguments: [staged.path, destination.path],
                                    timeout: Self.copyTimeout)
        } catch {
            throw UpdateBundleError.installFailed(error.localizedDescription)
        }
        guard !copied.timedOut else {
            throw UpdateBundleError.installFailed("copying it took too long")
        }
        guard copied.terminationStatus == 0 else {
            throw UpdateBundleError.installFailed(DiskImage.detail(of: copied))
        }

        // The copy that will be the app is verified as it sits on disk, not the
        // original it came from: a copy that did not survive the trip is a copy
        // that does not get installed.
        do {
            try signature.verify(destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }

        do {
            _ = try FileManager.default.replaceItemAt(runningBundle, withItemAt: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw UpdateBundleError.installFailed(error.localizedDescription)
        }
    }

    /// Exactly one application, deliberately: a volume holding two candidates
    /// has no answer this app can justify, and picking either would be a guess
    /// about which app the user is about to run.
    public static func appInside(_ directory: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let apps = entries.filter { $0.pathExtension == "app" }
        guard !apps.isEmpty else { throw UpdateBundleError.noAppInImage }
        guard apps.count == 1 else {
            throw UpdateBundleError.severalAppsInImage(apps.map(\.lastPathComponent).sorted())
        }
        return apps[0]
    }

    /// A private place to mount: not `/Volumes`, not the user's Desktop.
    static func makeMountPoint() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurtleDiver-mount-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                 ofItemAtPath: url.path)
        } catch {
            throw UpdateBundleError.mountFailed(error.localizedDescription)
        }
        return url
    }

    /// Detach first, then remove the directory: a mount point cannot be removed
    /// while something is still mounted on it.
    func tearDown(_ mountPoint: URL) throws {
        DiskImage(runner: runner).detach(mountPoint)
        try FileManager.default.removeItem(at: mountPoint)
    }
}
