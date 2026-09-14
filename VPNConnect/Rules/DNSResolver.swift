import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Resolver Abstraction

/// Resolves a host name into IP addresses. Abstracted so the matcher can be
/// unit-tested without real DNS.
public protocol DNSResolving: AnyObject, Sendable {
    /// Resolves `host` (no trailing-dot normalization done here). Returns an
    /// empty array when the host cannot be resolved. Called from arbitrary
    /// queues; implementations must be thread-safe.
    func resolve(host: String) -> [IPAddress]
}

// MARK: - System Resolver

/// `getaddrinfo`-backed resolver with strict AF_UNSPEC lookups (both A and
/// AAAA records).
public final class SystemDNSResolver: DNSResolving {
    public init() {}

    public func resolve(host: String) -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return [] }
        defer { freeaddrinfo(result) }

        var out: [IPAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            defer { node = current.pointee.ai_next }
            guard let sa = current.pointee.ai_addr else { continue }
            switch Int32(current.pointee.ai_family) {
            case AF_INET:
                let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                // in_addr already stores the octets in network byte order.
                let bytes = withUnsafeBytes(of: sin.sin_addr) { Array($0.prefix(4)) }
                if let ip = IPAddress(bytes: bytes) { out.append(ip) }
            case AF_INET6:
                let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var bytes: [UInt8] = []
                withUnsafeBytes(of: sin6.sin6_addr) { rawPtr in
                    bytes = Array(rawPtr)
                }
                if let ip = IPAddress(bytes: bytes) { out.append(ip) }
            default:
                break
            }
        }
        return out
    }
}

// MARK: - Caching Resolver

/// Wraps any resolver with a positive/negative TTL cache and an eviction
/// ceiling so long-running sessions cannot accumulate unbounded entries.
public final class CachingDNSResolver: DNSResolving, @unchecked Sendable {
    private struct Entry {
        let addresses: [IPAddress]
        let expiresAt: Date
    }

    private let underlying: DNSResolving
    private let positiveTTL: TimeInterval
    private let negativeTTL: TimeInterval
    private let maxEntries: Int

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]

    /// - Parameters:
    ///   - positiveTTL: how long successful resolutions are cached.
    ///   - negativeTTL: how long failures (empty results) are cached so a dead
    ///     DNS name does not slow every connection.
    ///   - maxEntries: oldest entries are evicted when the cache grows past
    ///     this size (simple safety valve for long-running apps).
    public init(
        underlying: DNSResolving = SystemDNSResolver(),
        positiveTTL: TimeInterval = 60,
        negativeTTL: TimeInterval = 10,
        maxEntries: Int = 512
    ) {
        self.underlying = underlying
        self.positiveTTL = positiveTTL
        self.negativeTTL = negativeTTL
        self.maxEntries = max(16, maxEntries)
    }

    public func resolve(host: String) -> [IPAddress] {
        let now = Date()
        lock.lock()
        if let entry = cache[host], entry.expiresAt > now {
            lock.unlock()
            return entry.addresses
        }
        lock.unlock()
        return resolveUncached(host: host)
    }

    /// Synchronous uncached resolve. Lookup happens on the calling thread and
    /// the result is stored for future callers. The matcher runs off-main, so
    /// a blocking call is acceptable there.
    public func resolveUncached(host: String) -> [IPAddress] {
        let addresses = underlying.resolve(host: host)
        let ttl = addresses.isEmpty ? negativeTTL : positiveTTL
        store(addresses: addresses, host: host, ttl: ttl)
        return addresses
    }

    private func store(addresses: [IPAddress], host: String, ttl: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count >= maxEntries {
            evictOldestLocked()
        }
        cache[host] = Entry(addresses: addresses, expiresAt: Date().addingTimeInterval(ttl))
    }

    /// Evicts expired entries first; if still full, drops the entry with the
    /// earliest expiry.
    private func evictOldestLocked() {
        let now = Date()
        for (host, entry) in cache where entry.expiresAt <= now {
            cache.removeValue(forKey: host)
        }
        guard cache.count >= maxEntries, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt }) else {
            return
        }
        cache.removeValue(forKey: oldest.key)
    }

    /// Drops all cached entries (called on profile hot-swap so rule changes
    /// that rely on fresh DNS take effect immediately).
    public func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// Snapshot for tests: number of live entries.
    var entryCount: Int {
        lock.withLock { cache.count }
    }
}

// MARK: - Lock Helper

// File-scoped so it cannot collide with other same-module extensions of
// NSLock (the app target compiles all sources as one module).
extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
