import Foundation
import TurtleDiverCore
import TurtleDiverSystem

/// The one place the CLI builds an `openconnect` command line.
///
/// This is the code that can drift from the app's (`VPNManager`), so it is a
/// value with no I/O: `build` is a pure function of the settings and the resolved
/// tool paths, and `Tests/TurtleDiverCLITests` pins each argument. When the
/// app's line changes, this one has to change in the same commit, and the test
/// is where that is noticed.
public struct OpenConnectInvocation: Equatable {
    public let openconnectPath: String
    public let arguments: [String]
    public let searchPath: String
    /// How many credential lines the agent's standard input carries. Two on this
    /// path — the PIN and the account password — because there is no `sudo -S`
    /// for openconnect to sit behind. See `TunnelAgentChannel.Launch`.
    public let credentialLineCount: Int

    public init(openconnectPath: String, arguments: [String], searchPath: String, credentialLineCount: Int) {
        self.openconnectPath = openconnectPath
        self.arguments = arguments
        self.searchPath = searchPath
        self.credentialLineCount = credentialLineCount
    }

    /// The tunnel's argv, in the app's order: options, then the host.
    ///
    /// - Parameter slicePath: the resolved `vpn-slice`, required when tunnelling
    ///   is on. A missing one is a missing tool, not a fallback: quietly
    ///   connecting without the routes the user asked for would be a tunnel that
    ///   looks up and does not work.
    public static func build(
        settings: AppSettings,
        openconnectPath: String,
        slicePath: String?,
        pidFilePath: String,
        searchPath: String = OpenConnectCommand.defaultSearchPath
    ) throws -> OpenConnectInvocation {
        let host = settings.vpnHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = settings.vpnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            throw CLIFailure.notConfigured("no VPN server is configured; set it in the app under Settings ▸ VPN")
        }
        guard !account.isEmpty else {
            throw CLIFailure.notConfigured("no VPN account is configured; set it in the app under Settings ▸ VPN")
        }

        // The order and spelling are copied from VPNManager.executeVPNConnection:
        // a 10s dead-peer check and a 7-day reconnect window, then the account,
        // then the pid file openconnect writes when it backgrounds (inert here —
        // the agent runs it in the foreground — but kept so the two paths'
        // arguments are identical).
        var arguments = [
            "--force-dpd=10",
            "--reconnect-timeout=604800",
            "--user=\(account)",
            "--pid-file", pidFilePath,
        ]

        if settings.useTunneling {
            guard let slicePath, !slicePath.isEmpty else {
                throw CLIFailure(
                    .missingTool,
                    "split tunnelling is on but vpn-slice is not installed",
                    details: ["tool": "vpn-slice", "formula": "vpn-slice"]
                )
            }
            let urls = settings.vpnSliceURLs.joined(separator: " ")
            // One argv element: the slice script and its URLs are a single `-s`
            // value, and splitting them would make openconnect read the URLs as
            // its own options.
            arguments.append(contentsOf: ["-s", "\(slicePath) \(urls)"])
        }

        arguments.append(host)

        return OpenConnectInvocation(
            openconnectPath: openconnectPath,
            arguments: arguments,
            searchPath: searchPath,
            credentialLineCount: TunnelAgentChannel.Launch.credentialLineCount
        )
    }

    /// For a human reading a preflight failure. Contains no credential — the
    /// argv never does — so it is safe to print and to log.
    public func commandLinePreview() -> String {
        ([openconnectPath] + arguments).joined(separator: " ")
    }
}

/// Everything the connect path needs to have resolved before it may run
/// anything, so that a missing piece is reported as a name and a remedy rather
/// than as an exit status from two layers down.
public struct ConnectPreflight: Equatable {
    public let openconnectPath: String
    public let slicePath: String?
    public let stokenPath: String?
    public let agentPath: String

    public init(openconnectPath: String, slicePath: String?, stokenPath: String?, agentPath: String) {
        self.openconnectPath = openconnectPath
        self.slicePath = slicePath
        self.stokenPath = stokenPath
        self.agentPath = agentPath
    }
}
