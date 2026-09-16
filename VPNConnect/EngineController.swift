import Foundation
import Combine
import OSLog

// The app target compiles these files into one module; the SPM target
// `TurtleDiverAppGlue` compiles them standalone, so the engine modules are
// imported only when they exist as modules (see Package.swift).
#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif
#if canImport(TurtleDiverRules)
import TurtleDiverRules
#endif
#if canImport(TurtleDiverEngine)
import TurtleDiverEngine
#endif
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

// MARK: - Profile Model Bridge

/// Bridges `ProfileManager`'s single change-hook slot into Combine so several
/// consumers (EngineController + SwiftUI views) can observe profile changes.
/// The bridge installs itself as the hook on first access.
final class ProfileModelBridge: ObservableObject {
    static let shared = ProfileModelBridge()

    /// Coalesces bursts of hook firings into one `objectWillChange` per
    /// main-queue tick. `saveAndActivate` mutates several published fields in
    /// a row (activeProfile, diagnostics, validationErrors), each firing the
    /// hook; without coalescing every consumer runs multiple times per edit.
    private var notificationScheduled = false
    private let lock = NSLock()

    private init() {
        ProfileManager.shared.objectWillChangePublisher = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.notificationScheduled {
                self.lock.unlock()
                return
            }
            self.notificationScheduled = true
            self.lock.unlock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                self.notificationScheduled = false
                self.lock.unlock()
                self.objectWillChange.send()
            }
        }
    }
}

// MARK: - Engine Controller

/// App-side glue between the proxy engine and the rest of the app:
/// - starts/stops the engine per the user toggle (auto-start at launch),
/// - hot-reloads the engine when the active profile changes,
/// - applies/clears auto-generated DIRECT rules when the VPN connects or
///   disconnects (corporate subnets must bypass proxy upstreams),
/// - owns the system-proxy lifecycle (snapshot before enable, restore on
///   disable/quit, repair stale snapshots after a crash).
///
/// The VPN's own flow is untouched: the controller only *observes* status.
@MainActor
final class EngineController: ObservableObject {

    static let shared = EngineController()

    // MARK: Published state (UI in Phase 5 binds to these)

    @Published private(set) var engineRunning = false
    @Published private(set) var httpPort: Int?
    @Published private(set) var socks5Port: Int?
    @Published private(set) var systemProxyOn = false
    /// True while the blocking `networksetup` work is in flight off the main
    /// thread, so the UI can show progress instead of freezing.
    @Published private(set) var systemProxyBusy = false
    @Published private(set) var lastError: String?

    /// Latest request-log snapshot (newest last). Refreshed on engine activity
    /// and after clear/pause transitions so the Dashboard can render it
    /// directly.
    @Published private(set) var requests: [RequestEntry] = []
    /// Latest policy health snapshot for the dashboard badges.
    @Published private(set) var policySummaries: [PolicySummary] = []
    /// One row per `[Rule Set]` entry, for the Rule Sets pane.
    @Published private(set) var ruleSetSummaries: [RuleSetSummary] = []
    /// Names whose refresh is in flight right now.
    @Published private(set) var ruleSetsRefreshing: Set<String> = []

    // MARK: Collaborators

    let engine: ProxyEngine
    let systemProxy: SystemProxyManager
    private let profileManager: ProfileManager
    private let settings: SettingsManager
    /// Injected so tests never touch the login keychain.
    private let secrets: SecretStore
    private var cancellables = Set<AnyCancellable>()

    /// Cached remote rule lists. Injected so tests never read or write the
    /// user's cache directory.
    let ruleSets: RuleSetStore
    /// Last refresh failure per lowercased set name.
    private var ruleSetErrors: [String: String] = [:]
    /// Signature of the sets the matcher currently has expanded, so an
    /// unrelated profile edit does not re-read the cache from disk.
    private var appliedRuleSetSignature = ""
    private var ruleSetTask: Task<Void, Never>?

    /// The DIRECT rules the VPN tie-in currently has overlaid onto the
    /// active profile (needed to remove exactly them later).
    private var appliedVPNRules: [ProfileRule] = []

    /// Launch-time, one-shot retirement of the legacy PAC path. Held so tests
    /// can await it; production never blocks on it.
    private var legacyPACCleanup: Task<Void, Never>?

    /// System-proxy request that arrived while another was still in flight.
    /// Requests are serialized because the toggle can be flipped mid-run;
    /// the most recent request wins.
    private var pendingSystemProxy: (enabled: Bool, persistingIntent: Bool)?

    // MARK: Init

    init(
        profileManager: ProfileManager = .shared,
        settings: SettingsManager = .shared,
        systemProxy: SystemProxyManager? = nil,
        secrets: SecretStore = KeychainBackedSecrets(),
        ruleSets: RuleSetStore? = nil
    ) {
        self.profileManager = profileManager
        self.settings = settings
        self.secrets = secrets
        self.ruleSets = ruleSets ?? RuleSetStore()
        self.systemProxy = systemProxy ?? SystemProxyManager(
            runner: SystemProxyManager.defaultRunner(adminPasswordProvider: {
                SettingsManager.shared.adminPassword
            })
        )

        let store = PolicyStore(profile: profileManager.activeProfile, autoStartTesting: true)
        self.engine = ProxyEngine(profile: profileManager.activeProfile, policyStore: store)
        refreshRequestDetailSettings()

        // Retire the legacy PAC path (its local server is gone): an armed PAC
        // pointing at 127.0.0.1:8765 would black-hole everything it proxied.
        // This half is subprocess-free and runs before the repair below so the
        // scrubbed snapshot is what gets restored; the `networksetup` sweep
        // follows asynchronously (see `legacyPACCleanup`).
        self.systemProxy.scrubLegacyPACFromSnapshot()

        // Repair a snapshot left behind by a crashed session before doing
        // anything else (user settings win over our half-applied state).
        if self.systemProxy.hasStaleSnapshot && !self.systemProxy.isEnabled {
            _ = self.systemProxy.restoreFromSnapshot()
        }

        observeProfileChanges()
        observeVPNStatus()

        // The sweep itself shells out to `networksetup`, so it is kept off the
        // main thread. It is one-shot (a no-op on every later launch). The
        // credential/PAC-key purge follows in the same task: it reads the
        // Keychain, which can block.
        self.legacyPACCleanup = Task { [systemProxy = self.systemProxy, secrets] in
            await Self.runLegacyDefaultsPurge(settings, secrets: secrets)
            await Self.runLegacyPACCleanup(systemProxy)
        }

        if settings.useProxyEngine {
            startEngine()
        }

        // Load whatever is already cached (off the main thread) so cached rule
        // sets work with no network at all, then refresh the stale ones.
        reloadRuleSets()
    }

    // MARK: Remote rule sets

    /// Reads the cached lists off the main thread, hands them to the matcher and
    /// rebuilds the pane's summaries. Idempotent; called at launch, on a profile
    /// switch, and after the Rule Sets pane edits a set.
    func reloadRuleSets(refreshStale: Bool = true) {
        let profile = profileManager.activeProfile
        let signature = Self.ruleSetSignature(of: profile.ruleSets)
        let store = ruleSets

        Task { [weak self] in
            let rules = await Task.detached(priority: .utility) { store.rulesBySet(for: profile) }.value
            guard let self else { return }
            self.engine.reload(profile: self.profileManager.activeProfile, ruleSets: rules)
            self.appliedRuleSetSignature = signature
            self.refreshRuleSetSummaries()

            // Opt-in: only sets that declare an interval are worth refreshing
            // on their own, and never while another refresh is running.
            if refreshStale, self.settings.ruleSetAutoRefresh, self.ruleSetsRefreshing.isEmpty {
                self.refreshRuleSets(self.ruleSets.staleSets(in: self.profileManager.activeProfile))
            }
        }
    }

    /// Refreshes one set (the pane's Refresh button).
    func refreshRuleSet(named name: String) {
        let profile = profileManager.activeProfile
        refreshRuleSets(profile.ruleSets.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    }

    /// Refreshes every declared set.
    func refreshAllRuleSets() {
        refreshRuleSets(profileManager.activeProfile.ruleSets)
    }

    /// Drops a cached copy; the next refresh fetches it from scratch.
    ///
    /// Takes the set itself rather than a name on purpose: a caller that has
    /// just deleted the declaration has already dropped it from the profile,
    /// so a lookup would find nothing and leave the files behind.
    func removeRuleSetCache(for set: RemoteRuleSet) {
        ruleSets.removeCache(for: set)
        ruleSetErrors[set.name.lowercased()] = nil
        reloadRuleSets(refreshStale: false)
    }

    private func refreshRuleSets(_ targets: [RemoteRuleSet]) {
        guard !targets.isEmpty else { return }
        ruleSetsRefreshing.formUnion(targets.map(\.name))
        let store = ruleSets

        ruleSetTask = Task { [weak self] in
            // Network + file writes happen off the main thread; the HTTP
            // transport is synchronous on purpose.
            let outcomes = await Task.detached(priority: .utility) {
                targets.map { ($0.name, store.refresh($0)) }
            }.value

            guard let self else { return }
            for (name, outcome) in outcomes {
                let key = name.lowercased()
                self.ruleSetsRefreshing.remove(name)
                switch outcome {
                case .updated, .notModified:
                    self.ruleSetErrors[key] = nil
                case .unavailable(let message):
                    self.ruleSetErrors[key] = message
                }
            }
            self.reloadRuleSets(refreshStale: false)
        }
    }

    private func refreshRuleSetSummaries() {
        let profile = profileManager.activeProfile
        ruleSetSummaries = RuleSetSummary.summaries(
            for: profile,
            entries: ruleSets.entries(for: profile),
            errors: ruleSetErrors
        )
    }

    /// Identity of the declared sets; a change means the matcher must be given
    /// a fresh expansion.
    nonisolated static func ruleSetSignature(of sets: [RemoteRuleSet]) -> String {
        sets.map { "\($0.name)=\($0.url)#\($0.interval.map(String.init) ?? "-")" }
            .joined(separator: "|")
    }

    // MARK: Engine lifecycle

    /// Starts the listeners from the active profile and applies the system
    /// proxy when the profile asks for it.
    func startEngine() {
        do {
            try engine.start(profile: profileManager.activeProfile)
            engineRunning = true
            lastError = nil
        } catch {
            engineRunning = false
            lastError = "Proxy engine failed to start: \(error.localizedDescription)"
            return
        }
        let ports = engine.listeningPorts
        httpPort = ports.http
        socks5Port = ports.socks5

        wireRequestLog()
        wirePolicyStore()
        // The hooks only fire on *changes*: without this pull the dashboard shows
        // "no policies in the active profile" until something happens to touch
        // the store, even though routing already works.
        refreshRequests()

        if profileManager.activeProfile.general.systemProxy {
            // A profile that asks for the system proxy re-applies it on every
            // launch, off the main thread (see `setSystemProxyEnabled`).
            Task { await setSystemProxyEnabled(true) }
        }
    }

    // MARK: Engine → Published bridges

    private var logHookInstalled = false

    /// Installs the request-log change hook (idempotent — survives engine
    /// restarts since RequestLog is engine-owned but persists across starts).
    private func wireRequestLog() {
        guard !logHookInstalled else { return }
        logHookInstalled = true
        engine.requestLog.onChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.requests = self.engine.requestLog.snapshot()
            }
        }
    }

    private var policyHookInstalled = false

    /// Installs the policy-store change hook for health badges (idempotent).
    private func wirePolicyStore() {
        guard !policyHookInstalled else { return }
        policyHookInstalled = true
        engine.policyStore.onChange = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.policySummaries = self.engine.policyStore.summaries()
            }
        }
    }

    /// Pulls the current request-log snapshot into `requests` (used by the
    /// dashboard for refresh and to clear the transient new-entry highlight).
    func refreshRequests() {
        requests = engine.requestLog.snapshot()
        policySummaries = engine.policyStore.summaries()
    }

    /// Pushes the two request-detail switches into the log the servers read.
    ///
    /// The servers ask the log per request rather than being handed a config at
    /// construction, because the engine is built once and the switches are
    /// meant to take effect immediately. Called from here rather than from
    /// `SettingsManager`'s property observers: the manager is also live in
    /// tests and in the launch path, where there is no engine to talk to.
    func refreshRequestDetailSettings() {
        engine.requestLog.capturesDetails = settings.recordRequestDetails
        engine.requestLog.revealsSensitiveHeaders = settings.revealSensitiveHeaders
    }

    /// Clears the engine's request log.
    func clearRequests() {
        engine.requestLog.clear()
        requests = []
    }

    func stopEngine() {
        teardownSystemProxy()
        engine.stop()
        engineRunning = false
        httpPort = nil
        socks5Port = nil
    }

    /// User toggle entry point. The flag is persisted in `SettingsManager` so
    /// the engine resumes on the next launch, matching what `init` reads.
    /// Both the Dashboard toggle and the status-bar menu route through here.
    func setEngineEnabled(_ enabled: Bool) {
        settings.useProxyEngine = enabled
        if enabled {
            startEngine()
        } else {
            stopEngine()
        }
    }

    // MARK: System proxy

    /// Points the macOS system proxy at the running listeners (or clears it).
    /// Requires the engine to be up for `enabled == true`.
    ///
    /// The `networksetup` work runs **off the main thread**: applying the proxy
    /// spawns a dozen-plus subprocesses (one per network service × setting),
    /// which froze the UI for seconds when done inline.
    ///
    /// `persistingIntent` records the choice in the active profile so the next
    /// launch re-applies it. Teardown paths pass `false` — stopping the engine
    /// must turn the proxy off (macOS must not be left pointing at a dead
    /// listener) without erasing what the user asked for.
    func setSystemProxyEnabled(_ enabled: Bool, persistingIntent: Bool = true) async {
        guard !systemProxyBusy else {
            pendingSystemProxy = (enabled, persistingIntent)
            return
        }

        if enabled, !engineRunning {
            lastError = "Cannot enable system proxy: engine is not running"
            return
        }

        systemProxyBusy = true
        let failure = await Self.runProxyWork(
            manager: systemProxy,
            enable: enabled,
            httpPort: httpPort,
            socksPort: socks5Port,
            skipProxy: profileManager.activeProfile.general.skipProxy
        )
        systemProxyBusy = false

        if let failure {
            // A failed enable leaves the system unproxied; a failed disable may
            // have applied partially, so keep reporting the last known state.
            // Neither writes the intent — the user's stored choice is only
            // replaced once the change actually landed.
            if enabled { systemProxyOn = false }
            lastError = failure
        } else {
            systemProxyOn = enabled
            lastError = nil
            if persistingIntent { persistSystemProxyIntent(enabled) }
        }

        if let pending = pendingSystemProxy {
            pendingSystemProxy = nil
            await setSystemProxyEnabled(pending.enabled, persistingIntent: pending.persistingIntent)
        }
    }

    /// Blocking `networksetup` work, hopped onto a background queue so the
    /// main thread (and the UI) stays responsive. Returns an error description,
    /// or `nil` on success.
    private nonisolated static func runProxyWork(
        manager: SystemProxyManager,
        enable: Bool,
        httpPort: Int?,
        socksPort: Int?,
        skipProxy: [String]
    ) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: applyProxyWork(
                    manager: manager,
                    enable: enable,
                    httpPort: httpPort,
                    socksPort: socksPort,
                    skipProxy: skipProxy
                ))
            }
        }
    }

    /// Runs the one-shot legacy PAC retirement off the main thread.
    private nonisolated static func runLegacyPACCleanup(_ manager: SystemProxyManager) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                manager.clearLegacyPAC()
                continuation.resume()
            }
        }
    }

    /// Awaits the launch-time legacy PAC retirement. Exposed so tests can
    /// synchronize on it (production never needs to block on it).
    func awaitLegacyPACCleanup() async {
        await legacyPACCleanup?.value
    }

    private nonisolated static func runLegacyDefaultsPurge(
        _ settings: SettingsManager,
        secrets: SecretStore
    ) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let purged = settings.purgeLegacyDefaults(secrets: secrets)
                if !purged.isEmpty {
                    Logger(subsystem: AppIdentity.bundleIdentifier, category: "settings")
                        .info("purged \(purged.count, privacy: .public) legacy defaults key(s)")
                }
                continuation.resume()
            }
        }
    }

    private nonisolated static func applyProxyWork(
        manager: SystemProxyManager,
        enable: Bool,
        httpPort: Int?,
        socksPort: Int?,
        skipProxy: [String]
    ) -> String? {
        do {
            if enable {
                guard let httpPort else {
                    return "Cannot enable system proxy: engine is not running"
                }
                try manager.enable(
                    httpHost: "127.0.0.1",
                    httpPort: httpPort,
                    socksHost: "127.0.0.1",
                    socksPort: socksPort ?? httpPort,
                    skipProxy: skipProxy
                )
            } else {
                try manager.disable()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Synchronous teardown for engine stop / app termination. Blocking briefly
    /// is correct there — the app must not exit leaving macOS pointed at a dead
    /// listener — but the persisted intent is deliberately left alone, so the
    /// next launch can restore it.
    func teardownSystemProxy() {
        guard systemProxyOn || systemProxy.isEnabled else { return }
        let failure = Self.applyProxyWork(
            manager: systemProxy,
            enable: false,
            httpPort: nil,
            socksPort: nil,
            skipProxy: []
        )
        systemProxyOn = false
        lastError = failure
    }

    /// The active profile is the source of truth for the system-proxy intent:
    /// `handleProfileChange()` re-applies `profile.general.systemProxy` on every
    /// profile change — including the VPN-overlay rewrite that happens on
    /// connect. Without writing the toggle back into the profile, the next
    /// profile change silently reverted it (the proxy flipped off the moment
    /// the VPN came up).
    private func persistSystemProxyIntent(_ enabled: Bool) {
        var profile = profileManager.activeProfile
        guard profile.general.systemProxy != enabled else { return }
        profile.general.systemProxy = enabled
        _ = profileManager.saveAndActivate(profile)
    }

    // MARK: Profile observation

    private func observeProfileChanges() {
        // ProfileManager changes arrive via the shared Combine bridge.
        ProfileModelBridge.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleProfileChange()
            }
            .store(in: &cancellables)
    }

    private func handleProfileChange() {
        guard engineRunning else { return }
        var profile = profileManager.activeProfile

        // Keep the VPN overlay consistent across external profile edits while
        // the tunnel is up. Comparisons must ignore rule identity UUIDs —
        // `VPNRuleGenerator.rules()` mints fresh UUIDs per call, so `==` on the
        // rule arrays is never equal across generations and would loop:
        // change → save → change-notification → save → … (main-thread hang).
        if vpnConnected {
            let (generated, _) = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs)
            if !generated.isEmpty {
                let merged = VPNRuleGenerator.merge(generated: generated, replacing: appliedVPNRules, into: profile)
                if !VPNRuleGenerator.sameRules(merged.rules, profile.rules) {
                    profile = merged
                    appliedVPNRules = generated
                    profileManager.saveAndActivate(profile)
                }
            }
        }

        if Self.ruleSetSignature(of: profile.ruleSets) != appliedRuleSetSignature {
            reloadRuleSets(refreshStale: false)
        } else {
            engine.reload(profile: profileManager.activeProfile)
        }

        // A profile switch can toggle the system-proxy flag.
        let wantsSystemProxy = profile.general.systemProxy
        if wantsSystemProxy && !systemProxyOn {
            Task { await setSystemProxyEnabled(true) }
        } else if !wantsSystemProxy && systemProxyOn {
            Task { await setSystemProxyEnabled(false) }
        }
    }

    // MARK: VPN tie-in

    private var vpnConnected: Bool {
        if case .connected = VPNManager.shared.status { return true }
        return false
    }

    private func observeVPNStatus() {
        VPNManager.shared.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleVPNStatus(status)
            }
            .store(in: &cancellables)
    }

    private func handleVPNStatus(_ status: VPNStatus) {
        guard engineRunning else { return }
        if case .connected = status {
            applyVPNRules()
        } else if case .disconnected = status {
            clearVPNRules()
        }
    }

    /// Adds DIRECT rules for vpn-slice targets on top of the user's rules so
    /// corporate traffic always bypasses proxy upstreams.
    private func applyVPNRules() {
        guard settings.useTunneling else { return }
        let (generated, invalid) = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs)
        if !invalid.isEmpty {
            VPNManager.shared.debugOutput += "[Engine] Skipped unrecognizable vpn-slice targets: \(invalid.joined(separator: ", "))\n"
        }
        guard !generated.isEmpty else { return }

        var profile = profileManager.activeProfile
        let merged = VPNRuleGenerator.merge(generated: generated, replacing: appliedVPNRules, into: profile)
        guard !VPNRuleGenerator.sameRules(merged.rules, profile.rules) else { return } // already applied
        profile = merged
        appliedVPNRules = generated
        profileManager.saveAndActivate(profile)
        engine.reload(profile: profile)
    }

    /// Removes the overlay when the tunnel goes down.
    private func clearVPNRules() {
        guard !appliedVPNRules.isEmpty else { return }
        var profile = profileManager.activeProfile
        let merged = VPNRuleGenerator.merge(generated: [], replacing: appliedVPNRules, into: profile)
        guard !VPNRuleGenerator.sameRules(merged.rules, profile.rules) else { return }
        profile = merged
        appliedVPNRules = []
        profileManager.saveAndActivate(profile)
        engine.reload(profile: profile)
    }

    // MARK: Shutdown

    /// Called from `applicationWillTerminate`: restore system proxy first so
    /// an app teardown can't strand the user's network settings.
    func shutdown() {
        // Identical to an explicit stop: point macOS away from the listener we
        // are about to close, keep the stored intent, and leave the published
        // state consistent — a stale `engineRunning = true` let a stopped
        // controller keep reacting to profile changes.
        stopEngine()
    }
}
