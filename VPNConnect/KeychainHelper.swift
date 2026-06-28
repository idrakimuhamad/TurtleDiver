import Foundation
import Security
import OSLog

// MARK: - Keychain Helper

/// Stores and retrieves sensitive credentials using the macOS Keychain.
/// All operations target the `kSecClassGenericPassword` class under the
/// app's bundle identifier, scoped to the calling application only.
enum KeychainHelper {

    /// The service name used to scope Keychain items to this app.
    private static var serviceName: String {
        Bundle.main.bundleIdentifier ?? "com.turtlediver"
    }

    /// Shared account names for credentials stored in the Keychain.
    static let adminPasswordAccount = "adminPassword"
    static let vpnPasswordAccount = "vpnPassword"
    static let vpnPasscodeAccount = "vpnPasscode"

    /// Logger for Keychain operations (visible in Console.app).
    private static let log = Logger(subsystem: serviceName, category: "keychain")

    // MARK: - CRUD

    /// Stores (or updates) a password string in the Keychain.
    /// - Parameters:
    ///   - password: The plain-text password to store.
    ///   - account: A unique identifier for this credential (e.g. `"adminPassword"`).
    static func store(password: String, account: String) {
        guard let data = password.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // Try to update if the item already exists
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("Failed to delete password for '\(account)': \(status)")
        }
    }
}
