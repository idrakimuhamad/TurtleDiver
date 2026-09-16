import Foundation
import Security
import OSLog

// The app target compiles these files into one module; the SPM target
// `TurtleDiverAppGlue` compiles them standalone, so the engine modules are
// imported only when they exist as modules (see Package.swift).
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

// MARK: - Secret store

/// The Keychain surface the app needs, as a protocol so tests can inject an
/// in-memory implementation instead of touching the login keychain.
protocol SecretStore: Sendable {
    func retrieve(account: String) -> String?
    func store(password: String, account: String)
    func delete(account: String)
}

/// The production store: the macOS Keychain via `KeychainHelper`.
struct KeychainBackedSecrets: SecretStore, Sendable {
    func retrieve(account: String) -> String? { KeychainHelper.retrieve(account: account) }
    func store(password: String, account: String) { KeychainHelper.store(password: password, account: account) }
    func delete(account: String) { KeychainHelper.delete(account: account) }
}

// MARK: - Keychain Helper

/// Stores and retrieves sensitive credentials using the macOS Keychain.
/// All operations target the `kSecClassGenericPassword` class under
/// `AppIdentity.bundleIdentifier`, scoped to the calling application only.
enum KeychainHelper {

    /// The service name used to scope Keychain items to this app.
    ///
    /// A constant rather than `Bundle.main.bundleIdentifier`: the same value is
    /// needed by the migration below and by `AppIdentityTests` (which checks it
    /// against the Xcode project), and a bare test binary has no app bundle to
    /// ask. `AppIdentity` documents the invariant.
    /// Internal rather than private so `SecretHygieneTests` can assert the app
    /// stores under the same identity the migration copies into.
    static var serviceName: String { AppIdentity.bundleIdentifier }

    /// Shared account names for credentials stored in the Keychain.
    static let adminPasswordAccount = "adminPassword"
    static let vpnPasswordAccount = "vpnPassword"
    static let vpnPasscodeAccount = "vpnPasscode"

    /// The accounts whose names doubled as `UserDefaults` keys before the move
    /// to the Keychain, in the order a migration should attempt them.
    static let credentialAccounts = [adminPasswordAccount, vpnPasswordAccount, vpnPasscodeAccount]

    /// Logger for Keychain operations (visible in Console.app).
    private static let log = Logger(subsystem: serviceName, category: "keychain")

    // MARK: - CRUD

    /// Stores (or updates) a password string in the Keychain.
    /// - Parameters:
    ///   - password: The plain-text password to store.
    ///   - account: A unique identifier for this credential (e.g. `"adminPassword"`).
    static func store(password: String, account: String) {
        persist(password: password, account: account, service: serviceName)
    }

    /// Stores under an explicit service. Only the migration passes a service
    /// other than the app's own.
    private static func persist(password: String, account: String, service: String) {
        guard let data = password.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Try to update if the item already exists
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it
            let status = SecItemAdd(query as CFDictionary, nil)
            if status != errSecSuccess {
                log.error("Failed to store password for '\(account)': \(status)")
            }
        } else if updateStatus != errSecSuccess {
            log.error("Failed to update password for '\(account)': \(updateStatus)")
        }
    }

    /// Retrieves a password string from the Keychain.
    /// - Parameter account: The identifier used when storing.
    /// - Returns: The stored password, or `nil` if no entry exists.
    static func retrieve(account: String) -> String? {
        read(account: account, service: serviceName)
    }

    /// Reads one item from one service.
    private static func read(account: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                log.error("Failed to retrieve password for '\(account)': \(status)")
            }
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Deletes a password string from the Keychain.
    /// - Parameter account: The identifier used when storing.
    static func delete(account: String) {
        erase(account: account, service: serviceName)
    }

    /// Deletes `account` from the app's service *and* every service it used
    /// before the bundle identifier changed.
    ///
    /// Used by "Reset All Settings", where "forget my credentials" has to mean
    /// all of them — leaving a copy behind under the old name would make the
    /// reset a lie. (The user's own reconnect script reads the old service by
    /// name, so it stops working after a reset; that is the point.)
    static func deleteEverywhere(account: String) {
        for service in AppIdentity.keychainServiceChain {
            erase(account: account, service: service)
        }
    }

    private static func erase(account: String, service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("Failed to delete password for '\(account)': \(status)")
        }
    }

    // MARK: - Migration

    /// Copies credentials that only exist under a pre-rename service into the
    /// current one, returning the accounts it copied.
    ///
    /// Safe to run on every launch — it only looks at a legacy item when the
    /// current one is missing — and it *copies* rather than moves, because the
    /// old items are read by name from outside this app. Running it can raise
    /// the system's "wants to access" key dialog once per item, which is why
    /// only the app calls it (at launch, with the user present) and tests never
    /// do.
    @discardableResult
    static func migrateLegacyServicesIfNeeded() -> [String] {
        let plan = KeychainMigration.sources(
            accounts: credentialAccounts,
            currentService: serviceName,
            legacyServices: AppIdentity.legacyBundleIdentifiers,
            read: { service, account in read(account: account, service: service) }
        )
        var migrated: [String] = []
        for item in plan {
            guard let value = read(account: item.account, service: item.service) else { continue }
            persist(password: value, account: item.account, service: serviceName)
            migrated.append(item.account)
        }
        return migrated
    }
}

/// Decides what a change of bundle identifier has to copy across in the
/// Keychain, without touching one.
///
/// Separate from `KeychainHelper` so the decision is testable with an injected
/// reader instead of a real login keychain (which is exactly what a test must
/// never open).
enum KeychainMigration {

    /// The legacy services that hold a copy of each account the current service
    /// is missing, in `accounts` order.
    ///
    /// - Parameter read: `read(service, account)` — the same read the migration
    ///   will perform. An empty string counts as missing: an empty secret is
    ///   not worth copying and not worth trusting.
    /// - Returns: one entry per account that needs copying, naming the service
    ///   to copy *from*. The first legacy service with a value wins, so the
    ///   list is ordered newest-first.
    static func sources(
        accounts: [String],
        currentService: String,
        legacyServices: [String],
        read: (_ service: String, _ account: String) -> String?
    ) -> [(account: String, service: String)] {
        func hasValue(_ service: String, _ account: String) -> Bool {
            !(read(service, account)?.isEmpty ?? true)
        }

        var plan: [(account: String, service: String)] = []
        for account in accounts {
            guard !hasValue(currentService, account) else { continue }
            guard let source = legacyServices.first(where: { hasValue($0, account) }) else { continue }
            plan.append((account, source))
        }
        return plan
    }
}
