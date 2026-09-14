import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules

final class DNSResolverTests: XCTestCase {

    // MARK: - Caching behavior

    func testCachesPositiveResults() {
        let fake = FakeDNSResolver(table: ["example.com": [IPAddress.parse("1.2.3.4")!]])
        let cache = CachingDNSResolver(underlying: fake, positiveTTL: 60, negativeTTL: 5)

        XCTAssertEqual(cache.resolve(host: "example.com").count, 1)
        XCTAssertEqual(cache.resolve(host: "example.com").count, 1)
        XCTAssertEqual(cache.resolve(host: "example.com").count, 1)
        XCTAssertEqual(fake.lookupCounts["example.com"], 1, "second and third lookups must be served from cache")
    }

    func testNegativeResultsCachedWithSeparateTTL() {
        let fake = FakeDNSResolver(table: [:])
        let cache = CachingDNSResolver(underlying: fake, positiveTTL: 60, negativeTTL: 5)

        _ = cache.resolve(host: "missing.example")
        _ = cache.resolve(host: "missing.example")
        XCTAssertEqual(fake.lookupCounts["missing.example"], 1)
    }

    func testExpiryTriggersRefetch() {
        let fake = FakeDNSResolver(table: ["example.com": [IPAddress.parse("1.2.3.4")!]])
        let cache = CachingDNSResolver(underlying: fake, positiveTTL: 0.05, negativeTTL: 5)

        _ = cache.resolve(host: "example.com")
        Thread.sleep(forTimeInterval: 0.08)
        _ = cache.resolve(host: "example.com")
        XCTAssertEqual(fake.lookupCounts["example.com"], 2)
    }

    func testClearCacheForcesRefetch() {
        let fake = FakeDNSResolver(table: ["example.com": [IPAddress.parse("1.2.3.4")!]])
        let cache = CachingDNSResolver(underlying: fake, positiveTTL: 60)

        _ = cache.resolve(host: "example.com")
        cache.clearCache()
        _ = cache.resolve(host: "example.com")
        XCTAssertEqual(fake.lookupCounts["example.com"], 2)
    }

    func testCacheEvictionCapsEntries() {
        var table: [String: [IPAddress]] = [:]
        for i in 0..<64 {
            table["host\(i).example"] = [IPAddress.parse("10.0.0.\(i)")!]
        }
        let fake = FakeDNSResolver(table: table)
        let cache = CachingDNSResolver(underlying: fake, positiveTTL: 60, maxEntries: 16)

        for i in 0..<64 {
            _ = cache.resolve(host: "host\(i).example")
        }
        XCTAssertLessThanOrEqual(cache.entryCount, 16)
    }

    // MARK: - System resolver (loopback only, no external DNS)

    func testSystemResolverResolvesLoopback() {
        let resolver = SystemDNSResolver()
        let addresses = resolver.resolve(host: "localhost")
        XCTAssertTrue(addresses.contains { $0.isIPv4 && $0.bytes == [127, 0, 0, 1] })
    }

    func testSystemResolverReturnsEmptyForGarbage() {
        let resolver = SystemDNSResolver()
        XCTAssertTrue(resolver.resolve(host: "definitely-not-a-real-host-turtlediver.invalid").isEmpty)
    }
}
