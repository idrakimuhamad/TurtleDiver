import Foundation

// The app builds this file as its own target, where `AskpassProgram`,
// `StoredSecret` and `AppIdentity` are compiled alongside it; `swift build`
// compiles them as the `TurtleDiverSystem` module instead. Same source, one
// program (see `Package.swift` and `docs/ELEVATION.md` §11).
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// `turtlediver-askpass` — the program `sudo -A` runs.
///
/// It prints the administrator password the app has stored, once, on standard
/// output, and exits. `sudo` reads that output as the password (see
/// `AskpassProgram` for why this program has to exist at all, and why it is not
/// a shell script).
///
/// Three things this program deliberately does not do:
///
/// * it does not look at its arguments — `sudo` passes the prompt it would have
///   shown as the first one, and a helper that took instructions from its caller
///   could be talked into something else;
/// * it does not read `SUDO_ASKPASS` or any other variable to find out what to
///   do — its mode comes from the name it was launched under and nothing else;
/// * it does not touch `stdout` unless it has the password. `sudo` parses that
///   stream, so a diagnostic line there would be read as part of the password.
///
/// Run by a person instead of by `sudo`, it refuses: the name is what decides the
/// mode, and the installed name is `turtlediver-askpass`, so being run under any
/// other name means someone is holding the wrong program. The refusal is not a
/// security boundary — anyone who can run this can run it under its real name —
/// it is an instruction, and it costs one line to give.
guard AskpassProgram.isHelperInvocation(executablePath: AskpassProgram.ownPath()) else {
    let name = AskpassProgram.ownPath().map { ($0 as NSString).lastPathComponent } ?? "turtlediver-askpass"
    FileHandle.standardError.write(Data("""
    \(name): this program is run by sudo, not by hand.
    Point sudo at it:  SUDO_ASKPASS=\(AskpassProgram.installedName) sudo -A <command>

    """.utf8))
    exit(64) // sysexits EX_USAGE
}

exit(AskpassProgram.run(
    read: {
        StoredSecret.read(services: AppIdentity.keychainServiceChain,
                          account: AskpassProgram.administratorAccount)
    },
    sentence: {
        StoredSecret.explain($0,
                             noun: "administrator password",
                             remedy: "save it in the app under Settings ▸ VPN")
            ?? "the administrator password could not be read from the Keychain"
    }
).rawValue)
