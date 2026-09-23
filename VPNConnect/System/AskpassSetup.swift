import Foundation
import Security

/// Whether the app's own askpass helper is ready to be trusted, and how that is
/// decided.
///
/// The helper inside the bundle (`AskpassProgram.bundledHelper`) can read the
/// stored administrator password only if the *user* has allowed it once, in the
/// Keychain dialog macOS raises the first time that program asks. That dialog is
/// the point of the design — a person decides, once, for one named program — but
/// it is also a bad thing to meet in the middle of a connect: the connect is
/// waiting, and the dialog can be missed behind another window.
///
/// So the app separates the two moments. Setting up means running the helper once
/// *on purpose*, from Settings, so the dialog appears where the user is looking,
/// and then recording what was approved. A connect uses the helper only when that
/// record still matches the helper actually in the bundle.
///
/// The record is the helper's **designated requirement** — the same text `codesign`
/// shows under `designated =>` — and not a bare "yes, prepared" flag. The
/// difference matters on an ad-hoc development build, whose requirement embeds
/// the code hash: rebuild, and the same path holds a different program. A flag
/// would say "ready" and the connect would meet the dialog anyway, in the worst
/// possible place. Comparing requirements notices, and the app can ask the user
/// to prepare again while they are looking at Settings.
public enum AskpassSetup {

    /// Where the approval is remembered, in the app's own preferences.
    ///
    /// One key, holding the requirement text. Not a secret — it names a program
    /// and its signer, the same thing `codesign -d` prints for anyone who asks —
    /// so it does not belong in the Keychain, whose every read can raise a dialog
    /// of its own.
    public static let defaultsKey = "askpassHelperRequirement"

    /// The helper's path in this app's bundle, or `nil` when it carries none.
    ///
    /// The default bundle is the running app, and the parameter exists so a test
    /// can point at a sandbox with a fake helper in it.
    public static func bundledHelperPath(
        bundleURL: URL = Bundle.main.bundleURL,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        AskpassProgram.bundledHelper(in: bundleURL, isExecutable: isExecutable)
    }

    /// The designated requirement of the program at `path`, as text.
    ///
    /// This is a *read* of a signed file: `SecStaticCodeCreateWithPath` inspects
    /// it on disk, does not run it, and asks nothing of the Keychain. `nil` means
    /// the file is missing, unreadable, or unsigned — never that some other
    /// requirement was found, because a requirement invented here would be a
    /// requirement nothing else agrees with.
    public static func fingerprint(ofProgramAt path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else { return nil }
        return text as String
    }

    /// Whether the recorded approval still names the helper that is here now.
    ///
    /// Both halves are required, and neither is inferred: something must have been
    /// recorded (a fresh install has not set this up), and the helper on disk must
    /// still carry exactly that requirement. An empty record is not an approval —
    /// it is the absence of one, spelled the way an unset preference comes back.
    public static func isPrepared(
        helperPath: String,
        recorded: String?,
        fingerprint: (String) -> String? = fingerprint(ofProgramAt:)
    ) -> Bool {
        guard let recorded, !recorded.isEmpty else { return false }
        guard let current = fingerprint(helperPath) else { return false }
        return current == recorded
    }

    /// The helper path a connect may use, or `nil` when there is nothing prepared
    /// to use.
    ///
    /// One function so the answer cannot be assembled differently in two places:
    /// the helper must exist in the bundle *and* the recorded approval must still
    /// match it. Every `nil` here is the ordinary, safe case — the connect falls
    /// back to asking the system, exactly as it did before the helper existed.
    public static func usableHelperPath(
        bundleURL: URL = Bundle.main.bundleURL,
        recorded: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fingerprint: (String) -> String? = fingerprint(ofProgramAt:)
    ) -> String? {
        guard let path = bundledHelperPath(bundleURL: bundleURL, isExecutable: isExecutable) else {
            return nil
        }
        guard isPrepared(helperPath: path, recorded: recorded, fingerprint: fingerprint) else {
            return nil
        }
        return path
    }

    /// What is remembered after a successful setup, or `nil` when the helper could
    /// not be fingerprinted (an unsigned build): a setup that approved *something*
    /// the app cannot name afterwards would be worse than none, because the next
    /// connect would trust it.
    public static func recordToStore(
        helperPath: String,
        fingerprint: (String) -> String? = fingerprint(ofProgramAt:)
    ) -> String? {
        fingerprint(helperPath)
    }
}
