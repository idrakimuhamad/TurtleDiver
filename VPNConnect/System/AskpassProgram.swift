import Foundation

/// The program `sudo` starts on the askpass route — and the rules that program
/// obeys, wherever it is installed.
///
/// `sudo -A` does not read a password from a pipe. It starts the program named by
/// `SUDO_ASKPASS`, as the invoking user, and reads the password from *that
/// program's* standard output. On a Mac whose `sudo` stack answers with `pam_tid`,
/// a piped password is never read — the module raises its own dialog first — but
/// `pam_tid` stands that dialog down in askpass mode, which is the whole reason
/// this program exists. `docs/ELEVATION.md` §1b has the measurement.
///
/// There are two of it. The command line tool installs itself a second time as
/// `turtlediver-askpass`; the app ships its own copy of the same program inside
/// its bundle (`Contents/Library/HelperTools/turtlediver-askpass`). Two binaries,
/// one protocol — this type — so neither can drift into being a slightly
/// different dispenser. The reason they are two and not one is that the Keychain
/// grant belongs to the *program*, and a user who installed only the app has no
/// `/usr/local/bin/turtlediver` to point at.
///
/// Deliberately **not** a shell script and deliberately **not**
/// `/usr/bin/security`, for the same reason twice: a script has no stable code
/// identity for the Keychain's access control to name, and `/usr/bin/security` is
/// a general-purpose dispenser that will hand the item to anything running as
/// this user. This program prints one thing, for one reason, and does nothing
/// else.
public enum AskpassProgram {

    /// The name the helper is installed under. One name for both copies, so a
    /// person reading `Keychain Access` can tell which program is being approved
    /// and the two routes cannot be confused for one another.
    public static let installedName = "turtlediver-askpass"

    /// The variable `sudo` reads the program's path from. Spelled here rather than
    /// in the callers so `sudo`'s own spelling appears once in the project.
    public static let environmentVariable = "SUDO_ASKPASS"

    /// The Keychain account the helper reads.
    ///
    /// Spelled here because the app's helper is compiled without
    /// `KeychainHelper`, whose constant is the same string. A drift between them
    /// would make the helper print nothing while the app stores something — a
    /// silent failure with an obvious remedy, which is why a test asserts the two
    /// agree rather than trusting this comment.
    public static let administratorAccount = "adminPassword"

    /// Where the helper sits inside an application bundle.
    ///
    /// `Contents/Library/HelperTools` is the conventional home for a helper
    /// executable, and it is the one Xcode's "Copy Files → Wrapper" phase can be
    /// pointed at. This helper is *not* privileged — `sudo` starts it as the
    /// invoking user — which is why it is allowed inside the app bundle at all:
    /// the tunnel agent, which does run as root, is installed outside the bundle
    /// for exactly that reason (`docs/ELEVATION.md` §10).
    public static let helperToolsDirectory = "Contents/Library/HelperTools"

    /// The helper's path inside the bundle at `bundleURL`.
    public static func bundledPath(bundleURL: URL) -> String {
        bundleURL.appendingPathComponent(helperToolsDirectory)
            .appendingPathComponent(installedName)
            .path
    }

    /// The bundled helper, or `nil` when this build does not carry one.
    ///
    /// Only the app's own bundle is searched: the command line tool's copy is a
    /// different program as far as the Keychain is concerned, so pointing at it
    /// would raise a *second* consent dialog and make the app depend on an
    /// installation that may not exist.
    public static func bundledHelper(
        in bundleURL: URL,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let candidate = bundledPath(bundleURL: bundleURL)
        return isExecutable(candidate) ? candidate : nil
    }

    /// Whether this process *is* the helper.
    ///
    /// Decided from the name the binary was invoked under, because that is the
    /// name `sudo` was given in `SUDO_ASKPASS`: the kernel keeps it as `argv[0]`
    /// even when the path is a symlink into the bundle. Not an argument and not an
    /// environment variable — either of those could be pointed at the wrong
    /// program by whoever ran this one, and a program that reads its instructions
    /// from its caller is a program that can be talked into misbehaving.
    public static func isHelperInvocation(executablePath: String?) -> Bool {
        guard let executablePath, !executablePath.isEmpty else { return false }
        return (executablePath as NSString).lastPathComponent == installedName
    }

    /// The name this process was started under, as far as it can be read.
    ///
    /// `CommandLine.arguments[0]` is what the caller wrote — which is what decides
    /// the mode — and it may be a bare name found on `PATH`.
    public static func ownPath() -> String? {
        CommandLine.arguments.first
    }

    /// What the helper's work amounts to, as the process exit status `sudo` sees.
    ///
    /// Two outcomes and no third: `sudo` treats any nonzero status as "no
    /// password was provided" and reports its own sentence, so a finer-grained
    /// code would only be a code nobody reads.
    public enum Outcome: Int32 {
        case printedPassword = 0
        case failed = 1
    }

    /// The helper's whole job: print the stored administrator password, and
    /// nothing else, on standard output.
    ///
    /// `sudo` reads this process's standard output *as* the password, so a stray
    /// line would become part of it: there is no format here, no JSON, no progress
    /// note, and the value is printed once and stored nowhere. The failure path
    /// goes to standard error, which `sudo` shows rather than parses.
    ///
    /// Every argument is ignored — `sudo` passes the prompt it would have shown as
    /// the first one — and that is a decision, not an oversight: this program's
    /// behaviour must not depend on anything the caller can choose.
    ///
    /// Both the read and the sentence are injected so the rules above can be
    /// tested without a login Keychain and without a password; the shipped callers
    /// pass `StoredSecret.read` and the wording their users already read.
    public static func run(
        output: FileHandle = .standardOutput,
        error: FileHandle = .standardError,
        read: () -> StoredSecret.ReadResult,
        sentence: (StoredSecret.ReadResult) -> String? = { _ in nil }
    ) -> Outcome {
        let result = read()
        guard case .value(let secret) = result else {
            let said = sentence(result)
                ?? "the administrator password could not be read from the Keychain"
            error.write(Data("\(installedName): \(said)\n".utf8))
            return .failed
        }
        output.write(Data((secret + "\n").utf8))
        return .printedPassword
    }
}
