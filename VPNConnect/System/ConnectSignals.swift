import Foundation

/// Decides which line of openconnect's output means the tunnel is **up**.
///
/// The distinction matters because the app acts on it the moment it is drawn:
/// the status becomes `.connected`, the action button stops offering "Cancel" and
/// starts offering "Disconnect", the duration timer starts, and the history row
/// is written. So a line that arrives while openconnect is still negotiating does
/// not merely mislabel the header — it tells the user the tunnel is ready before
/// it can carry any of the traffic it was opened for.
///
/// Measured on a real connection (2026-09-22, TLS, split tunnel via `vpn-slice`):
///
///     08:28:38  Got CONNECT response: HTTP/1.1 200 OK
///     08:28:38  CSTP connected. DPD 10, Keepalive 20
///     08:28:52  Configured as <address>, with SSL connected and DTLS in progress
///
/// The first two are the gateway's answer to the HTTPS CONNECT request and the
/// start of the CSTP session. Both are printed about fourteen seconds *before*
/// openconnect has run the routing script — and in that window the header said
/// "Connected" and the button said "Disconnect" while the tunnel was still
/// authenticating. `Configured as` is printed once that script has configured the
/// routes, which is the first moment the tunnel is usable.
///
/// `Connected as` is deliberately absent: openconnect prints it in the same
/// breath as the CSTP line, ahead of the script. It is left out rather than risk
/// the same premature flip on a build that does print it.
public enum ConnectSignals {

    /// The lines that mean openconnect has finished setting the tunnel up.
    ///
    /// `Configured as` is the measured one for this app's launch shape (it always
    /// passes a routing script). The two DTLS/ESP lines are the tunnel's own data
    /// path coming up, which necessarily happens after the session exists.
    public static let tunnelIsUp: [String] = [
        "Configured as",
        "Established DTLS",
        "ESP session established"
    ]

    /// Whether this line means the tunnel came up.
    ///
    /// `contains` rather than equality because openconnect prefixes these lines
    /// with its own logging decorations (`XML POST enabled`, `SSL negotiation…`)
    /// depending on version and verbosity, and the app has always matched on the
    /// distinguishing substring.
    public static func isTunnelUp(in text: String) -> Bool {
        tunnelIsUp.contains { text.contains($0) }
    }
}

/// What to say about a connect that ended before the tunnel was ready.
public struct TunnelEndingDiagnosis: Equatable, Sendable {
    /// The status the header and the history row carry.
    public let status: String
    /// The line the log gets, when there is more to say than the status.
    public let detail: String
}

extension ConnectSignals {

    /// The status for a tunnel that ended on its own, before it was ready.
    public static let tunnelEndedStatus = "Failed - Tunnel Ended"

    /// Names the cause of a connect that ended before the tunnel was ready.
    ///
    /// The exit status cannot name it on the agent path: the agent exits `0`
    /// because the tunnel it supervised had already gone, so "Connection failed
    /// (status: 0)" is a sentence with no information in it. The last line
    /// openconnect printed is the only thing that knows why — measured, a connect
    /// that fails to authenticate ends with `Failed to complete authentication` —
    /// so that is what the message is built from. With no line to report, the exit
    /// status is all there is, and it is better than saying nothing.
    public static func diagnosisForTunnelEnding(
        lastLine: String,
        terminationStatus: Int32,
        maximumLineBytes: Int = 160
    ) -> TunnelEndingDiagnosis {
        let line = lastLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            return TunnelEndingDiagnosis(
                status: "Connection failed (status: \(terminationStatus))",
                detail: ""
            )
        }
        return TunnelEndingDiagnosis(
            status: tunnelEndedStatus,
            detail: "The tunnel ended before it was ready — its last line was: "
                + String(line.prefix(maximumLineBytes)) + "\n"
        )
    }
}
