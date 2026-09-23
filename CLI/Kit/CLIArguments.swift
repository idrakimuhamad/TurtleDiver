import Foundation
import TurtleDiverCore

/// Identity facts for the command.
///
/// The version is the CLI's own, not the app's, and the two are allowed to move
/// independently: the tool's interface changes on its own schedule. The
/// identifier is the CLI's own, on purpose — the app's bundle id names the app,
/// and two differently-signed binaries claiming one identity is how a Keychain
/// prompt or an update check starts looking at the wrong thing. It is not the
/// code-signing name; that is `executableName`, below.
public enum CLIInfo {
    public static let name = "turtlediver"
    /// A `1.0` here means the interface is settled, not that it has shipped
    /// alongside that many app releases.
    public static let version = "0.1.0"
    public static let identifier = "com.xvii.kurakura.turtlediver"
    /// The name `publish.sh` signs the binary as, and the name it is installed
    /// under, so `codesign`, the package and `docs/CLI.md` agree by construction.
    public static let executableName = "turtlediver"

    /// The installed app's version, when the app can be found. Never invented:
    /// `nil` prints as "not found" rather than as a plausible number.
    public static func installedAppVersion(
        fileManager: FileManager = .default,
        searchPaths: [String] = ["/Applications/TurtleDiver.app", NSHomeDirectory() + "/Applications/TurtleDiver.app"]
    ) -> String? {
        for path in searchPaths {
            let plist = path + "/Contents/Info.plist"
            guard fileManager.fileExists(atPath: plist),
                  let data = fileManager.contents(atPath: plist),
                  let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dictionary = object as? [String: Any],
                  let version = dictionary["CFBundleShortVersionString"] as? String
            else { continue }
            return version
        }
        return nil
    }
}

/// The parsed command line: a command, its positional arguments, and its
/// options.
///
/// Deliberately tiny. The CLI has six commands and no subcommand tree deep
/// enough to want a parser library; what it does want is that an unknown option
/// is an error rather than a silently ignored word, because a caller that typed
/// `--jason` should not get human output and no complaint.
public struct ParsedCommandLine: Equatable {
    public var command: String?
    public var positional: [String]
    /// Options that take a value, by name without the leading dashes.
    public var options: [String: String]
    /// Options that are simply present.
    public var switches: Set<String>

    /// Options this CLI accepts a value for. Anything else with a value shape is
    /// a usage error unless it is a known switch.
    public static let valueOptions: Set<String> = ["profile", "port", "timeout", "format", SudoPasswordSource.optionName]
    /// Options that carry no value.
    public static let knownSwitches: Set<String> = ["json", "quiet", "help", "version", "force", "verbose"]

    public init(command: String? = nil, positional: [String] = [], options: [String: String] = [:], switches: Set<String> = []) {
        self.command = command
        self.positional = positional
        self.options = options
        self.switches = switches
    }

    public var wantsJSON: Bool { switches.contains("json") }
    public var wantsQuiet: Bool { switches.contains("quiet") }
    public var wantsHelp: Bool { switches.contains("help") }

    /// Parses everything after the program name.
    ///
    /// A `--` ends option parsing, so a host that starts with a dash can still be
    /// explained. The first non-option word is the command; the rest are
    /// positional. Short forms `-h`/`-v` are accepted because a person will type
    /// them whether or not they are documented.
    public static func parse(_ arguments: [String]) throws -> ParsedCommandLine {
        var parsed = ParsedCommandLine()
        var index = 0
        var optionsEnded = false

        while index < arguments.count {
            let token = arguments[index]
            index += 1

            if optionsEnded {
                assign(token, to: &parsed)
                continue
            }
            if token == "--" {
                optionsEnded = true
                continue
            }
            if token == "-h" { parsed.switches.insert("help"); continue }
            if token == "-v" { parsed.switches.insert("version"); continue }

            guard token.hasPrefix("--") else {
                assign(token, to: &parsed)
                continue
            }

            let body = String(token.dropFirst(2))
            let (name, inlineValue) = split(body)
            if let inlineValue {
                parsed.options[name] = inlineValue
                continue
            }
            if Self.valueOptions.contains(name) {
                guard index < arguments.count else {
                    throw CLIFailure.usage("--\(name) needs a value")
                }
                parsed.options[name] = arguments[index]
                index += 1
                continue
            }
            guard Self.knownSwitches.contains(name) else {
                throw CLIFailure.usage("unknown option --\(name)")
            }
            parsed.switches.insert(name)
        }

        return parsed
    }

    private static func split(_ body: String) -> (name: String, value: String?) {
        guard let equals = body.firstIndex(of: "=") else { return (body, nil) }
        return (String(body[body.startIndex ..< equals]), String(body[body.index(after: equals)...]))
    }

    private static func assign(_ token: String, to parsed: inout ParsedCommandLine) {
        if parsed.command == nil {
            parsed.command = token
        } else {
            parsed.positional.append(token)
        }
    }

    /// An integer option, or a usage error naming it — the failure a person
    /// actually makes is `--port ssh`.
    public func int(_ name: String) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let value = Int(raw) else {
            throw CLIFailure.usage("--\(name) expects a number, not \"\(raw)\"")
        }
        return value
    }

    public func int(_ name: String, default defaultValue: Int) throws -> Int {
        try int(name) ?? defaultValue
    }
}
