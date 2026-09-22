import XCTest

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Pins which of openconnect's lines count as "the tunnel is up".
///
/// The defect this records: the app treated the gateway's HTTPS `CONNECT` reply
/// and the `CSTP connected` line as success, so the header read "Connected" — and
/// the action button offered a red "Disconnect" instead of "Cancel" — about
/// fourteen seconds before openconnect had run the routing script. The user saw
/// it and asked why the button offered to disconnect a tunnel that was still
/// connecting.
///
/// The sequence in `liveSequence` below is copied from that run's log, verbatim
/// and in order. It is the strongest pin available for a pure classifier: it does
/// not ask whether any particular string is special, it asks *where in a real
/// connection the app would have flipped*, which is the thing that was wrong.
final class ConnectSignalsTests: XCTestCase {

    /// One real connection, in the order openconnect printed it.
    private let liveSequence = [
        "Please enter your username and password.",
        "PASSCODE:",
        "Password:",
        "Connected to HTTPS on vpn.example.com with ciphersuite (TLS1.2)-(ECDHE-X25519)-(RSA-SHA256)-(AES-256-GCM)",
        "Got CONNECT response: HTTP/1.1 200 OK",
        "CSTP connected. DPD 10, Keepalive 20",
        "DTLS handshake failed: Resource temporarily unavailable, try again.",
        "Configured as 198.18.5.44, with SSL connected and DTLS in progress",
        "route: writing to routing socket: File exists",
        "Got results: [<DNS IN A rdata: 198.18.5.44>]"
    ]

    /// The line the app is allowed to flip on, and it is not early in the list.
    private static let configuredLine = "Configured as 198.18.5.44, with SSL connected and DTLS in progress"

    // MARK: - The negotiation phase

    func testTheHTTPSHandshakeIsNotAnEstablishedTunnel() {
        XCTAssertFalse(ConnectSignals.isTunnelUp(in: "Got CONNECT response: HTTP/1.1 200 OK"),
                       "the gateway accepting the HTTPS CONNECT request is not a configured tunnel")
    }

    func testTheCSTPLineIsNotAnEstablishedTunnel() {
        XCTAssertFalse(ConnectSignals.isTunnelUp(in: "CSTP connected. DPD 10, Keepalive 20"),
                       "the CSTP session starting is not a configured tunnel")
    }

    /// Every line before the flip in the live run, one at a time.
    func testNothingFromTheNegotiationPhaseIsAccepted() {
        let before = liveSequence.prefix { $0 != Self.configuredLine }
        XCTAssertEqual(before.count, 7, "the fixture must keep every line that arrived before it")
        for line in before {
            XCTAssertFalse(ConnectSignals.isTunnelUp(in: line),
                           "\(line.debugDescription) arrived while openconnect was still negotiating")
        }
    }

    // MARK: - The tunnel itself

    func testTheConfiguredLineIsAnEstablishedTunnel() {
        XCTAssertTrue(ConnectSignals.isTunnelUp(in: Self.configuredLine),
                      "openconnect printed this after the routing script had run")
    }

    func testTheTunnelsOwnDataPathCounts() {
        XCTAssertTrue(ConnectSignals.isTunnelUp(in: "Established DTLS connection (using GnuTLS)."))
        XCTAssertTrue(ConnectSignals.isTunnelUp(in: "ESP session established with server 10.0.0.1:4500"))
    }

    // MARK: - The whole point

    /// Where in a real connection the app flips — and that it flips exactly once.
    func testTheLiveSequenceFlipsOnlyWhenTheRoutesAreConfigured() {
        let flips = liveSequence.filter { ConnectSignals.isTunnelUp(in: $0) }
        XCTAssertEqual(flips, [Self.configuredLine],
                       "a real connection must produce exactly one success signal, at the configured line")
    }

    /// A looser rule is how the defect happened: two lines of the negotiation
    /// phase were in the list. This asserts the list is made of the *up* lines
    /// and nothing else.
    func testTheAcceptedSetCarriesNoNegotiationLine() {
        XCTAssertEqual(ConnectSignals.tunnelIsUp.filter { $0.contains("CONNECT response") }, [])
        XCTAssertEqual(ConnectSignals.tunnelIsUp.filter { $0.contains("CSTP") }, [])
        XCTAssertEqual(ConnectSignals.tunnelIsUp.filter { $0.contains("Connected as") }, [],
                       "openconnect prints this one ahead of the routing script")
    }

    // MARK: - A tunnel that ended before it was ready

    /// The line a real failed connect ends with, from the live run that found
    /// this defect.
    private static let authenticationFailure = "Failed to complete authentication"

    /// On the agent path the exit status is 0 — the agent exits cleanly because
    /// the tunnel it supervised had already gone — so a message built from it
    /// says nothing. The tunnel's own last line is what names the cause.
    func testTheTunnelsLastLineNamesTheCause() {
        let diagnosis = ConnectSignals.diagnosisForTunnelEnding(
            lastLine: Self.authenticationFailure,
            terminationStatus: 0
        )
        XCTAssertEqual(diagnosis.status, ConnectSignals.tunnelEndedStatus)
        XCTAssertTrue(diagnosis.detail.contains(Self.authenticationFailure),
                      "the reason the tunnel gave is the whole value of this message: \(diagnosis.detail)")
        XCTAssertFalse(diagnosis.detail.contains("status: 0"),
                       "an exit status that means \"clean exit\" must not be what explains a failure")
    }

    /// With nothing to report, the exit status is all there is — and it must still
    /// be reported, because an attempt that fails silently becomes a history row
    /// that says "Connecting" for ever.
    func testWithNoLastLineTheExitStatusIsStillNamed() {
        let diagnosis = ConnectSignals.diagnosisForTunnelEnding(lastLine: "", terminationStatus: 1)
        XCTAssertEqual(diagnosis.status, "Connection failed (status: 1)")
        XCTAssertEqual(diagnosis.detail, "")
    }

    /// A status message is not a log dump: the line is bounded, and the whitespace
    /// openconnect leaves on it is not carried into the message.
    func testTheLineIsTrimmedAndBounded() {
        let diagnosis = ConnectSignals.diagnosisForTunnelEnding(
            lastLine: "\n  " + String(repeating: "x", count: 500) + "  \n",
            terminationStatus: 0,
            maximumLineBytes: 40
        )
        XCTAssertTrue(diagnosis.detail.contains(String(repeating: "x", count: 40)))
        XCTAssertFalse(diagnosis.detail.contains(String(repeating: "x", count: 41)),
                       "the line was not bounded")
        XCTAssertFalse(diagnosis.detail.contains("\n  x"), "the line kept the whitespace it arrived with")
    }
}
