import Foundation

// MARK: - Health State

/// Cached health state for one policy.
public struct PolicyHealth: Equatable, Sendable {
    public var lastResult: LatencyResult
    public var lastChecked: Date?

    /// Best-known latency across history (nil = never succeeded).
    public var bestLatencyMs: Double?

    public init(lastResult: LatencyResult = .notProbed, lastChecked: Date? = nil, bestLatencyMs: Double? = nil) {
        self.lastResult = lastResult
        self.lastChecked = lastChecked
        self.bestLatencyMs = bestLatencyMs
    }
}

/// Snapshot of a resolved policy for UI display.
public struct PolicySummary: Equatable, Sendable {
    public let name: String
    public let kind: Kind
    public let health: PolicyHealth

    public enum Kind: Equatable, Sendable {
        case builtin
        case proxy(ProxyType, host: String, port: Int)
        case group(ProxyGroupType, members: [String])
    }
}

// MARK: - PolicyStore

/// Resolves profile policies into runtime behavior:
/// - rule policy name → concrete forwarding decision (direct / proxy / reject)
/// - group semantics (select, url-test, fallback, load-balance) with health state
/// - automatic re-testing of auto groups on an interval
/// - user selection persistence for `select` groups
///
/// Thread-safety: all public methods are safe to call from any queue; state is
/// guarded by an internal lock. `onChange` fires on the calling queue when
/// resolution-relevant state changes (UI bridges it to the main queue).
public final class PolicyStore: @unchecked Sendable {

    // MARK: Types

    /// The outcome of resolving a policy to a concrete decision.
    public enum ResolvedDecision: Equatable, Sendable {
        /// Connect directly, no proxy.
        case direct
        /// Forward through this upstream proxy.
        case proxy(ProxyDefinition)
        /// Drop the connection.
        case reject
    }

    public enum PolicyStoreError: LocalizedError, Equatable {
        case unknownPolicy(String)
        case groupCycle([String])

        public var errorDescription: String? {
            switch self {
            case .unknownPolicy(let name): return "Unknown policy \"\(name)\""
            case .groupCycle(let path): return "Policy group cycle: " + path.joined(separator: " → ")
            }
        }
    }

    // MARK: State

    private let lock = NSLock()
    private var profile: Profile
    private var health: [String: PolicyHealth] = [:]
    /// User selection per `select` group, keyed by group name.
    private var selections: [String: String]
    /// Name of the select group currently used for rules that point at a group
    /// with multiple candidates when the rule's group is itself a chain — not
    /// used yet; reserved for the Phase 2 matcher.
    private var roundRobinCounters: [String: Int] = [:]

    private var testTimer: DispatchSourceTimer?
    private let probeQueue = DispatchQueue(label: "com.turtlediver.policy.probe", qos: .utility, attributes: .concurrent)
    private let measurer: LatencyMeasuring
    private let defaults: UserDefaults?
    /// When true, `testAllPolicies` blocks until all probes complete (tests).
    private let synchronousTesting: Bool

    /// Fired on whatever queue mutated state; UI should hop to main.
    public var onChange: (() -> Void)?

    // MARK: Init

    public init(
        profile: Profile,
        defaults: UserDefaults? = .standard,
        measurer: LatencyMeasuring = LatencyTester(),
        autoStartTesting: Bool = true,
        synchronousTesting: Bool = false
    ) {
        self.profile = profile
        self.measurer = measurer
        self.defaults = defaults
        self.synchronousTesting = synchronousTesting
        self.selections = Self.loadSelections(defaults: defaults)

        // Seed health for all policies.
        for name in profile.allPolicyNames where health[name] == nil {
            health[name] = PolicyHealth()
        }

        if autoStartTesting {
            startAutoTesting()
        }
    }

    deinit {
        testTimer?.cancel()
    }

    // MARK: Profile Swap

    /// Replaces the active profile (profile hot-swap). Health for policies that
    /// still exist is preserved; selections for removed groups are dropped.
    public func updateProfile(_ newProfile: Profile) {
        lock.lock()
        defer { lock.unlock() }
        let old = profile
        profile = newProfile

        // Prune/seed health.
        let names = Set(newProfile.allPolicyNames)
        health = health.filter { names.contains($0.key) }
        for name in newProfile.allPolicyNames where health[name] == nil {
            health[name] = PolicyHealth()
        }
        // Drop selections pointing at removed groups or unknown members.
        let groupNames = Set(newProfile.groups.map(\.name))
        selections = selections.filter { groupName, selected in
            guard let group = newProfile.groups.first(where: { $0.name == groupName }) else { return false }
            return group.policies.contains(selected)
        }
        roundRobinCounters.removeAll()
        _ = old // (readability: swap is intentionally state-preserving)

        onChange?()
    }

    // MARK: Resolution

    /// Resolves a rule policy name to a concrete decision.
    /// - Throws: unknown policy or group cycle.
    public func resolve(_ policyName: String) throws -> ResolvedDecision {
        try resolve(policyName, visited: [])
    }

    private func resolve(_ policyName: String, visited: [String]) throws -> ResolvedDecision {
        if visited.contains(policyName) {
            throw PolicyStoreError.groupCycle(visited + [policyName])
        }

        switch policyName.uppercased() {
        case BuiltinPolicy.direct.rawValue:
            return .direct
        case BuiltinPolicy.reject.rawValue:
            return .reject
        default:
            break
        }

        let (proxies, groups) = lock.withLock { (profile.proxies, profile.groups) }

        if let proxy = proxies.first(where: { $0.name == policyName }) {
            return .proxy(proxy)
        }
        if let group = groups.first(where: { $0.name == policyName }) {
            let chosen = selectMember(for: group)
            return try resolve(chosen, visited: visited + [policyName])
        }
        throw PolicyStoreError.unknownPolicy(policyName)
    }

    /// Picks the current member for a group according to its type.
    /// For `select` groups this honors the persisted user choice, falling back
    /// to the first member.
    public func selectMember(for group: ProxyGroup) -> String {
        let (healthCopy, selectionsCopy) = lock.withLock { (health, selections) }
        switch group.type {
        case .select:
            if let chosen = selectionsCopy[group.name], group.policies.contains(chosen) {
                return chosen
            }
            return group.policies.first ?? BuiltinPolicy.direct.rawValue

        case .urlTest:
            // Lowest-latency healthy candidate; ties/absent → first healthy → first listed.
            let candidates = group.policies
            let scored = candidates
                .compactMap { name -> (String, Double)? in
                    guard let ms = healthCopy[name]?.lastResult.milliseconds else { return nil }
                    return (name, ms)
                }
            if let best = scored.min(by: { $0.1 < $1.1 }) {
                return best.0
            }
            // No measurements yet: first candidate that isn't known-dead.
            return candidates.first { healthCopy[$0]?.lastResult.isUsable != false } ?? candidates.first ?? BuiltinPolicy.direct.rawValue

        case .fallback:
            // First candidate (in order) whose last probe succeeded;
            // if none is known-good, stay on the first (probe will fix it).
            for candidate in group.policies {
                if healthCopy[candidate]?.lastResult.isUsable == true {
                    return candidate
                }
            }
            return group.policies.first ?? BuiltinPolicy.direct.rawValue

        case .loadBalance:
            // Round-robin across candidates with a usable last probe.
            let healthy = group.policies.filter { healthCopy[$0]?.lastResult.isUsable != false }
            let pool = healthy.isEmpty ? group.policies : healthy
            guard !pool.isEmpty else { return BuiltinPolicy.direct.rawValue }
            let counter = incrementCounter(for: group.name, modulo: pool.count)
            return pool[counter]
        }
    }

    private func incrementCounter(for name: String, modulo: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (roundRobinCounters[name] ?? 0) % max(modulo, 1)
        roundRobinCounters[name] = next + 1
        return next
    }

    // MARK: Selection persistence (select groups)

    /// The user's current choice for a `select` group (nil = default/first).
    public func selection(forGroup groupName: String) -> String? {
        lock.withLock { selections[groupName] }
    }

    /// Sets the user's choice for a `select` group. No-op for other types or
    /// when the member isn't in the group.
    public func setSelection(_ member: String, forGroup groupName: String) {
        lock.lock()
        let group = profile.groups.first(where: { $0.name == groupName })
        guard let group, group.type == .select, group.policies.contains(member) else {
            lock.unlock()
            return
        }
        selections[groupName] = member
        lock.unlock()
        saveSelections()
        onChange?()
    }

    private static let selectionsKey = "policyGroupSelections"

    private static func loadSelections(defaults: UserDefaults?) -> [String: String] {
        guard let defaults,
              let data = defaults.data(forKey: selectionsKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveSelections() {
        guard let defaults else { return }
        let snapshot = lock.withLock { selections }
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.selectionsKey)
        }
    }

    // MARK: Health

    /// Health snapshot for one policy (nil if unknown policy).
    public func health(for policyName: String) -> PolicyHealth? {
        lock.withLock { health[policyName] }
    }

    /// All policies with health, for dashboard rendering.
    public func summaries() -> [PolicySummary] {
        let (profile, health) = lock.withLock { (profile, health) }
        var out: [PolicySummary] = []
        for name in BuiltinPolicy.names {
            out.append(PolicySummary(name: name, kind: .builtin, health: health[name] ?? PolicyHealth()))
        }
        for proxy in profile.proxies {
            out.append(PolicySummary(
                name: proxy.name,
                kind: .proxy(proxy.type, host: proxy.host, port: proxy.port),
                health: health[proxy.name] ?? PolicyHealth()
            ))
        }
        for group in profile.groups {
            out.append(PolicySummary(
                name: group.name,
                kind: .group(group.type, members: group.policies),
                health: health[group.name] ?? PolicyHealth()
            ))
        }
        return out
    }

    // MARK: Probing

    /// Measures latency for every concrete proxy in the profile.
    /// `completion` fires on an arbitrary queue when all probes finished.
    public func testAllPolicies(testURL: String? = nil, timeoutSeconds: Double? = nil, completion: (() -> Void)? = nil) {
        let (profile, general) = lock.withLock { (profile, profile.general) }
        let url = testURL ?? (groupTestURL(override: nil) ?? LatencyTester.defaultTestURL)
        _ = general
        let timeout = timeoutSeconds ?? Double(max(general.testTimeout, 1))

        let targets = concreteProbeTargets(profile: profile)
        guard !targets.isEmpty else {
            completion?()
            return
        }

        let group = DispatchGroup()
        for target in targets {
            group.enter()
            let work: () -> Void = { [weak self] in
                guard let self else { group.leave(); return }
                let result = self.measurer.measure(target, testURL: url, timeoutSeconds: timeout)
                self.record(result: result, for: target.policyName)
                group.leave()
            }
            if synchronousTesting {
                work()
            } else {
                probeQueue.async(execute: work)
            }
        }
        if synchronousTesting {
            onChange?()
            completion?()
        } else {
            group.notify(queue: .global()) { [weak self] in
                self?.onChange?()
                completion?()
            }
        }
    }

    /// Measures one policy by name: proxies probe their own path, DIRECT
    /// probes the test URL directly, groups probe their selected member.
    public func testPolicy(named name: String, testURL: String? = nil, timeoutSeconds: Double? = nil) {
        let (profile, general) = lock.withLock { (profile, profile.general) }
        let url = testURL ?? (groupTestURL(override: nil) ?? LatencyTester.defaultTestURL)
        let timeout = timeoutSeconds ?? Double(max(general.testTimeout, 1))

        guard let target = probeTarget(for: name, profile: profile, testURL: url) else { return }
        probeQueue.async { [weak self] in
            guard let self else { return }
            let result = self.measurer.measure(target, testURL: url, timeoutSeconds: timeout)
            self.record(result: result, for: name)
            self.onChange?()
        }
    }

    /// Starts the automatic interval timer for auto groups (url-test /
    /// fallback / load-balance) and their members.
    public func startAutoTesting() {
        lock.lock()
        defer { lock.unlock() }
        guard testTimer == nil else { return }
        let interval = TimeInterval(max(profile.general.testInterval, 30))
        let timer = DispatchSource.makeTimerSource(queue: probeQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.testAllPolicies()
        }
        timer.resume()
        testTimer = timer
    }

    public func stopAutoTesting() {
        lock.lock()
        testTimer?.cancel()
        testTimer = nil
        lock.unlock()
    }

    /// Per-group test URL override, else profile default.
    private func groupTestURL(override: String?) -> String? {
        override ?? lock.withLock { profile.general.testURL.isEmpty ? nil : profile.general.testURL }
    }

    /// Probe targets for all concrete policies (proxies only — DIRECT/REJECT
    /// and groups are resolved through their members).
    private func concreteProbeTargets(profile: Profile) -> [ProbeTarget] {
        profile.proxies.map { proxy in
            ProbeTarget(
                policyName: proxy.name,
                host: proxy.host,
                port: proxy.port,
                proxyType: proxy.type,
                proxyUsername: proxy.username,
                proxyPassword: proxy.password
            )
        }
    }

    /// Probe target for one policy name: proxies probe themselves; DIRECT
    /// probes the test URL host directly; groups probe their selected member.
    private func probeTarget(for name: String, profile: Profile, testURL: String) -> ProbeTarget? {
        if let proxy = profile.proxies.first(where: { $0.name == name }) {
            return ProbeTarget(
                policyName: proxy.name,
                host: proxy.host,
                port: proxy.port,
                proxyType: proxy.type,
                proxyUsername: proxy.username,
                proxyPassword: proxy.password
            )
        }
        if name == BuiltinPolicy.direct.rawValue {
            // Probe the test URL host directly.
            guard let (host, port, _) = LatencyTester.parseHTTPURL(testURL) else { return nil }
            return ProbeTarget(policyName: name, host: host, port: port, proxyType: nil)
        }
        // Group: probe its current member but record under the group name.
        if let group = profile.groups.first(where: { $0.name == name }) {
            let member = selectMember(for: group)
            if let memberTarget = probeTarget(for: member, profile: profile, testURL: testURL) {
                return ProbeTarget(
                    policyName: name, // record under the group name
                    host: memberTarget.host,
                    port: memberTarget.port,
                    proxyType: memberTarget.proxyType,
                    proxyUsername: memberTarget.proxyUsername,
                    proxyPassword: memberTarget.proxyPassword
                )
            }
        }
        return nil
    }

    private func record(result: LatencyResult, for name: String) {
        lock.lock()
        defer { lock.unlock() }
        var entry = health[name] ?? PolicyHealth()
        entry.lastResult = result
        entry.lastChecked = Date()
        if let ms = result.milliseconds {
            if entry.bestLatencyMs == nil || ms < entry.bestLatencyMs! {
                entry.bestLatencyMs = ms
            }
        }
        health[name] = entry
    }

    // MARK: Convenience

    /// Whether every rule policy reference resolves (cheap sanity check).
    public func allReferencesResolvable() -> Bool {
        lock.withLock { profile }.rules.allSatisfy { rule in
            (try? resolve(rule.policy)) != nil
        }
    }
}

// MARK: - Lock Helper

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
