import XCTest
import Foundation
@testable import TurtleDiverAppGlue
import TurtleDiverCore
import TurtleDiverRules
import TurtleDiverSystem

/// Returns a canned body without touching the network.
private final class StubRuleSetTransport: RuleSetTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RuleSetRequest] = []
    var body: String

    init(body: String) { self.body = body }

    var requests: [RuleSetRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    func send(_ request: RuleSetRequest) throws -> RuleSetResponse {
        lock.lock(); _requests.append(request); lock.unlock()
        return RuleSetResponse(statusCode: 200, body: Data(body.utf8))
    }
}

/// `EngineController`'s half of remote rule sets: it reads the cached lists off
/// the main thread and hands the expansion to the matcher. The pure pieces
/// (parsing, expansion, staleness) are pinned down in `RuleSetTests` and
/// `RuleSetStoreTests`; this suite covers the wiring, which is the part that can
/// silently stop happening.
@MainActor
final class RuleSetControllerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rulesetcontroller-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    private func makeSet(_ name: String = "Ads", url: String = "https://example.com/ads.conf") -> RemoteRuleSet {
        RemoteRuleSet(name: name, url: url)
    }

    /// A profile that references `set` from a single `RULE-SET` rule.
    private func makeController(
        sets: [RemoteRuleSet],
        store: RuleSetStore,
        httpPort: Int,
        socksPort: Int
    ) -> (controller: EngineController, manager: ProfileManager) {
        let suiteName = "turtlediver.rulesets.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let manager = ProfileManager(profilesDirectory: tempDir, defaults: defaults)
        var profile = manager.activeProfile
        profile.general.httpListen = "127.0.0.1:\(httpPort)"
        profile.general.socks5Listen = "127.0.0.1:\(socksPort)"
        profile.general.systemProxy = false
        profile.ruleSets = sets
        profile.rules = [
            ProfileRule(type: .ruleSet, value: sets.first?.name ?? "Ads", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ]
        _ = manager.saveAndActivate(profile)

        let systemProxy = SystemProxyManager(
            runner: NullNetworkSetupRunner(),
            defaults: defaults,
            snapshotURL: tempDir.appendingPathComponent("proxy-snapshot.json")
        )
        // Auto-refresh off: a test must never be able to reach the network.
        let settings = SettingsManager(defaults: defaults)
        settings.ruleSetAutoRefresh = false

        let controller = EngineController(
            profileManager: manager,
            settings: settings,
            systemProxy: systemProxy,
            ruleSets: store
        )
        return (controller, manager)
    }

    /// The reload hops off the main thread and back, so give it a moment.
    private func settle(_ condition: @escaping () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testACachedSetIsExpandedIntoTheMatcher() async throws {
        let set = makeSet()
        let transport = StubRuleSetTransport(body: """
        # ads
        DOMAIN-SUFFIX,doubleclick.net
        IP-CIDR,203.0.113.0/24
        """)
        let store = RuleSetStore(directory: tempDir, transport: transport)
        _ = try store.refresh(set)

        let (controller, _) = makeController(sets: [set], store: store, httpPort: 16_152, socksPort: 16_153)
        await settle { controller.engine.matcher.expandedRuleCount == 3 }

        XCTAssertEqual(controller.engine.matcher.expandedRuleCount, 3)
        XCTAssertTrue(controller.engine.matcher.unresolvedRuleSetNames.isEmpty)
        // The reference itself does not match; its members do, under its policy.
        let outcome = try? controller.engine.matcher.match(MatchContext(host: "ads.doubleclick.net", port: 443))
        XCTAssertEqual(outcome?.policy, "REJECT")
        XCTAssertEqual(controller.ruleSetSummaries.map(\.name), ["Ads"])
        XCTAssertEqual(controller.ruleSetSummaries.first?.ruleCount, 2)
    }

    /// A reference to a set that was never downloaded must stay inert — the
    /// reference's policy is not a fallback.
    func testAnUncachedSetExpandsToNothing() async throws {
        let set = makeSet()
        let store = RuleSetStore(directory: tempDir, transport: StubRuleSetTransport(body: ""))

        let (controller, _) = makeController(sets: [set], store: store, httpPort: 16_162, socksPort: 16_163)
        await settle { controller.ruleSetSummaries.count == 1 }

        XCTAssertEqual(controller.engine.matcher.expandedRuleCount, 1)
        XCTAssertEqual(controller.engine.matcher.unresolvedRuleSetNames, ["Ads"])
        // Falls through to FINAL, exactly as if the rule were not there.
        let outcome = try? controller.engine.matcher.match(MatchContext(host: "example.org", port: 443))
        XCTAssertEqual(outcome?.policy, "DIRECT")
        XCTAssertEqual(controller.ruleSetSummaries.first?.isDownloaded, false)
    }

    func testRemovingTheCacheMakesTheReferenceInertAgain() async throws {
        let set = makeSet()
        let store = RuleSetStore(directory: tempDir, transport: StubRuleSetTransport(body: "DOMAIN-SUFFIX,ads.example"))
        _ = try store.refresh(set)

        let (controller, _) = makeController(sets: [set], store: store, httpPort: 16_172, socksPort: 16_173)
        await settle { controller.engine.matcher.expandedRuleCount == 2 }

        controller.removeRuleSetCache(for: set)
        await settle { controller.engine.matcher.expandedRuleCount == 1 }

        XCTAssertEqual(controller.engine.matcher.unresolvedRuleSetNames, ["Ads"])
        XCTAssertNil(store.cachedRules(for: set))
    }

    /// Removing the declaration (what the pane's Delete does) drops the
    /// referencing rule with it, so nothing dangles and nothing is reported.
    func testDeletingTheDeclarationLeavesNoDanglingReference() async throws {
        let set = makeSet()
        let store = RuleSetStore(directory: tempDir, transport: StubRuleSetTransport(body: "DOMAIN-SUFFIX,ads.example"))
        _ = try store.refresh(set)

        let (controller, manager) = makeController(sets: [set], store: store, httpPort: 16_182, socksPort: 16_183)
        await settle { controller.engine.matcher.expandedRuleCount == 2 }

        var profile = manager.activeProfile
        profile.ruleSets.removeAll()
        profile.rules.removeAll { $0.type == .ruleSet }
        _ = manager.saveAndActivate(profile)
        // The pane drives this after every edit: the engine's profile hook only
        // runs while the engine is up.
        controller.reloadRuleSets(refreshStale: false)

        await settle { controller.ruleSetSummaries.isEmpty && controller.engine.matcher.expandedRuleCount == 1 }
        XCTAssertTrue(controller.engine.matcher.unresolvedRuleSetNames.isEmpty)
        XCTAssertTrue(manager.activeProfile.validate().isEmpty)
        XCTAssertTrue(controller.ruleSetSummaries.isEmpty)
    }

    /// The pane's Delete removes the declaration *and* then asks for the cache
    /// to go, in that order. A name lookup at that point finds nothing — the
    /// declaration is already gone — so the controller has to be handed the set
    /// itself, or the downloaded body survives a deletion that promised to
    /// remove it.
    func testDeletingTheDeclarationAlsoDropsItsCachedCopy() async throws {
        let set = makeSet()
        let store = RuleSetStore(directory: tempDir, transport: StubRuleSetTransport(body: "DOMAIN-SUFFIX,ads.example"))
        _ = try store.refresh(set)

        let (controller, manager) = makeController(sets: [set], store: store, httpPort: 16_202, socksPort: 16_203)
        await settle { controller.engine.matcher.expandedRuleCount == 2 }
        XCTAssertNotNil(store.cachedRules(for: set))

        // Exactly what `RuleSetsView.delete(_:)` does, in its order.
        var profile = manager.activeProfile
        profile.ruleSets.removeAll { $0.id == set.id }
        profile.rules.removeAll { $0.type == .ruleSet }
        _ = manager.saveAndActivate(profile)
        controller.removeRuleSetCache(for: set)

        await settle { controller.ruleSetSummaries.isEmpty }
        XCTAssertNil(store.cachedRules(for: set), "the dialog promises the downloaded list goes too")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.bodyURL(for: set).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.entryURL(for: set).path))
    }

    /// An unrelated edit must not quietly disable every rule set. The pane
    /// re-reads the cache; the engine's own profile hook — which runs while the
    /// engine is up and the set declarations are unchanged — passes no new
    /// expansions at all, so "keep what you have" has to be the default.
    func testAnUnrelatedProfileEditKeepsTheExpansion() async throws {
        let set = makeSet()
        let store = RuleSetStore(directory: tempDir, transport: StubRuleSetTransport(body: "DOMAIN-SUFFIX,ads.example"))
        _ = try store.refresh(set)

        let (controller, manager) = makeController(sets: [set], store: store, httpPort: 16_192, socksPort: 16_193)
        await settle { controller.engine.matcher.expandedRuleCount == 2 }

        var profile = manager.activeProfile
        profile.rules.insert(ProfileRule(type: .domain, value: "intranet.example.com", policy: "DIRECT"), at: 0)
        _ = manager.saveAndActivate(profile)
        // An edit that does not touch [Rule Set] must not clear the expansion.
        controller.reloadRuleSets(refreshStale: false)

        await settle { controller.engine.matcher.expandedRuleCount == 3 }
        XCTAssertEqual(controller.engine.matcher.expandedRuleCount, 3)

        // The engine-up path (`handleProfileChange` when the set signature is
        // unchanged) reloads the profile without touching the expansions.
        controller.engine.reload(profile: manager.activeProfile)
        XCTAssertEqual(controller.engine.matcher.expandedRuleCount, 3)
        XCTAssertTrue(controller.engine.matcher.unresolvedRuleSetNames.isEmpty)
    }

    /// The signature decides whether a profile edit needs a cache re-read.
    func testSignatureTracksNameURLAndInterval() {
        let a = RemoteRuleSet(name: "Ads", url: "https://example.com/a.conf", interval: 86400)
        let sameValues = RemoteRuleSet(name: "Ads", url: "https://example.com/a.conf", interval: 86400)
        let newInterval = RemoteRuleSet(name: "Ads", url: "https://example.com/a.conf", interval: 3600)
        let newURL = RemoteRuleSet(name: "Ads", url: "https://example.com/b.conf", interval: 86400)

        XCTAssertEqual(EngineController.ruleSetSignature(of: [a]),
                       EngineController.ruleSetSignature(of: [sameValues]))
        XCTAssertNotEqual(EngineController.ruleSetSignature(of: [a]),
                          EngineController.ruleSetSignature(of: [newInterval]))
        XCTAssertNotEqual(EngineController.ruleSetSignature(of: [a]),
                          EngineController.ruleSetSignature(of: [newURL]))
        XCTAssertEqual(EngineController.ruleSetSignature(of: []), "")
    }
}

/// Does nothing, so no test can leave a system proxy behind.
private final class NullNetworkSetupRunner: NetworkSetupRunning, @unchecked Sendable {
    func run(arguments: [String]) throws -> String { "" }
}
