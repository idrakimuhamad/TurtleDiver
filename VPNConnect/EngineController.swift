import Foundation
import Combine
import OSLog
import Network

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

/// Bridges `ProfileManager`'s change observers into Combine so several
/// consumers (EngineController + SwiftUI views) can observe profile changes.
///
/// Each bridge is scoped to the manager it was created for. Views use
/// ``shared`` (the app's `ProfileManager.shared`); the engine creates one for
/// its *injected* manager, so building engine glue in a test never reaches the
/// real profile directory.
final class ProfileModelBridge: ObservableObject {
    static let shared = ProfileModelBridge(manager: .shared)

    private let manager: ProfileManager
    private var observerID: UUID?

    /// Coalesces bursts of hook firings into one `objectWillChange` per
    /// main-queue tick. `saveAndActivate` mutates several published fields in
    /// a row (activeProfile, diagnostics, validationErrors), each firing the
    /// hook; without coalescing every consumer runs multiple times per edit.
    private var notificationScheduled = false
    private let lock = NSLock()

    init(manager: ProfileManager) {
        self.manager = manager
        self.observerID = manager.addChangeObserver { [weak self] in
            self?.scheduleNotification()
        }
    }

    deinit {
        if let observerID { manager.removeChangeObserver(observerID) }
    }

    private func scheduleNotification() {
        lock.lock()
        if notificationScheduled {
            lock.unlock()
            return
        }
        notificationScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.notificationScheduled = false
            self.lock.unlock()
            self.objectWillChange.send()
        }
    }
}

// MARK: - Tunnel Status Seam

/// Where `EngineController` reads the tunnel's state, and the one place it writes
/// a line of tunnel-diagnostic text.
///
/// A seam rather than a direct read of `VPNManager.shared`: creating that
/// singleton performs the launch-time adoption of a tunnel the app did not
/// start, so *building an engine controller in a test* adopted whatever
/// `openconnect` was running on the machine and wrote the user's pid file.
/// `LiveTunnelStatus` is the app's wiring; a test passes a stub.
protocol TunnelStatusSource: AnyObject {
    var status: VPNStatus { get }
    var statusChanges: AnyPublisher<VPNStatus, Never> { get }
    func log(_ line: String)
}

/// The app's tunnel: the real manager, including its launch-time adoption.
///
/// Deliberately lazy — nothing here touches `VPNManager.shared` until one of
/// these members is used, so constructing this object is not the same as
/// creating the manager.
final class LiveTunnelStatus: TunnelStatusSource {
    var status: VPNStatus { VPNManager.shared.status }

    var statusChanges: AnyPublisher<VPNStatus, Never> {
        VPNManager.shared.$status.eraseToAnyPublisher()
    }

    func log(_ line: String) { VPNManager.shared.debugOutput += line }
}

// MARK: - Share with a device

/// The lifecycle of "Share with a device", as the UI renders it.
///
/// `Equatable` so a view can diff it cheaply and switch on the case that is
/// currently true. `.active` carries the address a phone should be pointed at.
enum ShareState: Equatable {
    /// Sharing is switched off in settings.
    case off
    /// Switched on, but the proxy engine is not running yet.
    case waitingForEngine
    /// Switched on and the engine is up, but the app does not report the VPN
    /// tunnel as connected.
    case waitingForTunnel
    /// The engine and tunnel are up, but no LAN IPv4 address was found.
    case noNetwork
    /// Sharing a listener at `host:port`.
    case active(host: String, port: Int)
    /// A hard failure, with the message to show the user.
    case failed(String)
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

    /// "Share with a device" lifecycle. See ``ShareState``.
    @Published private(set) var shareState: ShareState = .off
    /// Clients the engine refused because they are not in the allowed list,
    /// newest attempt per address. The UI offers to add each one.
    @Published private(set) var shareRefusedClients: [RefusedClient] = []
    /// Set when the share password could not be read from or written to the
    /// Keychain. The password and the share state are otherwise left alone.
    @Published private(set) var sharePasswordError: String?
    /// The PAC URL a shared device can fetch, or `nil` when sharing is off.
    /// Carries a token derived from the share password, so regenerating the
    /// password changes it and a reset removes it.
    @Published private(set) var sharePACURL: String?

    // MARK: Collaborators

    let engine: ProxyEngine
    let systemProxy: SystemProxyManager
    private let profileManager: ProfileManager
    private let settings: SettingsManager
    /// Injected so tests never touch the login keychain.
    private let secrets: SecretStore
    /// The tunnel's state, injected so tests never create `VPNManager.shared`
    /// (which adopts the machine's own tunnel — see `TunnelStatusSource`).
    private let tunnel: TunnelStatusSource
    /// Scoped to `profileManager`; deliberately not `ProfileModelBridge.shared`,
    /// which installs itself on `ProfileManager.shared` and would make every
    /// engine test touch the real profiles directory.
    private let profileBridge: ProfileModelBridge
    private var cancellables = Set<AnyCancellable>()

    /// Reads the machine's primary LAN IPv4 for the interface names the system
    /// prefers (`NWPathMonitor.availableInterfaces` order). Injected so tests
    /// can force "no network" (or a fixed address) without a real network.
    private let lanAddress: ([String]) -> String?

    /// Watches the network path so the share follows the Mac between Wi-Fi and
    /// Ethernet (and is re-established after a drop) without a poll timer.
    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "app.turtlediver.share.network-path")

    /// Cached remote rule lists. Injected so tests never read or write the
    /// user's cache directory.
    let ruleSets: RuleSetStore
    /// Last refresh failure per lowercased set name.
    private var ruleSetErrors: [String: String] = [:]
    /// Signature of the sets the matcher currently has expanded, so an
    /// unrelated profile edit does not re-read the cache from disk.
    private var appliedRuleSetSignature = ""
    private var ruleSetTask: Task<Void, Never>?
    /// Cache-load generation and identity tracking.
    /// Monotonic token for `reloadRuleSets`: a load that finishes after a newer
    /// one started must not apply its rules or record its signature.
    private var ruleSetLoadGeneration = 0
    /// Expansions currently held by the matcher, and the URL each came from.
    /// The immediate install below may only reuse an expansion when the new
    /// profile declares the same set *identity* (lowercased name + URL): a
    /// same-named set pointing at a different URL has different contents, and
    /// reusing A's rules under B would route traffic with the wrong list.
    private var installedRuleSets: [String: [ProfileRule]] = [:]
    private var installedRuleSetURLs: [String: String] = [:]
    /// Test seam for the cached-rule load in `reloadRuleSets`; production
    /// leaves it `nil`. Runs off the main actor.
    var ruleSetLoaderOverride: (@Sendable (Profile) -> [String: [ProfileRule]])?

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
        ruleSets: RuleSetStore? = nil,
        tunnel: TunnelStatusSource = LiveTunnelStatus(),
        lanAddress: @escaping ([String]) -> String? = { LANAddress.primaryLANIPv4(preferredNames: $0) }
    ) {
        self.profileManager = profileManager
        self.settings = settings
        self.secrets = secrets
        self.tunnel = tunnel
        self.lanAddress = lanAddress
        self.ruleSets = ruleSets ?? RuleSetStore()
        self.systemProxy = systemProxy ?? SystemProxyManager(
            runner: SystemProxyManager.defaultRunner(adminPasswordProvider: {
                SettingsManager.shared.adminPassword
            })
        )

        let store = PolicyStore(profile: profileManager.activeProfile, autoStartTesting: true)
        self.engine = ProxyEngine(profile: profileManager.activeProfile, policyStore: store)
        self.profileBridge = ProfileModelBridge(manager: profileManager)
        refreshRequestDetailSettings()

        // Older builds wrote the vpn-slice DIRECT overlay into the profile
        // file. It is runtime-only now; strip a leftover prefix, keeping a
        // backup (see `stripPersistedVPNOverlay()`).
        stripPersistedVPNOverlay()

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
        observeShareSettings()
        observeNetworkPath()

        // "Reset all settings" deletes the share password from the Keychain.
        // The live share has to be torn down, and the cached copy dropped,
        // *before* that happens — otherwise the engine keeps serving with a
        // credential that no longer exists. `onResetBegan` runs synchronously,
        // so the listener is down before the reset can suspend.
        settings.onResetBegan = { [weak self] in
            self?.prepareForShareReset()
        }
        // Belt and braces: if anything brought a share back between the reset
        // beginning and its deletions, it is stopped here, while the credentials
        // are still in the Keychain but about to go.
        settings.onResetWillDeleteCredentials = { [weak self] in
            self?.prepareForShareReset()
        }

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
        // Establishes the initial share state (including `waitingForEngine` when
        // the setting is on but the engine is not).
        reconcileSharing()

        // Load whatever is already cached (off the main thread) so cached rule
        // sets work with no network at all, then refresh the stale ones.
        reloadRuleSets()
    }

    deinit {
        pathMonitor.cancel()
    }

    // MARK: Remote rule sets

    /// Reads the cached lists off the main thread, hands them to the matcher and
    /// rebuilds the pane's summaries. Idempotent; called at launch, on a profile
    /// switch, and after the Rule Sets pane edits a set.
    func reloadRuleSets(refreshStale: Bool = true) {
        let profile = profileManager.activeProfile
        let signature = Self.ruleSetSignature(of: profile.ruleSets)
        let store = ruleSets
        ruleSetLoadGeneration &+= 1
        let generation = ruleSetLoadGeneration

        // The profile itself is cheap: install it now, reusing only cached
        // expansions whose set identity (name + URL) is unchanged. A set that
        // now points somewhere else must match nothing until its load lands —
        // otherwise A's contents would be expanded under B's policy.
        let cached = reusableRuleSets(for: profile)
        engine.reload(profile: engineProfile(profile), ruleSets: cached)
        installedRuleSets = cached
        installedRuleSetURLs = Self.ruleSetURLs(of: profile, limitedTo: cached)
        appliedRuleSetSignature = signature

        let loader = ruleSetLoaderOverride
        Task { [weak self] in
            let rules: [String: [ProfileRule]]
            if let loader {
                rules = await Task.detached(priority: .utility) { loader(profile) }.value
            } else {
                rules = await Task.detached(priority: .utility) { store.rulesBySet(for: profile) }.value
            }
            guard let self, generation == self.ruleSetLoadGeneration else { return }

            // The active profile can have changed while the cache was read. A
            // newer change owns its own load; this one must not apply A's sets
            // to B's profile (and must not record A's signature).
            let current = self.profileManager.activeProfile
            guard Self.ruleSetSignature(of: current.ruleSets) == signature else { return }

            self.engine.reload(profile: self.engineProfile(current), ruleSets: rules)
            self.installedRuleSets = rules
            self.installedRuleSetURLs = Self.ruleSetURLs(of: current, limitedTo: rules)
            self.appliedRuleSetSignature = signature
            self.refreshRuleSetSummaries()

            // Opt-in: only sets that declare an interval are worth refreshing
            // on their own, and never while another refresh is running.
            if refreshStale, self.settings.ruleSetAutoRefresh, self.ruleSetsRefreshing.isEmpty {
                self.refreshRuleSets(self.ruleSets.staleSets(in: current))
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

    /// Cached expansions still valid for `profile`: same lowercased set name
    /// and identical URL (the identity `RuleSetStore` keys its cache by).
    private func reusableRuleSets(for profile: Profile) -> [String: [ProfileRule]] {
        var out: [String: [ProfileRule]] = [:]
        for set in profile.ruleSets {
            let key = set.name.lowercased()
            guard installedRuleSetURLs[key] == set.url,
                  let rules = installedRuleSets[key] else { continue }
            out[key] = rules
        }
        return out
    }

    private static func ruleSetURLs(
        of profile: Profile,
        limitedTo rules: [String: [ProfileRule]]
    ) -> [String: String] {
        var out: [String: String] = [:]
        for set in profile.ruleSets where rules[set.name.lowercased()] != nil {
            out[set.name.lowercased()] = set.url
        }
        return out
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
            // The overlay is applied to the profile the engine runs, never to
            // the profile file (see `engineProfile(_:)`).
            try engine.start(profile: engineProfile(profileManager.activeProfile))
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
        wireRefusedClients()
        // The hooks only fire on *changes*: without this pull the dashboard shows
        // "no policies in the active profile" until something happens to touch
        // the store, even though routing already works.
        refreshRequests()

        reconcileSharing()

        if profileManager.activeProfile.general.systemProxy {
            // A profile that asks for the system proxy re-applies it on every
            // launch, off the main thread (see `setSystemProxyEnabled`).
            Task { await setSystemProxyEnabled(true) }
        }
    }

    // MARK: Engine → Published bridges

    private var logHookInstalled = false
    /// True while a coalesced request refresh is sleeping in its window.
    private var requestsRefreshPending = false

    /// Installs the request-log change hook (idempotent — survives engine
    /// restarts since RequestLog is engine-owned but persists across starts).
    private func wireRequestLog() {
        guard !logHookInstalled else { return }
        logHookInstalled = true
        engine.requestLog.onChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleRequestRefresh()
            }
        }
    }

    /// Coalesces the log's per-event changes into at most one snapshot refresh
    /// every 100 ms.
    ///
    /// Every append/finish/attachDetail fires the hook, and a busy page load
    /// is dozens of those a second. Each uncoalesced refresh replaces the
    /// whole (up to 1000-row) snapshot on the main actor, and the request
    /// table re-diffs and re-lays out its visible rows for it — left as is,
    /// the table's layout fights the engine's event rate for the main thread,
    /// which is what made scrolling the list crawl while traffic flowed. One
    /// refresh per 100 ms keeps the table visibly live while bounding the
    /// layout work; the snapshot is taken at the END of the window, so events
    /// that arrived inside it are never lost.
    @MainActor
    private func scheduleRequestRefresh() {
        guard !requestsRefreshPending else { return }
        requestsRefreshPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            self.requestsRefreshPending = false
            self.requests = self.engine.requestLog.snapshot()
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
        engine.stopSharing()
        engine.stop()
        engineRunning = false
        httpPort = nil
        socks5Port = nil
        // Settles `shareState` on `off` or `waitingForEngine` per the setting.
        reconcileSharing()
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
    /// profile change. Without writing the toggle back into the profile, the
    /// next profile change silently reverted it.
    private func persistSystemProxyIntent(_ enabled: Bool) {
        var profile = profileManager.activeProfile
        guard profile.general.systemProxy != enabled else { return }
        profile.general.systemProxy = enabled
        _ = profileManager.saveAndActivate(profile, recordBackup: false)
    }

    // MARK: Profile observation

    private func observeProfileChanges() {
        // Instance-scoped: this bridge is bound to the injected manager, so an
        // `EngineController` built in a test never creates
        // `ProfileManager.shared` or touches the real profiles directory.
        profileBridge.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleProfileChange()
            }
            .store(in: &cancellables)
    }

    private func handleProfileChange() {
        // A profile restored from a backup, edited externally, or switched to
        // can still carry an overlay persisted by an older build. Checking on
        // every change (not behind a one-shot flag) covers all of those.
        stripPersistedVPNOverlay()
        guard engineRunning else { return }
        let profile = profileManager.activeProfile

        // The VPN DIRECT overlay is applied in memory only (see
        // `engineProfile(_:)`). This handler never saves, so a profile change
        // cannot cause the old save → notification → save loop.
        if Self.ruleSetSignature(of: profile.ruleSets) != appliedRuleSetSignature {
            reloadRuleSets(refreshStale: false)
        } else {
            engine.reload(profile: engineProfile(profile))
        }

        // A profile switch can toggle the system-proxy flag.
        let wantsSystemProxy = profile.general.systemProxy
        if wantsSystemProxy && !systemProxyOn {
            Task { await setSystemProxyEnabled(true) }
        } else if !wantsSystemProxy && systemProxyOn {
            Task { await setSystemProxyEnabled(false) }
        }

        // Sharing follows the profile too: the HTTP listener sharing depends on
        // can have been changed, and the allow-list may want re-pushing.
        reconcileSharing()
    }

    // MARK: VPN tie-in

    private var vpnConnected: Bool {
        if case .connected = tunnel.status { return true }
        return false
    }

    private func observeVPNStatus() {
        tunnel.statusChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.handleVPNStatus(status)
            }
            .store(in: &cancellables)
    }

    private func handleVPNStatus(_ status: VPNStatus) {
        if engineRunning {
            if case .connected = status {
                applyVPNRules()
            } else if case .disconnected = status {
                clearVPNRules()
            }
        }
        // The listener follows the app-reported tunnel state. Once active, its
        // traffic follows the same VPN and DIRECT routing as the Mac.
        reconcileSharing()
    }

    /// The profile the engine should run: the user's saved profile, with the
    /// vpn-slice DIRECT rules merged on top while the tunnel is connected.
    ///
    /// The overlay is **never** written back: `ProfileManager.activeProfile`
    /// (and therefore the rules editor) always shows what the user saved.
    private func engineProfile(_ base: Profile) -> Profile {
        guard settings.useTunneling, vpnConnected else { return base }
        let (generated, _) = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs)
        guard !generated.isEmpty else { return base }
        return VPNRuleGenerator.merge(generated: generated, replacing: [], into: base)
    }

    /// Older builds saved the vpn-slice DIRECT overlay at the top of the active
    /// profile. The overlay is runtime-only now: strip a leftover prefix.
    ///
    /// Runs on every profile load/change rather than once, because a backup
    /// restore or an external edit can bring the prefix back. One save is the
    /// whole fix: after it the prefix no longer matches, so the notification it
    /// causes converges instead of looping.
    private func stripPersistedVPNOverlay() {
        guard settings.useTunneling else { return }
        let (generated, _) = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs)
        guard !generated.isEmpty else { return }

        var profile = profileManager.activeProfile
        let leading = Array(profile.rules.prefix(generated.count))
        guard leading.count == generated.count,
              VPNRuleGenerator.sameRules(leading, generated) else { return }

        profile.rules.removeFirst(generated.count)
        _ = profileManager.saveAndActivate(profile, recordBackup: true)
    }

    /// Apply the DIRECT overlay for vpn-slice targets to the profile the engine
    /// runs, so corporate traffic bypasses proxy upstreams. Nothing is saved.
    private func applyVPNRules() {
        guard settings.useTunneling else { return }
        let (_, invalid) = VPNRuleGenerator.rules(forTargets: settings.vpnSliceURLs)
        if !invalid.isEmpty {
            tunnel.log("[Engine] Skipped unrecognizable vpn-slice targets: \(invalid.joined(separator: ", "))\n")
        }
        engine.reload(profile: engineProfile(profileManager.activeProfile))
    }

    /// Drops the in-memory overlay when the tunnel goes down.
    private func clearVPNRules() {
        engine.reload(profile: profileManager.activeProfile)
    }

    // MARK: Share with a device

    /// The fixed, non-secret proxy username a shared device authenticates with.
    var shareUsername: String { KeychainHelper.shareUsername }

    /// The share password once it has been read or created, so the value the UI
    /// shows is exactly the value the engine was given. Cleared by "Reset all
    /// settings".
    private var cachedSharePassword: String?

    /// The share password to display, or `nil` when the Keychain could not be
    /// read or written (see ``sharePasswordError``). Never touches the Keychain
    /// itself — call ``ensureSharePassword()`` to load it.
    var sharePassword: String? { cachedSharePassword }

    /// Loads the share password into memory, generating and storing one the
    /// first time it is needed.
    ///
    /// "No item" and "the Keychain would not say" are treated differently on
    /// purpose: only the former earns a freshly generated password, because
    /// replacing a password the app merely *failed to read* would leave the
    /// phone holding one that nothing on the Mac agrees with.
    ///
    /// - Returns: the password, or `nil` when the Keychain refused a read or a
    ///   write — in which case ``sharePasswordError`` says which.
    @discardableResult
    func ensureSharePassword() -> String? {
        if let cachedSharePassword { return cachedSharePassword }
        // A reset is deleting the Keychain item: reading it now could resurrect
        // (or regenerate) exactly what is about to disappear.
        guard !settings.isResetting else { return nil }

        switch secrets.lookup(account: KeychainHelper.sharePasswordAccount) {
        case .value(let existing) where !existing.isEmpty:
            cachedSharePassword = existing
        case .value, .missing:
            // An empty item is not worth trusting: treat it as missing.
            let generated = KeychainHelper.generateSharePassword()
            guard secrets.storeReportingFailure(password: generated, account: KeychainHelper.sharePasswordAccount) else {
                setSharePasswordError("Couldn't save the share password to the Keychain.")
                return nil
            }
            cachedSharePassword = generated
        case .failed:
            setSharePasswordError("Couldn't read the share password from the Keychain.")
            return nil
        }

        setSharePasswordError(nil)
        return cachedSharePassword
    }

    /// Replaces the share password and hands the new value to a running share.
    ///
    /// A password the Keychain refuses to persist is *not* adopted: the old,
    /// still-stored one keeps serving and the error is surfaced, so the phone's
    /// copy and the Mac's never disagree.
    func regenerateSharePassword() {
        // Nothing may be written to the Keychain mid-reset.
        guard !settings.isResetting else { return }
        let message = "Couldn't save the new share password to the Keychain."
        let generated = KeychainHelper.generateSharePassword()
        guard secrets.storeReportingFailure(password: generated, account: KeychainHelper.sharePasswordAccount) else {
            setSharePasswordError(message)
            if !sharingActive { setShareState(.failed(message)) }
            return
        }
        cachedSharePassword = generated
        setSharePasswordError(nil)
        pushShareAccess()
        refreshSharePACURL()
    }

    /// Approves `address`, pushes the new allowed list to the engine and tells
    /// the engine to stop refusing that client.
    func allowShareClient(_ address: String) {
        let normalized = address.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty, !settings.isResetting else { return }
        var list = settings.shareAllowedClients
        if !list.contains(normalized) {
            list.append(normalized)
            settings.shareAllowedClients = list
        }
        pushShareAccess()
        engine.forgetRefusedClient(normalized)
        refreshRefusedClients()
    }

    /// Removes a previously approved client.
    func removeShareClient(_ address: String) {
        guard !settings.isResetting else { return }
        var list = settings.shareAllowedClients
        list.removeAll { $0 == address }
        settings.shareAllowedClients = list
        pushShareAccess()
    }

    /// Hands the engine the current credentials and allow-list. A no-op when the
    /// password cannot be resolved — ``sharePasswordError`` already says why.
    private func pushShareAccess() {
        guard !settings.isResetting,
              case .active = shareState,
              let password = ensureSharePassword() else { return }
        engine.updateShareAccess(
            username: shareUsername,
            password: password,
            allowedClients: shareAllowedClientSet,
            tunnelMode: shareTunnelMode
        )
    }

    /// Pulls the engine's current refused-client list into the published state.
    func refreshRefusedClients() {
        let refused = engine.refusedClients
        if refused != shareRefusedClients { shareRefusedClients = refused }
    }

    private var shareAllowedClientSet: Set<String> { Set(settings.shareAllowedClients) }

    /// Full tunnel unless split tunneling is on *and* the list holds at least
    /// one usable target. A list of junk is still a full tunnel. The running
    /// VPN is configured from these same settings (`VPNManager` builds the
    /// `vpn-slice` command line from them), so this is the configuration the
    /// tunnel actually has.
    private var shareTunnelMode: SharePACGenerator.TunnelMode {
        SharePACGenerator.resolvedMode(
            useTunneling: settings.useTunneling,
            targets: settings.vpnSliceURLs
        )
    }

    /// Brings the running share in line with the setting, the engine, the tunnel,
    /// the network and the allowed-client list. Idempotent; every place one of
    /// those can change calls it.
    ///
    /// The order of the guards is the policy:
    /// - off in settings → `off`;
    /// - engine down → `waitingForEngine`;
    /// - app-reported tunnel down → `waitingForTunnel`;
    /// - no running HTTP listener → `failed`;
    /// - no LAN address → `noNetwork`;
    /// - unreadable/unwritable share password → `failed`;
    /// - otherwise start (or keep) a listener and report `active`/`failed`.
    func reconcileSharing() {
        // Fail-closed first, and before every other guard: a reset is deleting
        // the credentials a share is bound to, so a reconcile that arrives
        // mid-reset (a stale publisher event, a network tick) must not start
        // one — and must stop any that is somehow still up.
        guard !settings.isResetting else {
            stopSharing()
            setShareState(.off)
            return
        }
        guard settings.shareWithDevice else {
            stopSharing()
            setShareState(.off)
            return
        }
        guard engineRunning else {
            stopSharing()
            setShareState(.waitingForEngine)
            return
        }
        guard vpnConnected else {
            stopSharing()
            setShareState(.waitingForTunnel)
            return
        }
        // The port must come from the listener the engine is *actually* bound
        // to, not from the profile: editing `http-listen` does not rebind the
        // loopback listener (`ProxyEngine.reload` only hot-swaps rules), so
        // reading the profile would aim the phone at a port nothing serves.
        guard let port = engine.listeningPorts.http else {
            stopSharing()
            setShareState(.failed("The HTTP listener is off."))
            return
        }
        guard let host = lanAddress(preferredLANInterfaceNames) else {
            stopSharing()
            setShareState(.noNetwork)
            return
        }
        guard let password = ensureSharePassword() else {
            stopSharing()
            setShareState(.failed(sharePasswordError ?? "The share password is unavailable."))
            return
        }

        // Already sharing this exact listener: keep the connections, but push a
        // changed allowed-client list so approving a device takes effect at once.
        if case .active(let currentHost, let currentPort) = shareState,
           currentHost == host, currentPort == port, engine.sharingAddress != nil {
            engine.updateShareAccess(
                username: shareUsername,
                password: password,
                allowedClients: shareAllowedClientSet,
                tunnelMode: shareTunnelMode
            )
            refreshSharePACURL()
            return
        }

        do {
            try engine.startSharing(ShareConfiguration(
                host: host,
                port: port,
                username: shareUsername,
                password: password,
                allowedClients: shareAllowedClientSet,
                tunnelMode: shareTunnelMode
            ))
            setShareState(.active(host: host, port: port))
            refreshSharePACURL()
            refreshRefusedClients()
        } catch {
            setShareState(.failed(error.localizedDescription))
            setSharePACURL(nil)
        }
    }

    /// Stops a running share and clears the refused-client list. Cheap and safe
    /// when nothing is sharing.
    private func stopSharing() {
        if sharingActive { engine.stopSharing() }
        if !shareRefusedClients.isEmpty { shareRefusedClients = [] }
        setSharePACURL(nil)
    }

    /// Torn down before "Reset all settings" deletes the credentials the share
    /// is holding: the listener goes, and so does the in-memory copy of the
    /// password the user can still see on screen.
    ///
    /// Called synchronously from `SettingsManager.beginReset()` and again from
    /// the awaited teardown hook, so a share that somehow came back between the
    /// two is stopped before the Keychain item disappears.
    private func prepareForShareReset() {
        stopSharing()
        setShareState(.off)
        cachedSharePassword = nil
        setSharePasswordError(nil)
    }

    private var sharingActive: Bool {
        if case .active = shareState { return true }
        return engine.sharingAddress != nil
    }

    /// Recomputes the PAC URL from the state that is actually serving: the
    /// active listener's host/port and the password the engine was given. Called
    /// whenever any of those can move (share start, LAN rebind, password
    /// regeneration) and from `stopSharing()` with the share off.
    private func refreshSharePACURL() {
        guard case .active(let host, let port) = shareState,
              let password = cachedSharePassword else {
            setSharePACURL(nil)
            return
        }
        setSharePACURL(SharePACGenerator.pacURL(host: host, port: port, password: password))
    }

    private func setSharePACURL(_ url: String?) {
        if sharePACURL != url { sharePACURL = url }
    }

    /// Publishes only on a real change: `reconcileSharing()` runs on every
    /// profile edit and network tick, and `@Published` fires its observers on
    /// every assignment whether or not the value moved.
    private func setShareState(_ state: ShareState) {
        if shareState != state { shareState = state }
    }

    private func setSharePasswordError(_ message: String?) {
        if sharePasswordError != message { sharePasswordError = message }
    }

    /// Interface names the system currently prefers for reaching the network,
    /// restricted to the kinds a phone on the same network can reach.
    private var preferredLANInterfaceNames: [String] {
        let pathInterfaces = pathMonitor.currentPath.availableInterfaces.map { interface in
            LANAddress.PathInterface(name: interface.name, kind: Self.kind(of: interface.type))
        }
        return LANAddress.preferredNames(from: pathInterfaces)
    }

    private static func kind(of type: NWInterface.InterfaceType) -> LANAddress.InterfaceKind {
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        default: return .other
        }
    }

    private var refusedClientsHookInstalled = false

    /// Installs the engine's refused-client hook (idempotent — survives engine
    /// restarts). The hook may fire off the main thread, so it hops back.
    private func wireRefusedClients() {
        guard !refusedClientsHookInstalled else { return }
        refusedClientsHookInstalled = true
        engine.onRefusedClient = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRefusedClients()
            }
        }
    }

    private func observeShareSettings() {
        settings.$shareWithDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Read the *current* settings, never the event's payload: a
                // value captured before "Reset all settings" began can still be
                // delivered mid-reset, and acting on it would recreate the very
                // password the reset is deleting.
                if self.settings.shareWithDevice && !self.settings.isResetting {
                    // Load (or create) the password as soon as the user asks for
                    // sharing, so the phone can be set up before the tunnel is up.
                    self.ensureSharePassword()
                }
                self.reconcileSharing()
            }
            .store(in: &cancellables)
        settings.$shareAllowedClients
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcileSharing() }
            .store(in: &cancellables)
        // The end of a reset is the one moment a reconcile is *supposed* to run
        // again, and the intent is already off by then, so it settles on `.off`.
        settings.$isResetting
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resetting in
                guard let self, !resetting else { return }
                self.reconcileSharing()
            }
            .store(in: &cancellables)
    }

    private func observeNetworkPath() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                // Re-read the LAN address; reconcileSharing() restarts the
                // share only when the address it is bound to changed. The gates
                // are read here, at handling time, not when the update arrived.
                guard let self,
                      self.settings.shareWithDevice,
                      !self.settings.isResetting else { return }
                self.reconcileSharing()
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
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
