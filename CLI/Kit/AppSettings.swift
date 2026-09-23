import Foundation
import TurtleDiverCore
import TurtleDiverSystem

/// The settings the app already has, read-only.
///
/// The CLI has no configuration of its own on purpose. A second place to write
/// the server address and the account name would be a second product, and the
/// first thing to go stale. `turtlediver` reads what the app wrote and nothing
/// else — `docs/CLI.md` calls this out as the reason it does not use
/// `ProfileManager`, whose initialiser creates files.
public struct AppSettings: Equatable {
    public var vpnHost: String
    public var vpnID: String
    public var useTunneling: Bool
    public var vpnSliceURLs: [String]
    public var stokenRCPath: String
    public var stokenTokenFilePath: String
    /// The app's selected profile, read from the same domain.
    public var activeProfileName: String?
    /// The administrator password is deliberately absent: the CLI authenticates
    /// through `sudo`'s own prompt and never carries that credential.

    public init(
        vpnHost: String = "",
        vpnID: String = "",
        useTunneling: Bool = false,
        vpnSliceURLs: [String] = [],
        stokenRCPath: String = "",
        stokenTokenFilePath: String = "",
        activeProfileName: String? = nil
    ) {
        self.vpnHost = vpnHost
        self.vpnID = vpnID
        self.useTunneling = useTunneling
        self.vpnSliceURLs = vpnSliceURLs
        self.stokenRCPath = stokenRCPath
        self.stokenTokenFilePath = stokenTokenFilePath
        self.activeProfileName = activeProfileName
    }

    /// Keys shared with `SettingsManager` (`VPNConnect/SettingsManager.swift`).
    /// They are spelled here rather than imported because that type is
    /// `internal` and imports `Cocoa`; a mismatch would show up as an empty
    /// host, which `connect` refuses before it runs anything.
    enum Key {
        static let vpnHost = "vpnHost"
        static let vpnID = "vpnID"
        static let useTunneling = "useTunneling"
        static let vpnSliceURLs = "vpnSliceURLs"
        static let stokenRCPath = "stokenRCPath"
        static let stokenTokenFilePath = "stokenTokenFilePath"
        static let activeProfileName = "activeProfileName"
    }

    public static func read(from defaults: UserDefaults) -> AppSettings {
        AppSettings(
            vpnHost: defaults.string(forKey: Key.vpnHost) ?? "",
            vpnID: defaults.string(forKey: Key.vpnID) ?? "",
            useTunneling: defaults.bool(forKey: Key.useTunneling),
            vpnSliceURLs: defaults.stringArray(forKey: Key.vpnSliceURLs) ?? [],
            stokenRCPath: defaults.string(forKey: Key.stokenRCPath) ?? "",
            stokenTokenFilePath: defaults.string(forKey: Key.stokenTokenFilePath) ?? "",
            activeProfileName: defaults.string(forKey: Key.activeProfileName)
        )
    }

    /// The app's own defaults domain.
    ///
    /// `suiteName` reads the persistent domain `com.xvii.kurakura.vpn`, which is
    /// the plist the app writes, and goes through `cfprefsd` so it sees a value
    /// the app changed a moment ago. Nothing here writes, so no file is created
    /// by a read-only command.
    public static func appDefaults() -> UserDefaults {
        UserDefaults(suiteName: AppIdentity.bundleIdentifier) ?? .standard
    }

    /// The app's settings across every domain it has used.
    ///
    /// `AppIdentity.legacyBundleIdentifiers` exists because the bundle id — which
    /// is also the prefs domain — changed. Reading only the current one would
    /// report "not configured" over an installation that is configured, so the
    /// current domain wins and the older ones fill the gaps. Nothing is migrated
    /// here: the CLI is a reader, and the app owns that migration.
    public static func readFromAppDomains() -> AppSettings {
        var merged = read(from: appDefaults())
        for legacy in AppIdentity.legacyBundleIdentifiers {
            guard let defaults = UserDefaults(suiteName: legacy) else { continue }
            let older = read(from: defaults)
            if merged.vpnHost.isEmpty { merged.vpnHost = older.vpnHost }
            if merged.vpnID.isEmpty { merged.vpnID = older.vpnID }
            if !merged.useTunneling { merged.useTunneling = older.useTunneling }
            if merged.vpnSliceURLs.isEmpty { merged.vpnSliceURLs = older.vpnSliceURLs }
            if merged.stokenRCPath.isEmpty { merged.stokenRCPath = older.stokenRCPath }
            if merged.stokenTokenFilePath.isEmpty { merged.stokenTokenFilePath = older.stokenTokenFilePath }
            if merged.activeProfileName == nil { merged.activeProfileName = older.activeProfileName }
        }
        return merged
    }

    /// True when there is enough to attempt a connect. The password lives in the
    /// Keychain and is checked separately, because "not configured" and "not
    /// authorized to read the stored password" want different messages.
    public var canConnect: Bool {
        !vpnHost.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// The credentials this tool can read out of the app's Keychain: the account
/// password, the stoken PIN's static half, and — only for a caller that asks for
/// it with `--sudo-password keychain` — the administrator password.
///
/// Both live under the app's Keychain service. Reading them from a different
/// binary is what makes macOS show its own consent dialog the first time; that
/// is the correct place for the decision, and the alternative — a second copy on
/// disk — is worse. `kSecUseAuthenticationUI` is not set: the access control is
/// the app's, and this binary has no business changing it.
public enum KeychainSecret: String, CaseIterable {
    case vpnPassword
    case vpnPasscode
    /// Written by the app's Settings ▸ VPN, under the same service as the
    /// other two. Its presence here does not make it read: only
    /// `--sudo-password keychain` does, and `docs/CLI.md` says so in as many
    /// words.
    case adminPassword

    /// What to call it in a sentence. Not `rawValue`: the Keychain account names
    /// are identifiers, and "the app has no stored vpnPassword" is not a
    /// sentence a person can act on.
    var noun: String {
        switch self {
        case .vpnPassword: return "VPN account password"
        case .vpnPasscode: return "stoken passcode"
        case .adminPassword: return "administrator password"
        }
    }

    /// Where a person goes to fix a missing one. The two doors are in different
    /// panes, so one remedy for both would send half the readers to the wrong
    /// one.
    var remedy: String {
        switch self {
        case .vpnPassword, .vpnPasscode: return "set it in the app under Settings ▸ VPN"
        case .adminPassword: return "save it in the app under Settings ▸ VPN"
        }
    }

    /// Three outcomes, not two, because "you denied the prompt" and "the app has
    /// never stored a password" want different sentences and different remedies.
    ///
    /// The same type the app and the askpass helper read through
    /// (`StoredSecret.ReadResult`), so all three agree on what a failure *is* even
    /// though they describe it in their own words.
    public typealias ReadResult = StoredSecret.ReadResult

    /// No `kSecUseAuthenticationUI` override: the ACL dialog is the point, and
    /// suppressing it would turn a one-time consent into an unusable command.
    ///
    /// The service chain is tried in order — the current identifier, then the
    /// ones this app has shipped under — because an item can live under an older
    /// name and the connect would otherwise report "not configured" over a
    /// credential that is right there. The query itself lives in `StoredSecret`:
    /// three readers of the same item is three chances to disagree about what to
    /// ask for.
    public func read() -> ReadResult {
        StoredSecret.read(services: AppIdentity.keychainServiceChain, account: rawValue)
    }

    /// The item's presence, read without its data.
    ///
    /// Attributes are not what an item's access control protects: a query that
    /// asks for them and not for `kSecReturnData` answers without raising the
    /// consent dialog and without decrypting anything. The askpass route needs
    /// exactly this much and no more — the password itself is printed by the
    /// helper, a separate process `sudo` starts, so this process must not read
    /// it — but it still has to tell "the app has never stored one", where the
    /// remedy is a pane in the app, apart from "`sudo` would not take the one
    /// that was printed", where the remedy is the value itself.
    ///
    /// Presence and not validity: an item whose value is empty reads as present
    /// here and as missing to `read()`. That case is already broken for the
    /// `sudo -S` route, and the helper — which does use `read()` — fails on it
    /// with the sentence that names the item.
    public func isPresent() -> Bool {
        StoredSecret.isPresent(services: AppIdentity.keychainServiceChain, account: rawValue)
    }

    /// The value, or nil for either failure. For callers that already know which
    /// sentence they will print.
    public var value: String? {
        if case .value(let text) = read() { return text }
        return nil
    }

    /// What to tell a person about a refusal, quoting the status so the answer is
    /// checkable rather than reassuring. The words are this tool's (the app is the
    /// thing a reader has to go and open); the shape is `StoredSecret`'s.
    public static func explain(_ result: ReadResult, account: KeychainSecret) -> String? {
        StoredSecret.explain(result, noun: account.noun, remedy: account.remedy)
    }
}
