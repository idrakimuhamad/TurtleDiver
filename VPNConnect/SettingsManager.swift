import Foundation
import Combine

// MARK: - Proxy Configuration

struct ProxyConfiguration: Codable, Identifiable {
    let id: UUID
    var name: String
    var pacFilePath: String?
    var pacBookmarkData: Data?
    var pacCode: String?
    var isActive: Bool
    
    init(id: UUID = UUID(), name: String, pacFilePath: String? = nil, pacBookmarkData: Data? = nil, pacCode: String? = nil, isActive: Bool = false) {
        self.id = id
        self.name = name
        self.pacFilePath = pacFilePath
        self.pacBookmarkData = pacBookmarkData
        self.pacCode = pacCode
        self.isActive = isActive
    }
    
    var resolvedPACURL: URL? {
        if let bookmarkData = pacBookmarkData {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return url
            }
        }
        if let path = pacFilePath {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
    
    var pacContent: String? {
        if let code = pacCode {
            return code
        }
        if let url = resolvedPACURL {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        return nil
    }
}

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
        static let proxyConfigurations = "proxyConfigurations"
        static let useProxy = "useProxy"
        static let selectedProxyID = "selectedProxyID"
    }
    
    func resetAllSettings() async {
        if let bundleID = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: bundleID)
            defaults.synchronize()
        }
        
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
    
    // MARK: - Proxy Configuration Properties
    
    var proxyConfigurations: [ProxyConfiguration] {
        get {
            guard let data = defaults.data(forKey: Keys.proxyConfigurations),
                  let configs = try? JSONDecoder().decode([ProxyConfiguration].self, from: data) else {
                return []
            }
            return configs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.proxyConfigurations)
            }
        }
    }
    
    @Published var useProxy: Bool = false {
        didSet { defaults.set(useProxy, forKey: Keys.useProxy) }
    }
    
    @Published var selectedProxyID: UUID? = nil {
        didSet { defaults.set(selectedProxyID?.uuidString, forKey: Keys.selectedProxyID) }
    }
    
    var selectedProxy: ProxyConfiguration? {
        guard let id = selectedProxyID else { return nil }
        return proxyConfigurations.first { $0.id == id }
    }
    
    func addProxyConfiguration(_ config: ProxyConfiguration) {
        var configs = proxyConfigurations
        configs.append(config)
        proxyConfigurations = configs
        objectWillChange.send()
    }
    
    func updateProxyConfiguration(_ config: ProxyConfiguration) {
        var configs = proxyConfigurations
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
            proxyConfigurations = configs
        }
        objectWillChange.send()
    }
    
    func deleteProxyConfiguration(id: UUID) {
        var configs = proxyConfigurations
        configs.removeAll { $0.id == id }
        proxyConfigurations = configs
        if selectedProxyID == id {
            selectedProxyID = nil
        }
        objectWillChange.send()
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
        useProxy = defaults.bool(forKey: Keys.useProxy)
        if let str = defaults.string(forKey: Keys.selectedProxyID), let uuid = UUID(uuidString: str) {
            selectedProxyID = uuid
        }
        
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
