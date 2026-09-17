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

/// `@unchecked Sendable`: every stored property is either an immutable
/// reference or a thread-safe store (`UserDefaults`, the Keychain), and the
/// launch-time hygiene pass below is the only thing that touches it off the
/// main thread — it never mutates `@Published` state.
class SettingsManager: ObservableObject, @unchecked Sendable {
    static let shared = SettingsManager()
    
    private let defaults: UserDefaults    
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
    
    func resetAllSettings() async {
        defaults.removePersistentDomain(forName: AppIdentity.bundleIdentifier)
        defaults.synchronize()

        // Every service this app has written to, not just the current one: a
        // credential left behind under an older bundle identifier would make
        // "reset all settings" a half-truth.
        for account in KeychainHelper.credentialAccounts {
            KeychainHelper.deleteEverywhere(account: account)
        }
        stokenBookmarkData = nil
        stokenTokenBookmarkData = nil
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
    
    /// Internal (not private) so tests can drive the manager against a
    /// throwaway `UserDefaults` suite instead of the user's real plist.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
