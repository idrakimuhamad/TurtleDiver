import Foundation

// MARK: - Version

/// A release version, as this project tags one ("v2.1.0"), reduced to what
/// comparing it against the running build needs.
///
/// Parsing is deliberately strict: anything this cannot order — "nightly",
/// "2.1.0-beta.1", "1.x" — parses to `nil` rather than to a guess, and the caller
/// reports that instead of offering an update it cannot justify.
///
/// Comparison is numeric, field by field, which is the reason the type exists:
/// as text "2.10.0" sorts *before* "2.9.0", and a release judged older than the
/// running build is a release that is never offered. A shorter version is padded
/// with zeros, so "2.0" and "2.0.0" are the same version rather than an ordering
/// accident.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {

    /// One integer per dot-separated field, in the order written.
    public let fields: [Int]

    /// `nil` unless `text` is dotted decimal, optionally `v`-prefixed.
    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }
        guard !body.isEmpty else { return nil }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        var fields: [Int] = []
        fields.reserveCapacity(parts.count)
        for part in parts {
            // ASCII digits only: `Int("٣")` parses, and a version field is never
            // anything but 0-9. `Int` returns nil on overflow, which is the right
            // answer for a field with twenty digits in it.
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part) else { return nil }
            fields.append(value)
        }
        self.fields = fields
    }

    public var description: String { fields.map(String.init).joined(separator: ".") }

    public static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let width = max(lhs.fields.count, rhs.fields.count)
        for index in 0..<width {
            let left = index < lhs.fields.count ? lhs.fields[index] : 0
            let right = index < rhs.fields.count ? rhs.fields[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

// MARK: - The feed's own shape

/// One file attached to a release.
public struct UpdateAsset: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let byteCount: Int?
    /// GitHub's own server-computed digest (`"sha256:…"`), when the API supplies
    /// one. It is a second opinion rather than a replacement: the project also
    /// publishes a `.sha256` asset beside the installer, and the download path
    /// compares both.
    public let digest: String?

    public init(name: String, url: URL, byteCount: Int? = nil, digest: String? = nil) {
        self.name = name
        self.url = url
        self.byteCount = byteCount
        self.digest = digest
    }

    /// The bare hexadecimal digest, when the API supplied a `sha256:` one.
    public var sha256: String? {
        guard let digest else { return nil }
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return nil }
        return String(digest.dropFirst(prefix.count))
    }
}

/// A published release as the feed describes it — not yet judged against the
/// build that is running.
public struct UpdateRelease: Equatable, Sendable {
    public let tag: String
    /// `nil` when the tag is not a version this app can order.
    public let version: ReleaseVersion?
    public let pageURL: URL?
    public let isDraft: Bool
    public let isPrerelease: Bool
    public let assets: [UpdateAsset]

    public init(tag: String,
                version: ReleaseVersion?,
                pageURL: URL? = nil,
                isDraft: Bool = false,
                isPrerelease: Bool = false,
                assets: [UpdateAsset] = []) {
        self.tag = tag
        self.version = version
        self.pageURL = pageURL
        self.isDraft = isDraft
        self.isPrerelease = isPrerelease
        self.assets = assets
    }
}

/// A newer release the app is willing to hand to a download.
public struct UpdateOffer: Equatable, Sendable {
    public let version: ReleaseVersion
    public let tag: String
    public let pageURL: URL?

    /// The disk image to download, or `nil` when this release has none the app
    /// would use — see `withheldReason`. An offer with no installer is still
    /// worth showing: the release page explains more than a download would.
    ///
    /// It is the disk image and not the package on purpose. The image is a copy
    /// that needs no privilege; the package installs with an installer and an
    /// administrator, and this app never elevates on its own initiative.
    public let installer: UpdateAsset?
    /// The published `.sha256` published beside the installer, when there is one.
    public let checksum: UpdateAsset?
    /// Why there is no installer, in a sentence. `nil` when there is one.
    public let withheldReason: String?

    public init(version: ReleaseVersion,
                tag: String,
                pageURL: URL? = nil,
                installer: UpdateAsset? = nil,
                checksum: UpdateAsset? = nil,
                withheldReason: String? = nil) {
        self.version = version
        self.tag = tag
        self.pageURL = pageURL
        self.installer = installer
        self.checksum = checksum
        self.withheldReason = withheldReason
    }

    /// True when there is something to download.
    public var canInstall: Bool { installer != nil }
}

/// What a check concluded.
///
/// Three answers, because two would not be honest: "up to date" and "a newer
/// release exists but it is not one this app will install" are different facts,
/// and reporting the second as the first is a lie the user cannot see.
public enum UpdateDecision: Equatable, Sendable {
    /// Nothing newer than `running` has been published.
    case upToDate(running: ReleaseVersion)
    /// A newer release exists.
    case available(UpdateOffer)
    /// The feed pointed at something this app will not offer, and why. Nothing
    /// to do about it from here; the release page may still be worth reading.
    case withheld(reason: String)
}

// MARK: - Feed

/// The release feed, and the offline judgement of it.
///
/// Everything here is deterministic: the only I/O is the transport a caller
/// hands in, so the decision can be tested against a canned body and no test in
/// this project ever reaches GitHub.
public enum UpdateFeed {

    /// The feed's address, kept as a string so a malformed one is a thrown error
    /// rather than a crash — this project does not force-unwrap URLs.
    public static let latestReleaseURLString =
        "https://api.github.com/repos/idrakimuhamad/TurtleDiver/releases/latest"

    /// Where the newest release is asked for.
    ///
    /// The `latest` endpoint is defined to skip drafts and prereleases, so this
    /// app never sees one — which is why there is no prerelease filter here and
    /// no prerelease setting to explain. A prerelease channel would need the
    /// releases list instead, and is not proposed.
    public static func latestReleaseURL() throws -> URL {
        guard let url = URL(string: latestReleaseURLString) else {
            throw UpdateFeedError.malformed("The update feed's address is not a usable URL")
        }
        return url
    }

    /// The installer's name for a version. The same name `publish.sh` writes, so
    /// a release that does not use it is a release the app will not install.
    public static func installerName(for version: ReleaseVersion) -> String {
        "TurtleDiver-\(version).dmg"
    }

    /// The published checksum's name for a version — beside the installer, not
    /// appended to it: `TurtleDiver-2.0.0.sha256`, not `….dmg.sha256`.
    public static func checksumName(for version: ReleaseVersion) -> String {
        "TurtleDiver-\(version).sha256"
    }

    /// The version this build reports, from `CFBundleShortVersionString` (which
    /// `MARKETING_VERSION` sets). `nil` when there is nothing readable to parse,
    /// which the caller reports as "cannot check" rather than as "up to date".
    public static func runningVersion(fromShortVersionString text: String?) -> ReleaseVersion? {
        guard let text else { return nil }
        return ReleaseVersion(text)
    }

    /// Decodes one release. Throws rather than returning a half-built release: a
    /// feed that has changed shape is not a reason to claim an update exists.
    public static func release(fromJSON data: Data) throws -> UpdateRelease {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UpdateFeedError.malformed("The update feed's reply was not in the expected shape")
        }
        guard !payload.tagName.isEmpty else {
            throw UpdateFeedError.malformed("The update feed's reply carried no version tag")
        }

        let assets: [UpdateAsset] = (payload.assets ?? []).compactMap { asset in
            // An installer is fetched over https or not at all. A relative or
            // plain-http address is a release this app will not install, so it
            // is dropped here and the later decision says so, rather than being
            // surfaced as an offer that fails at the download.
            guard let url = URL(string: asset.browserDownloadURL),
                  url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return UpdateAsset(name: asset.name, url: url, byteCount: asset.size, digest: asset.digest)
        }

        return UpdateRelease(
            tag: payload.tagName,
            version: ReleaseVersion(payload.tagName),
            pageURL: payload.htmlURL.flatMap(URL.init(string:)),
            isDraft: payload.draft ?? false,
            isPrerelease: payload.prerelease ?? false,
            assets: assets
        )
    }

    /// Judges a release against the build that is running.
    public static func decide(running: ReleaseVersion, release: UpdateRelease) -> UpdateDecision {
        if release.isDraft {
            return .withheld(reason: "The newest release is still a draft")
        }
        guard let version = release.version else {
            return .withheld(reason: "The newest release is tagged “\(release.tag)”, "
                + "which is not a version this app can compare")
        }
        guard version > running else { return .upToDate(running: running) }

        // The assets are named for the version they install, so a release whose
        // installer disagrees with its own tag is a release to read, not to run.
        let expected = installerName(for: version)
        let installer = release.assets.first { $0.name == expected }
        let checksum = release.assets.first { $0.name == checksumName(for: version) }

        return .available(UpdateOffer(
            version: version,
            tag: release.tag,
            pageURL: release.pageURL,
            installer: installer,
            checksum: checksum,
            withheldReason: installer == nil ? withholdingReason(release: release, expected: expected) : nil
        ))
    }

    /// Why a newer release has nothing to download, in a sentence.
    private static func withholdingReason(release: UpdateRelease, expected: String) -> String {
        let images = release.assets.map(\.name).filter { $0.hasSuffix(".dmg") }
        guard let first = images.first else {
            // Also the answer when the feed's disk image was dropped for using
            // something other than https: the sentence has to stay true either
            // way, so it names what the app will download, not what exists.
            return "That release has no disk image this app will download"
        }
        return "That release's disk image is named \(first) rather than \(expected), "
            + "so the app will not download it"
    }

    /// The parts of GitHub's release payload this app reads. Extra keys are
    /// ignored, and every optional here is genuinely optional in the API.
    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String
            let size: Int?
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
                case size
                case digest
            }
        }

        let tagName: String
        let htmlURL: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft
            case prerelease
            case assets
        }
    }
}

// MARK: - Errors

public enum UpdateFeedError: LocalizedError, Equatable {
    case insecureURL(String)
    case redirectedToInsecureURL(String)
    case tooLarge(bytes: Int, limit: Int)
    case httpStatus(Int)
    case malformed(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url):
            return "Refusing to fetch \(url): the update feed must use https"
        case .redirectedToInsecureURL(let url):
            return "Refusing to follow a redirect to \(url): the update feed must use https"
        case .tooLarge(let bytes, let limit):
            return "The update feed's reply is \(bytes / 1024) KB, over the \(limit / 1024) KB limit"
        case .httpStatus(let code):
            if code == 403 || code == 429 {
                return "The update feed answered HTTP \(code), which is how GitHub reports "
                    + "its unauthenticated rate limit"
            }
            return "The update feed answered HTTP \(code)"
        case .malformed(let detail):
            return detail
        case .transport(let detail):
            return detail
        }
    }

    /// One short sentence for a failed request.
    ///
    /// A `URLError` arrives here as a bridged `NSError`, so interpolating it
    /// prints the whole `UserInfo` dictionary — `_kCFStreamErrorDomainKey`,
    /// session-task UUIDs and all. The interesting codes get a sentence of their
    /// own and the rest get the code.
    public static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return (error as? LocalizedError)?.errorDescription ?? "Could not check for updates"
        }
        switch URLError.Code(rawValue: nsError.code) {
        case .cannotFindHost, .dnsLookupFailed:
            return "Could not find the update feed's host"
        case .notConnectedToInternet:
            return "No internet connection"
        case .networkConnectionLost:
            return "The network connection was lost"
        case .timedOut:
            return "The update feed took too long to answer"
        case .cannotConnectToHost:
            return "Could not connect to the update feed's host"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired:
            return "Could not establish a secure connection to the update feed"
        case .unsupportedURL, .badURL:
            return "The update feed's address is not a usable URL"
        case .httpTooManyRedirects:
            return "The update feed redirected too many times"
        default:
            return "Could not check for updates (network error \(nsError.code))"
        }
    }
}

// MARK: - Transport

/// One GET for the feed. A protocol so a checker can be pointed at a canned body
/// — no test in this project reaches GitHub.
public protocol UpdateFeedTransport: Sendable {
    func get(_ url: URL) throws -> (data: Data, finalURL: URL?)
}

/// `URLSession`-backed transport. Synchronous on purpose: the only caller is a
/// background task, and a synchronous call keeps the checker's logic — which is
/// what the tests care about — free of concurrency.
public struct URLSessionUpdateFeedTransport: UpdateFeedTransport {
    public var timeout: TimeInterval
    public var userAgent: String

    /// The release JSON is a few KB. This is a stop for a feed that answers with
    /// something enormous, not a working limit.
    public static let maxBytes = 512 * 1024

    public init(timeout: TimeInterval = 20, userAgent: String = "TurtleDiver") {
        self.timeout = timeout
        self.userAgent = userAgent
    }

    public func get(_ url: URL) throws -> (data: Data, finalURL: URL?) {
        guard url.scheme?.lowercased() == "https" else {
            throw UpdateFeedError.insecureURL(url.absoluteString)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        // GitHub's API wants a User-Agent, and asks that the versioned media type
        // be requested explicitly.
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, URL?), UpdateFeedError>?
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(.transport(UpdateFeedError.describe(error)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(.transport("The update feed sent no HTTP response"))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                outcome = .failure(.httpStatus(http.statusCode))
                return
            }
            guard let data else {
                outcome = .failure(.transport("The update feed sent an empty reply"))
                return
            }
            guard data.count <= Self.maxBytes else {
                outcome = .failure(.tooLarge(bytes: data.count, limit: Self.maxBytes))
                return
            }
            outcome = .success((data, http.url))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw UpdateFeedError.transport("The update feed took too long to answer (over \(Int(timeout))s)")
        }
        guard let outcome else { throw UpdateFeedError.transport("The update feed produced no result") }

        let (data, finalURL) = try outcome.get()
        if let scheme = finalURL?.scheme?.lowercased(), scheme != "https" {
            throw UpdateFeedError.redirectedToInsecureURL(finalURL?.absoluteString ?? "")
        }
        return (data, finalURL)
    }
}

// MARK: - Checker

/// Asks the feed what the newest release is, and judges it against a version.
///
/// There is no ETag or `If-None-Match` here on purpose: this runs once per
/// launch, which is one request, and persisting a validator to save one request
/// would be more state than it is worth.
public struct UpdateChecker: Sendable {
    public let transport: any UpdateFeedTransport

    public init(transport: any UpdateFeedTransport = URLSessionUpdateFeedTransport()) {
        self.transport = transport
    }

    /// The newest release, judged against `running`. Throws only when the check
    /// could not be made — an unreachable feed, or a reply this app cannot read.
    public func check(running: ReleaseVersion) throws -> UpdateDecision {
        let url = try UpdateFeed.latestReleaseURL()
        let (data, _) = try transport.get(url)
        return UpdateFeed.decide(running: running, release: try UpdateFeed.release(fromJSON: data))
    }
}
