import Foundation
import TurtleDiverCore
import TurtleDiverSystem

#if canImport(Darwin)
import Darwin
#endif

/// The program `sudo` runs on the askpass route — which is this same binary
/// under a second name.
///
/// `sudo -A` does not read a password from a pipe. It starts the program named
/// by `SUDO_ASKPASS`, as the invoking user, and reads the password from *that
/// program's* standard output. That is the reason this type exists: on a Mac
/// whose `sudo` stack answers with `pam_tid`, a piped password is never read —
/// the module raises its own dialog first — but `pam_tid` stands that dialog
/// down in askpass mode, which its own strings say (`askpass-enabled`,
/// `sudo askpass mode, not showing UI`) and which was measured on this Mac.
///
/// The helper is this binary installed a second time as `turtlediver-askpass`,
/// rather than a shell script or `/usr/bin/security`. Both alternatives hand the
/// administrator password to something generic:
///
/// * the Keychain item's access control is granted to one *program*, so a
///   dedicated helper makes the grant a named, revocable thing (`Keychain
///   Access` ▸ the item ▸ Access Control) instead of whatever ran a script;
/// * `/usr/bin/security` is a general-purpose dispenser: anything that can run
///   as this user can call it and ask for the item. This program prints the
///   administrator password for exactly one reason and does nothing else.
///
/// The residual risk is stated rather than papered over: once that grant exists,
/// any process running as this user that can exec the helper can obtain the
/// password. That is the same exposure as `--sudo-password keychain` on a Mac
/// without `pam_tid`, and less than a sudoers `!authenticate` rule, which hands
/// out root to any local process. `docs/CLI.md` says so in as many words.
public enum AskpassHelper {

    /// The second name this binary is installed under. Deliberately the CLI's own
    /// name plus a suffix, so a person reading `Keychain Access` or `ps` can tell
    /// the two are one program.
    public static let installedName = "turtlediver-askpass"

    /// The variable `sudo` reads the helper's path from, spelled in one place for
    /// the whole project.
    public static let environmentVariable = TunnelAgentChannel.Launch.askpassVariable

    /// True when this process *is* the helper.
    ///
    /// Decided from the name the binary was invoked under, because that is the
    /// name `sudo` was given in `SUDO_ASKPASS` — the kernel keeps it as `argv[0]`
    /// even when the path is a symlink. Not an argument and not an environment
    /// variable: either of those could be pointed at the wrong program by
    /// whoever ran this one.
    public static func isHelperInvocation(executablePath: String?) -> Bool {
        guard let executablePath, !executablePath.isEmpty else { return false }
        return (executablePath as NSString).lastPathComponent == installedName
    }

    /// The name this process was started under, as far as it can be read.
    ///
    /// `CommandLine.arguments[0]` is what the caller wrote, which is what decides
    /// the mode; it may be a bare name found on `PATH`.
    public static func ownPath() -> String? {
        CommandLine.arguments.first
    }

    /// Where the helper is, as `SUDO_ASKPASS` has to name it: an absolute path to
    /// an executable file.
    ///
    /// The candidates are the directory this process was started from and the
    /// installed one, in that order. That is what makes a development build work
    /// without an install (`ln -s turtlediver turtlediver-askpass` beside it) and
    /// what makes the installed package work at all. No environment variable is
    /// consulted: which program is handed the administrator password is not a
    /// choice this CLI lets a caller make.
    public static func path(
        invokedAs: String? = ownPath(),
        runningAt: String? = Bundle.main.executablePath,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        for directory in searchDirectories(invokedAs: invokedAs, runningAt: runningAt) {
            let candidate = (directory as NSString).appendingPathComponent(installedName)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// Where the helper would be looked for, whether or not it is there — so a
    /// refusal can name a path instead of leaving the caller to guess one.
    public static func expectedPath(
        invokedAs: String? = ownPath(),
        runningAt: String? = Bundle.main.executablePath
    ) -> String {
        let directory = searchDirectories(invokedAs: invokedAs, runningAt: runningAt).first
            ?? "/usr/local/bin"
        return (directory as NSString).appendingPathComponent(installedName)
    }

    /// The directories searched, in order and without duplicates. A bare program
    /// name carries no directory, which is why the running binary's own path is
    /// consulted as well.
    static func searchDirectories(invokedAs: String?, runningAt: String?) -> [String] {
        var directories: [String] = []
        for candidate in [invokedAs, runningAt] {
            guard let candidate, candidate.hasPrefix("/") else { continue }
            directories.append((candidate as NSString).deletingLastPathComponent)
        }
        directories.append("/usr/local/bin")

        var seen = Set<String>()
        return directories.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The helper's whole job: print the stored administrator password, and
    /// nothing else, on standard output.
    ///
    /// `sudo` reads this process's standard output *as* the password, so a stray
    /// line would become part of it. There is no format here, no JSON, no
    /// progress note: the value is printed once, is never stored, and this is the
    /// only place in the program that writes a password anywhere. The failure
    /// path goes to standard error with a nonzero status, which `sudo` turns into
    /// its own sentence and a failed authentication.
    ///
    /// Every argument is ignored. `sudo` passes the prompt it would have shown as
    /// the first one, and a program that reads its instructions from a command
    /// line is a program that can be talked into misbehaving.
    public static func run(
        output: FileHandle = .standardOutput,
        error: FileHandle = .standardError,
        readStored: (KeychainSecret) -> KeychainSecret.ReadResult = { $0.read() }
    ) -> CLIExitCode {
        let result = readStored(.adminPassword)
        guard case .value(let secret) = result else {
            let sentence = KeychainSecret.explain(result, account: .adminPassword)
                ?? "the administrator password could not be read from the Keychain"
            error.write(Data("\(installedName): \(sentence)\n".utf8))
            return .failure
        }
        output.write(Data((secret + "\n").utf8))
        return .ok
    }
}
