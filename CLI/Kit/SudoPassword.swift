import Foundation
import TurtleDiverCore

#if canImport(Darwin)
import Darwin
#endif

/// Where a caller offers the administrator password, when it offers one at all.
///
/// There is no default source, and that is the whole design: with no
/// `--sudo-password` the connect behaves exactly as it did before this option
/// existed — a terminal gets `sudo -v` (and with `pam_tid`, its dialog), a pipe
/// gets `sudo -n -v`, and a cold timestamp is exit 6 with the remedy printed.
/// Naming a source is a deliberate act that says *here is the password*, so the
/// CLI never picks one on the caller's behalf and never falls back to another
/// when the named one is empty.
///
/// Both sources keep the password out of `argv` and out of the environment:
/// an argument is readable by any process running as this user (`ps`, `pgrep -f`)
/// and is copied into crash reports, and an environment variable is readable the
/// same way (`ps -E`) and is inherited by every child.
public enum SudoPasswordSource: String, CaseIterable, Equatable {
    /// The app's own Keychain item, `adminPassword` — written by the app's
    /// Settings ▸ Advanced, under the same service as the VPN credentials. The
    /// only source in which the password never enters the caller's own memory.
    case keychain
    /// One line on this process's standard input. The CLI reads its own standard
    /// input nowhere else — the pipe the tunnel's lifetime hangs on belongs to
    /// the agent, not to this process — so a caller can spend it here.
    case stdin

    /// The option name, spelled once so the parser, the help text and the
    /// refusals cannot disagree about it.
    public static let optionName = "sudo-password"

    /// How to name a source in a message a person reads.
    public var syntax: String { "--\(Self.optionName) \(rawValue)" }

    /// The flag's value, or a usage error listing what it accepts.
    public static func parse(_ raw: String) throws -> SudoPasswordSource {
        guard let source = SudoPasswordSource(rawValue: raw) else {
            throw CLIFailure.usage(
                "--\(optionName) expects \(allCases.map(\.rawValue).joined(separator: " or "))"
                    + ", not \"\(raw)\""
            )
        }
        return source
    }
}

/// Reading the administrator password from the place the caller named.
///
/// The value this returns is used for exactly one thing — the connect's
/// `sudo -S -v` warm-up, as a direct child of this process — and is never
/// printed, never put in a `--json` body, and never included in an error's
/// detail. `docs/CLI.md` states the invariant in full.
public enum SudoPassword {

    /// One sentence saying where the password is about to be read from, printed
    /// *before* the read. The Keychain read can raise macOS's own consent dialog,
    /// and a dialog with nothing above it reads as a crash rather than as a
    /// question. Never contains the secret — it is printed unconditionally.
    public static func announcement(for source: SudoPasswordSource) -> String {
        switch source {
        case .keychain:
            return "reading the administrator password from the Keychain"
                + " (macOS may ask once, the first time this binary reads it)"
        case .stdin:
            return "reading the administrator password from standard input"
        }
    }

    /// The password, or a `CLIFailure` naming what was wrong with the offer.
    ///
    /// A named source that does not deliver is refused rather than quietly
    /// upgraded to a prompt: a scripted caller that asked for `stdin` and got a
    /// Touch ID dialog would hang, and one that asked for `keychain` and got a
    /// prompt would fail in a way it cannot see.
    public static func read(
        _ source: SudoPasswordSource,
        stdinIsTerminal: Bool = isatty(STDIN_FILENO) != 0,
        readStored: (KeychainSecret) -> KeychainSecret.ReadResult = { $0.read() },
        readLine: () -> String? = SudoPassword.lineFromStandardInput
    ) throws -> String {
        switch source {
        case .keychain:
            let result = readStored(.adminPassword)
            guard case .value(let secret) = result else {
                throw CLIFailure.notConfigured(
                    KeychainSecret.explain(result, account: .adminPassword)
                        ?? "the administrator password could not be read from the Keychain"
                )
            }
            return secret

        case .stdin:
            guard !stdinIsTerminal else {
                throw CLIFailure.usage(
                    "\(source.syntax) expects the password on a pipe, and standard input is a terminal;"
                        + " pipe one line in, or drop the option and be prompted instead"
                )
            }
            guard let line = readLine(), !line.isEmpty else {
                throw CLIFailure.usage(
                    "\(source.syntax) got no password on standard input;"
                        + " write exactly one line, e.g."
                        + " `printf '%s\\n' \"$sudo_password\" | turtlediver connect --sudo-password stdin`"
                )
            }
            return line
        }
    }

    /// One line of this process's standard input, with only its line ending
    /// removed.
    ///
    /// Deliberately not trimmed: a password may begin or end with a space, and
    /// stripping one would turn a correct password into a wrong one with nothing
    /// on screen to explain it. A trailing carriage return *is* removed, so a
    /// line from a CRLF file is not handed to `sudo` with an invisible byte on
    /// the end of it.
    public static func lineFromStandardInput() -> String? {
        guard let line = Swift.readLine() else { return nil }
        return trimmingLineEnding(line)
    }

    /// A line with only its line ending removed — split out so the rule can be
    /// tested without a pipe attached to the test process.
    public static func trimmingLineEnding(_ line: String) -> String {
        guard line.hasSuffix("\r") else { return line }
        return String(line.dropLast())
    }
}
