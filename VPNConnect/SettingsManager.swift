import Foundation
import Combine

// The app target compiles these files into one module; the SPM target
// `TurtleDiverAppGlue` compiles them standalone, so the engine modules are
// imported only when they exist as modules (see Package.swift).
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

enum AppTheme: String, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    
    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// Where a `SettingsManager` keeps its preferences — and therefore exactly
/// which `UserDefaults` domain "Reset all settings" wipes.
///
/// The store and the domain are **one value** on purpose. When they were two
/// (an injected `UserDefaults` instance beside a hard-coded
/// `AppIdentity.bundleIdentifier`), any test built on a disposable suite still
/// deleted the *real* preferences of whoever ran the suite: the injected
/// instance said "throwaway suite", the reset said "the app's domain", and
/// nothing could notice the disagreement. With a single spec, a manager reading
/// a disposable suite cannot be made to wipe anything else.
enum PreferenceStore: Equatable, Sendable {
    /// The application's own domain (`AppIdentity.bundleIdentifier`).
    case application
    /// A disposable suite, named by the caller. Tests only.
    case suite(String)

    /// The `UserDefaults` domain this store reads, writes and resets.
    var domain: String {
        switch self {
        case .application: return AppIdentity.bundleIdentifier
        case .suite(let name): return name
        }
    }

    /// A `UserDefaults` bound to ``domain``.
    var defaults: UserDefaults {
        switch self {
        case .application:
            return .standard
        case .suite(let name):
            guard let suite = UserDefaults(suiteName: name) else {
                preconditionFailure("\(name) is not a usable UserDefaults suite")
            }
            return suite
        }
    }
}

/// `@unchecked Sendable`: every stored property is either an immutable
/// reference or a thread-safe store (`UserDefaults`, the Keychain), and the
/// launch-time hygiene pass below is the only thing that touches it off the
/// main thread — it never mutates `@Published` state.
class SettingsManager: ObservableObject, @unchecked Sendable {
    static let shared = SettingsManager(preferences: .application)
    
    /// The store this manager reads, writes and — on reset — wipes. One value,
    /// so the two can never disagree (see ``PreferenceStore``).
    private let preferences: PreferenceStore
    private let defaults: UserDefaults
    /// Where ``resetAllSettings()`` deletes credentials from. The real Keychain
    /// in production.
    private let secrets: SecretStore
    @Published var theme: AppTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: "appTheme")
        }
    }

    private enum Keys {
        static let vpnHost = "vpnHost"
        static let vpnID = "vpnID"
        // Credentials (adminPassword, vpnPassword, vpnPasscode) are stored in the Keychain, not UserDefaults
        static let vpnSliceURLs = "vpnSliceURLs"
        static let debugMode = "debugMode"
        static let stokenRCPath = "stokenRCPath"
        static let stokenBookmarkData = "stokenBookmarkData"
        static let stokenTokenFilePath = "stokenTokenFilePath"
        static let stokenTokenBookmarkData = "stokenTokenBookmarkData"
        static let useTunneling = "useTunneling"
        static let useProxyEngine = "useProxyEngine"
        static let dashboardExpanded = "mainWindowDashboardExpanded"
        static let recordRequestDetails = "recordRequestDetails"
        static let revealSensitiveHeaders = "revealSensitiveHeaders"
        static let settingsPane = "settingsPane"
        static let ruleSetAutoRefresh = "ruleSetAutoRefresh"
        static let updatesCheckEnabled = "updatesCheckEnabled"
        static let shareWithDevice = "shareWithDevice"
        static let shareAllowedClients = "shareAllowedClients"
        static let askpassHelperRequirement = AskpassSetup.defaultsKey
    }

    /// `UserDefaults` keys that older builds wrote and nothing reads any more:
    /// credentials now live in the Keychain, and the PAC-era proxy selection is
    /// gone. Leaving them in the plist means a plaintext password sitting next
    /// to a pile of keys that no longer mean anything.
    static let legacyDefaultsKeys = [
        "adminPassword", "vpnPassword", "vpnPasscode",
        "useProxy", "proxyConfigurations", "selectedProxyID", "migratedFromPAC",
    ]

    /// Launch-time hygiene pass: move any credential still stored in
    /// `UserDefaults` into the Keychain (only when the Keychain has nothing —
    /// the Keychain always wins), then delete every dead key.
    ///
    /// It never writes a credential back to `UserDefaults`, and it is
    /// deliberately *not* gated behind a one-shot flag: the checks are a
    /// handful of dictionary lookups, only a credential key that is actually
    /// present costs a Keychain read, and running it on every launch means it
    /// self-heals if something writes one of these keys again. Returning the
    /// keys it removed keeps it testable; production ignores the result.
    @discardableResult
    func purgeLegacyDefaults(secrets: SecretStore = KeychainBackedSecrets()) -> [String] {
        // Read-through migration first: if a credential is still only in the
        // plist, save it to the Keychain before removing it.
        for account in KeychainHelper.credentialAccounts {
            guard let legacy = defaults.string(forKey: account),
                  !legacy.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if secrets.retrieve(account: account)?.isEmpty ?? true {
                secrets.store(password: legacy, account: account)
            }
        }

        var purged: [String] = []
        for key in Self.legacyDefaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
            purged.append(key)
        }
        return purged
    }
    
    /// Whether "Reset all settings" is in progress.
    ///
    /// While true the app is failing closed: the sharing intent is already off,
    /// any live share is already stopped, and nothing may read, create or store
    /// the share password until it ends. Published so observers can gate on the
    /// *current* value rather than on a publisher event that may have been
    /// queued before the reset began.
    @Published private(set) var isResetting = false

    /// Invoked **synchronously** by ``beginReset()``, while the main actor is
    /// still held, so whatever is serving a credential can be stopped before
    /// anything suspends. Main-actor isolated on purpose: a hook that has to
    /// reach the app's state must not be able to run anywhere else.
    var onResetBegan: (@MainActor () -> Void)?

    /// Invoked (and awaited) after the sharing intent is off and the share is
    /// down, before the credentials are deleted. A teardown that genuinely needs
    /// to run asynchronously belongs here — never in ``onResetBegan``.
    var onResetWillDeleteCredentials: (@MainActor () async -> Void)?

    /// The fail-closed half of a reset, and the only part that must be
    /// synchronous: mark the reset in progress, switch the sharing intent off,
    /// and let whoever is holding a credential stop using it — all before the
    /// first suspension point.
    ///
    /// Order matters: `isResetting` goes up first so any observer that runs as a
    /// side effect of `shareWithDevice` changing already sees the gate closed.
    @MainActor
    func beginReset() {
        isResetting = true
        shareWithDevice = false
        shareAllowedClients = []
        onResetBegan?()
    }

    /// Wipes every stored preference and credential.
    ///
    /// `@MainActor` because it mutates `@Published` state. The sequence is the
    /// point: fail closed synchronously, *then* suspend, and only then delete.
    /// A stale publisher event (one that captured `true` before the reset) can
    /// still land in the middle — which is why every observer reads the live
    /// settings and ``isResetting`` when it handles an event instead of trusting
    /// the value it was handed.
    @MainActor
    func resetAllSettings() async {
        // 1. Synchronous, before any await: nothing can be sharing from here on.
        beginReset()

        // 2. Only now may anything suspend — the intent is off and the listener
        //    that was using the credentials is down.
        await onResetWillDeleteCredentials?()

        // 3. A teardown hook must not be able to re-enable what is about to be
        //    deleted.
        shareWithDevice = false
        shareAllowedClients = []

        // 4. Wipe persisted state. The domain comes from the same value as the
        //    store, so this is the suite the manager was built on — never the
        //    app's own preferences when the manager is a test's.
        defaults.removePersistentDomain(forName: preferences.domain)
        defaults.synchronize()

        // 5. Every service this app has written to, not just the current one: a
        //    credential left behind under an older bundle identifier would make
        //    "reset all settings" a half-truth.
        for account in KeychainHelper.credentialAccounts {
            secrets.deleteEverywhere(account: account)
        }
        stokenBookmarkData = nil
        stokenTokenBookmarkData = nil

        // 6. Reset over: observers may reconcile again, from a disabled intent.
        isResetting = false
    }
    
    var vpnHost: String {
        get { defaults.string(forKey: Keys.vpnHost) ?? "" }
        set { defaults.set(newValue, forKey: Keys.vpnHost) }
    }
    
    /// Stored in the system Keychain rather than UserDefaults for security.
    var vpnPassword: String {
        get { KeychainHelper.retrieve(account: KeychainHelper.vpnPasswordAccount) ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(account: KeychainHelper.vpnPasswordAccount)
            } else {
                KeychainHelper.store(password: newValue, account: KeychainHelper.vpnPasswordAccount)
            }
        }
    }
    
    var vpnID: String {
        get { defaults.string(forKey: Keys.vpnID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.vpnID) }
    }
    
    /// Stored in the system Keychain rather than UserDefaults for security.
    var vpnPasscode: String {
        get { KeychainHelper.retrieve(account: KeychainHelper.vpnPasscodeAccount) ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(account: KeychainHelper.vpnPasscodeAccount)
            } else {
                KeychainHelper.store(password: newValue, account: KeychainHelper.vpnPasscodeAccount)
            }
        }
    }
    
    /// Stored in the system Keychain rather than UserDefaults for security.
    /// Falls back to empty string if no entry exists (triggers the on-demand alert).
    var adminPassword: String {
        get { KeychainHelper.retrieve(account: KeychainHelper.adminPasswordAccount) ?? "" }
        set {
            if newValue.isEmpty {
                KeychainHelper.delete(account: KeychainHelper.adminPasswordAccount)
            } else {
                KeychainHelper.store(password: newValue, account: KeychainHelper.adminPasswordAccount)
            }
        }
    }
    
    var vpnSliceURLs: [String] {
        get { defaults.stringArray(forKey: Keys.vpnSliceURLs) ?? defaultSliceURLs() }
        set { defaults.set(newValue, forKey: Keys.vpnSliceURLs) }
    }
    
    @Published var debugMode: Bool = false {
        didSet { defaults.set(debugMode, forKey: Keys.debugMode) }
    }
    
    var stokenRCPath: String {
        get { defaults.string(forKey: Keys.stokenRCPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.stokenRCPath) }
    }
    
    var stokenBookmarkData: Data? {
        get { defaults.data(forKey: Keys.stokenBookmarkData) }
        set { defaults.set(newValue, forKey: Keys.stokenBookmarkData) }
    }
    
    func updateStokenURL(_ url: URL) {
        stokenRCPath = url.path
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            stokenBookmarkData = data
        }
    }
    
    func resolvedStokenURL() -> URL? {
        guard let data = stokenBookmarkData else { return nil }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return url
        }
        return nil
    }
    
    var stokenTokenFilePath: String {
        get { defaults.string(forKey: Keys.stokenTokenFilePath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.stokenTokenFilePath) }
    }
    
    var stokenTokenBookmarkData: Data? {
        get { defaults.data(forKey: Keys.stokenTokenBookmarkData) }
        set { defaults.set(newValue, forKey: Keys.stokenTokenBookmarkData) }
    }
    
    @Published var useTunneling: Bool = false {
        didSet { defaults.set(useTunneling, forKey: Keys.useTunneling) }
    }
    
    /// Master switch for the proxy engine (local HTTP/SOCKS5 listeners +
    /// rule-based routing).
    @Published var useProxyEngine: Bool = false {
        didSet { defaults.set(useProxyEngine, forKey: Keys.useProxyEngine) }
    }

    /// "Share with a device": while the tunnel is up and the engine is running,
    /// let a phone or tablet on the same network route through the rule engine
    /// by pointing its manual HTTP proxy at this Mac. Off by default — it opens
    /// a listener to the LAN, so it is a thing the user asks for.
    @Published var shareWithDevice: Bool = false {
        didSet { defaults.set(shareWithDevice, forKey: Keys.shareWithDevice) }
    }

    /// The client addresses the user has approved to share with, in the order
    /// they were added. Empty is valid: the device is approved on demand when
    /// the engine refuses it (see `EngineController.allowShareClient`).
    @Published var shareAllowedClients: [String] = [] {
        didSet { defaults.set(shareAllowedClients, forKey: Keys.shareAllowedClients) }
    }

    /// Main-window presentation state: `false` = compact controls only,
    /// `true` = the expanded dashboard. Persisted so the window reopens the way
    /// the user left it — the window itself sizes from this in `AppDelegate`.
    @Published var dashboardExpanded: Bool = false {
        didSet { defaults.set(dashboardExpanded, forKey: Keys.dashboardExpanded) }
    }

    /// Which Settings pane was open last (raw `SettingsRoute`). Settings is a
    /// place you jump between, so reopening it on the last pane beats always
    /// landing back on the first one; unknown values fall back to the default.
    @Published var settingsPane: String = "" {
        didSet { defaults.set(settingsPane, forKey: Keys.settingsPane) }
    }

    /// Opt-in: refresh rule sets whose own `interval` has elapsed, in the
    /// background. Off by default — a remote list decides where traffic goes,
    /// so a fetch should be something the user asked for until they say
    /// otherwise. Sets without an interval are never fetched on their own.
    @Published var ruleSetAutoRefresh: Bool = false {
        didSet { defaults.set(ruleSetAutoRefresh, forKey: Keys.ruleSetAutoRefresh) }
    }

    /// Whether the app asks GitHub for the newest release when it starts. On by
    /// default — an update nobody is told about is an update nobody installs —
    /// and the request carries no account and nothing about this machine. Off
    /// means the check never runs on its own; pressing Check Now still works,
    /// because that is a request the user just made.
    @Published var updatesCheckEnabled: Bool = true {
        didSet { defaults.set(updatesCheckEnabled, forKey: Keys.updatesCheckEnabled) }
    }

    /// Whether the request table keeps a detail payload (request line, headers,
    /// the TLS handshake's public facts). On by default — it is the point of
    /// the feature — and held in memory only: nothing here is ever written to
    /// `vpn.log`, and old details age out of the ring buffer.
    @Published var recordRequestDetails: Bool = true {
        didSet { defaults.set(recordRequestDetails, forKey: Keys.recordRequestDetails) }
    }

    /// Whether sensitive header values (cookies, authorization, tokens) are
    /// kept as-is instead of `•••• (N chars)`. Off by default, and it applies
    /// only to *new* captures: a value withheld at capture time is not kept
    /// anywhere to be revealed later, so flipping this does not resurrect old
    /// cookies — it stops hiding the next ones.
    @Published var revealSensitiveHeaders: Bool = false {
        didSet { defaults.set(revealSensitiveHeaders, forKey: Keys.revealSensitiveHeaders) }
    }

    /// The designated requirement of the askpass helper the user approved for
    /// unattended elevation, or empty when nothing was approved.
    ///
    /// Not a credential: it names a program and its signer, which is what
    /// `codesign -d` prints for anyone who asks, so it lives in `UserDefaults`
    /// rather than the Keychain — whose reads can raise their own dialog, and a
    /// dialog raised while deciding whether a dialog is needed would be a
    /// comedy. The key's spelling comes from `AskpassSetup` so the connect's
    /// question and Settings' answer cannot drift apart.
    ///
    /// Read directly by `VPNManager` at connect time, because the answer must be
    /// this second's: a rebuild replaces the helper, and an approval for the old
    /// one is not an approval for the new one (`docs/ELEVATION.md` §11).
    var askpassHelperRequirement: String {
        get { defaults.string(forKey: Keys.askpassHelperRequirement) ?? "" }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: Keys.askpassHelperRequirement)
            } else {
                defaults.set(newValue, forKey: Keys.askpassHelperRequirement)
            }
        }
    }
    
    func updateStokenTokenURL(_ url: URL) {
        stokenTokenFilePath = url.path
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            stokenTokenBookmarkData = data
        }
    }
    
    func resolvedStokenTokenURL() -> URL? {
        guard let data = stokenTokenBookmarkData else { return nil }
        var isStale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return url
        }
        return nil
    }
    
    /// `preferences` names the suite *and* the domain a reset wipes, so a test
    /// helper cannot pass a disposable store and still reach the app's real
    /// preferences. It has **no default** on purpose: reaching the application's
    /// own preferences has to be spelled out as `.application`, which is easy to
    /// see in review and impossible to arrive at by forgetting an argument.
    ///
    /// `secrets` is injectable so a test can watch "Reset all settings" delete
    /// credentials without opening the login Keychain; production gets the real
    /// one.
    init(preferences: PreferenceStore, secrets: SecretStore = KeychainBackedSecrets()) {
        self.preferences = preferences
        self.defaults = preferences.defaults
        self.secrets = secrets
        // Load persisted values
        debugMode = defaults.bool(forKey: Keys.debugMode)
        useTunneling = defaults.bool(forKey: Keys.useTunneling)
        useProxyEngine = defaults.bool(forKey: Keys.useProxyEngine)
        dashboardExpanded = defaults.bool(forKey: Keys.dashboardExpanded)
        settingsPane = defaults.string(forKey: Keys.settingsPane) ?? SettingsCatalog.defaultRoute.rawValue
        ruleSetAutoRefresh = defaults.bool(forKey: Keys.ruleSetAutoRefresh)
        // Same reasoning as `recordRequestDetails` below: the key is absent on
        // every install that predates it, and `bool(forKey:)` cannot tell that
        // apart from an explicit "off".
        updatesCheckEnabled = defaults.object(forKey: Keys.updatesCheckEnabled) as? Bool ?? true
        // Absent key = never answered = default on. `bool(forKey:)` cannot tell
        // "off" from "unset", and reading an unset key as off would silently
        // ship the feature disabled for every existing install.
        recordRequestDetails = defaults.object(forKey: Keys.recordRequestDetails) as? Bool ?? true
        revealSensitiveHeaders = defaults.bool(forKey: Keys.revealSensitiveHeaders)
        shareWithDevice = defaults.bool(forKey: Keys.shareWithDevice)
        shareAllowedClients = defaults.stringArray(forKey: Keys.shareAllowedClients) ?? []
        
        // Load theme
        if let raw = defaults.string(forKey: "appTheme"), let t = AppTheme(rawValue: raw) {
            self.theme = t
        } else {
            self.theme = .system
        }
    }
    
    private func defaultSliceURLs() -> [String] {
        return []
    }
}
