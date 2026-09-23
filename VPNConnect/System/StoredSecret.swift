import Foundation
import Security

/// One credential out of the login Keychain, with the answer kept whole.
///
/// Three programs read the same items — the app, the command line tool, and the
/// askpass helper — and each of them used to carry its own `SecItemCopyMatching`
/// call. That is the wrong shape for a security-sensitive read: three copies of a
/// query means three chances for one of them to ask for something the others do
/// not (the data, the attributes, a different access control), and the symptom of
/// a divergence is a Keychain dialog nobody expected. So the query lives here,
/// once, and the callers decide only what the answer *means*.
///
/// Nothing in this type logs, prompts, caches or retries. It answers, and the
/// caller does the talking.
public enum StoredSecret {

    /// Three outcomes, not two, because "there is no item" and "the item is there
    /// and this program was refused" want different sentences and different
    /// remedies — one is a pane in the app, the other is a click on a dialog.
    public enum ReadResult: Equatable, Sendable {
        /// The stored value. Never empty: an empty secret is not a secret, and
        /// reporting one as a value would turn "not set" into a failed
        /// authentication three steps later.
        case value(String)
        /// No item under any of the services asked for.
        case missing
        /// The item exists and the read was refused, with the status that says
        /// why (`errSecUserCanceled` is a person clicking Deny, not a bug).
        case refused(OSStatus)
    }

    /// The value of one item, trying each service in order and remembering the
    /// last status seen.
    ///
    /// The service chain matters for the same reason it does everywhere else in
    /// this app: the identifier *is* the Keychain service name, it changed once,
    /// and an item can still live under the old name. Reading only the current
    /// one would report "not configured" over a credential that is right there.
    ///
    /// No `kSecUseAuthenticationUI` override: the consent dialog is the point.
    /// Suppressing it would turn a one-time decision into a command that cannot
    /// work on a machine where it has not been answered yet.
    public static func read(services: [String], account: String) -> ReadResult {
        var lastStatus: OSStatus = errSecItemNotFound
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let text = String(data: data, encoding: .utf8), !text.isEmpty {
                return .value(text)
            }
            lastStatus = status
        }
        return lastStatus == errSecItemNotFound ? .missing : .refused(lastStatus)
    }

    /// Whether the item is there at all, read without its data.
    ///
    /// Attributes are not what an item's access control protects: a query that
    /// asks for them and not for `kSecReturnData` answers without decrypting
    /// anything and without raising the consent dialog. That is the difference
    /// between asking "is there an administrator password?" — which a screen may
    /// ask every time it is opened — and asking for the password itself, which is
    /// a thing a person should see happen once and on purpose.
    ///
    /// Presence, not validity: an item whose value is empty reads as present here
    /// and as missing to `read()`. The helper, which does use `read()`, fails on
    /// that case with the sentence that names the item.
    public static func isPresent(services: [String], account: String) -> Bool {
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess { return true }
        }
        return false
    }

    /// What to tell a person about a read that produced no value, or `nil` when
    /// there is nothing to explain.
    ///
    /// `noun` is what the credential is called in a sentence and `remedy` is
    /// where a person goes to fix a missing one; both belong to the caller,
    /// because the app and the command line tool store the same secret and would
    /// otherwise each describe it in their own words. The status is quoted rather
    /// than interpreted: a number a person can search for is worth more than a
    /// reassuring sentence that hides which failure this was.
    public static func explain(_ result: ReadResult, noun: String, remedy: String) -> String? {
        switch result {
        case .value:
            return nil
        case .missing:
            return "the app has no stored \(noun); \(remedy)"
        case .refused(let status):
            return "macOS refused access to the stored \(noun) (OSStatus \(status));"
                + " allow the prompt, or run the app and connect once first"
        }
    }
}
