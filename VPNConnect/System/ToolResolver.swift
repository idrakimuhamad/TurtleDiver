import Foundation

// MARK: - Requirements

/// A command-line tool the app drives, and what stops working without it.
///
/// The app shells out to four programs (`openconnect`, `stoken`, `vpn-slice`
/// and, to install the other three, `brew`). Which of them exist — and *where*
/// — used to be hard-coded in `VPNManager.binaryPath`, which searched four
/// directories and never looked at `$PATH`. Homebrew on Apple silicon installs
/// into `/opt/homebrew/bin` (covered) but MacPorts uses `/opt/local/bin` and
/// `pipx`/hand-rolled installs use `~/.local/bin`, so a tool the user had
/// installed was invisible to the app and the connect failed with a message
/// about the *token* rather than about the missing tool.
public struct ToolRequirement: Identifiable, Equatable, Sendable {

    /// The executable's name, and the identifier used everywhere else
    /// ("openconnect", "stoken", "vpn-slice", "brew").
    public let id: String

    /// How the tool is named in the UI. Same as `id` for the three real tools;
    /// the resolver's own label for Homebrew.
    public let displayName: String

    /// The Homebrew formula that provides it, or `nil` when Homebrew itself is
    /// the requirement (it cannot install itself).
    public let formula: String?

    /// Where to read more. Homebrew points at brew.sh; the rest at the
    /// project's own page.
    public let documentationURL: String

    /// One line, written for the pane: what breaks if this is missing.
    public let consequence: String

    /// Arguments that make the tool print its version.
    public let versionArguments: [String]

    public init(id: String,
                displayName: String,
                formula: String?,
                documentationURL: String,
                consequence: String,
                versionArguments: [String] = ["--version"]) {
        self.id = id
        self.displayName = displayName
        self.formula = formula
        self.documentationURL = documentationURL
        self.consequence = consequence
        self.versionArguments = versionArguments
    }
}

extension ToolRequirement {

    public static let homebrew = ToolRequirement(
        id: "brew",
        displayName: "Homebrew",
        formula: nil,
        documentationURL: "https://brew.sh",
        consequence: "Installs the three tools below. The app never installs it for you.",
        versionArguments: ["--version"]
    )

    public static let openconnect = ToolRequirement(
        id: "openconnect",
        displayName: "openconnect",
        formula: "openconnect",
        documentationURL: "https://www.infradead.org/openconnect/",
        consequence: "The tunnel itself — no openconnect, no VPN connection.",
        versionArguments: ["--version"]
    )

    public static let stoken = ToolRequirement(
        id: "stoken",
        displayName: "stoken",
        formula: "stoken",
        documentationURL: "https://github.com/stoken-dev/stoken",
        consequence: "The one-time code appended to your PIN. Without it a connect cannot start.",
        versionArguments: ["--version"]
    )

    public static let vpnSlice = ToolRequirement(
        id: "vpn-slice",
        displayName: "vpn-slice",
        formula: "vpn-slice",
        documentationURL: "https://github.com/dlenski/vpn-slice",
        consequence: "Split tunneling only. A standard VPN connection works without it.",
        versionArguments: ["--version"]
    )

    /// Everything the pane reports on, in the order it is shown.
    public static let all: [ToolRequirement] = [.homebrew, .openconnect, .stoken, .vpnSlice]

    /// The tools Homebrew can install for the user — i.e. everything except
    /// Homebrew itself.
    public static var installable: [ToolRequirement] { all.filter { $0.formula != nil } }

    public static func named(_ id: String) -> ToolRequirement? {
        all.first { $0.id == id }
    }
}

// MARK: - Resolution

/// Finds an executable by name.
///
/// Resolution is a pure function over a list of directories so it can be tested
/// without touching the machine's real filesystem — and so the search order is
/// visible rather than an accident of whichever branch ran first.
public enum ToolResolver {

    /// Directories searched *after* `$PATH`, in order.
    ///
    /// `$PATH` comes first because that is what the user chose; this list is the
    /// safety net for the two ways a GUI-launched app loses it. `/opt/homebrew`
    /// and `/usr/local` are Homebrew on Apple silicon and Intel; `/opt/local` is
    /// MacPorts; `~/.local/bin` is where `pipx` and hand-rolled installs land.
    public static let fallbackDirectories = [
        "/opt/homebrew/bin",   // Homebrew, Apple silicon
        "/usr/local/bin",      // Homebrew, Intel
        "/opt/local/bin",      // MacPorts
        "~/.local/bin",        // pipx, hand-rolled installs
        "/usr/bin",
        "/bin",
    ]

    /// `$PATH` entries (in order, de-duplicated, empties dropped) followed by
    /// `fallbackDirectories` with `~` resolved against `home`.
    public static func searchPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: String = NSHomeDirectory(),
                                  fallbacks: [String] = fallbackDirectories) -> [String] {
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { expand(String($0), home: home) }
        return dedupe(fromPath + fallbacks.map { expand($0, home: home) })
    }

    /// Pure resolution: the first directory in `searchPath` holding an
    /// executable called `name`.
    public static func path(for name: String,
                            searchPath: [String],
                            isExecutable: (String) -> Bool) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for directory in searchPath where !directory.isEmpty {
            let candidate = directory.hasSuffix("/")
                ? directory + name
                : directory + "/" + name
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// The filesystem-backed convenience: `$PATH` first, then the prefixes.
    public static func locate(_ name: String,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: String = NSHomeDirectory(),
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        path(for: name,
             searchPath: searchPath(environment: environment, home: home),
             isExecutable: isExecutable)
    }

    /// Where Homebrew's own directory is, if the app can find `brew` at all.
    public static func homebrewDirectory(brewPath: String) -> String {
        (brewPath as NSString).deletingLastPathComponent
    }

    private static func expand(_ directory: String, home: String) -> String {
        guard directory == "~" || directory.hasPrefix("~/") else { return directory }
        return home + directory.dropFirst()
    }

    private static func dedupe(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for directory in directories where !directory.isEmpty {
            if seen.insert(directory).inserted { result.append(directory) }
        }
        return result
    }
}

// MARK: - Versions

/// Pulls a version number out of a tool's `--version` output.
///
/// Every one of these programs formats its first line differently —
/// "OpenConnect version v9.21", "stoken 0.93 - software token…",
/// "vpn-slice 0.16.1", "Homebrew 7.0.1" — so the rule is "the first dotted
/// number", not "the second word".
public enum ToolVersion {

    /// The first `digits.digits(.digits…)` run in the text, or `nil`.
    public static func parse(_ output: String) -> String? {
        var digits: [Character] = []
        var candidate: String?

        /// A version needs a dot and must end in a digit: "9" is a count, and
        /// "1." is the start of something the tool never finished printing.
        func flush() -> String? {
            var trimmed = digits
            while trimmed.last == "." { trimmed.removeLast() }
            guard trimmed.contains(".") else { return nil }
            return String(trimmed)
        }

        for character in output {
            if character.isNumber {
                digits.append(character)
            } else if character == ".", !digits.isEmpty, digits.last != "." {
                digits.append(character)
            } else {
                if let found = flush() { candidate = found; break }
                digits.removeAll()
            }
        }
        return candidate ?? flush()
    }

    /// The first non-empty line — what these tools print their version on.
    public static func firstLine(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? ""
    }
}

// MARK: - Status

/// What the app found when it looked for one tool.
public struct ToolStatus: Equatable, Sendable, Identifiable {
    public let requirement: ToolRequirement
    /// Absolute path to the executable, or `nil` if it was not found.
    public let path: String?
    /// Parsed version, when the tool could be run and answered.
    public let version: String?

    public init(requirement: ToolRequirement, path: String?, version: String?) {
        self.requirement = requirement
        self.path = path
        self.version = version
    }

    public var id: String { requirement.id }

    public var isInstalled: Bool { path != nil }

    /// "9.21" / "not installed".
    public var versionSummary: String {
        version ?? (isInstalled ? "version unknown" : "not installed")
    }
}

// MARK: - Preflight

/// Decides whether a connection can start, and says which tool is missing when
/// it cannot.
///
/// This runs *before* `stoken` is asked for a code, which is the whole point:
/// a missing binary used to surface as "Failed to generate token", sending the
/// user to check their PIN and token file when the real problem was that
/// nothing was installed.
public enum ToolPreflight {

    /// The tools a connect needs. `vpn-slice` is only the split-tunnel helper,
    /// so standard VPN mode does not require it.
    public static func required(splitTunneling: Bool) -> [ToolRequirement] {
        splitTunneling ? [.openconnect, .stoken, .vpnSlice] : [.openconnect, .stoken]
    }

    /// The subset of `required(splitTunneling:)` the resolver cannot find.
    public static func missing(splitTunneling: Bool,
                              locate: (String) -> String? = { ToolResolver.locate($0) }) -> [ToolRequirement] {
        required(splitTunneling: splitTunneling).filter { locate($0.id) == nil }
    }

    /// "stoken is not installed — see Settings ▸ Setup".
    public static func message(for missing: [ToolRequirement]) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.displayName)
        let list: String
        switch names.count {
        case 1: list = names[0]
        case 2: list = "\(names[0]) and \(names[1])"
        default: list = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "\(list) \(names.count == 1 ? "is" : "are") not installed — see Settings ▸ Setup"
    }
}
