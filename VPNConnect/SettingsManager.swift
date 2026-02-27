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
        static let vpnPassword = "vpnPassword"
        static let vpnID = "vpnID"
        static let vpnPasscode = "vpnPasscode"
        static let adminPassword = "adminPassword"
        static let vpnSliceURLs = "vpnSliceURLs"
        static let debugMode = "debugMode"
        static let stokenRCPath = "stokenRCPath"
        static let stokenBookmarkData = "stokenBookmarkData"
        static let stokenTokenFilePath = "stokenTokenFilePath"
        static let stokenTokenBookmarkData = "stokenTokenBookmarkData"
        static let useTunneling = "useTunneling"
    }
    
    func resetAllSettings() {
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
            defaults.synchronize()
        }
        
        // Re-initialize properties if needed (though removing domain should clear values for getters)
        // Reset in-memory values if they were cached (properties are computed so they pull from defaults)
        
        // Specific reset for complex objects if needed
        stokenBookmarkData = nil
        stokenTokenBookmarkData = nil
    }
    
    var vpnHost: String {
        get { defaults.string(forKey: Keys.vpnHost) ?? "" }
        set { defaults.set(newValue, forKey: Keys.vpnHost) }
    }
    
    var vpnPassword: String {
        get { defaults.string(forKey: Keys.vpnPassword) ?? "" }
        set { defaults.set(newValue, forKey: Keys.vpnPassword) }
    }
    
    var vpnID: String {
        get { defaults.string(forKey: Keys.vpnID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.vpnID) }
    }
    
    var vpnPasscode: String {
        get { defaults.string(forKey: Keys.vpnPasscode) ?? "" }
        set { defaults.set(newValue, forKey: Keys.vpnPasscode) }
    }
    
    var adminPassword: String {
        get { defaults.string(forKey: Keys.adminPassword) ?? "" }
        set { defaults.set(newValue, forKey: Keys.adminPassword) }
    }
    
    var vpnSliceURLs: [String] {
        get { defaults.stringArray(forKey: Keys.vpnSliceURLs) ?? defaultSliceURLs() }
        set { defaults.set(newValue, forKey: Keys.vpnSliceURLs) }
    }
    
    var debugMode: Bool {
        get { defaults.bool(forKey: Keys.debugMode) }
        set { defaults.set(newValue, forKey: Keys.debugMode) }
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
    
    var useTunneling: Bool {
        get { defaults.bool(forKey: Keys.useTunneling) }
        set { defaults.set(newValue, forKey: Keys.useTunneling) }
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
