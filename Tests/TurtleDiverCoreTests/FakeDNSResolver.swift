import Foundation
@testable import TurtleDiverCore
@testable import TurtleDiverRules

/// Deterministic resolver for matcher tests: maps host names to canned
/// addresses and counts how often each host was actually resolved.
final class FakeDNSResolver: DNSResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let table: [String: [IPAddress]]
    private var counts: [String: Int] = [:]

    init(table: [String: [IPAddress]]) {
        self.table = table
    }

    func resolve(host: String) -> [IPAddress] {
        lock.lock()
        defer { lock.unlock() }
        counts[host, default: 0] += 1
        return table[host] ?? []
    }

    var lookupCounts: [String: Int] {
        lock.withLock { counts }
    }
}
