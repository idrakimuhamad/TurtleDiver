import Foundation

/// Identity facts about the app that outlive a single build.
///
/// The bundle identifier is not just a label: it *is* the `UserDefaults` domain
/// and the Keychain service name. Renaming it therefore does not "rename the
/// app" — it orphans every stored setting and every stored credential, which
/// for this app means three secrets (VPN password, passcode, administrator
/// password) that the user would have to retype. This type names the current
/// identifier and the ones it used to have, so the launch-time migration can
/// find the old data instead of losing it.
public enum AppIdentity {

    /// The current identifier.
    ///
    /// Must match `PRODUCT_BUNDLE_IDENTIFIER` in `VPNConnect.xcodeproj`:
    /// `KeychainHelper` stores under this name while the system sees the
    /// bundle's own, and if the two ever diverge the app writes credentials
    /// nobody reads. `AppIdentityTests` fails the suite when they drift.
    public static let bundleIdentifier = "com.xvii.kurakura.vpn"

    /// Identifiers this app has shipped under, newest first.
    ///
    /// `com.idraki.turtle.vpn` was every build up to and including 1.5.0.
    /// `com.turtlediver` is the fallback `KeychainHelper` used when
    /// `Bundle.main.bundleIdentifier` was nil (a bare test binary), so items can
    /// exist under it too.
    public static let legacyBundleIdentifiers = ["com.idraki.turtle.vpn", "com.turtlediver"]

    /// The team whose signature a downloaded update is allowed to come from.
    ///
    /// This is the updater's trust anchor, and the signature alone is what it
    /// can be: the project holds no Developer ID certificate and notarizes
    /// nothing, so Gatekeeper's own verdict (`spctl`) refuses every release this
    /// app could ever publish. What *can* be insisted on is that the
    /// application inside a downloaded image was signed by this team — the same
    /// one that signs the running app — which `UpdateBundle.swift` does before
    /// anything is written over it.
    ///
    /// Must match `DEVELOPMENT_TEAM` in `VPNConnect.xcodeproj`.
    public static let updateTeamIdentifier = "KT7QU923S8"

    /// Keychain services to try, in order, when a read misses: the current name
    /// first, then the legacy ones, without duplicates.
    public static var keychainServiceChain: [String] {
        var chain = [bundleIdentifier]
        for identifier in legacyBundleIdentifiers where !chain.contains(identifier) {
            chain.append(identifier)
        }
        return chain
    }
}

/// Moves settings across the `UserDefaults` domains this app used before the
/// bundle identifier changed.
///
/// Deliberately one-directional and copy-only: a key that already has a value
/// under the current identity is never overwritten, and nothing is removed from
/// the legacy domain. The old plist costs a few hundred bytes and is the only
/// copy if a migration goes wrong.
public enum SettingsDomainMigration {

    /// Copies the persisted settings of each identifier in `legacyIdentifiers`
    /// into `current`, and returns the keys it copied (sorted).
    @discardableResult
    public static func copyLegacyDomains(
        into current: UserDefaults = .standard,
        from legacyIdentifiers: [String] = AppIdentity.legacyBundleIdentifiers
    ) -> [String] {
        var copied: Set<String> = []
        for identifier in legacyIdentifiers {
            // `persistentDomain(forName:)` — not `UserDefaults(suiteName:)`
            // `.dictionaryRepresentation()`, which merges in the global domain
            // (AppleLanguages and friends). Copying *those* into the app's own
            // domain would pin system-wide settings.
            guard let legacy = current.persistentDomain(forName: identifier) else { continue }
            copied.formUnion(copy(legacy, into: current))
        }
        return copied.sorted()
    }

    /// Copies every key in `legacy` that `current` does not already have, and
    /// returns the keys it copied. Values are moved as-is, so a `Data` bookmark
    /// survives.
    @discardableResult
    public static func copy(_ legacy: [String: Any], into current: UserDefaults) -> [String] {
        var copied: [String] = []
        for (key, value) in legacy where current.object(forKey: key) == nil {
            current.set(value, forKey: key)
            copied.append(key)
        }
        return copied.sorted()
    }
}
