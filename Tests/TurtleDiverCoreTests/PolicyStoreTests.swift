import XCTest
@testable import TurtleDiverCore

final class PolicyStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PolicyStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fixture

    /// Profile: two proxies (Fast, Slow), a url-test group, a fallback group,
    /// a load-balance group, a select group, and rules covering each.
    private func makeProfile() -> Profile {
        var profile = Profile(name: "P1")
        profile.proxies = [
            ProxyDefinition(name: "Fast", type: .http, host: "fast.example.com", port: 8080),
            ProxyDefinition(name: "Slow", type: .socks5, host: "slow.example.com", port: 1080),
            ProxyDefinition(name: "Dead", type: .http, host: "dead.example.com", port: 1)
        ]
        profile.groups = [
            ProxyGroup(name: "Auto", type: .urlTest, policies: ["Fast", "Slow", "Dead"]),
            ProxyGroup(name: "Backup", type: .fallback, policies: ["Dead", "Fast", "Slow"]),
            ProxyGroup(name: "Spread", type: .loadBalance, policies: ["Fast", "Slow"]),
            ProxyGroup(name: "Pick", type: .select, policies: ["Auto", "Fast", "DIRECT"]),
            ProxyGroup(name: "Chain", type: .select, policies: ["Auto"])
        ]
        profile.rules = [
            ProfileRule(type: .domainSuffix, value: "example.com", policy: "Auto"),
            ProfileRule(type: .domain, value: "exact.com", policy: "Backup"),
            ProfileRule(type: .domainKeyword, value: "bal", policy: "Spread"),
            ProfileRule(type: .domainSuffix, value: "pick.com", policy: "Pick"),
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ]
        return profile
    }

    private func makeStore(
        profile: Profile? = nil,
        measurer: LatencyMeasuring = FakeLatencyMeasurer(results: [:]),
        autoStart: Bool = false
    ) -> PolicyStore {
        PolicyStore(
            profile: profile ?? makeProfile(),
            defaults: defaults,
            measurer: measurer,
            autoStartTesting: autoStart,
            synchronousTesting: true
        )
    }

    // MARK: - Basic resolution

    func testResolveBuiltins() throws {
        let store = makeStore()
        XCTAssertEqual(try store.resolve("DIRECT"), .direct)
        XCTAssertEqual(try store.resolve("direct"), .direct, "case-insensitive")
        XCTAssertEqual(try store.resolve("REJECT"), .reject)
    }

    func testResolveProxyPolicy() throws {
        let store = makeStore()
        guard case .proxy(let proxy) = try store.resolve("Fast") else {
            return XCTFail("expected proxy decision")
        }
        XCTAssertEqual(proxy.name, "Fast")
        XCTAssertEqual(proxy.port, 8080)
    }

    func testResolveUnknownPolicyThrows() {
        let store = makeStore()
        XCTAssertThrowsError(try store.resolve("Nope")) { error in
            XCTAssertEqual(error as? PolicyStore.PolicyStoreError, .unknownPolicy("Nope"))
        }
    }

    func testRuleReferencesResolve() {
        let store = makeStore()
        XCTAssertTrue(store.allReferencesResolvable())
    }

    // MARK: - Group behaviors (with canned health)

    func testURLTestGroupPicksLowestLatency() throws {
        let measurer = FakeLatencyMeasurer(results: [
            "Fast": .success(ms: 12),
            "Slow": .success(ms: 250),
            "Dead": .failure("refused")
        ])
        let store = makeStore(measurer: measurer)
        store.testAllPolicies() // synchronous through the fake
        guard case .proxy(let chosen) = try store.resolve("Auto") else {
            return XCTFail("expected proxy")
        }
        XCTAssertEqual(chosen.name, "Fast")
    }

    func testURLTestGroupFallsBackToFirstHealthyWhenNoMeasurements() throws {
        // All unknown (no probes yet): first candidate wins.
        let store = makeStore()
        guard case .proxy(let chosen) = try store.resolve("Auto") else {
            return XCTFail("expected proxy")
        }
        XCTAssertEqual(chosen.name, "Fast", "no data → first listed")
    }

    func testURLTestGroupSkipsDeadWhenUntested() throws {
        let store = makeStore()
        // Mark Fast as dead without probing the others.
        var profile = makeProfile()
        profile.groups[0] = ProxyGroup(name: "Auto", type: .urlTest, policies: ["Dead", "Fast", "Slow"])
        let store2 = PolicyStore(profile: profile, defaults: defaults, measurer: FakeLatencyMeasurer(results: [:]), autoStartTesting: false, synchronousTesting: true)
        store2.testAllPolicies(testURL: nil, timeoutSeconds: 1)
        // After probing with all failures, no candidate is healthy — first listed returned.
        guard case .proxy(let chosen) = try store2.resolve("Auto") else {
            return XCTFail("expected proxy")
        }
        XCTAssertEqual(chosen.name, "Dead")
    }

    func testFallbackGroupPrefersFirstHealthyInOrder() throws {
        let measurer = FakeLatencyMeasurer(results: [
            "Fast": .success(ms: 5),      // healthy but later in order
            "Dead": .failure("refused")   // first in order, dead
        ])
        let store = makeStore(measurer: measurer)
        store.testAllPolicies()
        guard case .proxy(let chosen) = try store.resolve("Backup") else {
            return XCTFail("expected proxy")
        }
        XCTAssertEqual(chosen.name, "Fast", "first healthy in order (Dead is first but failed)")
    }

    func testFallbackGroupStaysOnFirstWhenNothingHealthy() throws {
        let measurer = FakeLatencyMeasurer(results: [
            "Fast": .failure("x"), "Slow": .failure("x"), "Dead": .failure("x")
        ])
        let store = makeStore(measurer: measurer)
        store.testAllPolicies()
        guard case .proxy(let chosen) = try store.resolve("Backup") else {
            return XCTFail("expected proxy")
        }
        XCTAssertEqual(chosen.name, "Dead", "nothing healthy → stay on first in order")
    }

    func testLoadBalanceRotatesAcrossHealthyMembers() throws {
        let measurer = FakeLatencyMeasurer(results: [
            "Fast": .success(ms: 10),
            "Slow": .success(ms: 20)
        ])
        var profile = makeProfile()
        // Add Dead to the pool; it must be excluded from rotation.
        profile.groups[2] = ProxyGroup(name: "Spread", type: .loadBalance, policies: ["Fast", "Slow", "Dead"])
        let store = makeStore(profile: profile, measurer: measurer)
        store.testAllPolicies()

        var picks: [String] = []
        for _ in 0..<4 {
            guard case .proxy(let chosen) = try store.resolve("Spread") else {
                return XCTFail("expected proxy")
            }
            picks.append(chosen.name)
        }
        XCTAssertEqual(Set(picks), ["Fast", "Slow"], "rotation covers healthy members only")
        XCTAssertFalse(picks.contains("Dead"))
    }

    func testNestedGroupResolutionChain() throws {
        let measurer = FakeLatencyMeasurer(results: ["Fast": .success(ms: 30), "Slow": .success(ms: 90)])
        let store = makeStore(measurer: measurer)
        store.testAllPolicies()
        // Chain → Auto (url-test) → Fast
        guard case .proxy(let chosen) = try store.resolve("Chain") else {
            return XCTFail("expected proxy")
        }
        XCTAssertEqual(chosen.name, "Fast")
    }

    // MARK: - Select groups & persistence

    func testSelectGroupDefaultsToFirst() throws {
        let store = makeStore()
        XCTAssertEqual(store.selection(forGroup: "Pick"), nil)
        guard case .proxy(let chosen) = try store.resolve("Pick") else {
            return XCTFail("expected proxy")
        }
        XCTAssertEqual(chosen.name, "Fast", "first member (Auto resolves to Fast with no data)")
    }

    func testSelectGroupUserChoicePersisted() throws {
        let store = makeStore()
        store.setSelection("DIRECT", forGroup: "Pick")
        XCTAssertEqual(store.selection(forGroup: "Pick"), "DIRECT")
        XCTAssertEqual(try store.resolve("Pick"), .direct)

        // A new store over the same defaults must restore the choice.
        let store2 = makeStore()
        XCTAssertEqual(store2.selection(forGroup: "Pick"), "DIRECT")
    }

    func testSetSelectionRejectsInvalidMember() {
        let store = makeStore()
        store.setSelection("REJECT", forGroup: "Pick") // not a member
        XCTAssertEqual(store.selection(forGroup: "Pick"), nil)
        store.setSelection("Fast", forGroup: "Auto") // not a select group
        XCTAssertEqual(store.selection(forGroup: "Auto"), nil)
    }

    // MARK: - Health bookkeeping

    func testBestLatencyTrackedAcrossRuns() {
        let measurer = FakeLatencyMeasurer(results: ["Fast": .success(ms: 100)])
        let store = makeStore(measurer: measurer)
        store.testAllPolicies()
        XCTAssertEqual(store.health(for: "Fast")?.bestLatencyMs, 100)

        measurer.setResult(.success(ms: 40), for: "Fast")
        store.testAllPolicies()
        XCTAssertEqual(store.health(for: "Fast")?.bestLatencyMs, 40, "best latency keeps the minimum")

        measurer.setResult(.failure("down"), for: "Fast")
        store.testAllPolicies()
        XCTAssertEqual(store.health(for: "Fast")?.bestLatencyMs, 40, "failures don't erase best")
        XCTAssertEqual(store.health(for: "Fast")?.lastResult, .failure("down"))
    }

    func testSummariesIncludeBuiltinsProxiesGroups() {
        let store = makeStore()
        let names = store.summaries().map(\.name)
        XCTAssertTrue(names.contains("DIRECT"))
        XCTAssertTrue(names.contains("REJECT"))
        XCTAssertTrue(names.contains("Fast"))
        XCTAssertTrue(names.contains("Auto"))
    }

    // MARK: - Profile swap

    func testUpdateProfilePreservesHealthForExistingPolicies() {
        let measurer = FakeLatencyMeasurer(results: ["Fast": .success(ms: 42)])
        let store = makeStore(measurer: measurer)
        store.testAllPolicies()
        XCTAssertEqual(store.health(for: "Fast")?.lastResult, .success(ms: 42))

        var newProfile = makeProfile()
        // Replace Fast's definition (same name → health should survive)...
        newProfile.proxies[0] = ProxyDefinition(name: "Fast", type: .http, host: "newhost.example.com", port: 9090)
        // ...and remove Slow entirely (its health must be pruned).
        newProfile.proxies.removeAll { $0.name == "Slow" }
        store.updateProfile(newProfile)

        XCTAssertEqual(store.health(for: "Fast")?.lastResult, .success(ms: 42), "health survives the swap for same-named policies")
        XCTAssertNil(store.health(for: "Slow"), "policies absent from new profile are pruned")
    }

    func testUpdateProfileDropsSelectionsForRemovedGroups() {
        let store = makeStore()
        store.setSelection("DIRECT", forGroup: "Pick")
        XCTAssertEqual(store.selection(forGroup: "Pick"), "DIRECT")

        var newProfile = makeProfile()
        newProfile.groups.removeAll { $0.name == "Pick" }
        store.updateProfile(newProfile)
        XCTAssertEqual(store.selection(forGroup: "Pick"), nil)
    }

    // MARK: - Defensive cycle guard

    func testResolveDetectsCycleDefensively() {
        // Construct a cycle bypassing profile-level validation, as could
        // happen via a direct API user.
        var profile = Profile(name: "Cycle")
        profile.groups = [
            ProxyGroup(name: "A", type: .select, policies: ["B"]),
            ProxyGroup(name: "B", type: .select, policies: ["A"])
        ]
        let store = PolicyStore(profile: profile, defaults: nil, measurer: FakeLatencyMeasurer(results: [:]), autoStartTesting: false, synchronousTesting: true)
        XCTAssertThrowsError(try store.resolve("A")) { error in
            if case PolicyStore.PolicyStoreError.groupCycle(let path)? = error as? PolicyStore.PolicyStoreError {
                XCTAssertEqual(path, ["A", "B", "A"])
            } else {
                XCTFail("expected cycle error, got \(error)")
            }
        }
    }

    // MARK: - Auto-testing lifecycle

    func testAutoTestingStartsAndStops() {
        let store = makeStore(autoStart: false)
        store.startAutoTesting()
        store.stopAutoTesting() // must not crash; timer cancelled
        store.stopAutoTesting() // idempotent
    }
}
