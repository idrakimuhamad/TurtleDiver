import CryptoKit
import Foundation

// MARK: - Errors

/// Why a release's file was not accepted.
///
/// Terse phrases, like `UpdateFeedError`, because this ends up as one line
/// beside a pill. The digests themselves stay in the value — a test and any
/// diagnostic can read them, but a pair of 64-character hex strings is not a
/// sentence for a human.
public enum UpdateArtifactError: LocalizedError, Equatable {
    case insecureURL(String)
    case redirectedToInsecureURL(String)
    case wrongName(expected: String, actual: String)
    case tooLarge(bytes: Int, limit: Int)
    case sizeDisagrees(expected: Int, actual: Int)
    case noPublishedChecksum(String)
    case checksumMismatch(source: String, expected: String, actual: String)
    case malformed(String)
    case transport(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url):
            return "Refusing to download \(url): a release file must come over https"
        case .redirectedToInsecureURL(let url):
            return "Refusing to follow a redirect to \(url): a release file must come over https"
        case .wrongName(let expected, let actual):
            return "That release's file is named \(actual) rather than \(expected), "
                + "so the app will not download it"
        case .tooLarge(let bytes, let limit):
            return "The release file is \(bytes / 1024) KB, over the \(limit / 1024) KB limit"
        case .sizeDisagrees(let expected, let actual):
            return "The release file is \(actual) bytes, and the release says it is \(expected)"
        case .noPublishedChecksum(let name):
            return "\(name) was published without a SHA-256 digest to check it against"
        case .checksumMismatch(let source, _, _):
            return "The downloaded file is not the file \(source) describes"
        case .malformed(let detail):
            return detail
        case .transport(let detail):
            return detail
        case .writeFailed(let detail):
            return "Could not save the downloaded file: \(detail)"
        }
    }

    /// Anything thrown on the way in, as one of these.
    ///
    /// The small fetches share `UpdateFeedTransport`, so their failures arrive as
    /// `UpdateFeedError` — already sentences. A bare `URLError` is the other
    /// shape a failure takes here, and it must not print its `UserInfo`.
    public static func wrap(_ error: Error) -> UpdateArtifactError {
        if let error = error as? UpdateArtifactError { return error }
        if let error = error as? UpdateFeedError {
            return .transport(error.errorDescription ?? "Could not download the release file")
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return .transport(UpdateFeedError.describe(error))
        }
        return .malformed((error as? LocalizedError)?.errorDescription
            ?? "Could not download the release file")
    }
}

// MARK: - Limits

/// How big a release file may be, and the refusal when it is bigger.
///
/// One place, so the transport's backstop (which keeps an enormous reply out of
/// the system's temporary directory) and the downloader's own check (which keeps
/// one out of the app's directory) cannot drift apart — and so the decision is
/// testable without a network.
public enum UpdateArtifactLimit {
    /// A release image is a few megabytes. This is a stop for a release that
    /// answers with something enormous, not a working limit.
    public static let installerBytes = 256 * 1024 * 1024

    public static func refusal(size: Int, limit: Int = installerBytes) -> UpdateArtifactError? {
        size > limit ? .tooLarge(bytes: size, limit: limit) : nil
    }
}

// MARK: - Digests

/// SHA-256, and the two shapes a published digest is written in.
///
/// `CryptoKit` here, deliberately, where `RuleSetStore` uses FNV-1a for cache
/// file names: a cache name only has to be stable, and this has to be
/// unforgeable. The value being checked is the only thing standing between a
/// release file and the user's disk, so it is a real hash.
public enum FileDigest {

    /// The digest of a file, read in chunks so a disk image never has to be in
    /// memory at once.
    public static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    public static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The digest inside a published `.sha256` file: `<hex>`, or `<hex>  <name>`
    /// the way `shasum -a 256` writes it. `nil` when the file holds no digest
    /// this app can read — a checksum it cannot read is a checksum it cannot
    /// use, and guessing one is worse than refusing.
    public static func published(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let field = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if isHexDigest(field) { return field.lowercased() }
        }
        return nil
    }

    /// Exactly 64 ASCII hexadecimal characters.
    ///
    /// `isASCII` is not redundant beside `isHexDigit`: that property is true for
    /// the full-width forms too, and a digest written in ＡＢＣ is not a digest
    /// any tool here would agree with.
    public static func isHexDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}

// MARK: - What was fetched

/// A release file that is on disk, with the evidence that it is the file the
/// release published.
public struct DownloadedUpdate: Equatable, Sendable {
    public let version: ReleaseVersion
    public let imageURL: URL
    public let byteCount: Int
    /// The digest this app computed from the bytes it received.
    public let sha256: String
    /// The digest published beside the file, when there was one.
    public let publishedChecksum: String?
    /// The digest GitHub's API computed for the asset, when it reported one.
    public let apiDigest: String?

    public init(version: ReleaseVersion,
                imageURL: URL,
                byteCount: Int,
                sha256: String,
                publishedChecksum: String? = nil,
                apiDigest: String? = nil) {
        self.version = version
        self.imageURL = imageURL
        self.byteCount = byteCount
        self.sha256 = sha256
        self.publishedChecksum = publishedChecksum
        self.apiDigest = apiDigest
    }
}

// MARK: - Transport

/// One fetch of a release file, to a path the caller owns. A protocol so no test
/// in this project reaches GitHub.
public protocol UpdateFileTransport: Sendable {
    /// Writes `url` into `destination`, following redirects, and reports the
    /// address it finally read from so the caller can insist it was https.
    func fetch(_ url: URL, to destination: URL) throws -> URL?
}

/// `URLSession`-backed file transport. Synchronous on purpose: the only caller
/// is a background task.
public struct URLSessionUpdateFileTransport: UpdateFileTransport {
    public var timeout: TimeInterval
    public var userAgent: String
    public var maxBytes: Int

    public init(timeout: TimeInterval = 120,
                userAgent: String = "TurtleDiver",
                maxBytes: Int = UpdateArtifactLimit.installerBytes) {
        self.timeout = timeout
        self.userAgent = userAgent
        self.maxBytes = maxBytes
    }

    public func fetch(_ url: URL, to destination: URL) throws -> URL? {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw UpdateArtifactError.insecureURL(url.absoluteString)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(URL?, Int), UpdateArtifactError>?
        let task = URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(.transport(UpdateFeedError.describe(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(.transport("The release file's download sent no HTTP response"))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                outcome = .failure(.transport("The release file's download answered HTTP \(http.statusCode)"))
                return
            }
            guard let location else {
                outcome = .failure(.malformed("The release file's download produced no file"))
                return
            }
            // `location` is deleted the moment this closure returns, so the size
            // is read and the file moved here or not at all. An oversized file
            // is refused before it ever reaches the app's own directory.
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path))
                .flatMap { $0[.size] as? Int } ?? 0
            guard size > 0 else {
                outcome = .failure(.malformed("The release file's download was empty"))
                return
            }
            if let refusal = UpdateArtifactLimit.refusal(size: size, limit: maxBytes) {
                outcome = .failure(refusal)
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                outcome = .failure(.writeFailed(error.localizedDescription))
                return
            }
            outcome = .success((http.url, size))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw UpdateArtifactError.transport(
                "The release file took too long to download (over \(Int(timeout))s)")
        }
        guard let outcome else {
            throw UpdateArtifactError.transport("The release file's download produced no result")
        }
        return try outcome.get().0
    }
}

// MARK: - Downloading one release's file

/// Fetches a release's disk image and proves it is the file the release
/// published, before anything looks inside it.
///
/// Two of the four gates live here, both decided offline and both decided from
/// what the release itself says:
///
/// 1. **Provenance.** The image is named `TurtleDiver-<version>.dmg`, and every
///    address involved is https. A release whose file is named something else is
///    not a release this app will run — the name is the only place where the
///    feed's tag and its file are made to agree.
/// 2. **The bytes.** The SHA-256 of what arrived is compared against the digest
///    published beside the file *and* against the digest GitHub computed for the
///    asset. Both must agree when both exist; a release that publishes neither is
///    not installed, however plausible its file looks.
///
/// The other two — the signature and the bundle's own identity — need to look
/// inside the image, and live in `UpdateBundle`.
public struct UpdateDownloader: Sendable {
    public let files: any UpdateFileTransport
    /// Used for the small checksum file, which is text: the feed transport
    /// already enforces https, a size cap and a deadline on it.
    public let feed: any UpdateFeedTransport
    /// Where the image is kept. Created 0700, and never a predictable
    /// world-writable path.
    public let directory: URL
    public var maxBytes: Int

    public init(files: any UpdateFileTransport = URLSessionUpdateFileTransport(),
                feed: any UpdateFeedTransport = URLSessionUpdateFeedTransport(),
                directory: URL? = nil,
                maxBytes: Int = UpdateArtifactLimit.installerBytes) {
        self.files = files
        self.feed = feed
        self.directory = directory ?? Self.defaultDirectory
        self.maxBytes = maxBytes
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("TurtleDiver/Updates", isDirectory: true)
    }

    /// Fetches, and returns the evidence. Throws rather than returning a file
    /// that failed any check: there is no "probably fine" here.
    public func fetch(_ offer: UpdateOffer) throws -> DownloadedUpdate {
        guard let installer = offer.installer else {
            throw UpdateArtifactError.malformed("That release has nothing to download")
        }
        try Self.checkProvenance(installer: installer, checksum: offer.checksum, version: offer.version)
        try prepareDirectory()

        // The small file first: a release with nothing to check against should
        // not cost the user six megabytes to find out.
        let published = try publishedChecksum(offer)
        let apiDigest = installer.sha256
        // Both sources are known before a byte is fetched, so a release that
        // published neither is refused here rather than after the download.
        guard published != nil || apiDigest != nil else {
            throw UpdateArtifactError.noPublishedChecksum(installer.name)
        }

        let destination = directory.appendingPathComponent(installer.name)
        if let finalURL = try files.fetch(installer.url, to: destination),
           finalURL.scheme?.lowercased() != "https" {
            throw UpdateArtifactError.redirectedToInsecureURL(finalURL.absoluteString)
        }

        let byteCount = (try? FileManager.default.attributesOfItem(atPath: destination.path))
            .flatMap { $0[.size] as? Int } ?? 0
        do {
            if let refusal = UpdateArtifactLimit.refusal(size: byteCount, limit: maxBytes) {
                throw refusal
            }
            if let expected = installer.byteCount, expected != byteCount {
                throw UpdateArtifactError.sizeDisagrees(expected: expected, actual: byteCount)
            }

            let computed = try FileDigest.sha256(ofFileAt: destination)
            try Self.checkDigests(computed: computed, published: published, api: apiDigest)

            discardOlderFiles(keeping: destination)
            return DownloadedUpdate(version: offer.version,
                                    imageURL: destination,
                                    byteCount: byteCount,
                                    sha256: computed,
                                    publishedChecksum: published,
                                    apiDigest: apiDigest)
        } catch {
            // A file this app has refused is not left staged in the directory the
            // next attempt will read. Nothing reaches it that failed a gate.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Gate 1.
    public static func checkProvenance(installer: UpdateAsset,
                                       checksum: UpdateAsset?,
                                       version: ReleaseVersion) throws {
        try checkSecure(installer.url)
        let expectedImage = UpdateFeed.installerName(for: version)
        guard installer.name == expectedImage else {
            throw UpdateArtifactError.wrongName(expected: expectedImage, actual: installer.name)
        }
        if let checksum {
            try checkSecure(checksum.url)
            let expectedChecksum = UpdateFeed.checksumName(for: version)
            guard checksum.name == expectedChecksum else {
                throw UpdateArtifactError.wrongName(expected: expectedChecksum, actual: checksum.name)
            }
        }
    }

    /// Gate 2. Two independent published digests, both compared against the
    /// bytes that arrived; agreement between them follows, but each source is
    /// named separately so a refusal says which one disagreed.
    public static func checkDigests(computed: String, published: String?, api: String?) throws {
        if let api, api.lowercased() != computed {
            throw UpdateArtifactError.checksumMismatch(source: "the release feed's digest",
                                                      expected: api.lowercased(),
                                                      actual: computed)
        }
        if let published, published.lowercased() != computed {
            throw UpdateArtifactError.checksumMismatch(source: "the release's published checksum",
                                                      expected: published.lowercased(),
                                                      actual: computed)
        }
    }

    private static func checkSecure(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw UpdateArtifactError.insecureURL(url.absoluteString)
        }
    }

    /// The digest published in the `.sha256` file beside the installer, or `nil`
    /// when the release published no such file — which is allowed here and
    /// decided in `fetch`, where "neither source exists" is the answer that
    /// matters.
    private func publishedChecksum(_ offer: UpdateOffer) throws -> String? {
        guard let checksum = offer.checksum else { return nil }
        let body: Data
        do {
            body = try feed.get(checksum.url).data
        } catch {
            throw UpdateArtifactError.wrap(error)
        }
        guard let text = String(data: body, encoding: .utf8) else {
            throw UpdateArtifactError.malformed("The release's checksum file was not text")
        }
        guard let digest = FileDigest.published(in: text) else {
            throw UpdateArtifactError.malformed(
                "The release's checksum file holds no SHA-256 digest this app can read")
        }
        return digest
    }

    private func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // After creation, not through it: `createDirectory` applies the mode
            // to the last component only, and this directory holds what the
            // update is about to run.
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                 ofItemAtPath: directory.path)
        } catch {
            throw UpdateArtifactError.writeFailed(error.localizedDescription)
        }
    }

    /// A previous download is dead weight — six megabytes of an older release,
    /// kept in a directory nothing else reads. Only the file just fetched stays.
    private func discardOlderFiles(keeping kept: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry.lastPathComponent != kept.lastPathComponent {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
