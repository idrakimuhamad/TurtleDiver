import Foundation
import Combine

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

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    private let defaults = UserDefaults.standard
    
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
    }
    
    func resetAllSettings() async {
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
            defaults.synchronize()
        }
        
        KeychainHelper.delete(account: KeychainHelper.adminPasswordAccount)
        KeychainHelper.delete(account: KeychainHelper.vpnPasswordAccount)
        KeychainHelper.delete(account: KeychainHelper.vpnPasscodeAccount)
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
    
    private init() {
        // Load persisted values
        debugMode = defaults.bool(forKey: Keys.debugMode)
        useTunneling = defaults.bool(forKey: Keys.useTunneling)
        useProxyEngine = defaults.bool(forKey: Keys.useProxyEngine)
        dashboardExpanded = defaults.bool(forKey: Keys.dashboardExpanded)
        
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
