import Foundation

#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif

// MARK: - Transport

/// A conditional GET for one rule list.
public struct RuleSetRequest: Equatable, Sendable {
    public var url: URL
    /// `If-None-Match` when we already have a copy.
    public var etag: String?
    /// `If-Modified-Since` when we already have a copy.
    public var lastModified: String?

    public init(url: URL, etag: String? = nil, lastModified: String? = nil) {
        self.url = url
        self.etag = etag
        self.lastModified = lastModified
    }
}

public struct RuleSetResponse: Equatable, Sendable {
    public var statusCode: Int
    /// `nil` for `304 Not Modified`.
    public var body: Data?
    public var etag: String?
    public var lastModified: String?
    /// Where the response actually came from, after redirects. Used to refuse a
    /// redirect that silently downgrades to `http`.
    public var finalURL: URL?

    public init(
        statusCode: Int,
        body: Data? = nil,
        etag: String? = nil,
        lastModified: String? = nil,
        finalURL: URL? = nil
    ) {
        self.statusCode = statusCode
        self.body = body
        self.etag = etag
        self.lastModified = lastModified
        self.finalURL = finalURL
    }
}

/// Injected so the store can be tested without a network.
public protocol RuleSetTransport: Sendable {
    func send(_ request: RuleSetRequest) throws -> RuleSetResponse
}

/// `URLSession`-backed transport. Synchronous on purpose: the only caller is a
/// background `Task`, and a synchronous call keeps the store's logic — which is
/// what the tests care about — free of concurrency.
public struct URLSessionRuleSetTransport: RuleSetTransport {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    public func send(_ request: RuleSetRequest) throws -> RuleSetResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = timeout
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("TurtleDiver", forHTTPHeaderField: "User-Agent")
        if let etag = request.etag { urlRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = request.lastModified {
            urlRequest.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<RuleSetResponse, Error>?
        let task = URLSession.shared.dataTask(with: urlRequest) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                outcome = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure(RuleSetStoreError.transport("no HTTP response"))
                return
            }
            outcome = .success(RuleSetResponse(
                statusCode: http.statusCode,
                body: http.statusCode == 304 ? nil : data,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                finalURL: http.url
            ))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw RuleSetStoreError.transport("timed out after \(Int(timeout))s")
        }
        guard let outcome else { throw RuleSetStoreError.transport("no response") }
        return try outcome.get()
    }
}

// MARK: - Errors

public enum RuleSetStoreError: LocalizedError, Equatable {
    case insecureURL(String)
    case tooLarge(bytes: Int, limit: Int)
    case notUTF8
    case httpStatus(Int)
    case redirectedToInsecureURL(String)
    case transport(String)
    case ruleLimitExceeded(Int)

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url):
            return "Refusing to fetch \(url): rule sets must use https"
        case .tooLarge(let bytes, let limit):
            return "Rule set is \(bytes / 1024) KB, over the \(limit / 1024) KB limit; keeping the last good copy"
        case .notUTF8:
            return "Rule set is not valid UTF-8 text"
        case .httpStatus(let code):
            return "Server returned HTTP \(code)"
        case .redirectedToInsecureURL(let url):
            return "Refusing to follow a redirect to \(url): rule sets must use https"
        case .transport(let detail):
            return detail
        case .ruleLimitExceeded(let limit):
            return "Rule set has more than \(limit) rules; keeping the last good copy"
        }
    }
}

// MARK: - Store

/// Owns the on-disk cache of remote rule lists: one body per set, plus a
/// sidecar with the HTTP validators and the fetch time.
///
/// Nothing here touches the network synchronously from the caller's thread by
/// itself — the caller decides. Failures never delete a good copy: a set that
/// cannot be refreshed keeps the rules it already has, and `RuleSetCacheEntry`
/// records how old they are so the UI can say so.
public struct RuleSetStore: Sendable {
    /// Hard cap on a downloaded body. A rule list is text that decides where
    /// traffic goes; 8 MB is roughly 200k rules, which is already absurd.
    public static let maxBytes = 8 * 1024 * 1024

    public let directory: URL
    private let transport: any RuleSetTransport
    private let now: @Sendable () -> Date

    public init(
        directory: URL,
        transport: any RuleSetTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.transport = transport
        self.now = now
    }

    /// `~/Library/Application Support/TurtleDiver/RuleSets`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("TurtleDiver", isDirectory: true)
            .appendingPathComponent("RuleSets", isDirectory: true)
    }

    public init(transport: any RuleSetTransport = URLSessionRuleSetTransport()) {
        self.init(directory: Self.defaultDirectory(), transport: transport)
    }

    // MARK: Paths

    public func bodyURL(for set: RemoteRuleSet) -> URL {
        directory.appendingPathComponent("\(set.cacheFileName).rules")
    }

    public func entryURL(for set: RemoteRuleSet) -> URL {
        directory.appendingPathComponent("\(set.cacheFileName).json")
    }

    // MARK: Reading

    /// Cached rules for every set `profile` declares, keyed by lowercased name.
    /// This is what the matcher wants: `RuleMatcher.expand` looks names up
    /// case-insensitively.
    public func rulesBySet(for profile: Profile) -> [String: [ProfileRule]] {
        var out: [String: [ProfileRule]] = [:]
        for set in profile.ruleSets {
            if let rules = cachedRules(for: set) { out[set.name.lowercased()] = rules }
        }
        return out
    }

    /// Cache state per set name, for the Rule Sets pane. A set that is declared
    /// but never fetched simply has no entry.
    public func entries(for profile: Profile) -> [String: RuleSetCacheEntry] {
        var out: [String: RuleSetCacheEntry] = [:]
        for set in profile.ruleSets {
            if let entry = entry(for: set) { out[set.name.lowercased()] = entry }
        }
        return out
    }

    /// Every set in `profile` whose cached copy is older than its interval.
    public func staleSets(in profile: Profile, now date: Date? = nil) -> [RemoteRuleSet] {
        let reference = date ?? now()
        return profile.ruleSets.filter { set in
            guard let entry = entry(for: set) else { return true }
            return entry.isStale(interval: set.interval, now: reference)
        }
    }

    /// The sidecar for `set`, or nil when it is not cached (or was cached under
    /// a different URL, which means the profile now points somewhere else).
    public func entry(for set: RemoteRuleSet) -> RuleSetCacheEntry? {
        guard let data = try? Data(contentsOf: entryURL(for: set)),
              let entry = try? JSONDecoder().decode(RuleSetCacheEntry.self, from: data),
              entry.url == set.url else { return nil }
        return entry
    }

    /// Cached rules for `set`, parsed. `nil` when the set has never been
    /// fetched. An empty array is a legitimate answer: a list can be empty.
    public func cachedRules(for set: RemoteRuleSet) -> [ProfileRule]? {
        guard entry(for: set) != nil,
              let data = try? Data(contentsOf: bodyURL(for: set)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return RuleSetParser.parse(text).rules
    }

    public struct Loaded: Equatable, Sendable {
        public var entry: RuleSetCacheEntry
        public var rules: [ProfileRule]
    }

    public func load(_ set: RemoteRuleSet) -> Loaded? {
        guard let entry = entry(for: set), let rules = cachedRules(for: set) else { return nil }
        return Loaded(entry: entry, rules: rules)
    }

    // MARK: Refreshing

    public enum Outcome: Equatable, Sendable {
        case updated(RuleSetCacheEntry)
        case notModified(RuleSetCacheEntry)
        /// The previous copy (if any) is still in place.
        case unavailable(message: String)
    }

    @discardableResult
    public func refresh(_ set: RemoteRuleSet) -> Outcome {
        guard RemoteRuleSet.isAllowedURLString(set.url), let url = URL(string: set.url) else {
            return .unavailable(message: RuleSetStoreError.insecureURL(set.url).localizedDescription)
        }

        let previous = entry(for: set)
        let response: RuleSetResponse
        do {
            response = try transport.send(RuleSetRequest(
                url: url,
                etag: previous?.etag,
                lastModified: previous?.lastModified
            ))
        } catch {
            return .unavailable(message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }

        if let finalURL = response.finalURL, finalURL.scheme?.lowercased() != "https" {
            return .unavailable(message: RuleSetStoreError.redirectedToInsecureURL(finalURL.absoluteString).localizedDescription)
        }

        if response.statusCode == 304 {
            // Nothing new; the copy we have is current. Touch the fetch time so
            // "updated 3 days ago" reflects the last *confirmation*.
            guard var entry = previous else {
                return .unavailable(message: RuleSetStoreError.httpStatus(304).localizedDescription)
            }
            entry.fetchedAt = now()
            if let etag = response.etag { entry.etag = etag }
            if let modified = response.lastModified { entry.lastModified = modified }
            guard write(entry, for: set) else {
                return .unavailable(message: "Could not update \(entryURL(for: set).lastPathComponent)")
            }
            return .notModified(entry)
        }

        guard response.statusCode == 200 else {
            return .unavailable(message: RuleSetStoreError.httpStatus(response.statusCode).localizedDescription)
        }
        guard let body = response.body else {
            return .unavailable(message: RuleSetStoreError.transport("empty response body").localizedDescription)
        }
        guard body.count <= Self.maxBytes else {
            return .unavailable(message: RuleSetStoreError.tooLarge(bytes: body.count, limit: Self.maxBytes).localizedDescription)
        }
        guard let text = String(data: body, encoding: .utf8) else {
            return .unavailable(message: RuleSetStoreError.notUTF8.localizedDescription)
        }

        let parsed = RuleSetParser.parse(text)
        guard !parsed.truncated else {
            return .unavailable(message: RuleSetStoreError.ruleLimitExceeded(RuleSetParser.maxRules).localizedDescription)
        }

        let entry = RuleSetCacheEntry(
            name: set.name,
            url: set.url,
            etag: response.etag ?? previous?.etag,
            lastModified: response.lastModified ?? previous?.lastModified,
            fetchedAt: now(),
            ruleCount: parsed.rules.count,
            skippedCount: parsed.skipped.count,
            byteCount: body.count
        )

        // Body first, then the sidecar: a crash in between leaves an unread
        // body (readable only once the sidecar exists) rather than an entry
        // that claims rules which are not there.
        guard write(body, to: bodyURL(for: set)) else {
            return .unavailable(message: "Could not write \(bodyURL(for: set).lastPathComponent)")
        }
        guard write(entry, for: set) else {
            return .unavailable(message: "Could not write \(entryURL(for: set).lastPathComponent)")
        }
        return .updated(entry)
    }

    /// Drops the cached copy of `set`. The next refresh fetches from scratch.
    public func removeCache(for set: RemoteRuleSet) {
        try? FileManager.default.removeItem(at: bodyURL(for: set))
        try? FileManager.default.removeItem(at: entryURL(for: set))
    }

    // MARK: Writing

    private func write(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private func write(_ entry: RuleSetCacheEntry, for set: RemoteRuleSet) -> Bool {
        guard let data = try? JSONEncoder().encode(entry) else { return false }
        return write(data, to: entryURL(for: set))
    }
}
