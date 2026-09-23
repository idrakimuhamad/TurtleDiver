import Foundation
import TurtleDiverCore
import TurtleDiverSystem

#if canImport(Darwin)
import Darwin
#endif

/// Where the command line tool finds the askpass helper, and how it hands the
/// job to it.
///
/// The helper itself — the program `sudo -A` runs, the rules it obeys, and why it
/// is a dedicated binary rather than a shell script or `/usr/bin/security` — is
/// `AskpassProgram`, shared with the copy the app ships inside its bundle. What
/// is left here is the part that is specific to this tool: the directory search
/// that makes a development build work without an install, and the exit code
/// mapping.
///
/// The helper is this binary under a second name (`turtlediver-askpass`). Two
/// names, one program, one signature — so the Keychain grant is a named,
/// revocable thing (`Keychain Access` ▸ the item ▸ Access Control) instead of
/// whatever ran a script.
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
    public static let installedName = AskpassProgram.installedName

    /// The variable `sudo` reads the helper's path from, spelled in one place for
    /// the whole project.
    public static let environmentVariable = AskpassProgram.environmentVariable

    /// True when this process *is* the helper.
    public static func isHelperInvocation(executablePath: String?) -> Bool {
        AskpassProgram.isHelperInvocation(executablePath: executablePath)
    }

    /// The name this process was started under, as far as it can be read.
    ///
    /// `CommandLine.arguments[0]` is what the caller wrote, which is what decides
    /// the mode; it may be a bare name found on `PATH`.
    public static func ownPath() -> String? {
        AskpassProgram.ownPath()
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
    /// nothing else, on standard output. `AskpassProgram.run` holds the rules; the
    /// only thing added here is this tool's way of describing a failure, and the
    /// exit code `docs/CLI.md` documents.
    public static func run(
        output: FileHandle = .standardOutput,
        error: FileHandle = .standardError,
        readStored: (KeychainSecret) -> KeychainSecret.ReadResult = { $0.read() }
    ) -> CLIExitCode {
        let outcome = AskpassProgram.run(
            output: output,
            error: error,
            read: { readStored(.adminPassword) },
            sentence: { KeychainSecret.explain($0, account: .adminPassword) }
        )
        return outcome == .printedPassword ? .ok : .failure
    }
}
