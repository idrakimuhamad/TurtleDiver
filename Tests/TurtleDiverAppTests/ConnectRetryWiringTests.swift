import XCTest
@testable import TurtleDiverAppGlue

/// Pins the pair that made the "Reconnect" button do nothing.
///
/// `VPNStatus` and `VPNManager` live in `VPNConnect/`, which the SPM harness does
/// not compile, so these assertions are source scans: they pin *structure*. What
/// they can still prove is the thing that was wrong — that the set of statuses the
/// UI offers to connect from is the set the model accepts.
final class ConnectRetryWiringTests: XCTestCase {

    // MARK: - The model

    /// A failed connect is a state a retry is allowed to start from.
    ///
    /// The defect: `MainView.actionButtonText` returns "Reconnect" for `.error`
    /// and `actionButtonTapped` calls `vpn.connect()` there, but `connect()`
    /// opened with `guard case .disconnected = status else { return }`. From
    /// `.error` that returned silently — no log line, no history row, nothing on
    /// screen — so one failed connect wedged the app until it was quit and
    /// relaunched. The menu bar item had the same mismatch.
    func testTheConnectableStatusesIncludeTheFailedOne() throws {
        let manager = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertTrue(manager.contains("guard status.isConnectable else { return }"),
                      "connect() must accept every status the UI offers to connect from")
        XCTAssertFalse(manager.contains("guard case .disconnected = status"),
                       "the silent refusal that made \"Reconnect\" do nothing")

        let start = try XCTUnwrap(manager.range(of: "var isConnectable: Bool"))
        let body = manager[start.lowerBound...].prefix(240)
        XCTAssertTrue(body.contains("case .disconnected, .error: return true"),
                      "a failed attempt is a state a retry may start from")
        XCTAssertTrue(body.contains("case .connecting, .connected, .disconnecting: return false"),
                      "and it is the only extra one: the in-flight states must still refuse")
    }

    // MARK: - The two places that offer it

    /// The label, the tap and the menu item all agree about when a retry is on
    /// offer. A UI affordance backed by a guard mismatch is a defect, not a
    /// quirk, and it is invisible until someone presses it.
    func testTheUIOffersARetryExactlyWhereTheModelAcceptsOne() throws {
        let view = try strippedCode(at: "VPNConnect/MainView.swift")
        XCTAssertTrue(view.contains("case .error: return \"Reconnect\""),
                      "the action button still promises a retry in the error state")
        XCTAssertTrue(view.contains(".disabled(vpn.status == .disconnecting)"),
                      "only the in-flight state may be disabled: a failed connect has to be clickable")

        let tap = try XCTUnwrap(view.range(of: "private func actionButtonTapped()"))
        let body = view[tap.lowerBound...].prefix(1400)
        XCTAssertTrue(body.contains("case .disconnected, .error:"),
                      "the tappable branch must include the status the label offers")
        XCTAssertTrue(body.contains("vpn.connect()"), "…and must reach connect()")

        let appDelegate = try strippedCode(at: "VPNConnect/AppDelegate.swift")
        let toggle = try XCTUnwrap(appDelegate.range(of: "@objc private func toggleVPN()"))
        XCTAssertTrue(appDelegate[toggle.lowerBound...].prefix(600).contains("status.isConnectable"),
                      "the menu bar item must derive its offer from the same rule")
    }

    // MARK: - When a connect counts as connected

    /// The test for "the tunnel is up" has one home, and it is not a list inside
    /// the manager.
    ///
    /// The defect: `VPNManager` kept its own list of success lines and it accepted
    /// two that openconnect prints during negotiation, so the header read
    /// "Connected" and the action button offered "Disconnect" while the tunnel was
    /// still being set up. A list that sits next to the code acting on it is easy
    /// to widen; `ConnectSignals` decides, and `ConnectSignalsTests` replays a real
    /// connection against it.
    func testTheSuccessTestHasOneHome() throws {
        let manager = try strippedCode(at: "VPNConnect/VPNManager.swift")
        XCTAssertTrue(manager.contains("guard ConnectSignals.isTunnelUp(in: text) else { return }"),
                      "the manager must ask the classifier rather than decide for itself")
        XCTAssertFalse(manager.contains("Got CONNECT response"),
                       "the HTTPS handshake line must not come back as a success signal")
        XCTAssertFalse(manager.contains("CSTP connected"),
                       "nor the line openconnect prints as the session starts")
        XCTAssertFalse(manager.contains("successSignals"),
                       "and no second copy of the list may be kept here")

        let signals = try strippedCode(at: "VPNConnect/System/ConnectSignals.swift")
        XCTAssertTrue(signals.contains("static let tunnelIsUp"), "the list lives where it is decided")
        XCTAssertTrue(signals.contains("static func isTunnelUp(in text: String) -> Bool"),
                      "…behind one predicate")
    }

    /// Finding the process is not the same as finishing with it.
    ///
    /// The pid-file poller used to call the connection established the moment it
    /// saw a live openconnect. With a routing script in play that is fourteen
    /// seconds early (measured on this machine), and it is the one flip
    /// `ConnectSignals` cannot correct afterwards: the app would say Connected
    /// while the tunnel is not yet usable.
    func testThePidFilePollerDoesNotCallTheTunnelConnectedWhileTheScriptRuns() throws {
        let manager = try strippedCode(at: "VPNConnect/VPNManager.swift")

        let call = try XCTUnwrap(manager.range(of: "startConnectionPollingTimer(log: log, gen: gen"),
                                  "the poller must be told what this connect is waiting for")
        XCTAssertTrue(manager[call.lowerBound...].contains("waitsForRoutingScript: withTunneling"),
                      "…and what it waits for is the routing script this connect runs")

        let poller = try XCTUnwrap(manager.range(
            of: "func startConnectionPollingTimer(log: VpnConnectionLogger, gen: UInt64, waitsForRoutingScript: Bool)"),
            "the poller keeps its own declaration")
        let body = manager[poller.upperBound...]
        let guarded = try XCTUnwrap(body.range(of: "guard !waitsForRoutingScript else {"),
                                    "with a script the poller must hand the verdict to the classifier")
        let flip = try XCTUnwrap(body.range(of: "self.status = .connected"),
                                 "without one it still flips here, exactly as it always did")
        XCTAssertTrue(guarded.lowerBound < flip.lowerBound,
                      "the guard comes first, or a live pid alone still means connected")
        XCTAssertFalse(body[guarded.upperBound..<flip.lowerBound].contains("cancelConnectionTimer()"),
                       "and the connect timeout stays armed, so a script that never returns fails loudly")
    }

    /// A connect that ends by itself has to say why.
    ///
    /// The defect, from a live run: openconnect failed at the HTTPS stage and
    /// exited, and nothing reported it — the agent's reading thread was blocked on
    /// the channel — so the app sat on "Connecting" until its own 90 s timeout,
    /// which then blamed the clock rather than the tunnel. The exit status cannot
    /// carry the reason on the agent path, because the agent exits `0` once its
    /// tunnel is gone, so the manager keeps the tunnel's own last line and asks
    /// `ConnectSignals` what to say about it.
    func testAFailedConnectIsNamedFromTheTunnelsOwnLastLine() throws {
        let manager = try strippedCode(at: "VPNConnect/VPNManager.swift")

        let note = try XCTUnwrap(manager.range(of: "func noteTunnelSignals"),
                                 "the one function both handlers call is where the line is seen")
        let body = manager[note.upperBound...]
        let record = try XCTUnwrap(body.range(of: "lastTunnelLine = text"),
                                   "the last line the tunnel logged has to be kept")
        let successTest = try XCTUnwrap(body.range(
            of: "guard ConnectSignals.isTunnelUp(in: text) else { return }"),
            "the classifier is still the only success test")
        XCTAssertTrue(body[body.startIndex..<record.lowerBound].contains("source == \"STDERR\""),
                      "kept from the tunnel's own log, not from the agent's protocol words: `done` names nothing")
        XCTAssertTrue(record.lowerBound < successTest.lowerBound,
                      "the record comes first, or the only lines ever kept are the ones that succeed — "
                      + "and a failure is exactly a line that does not")

        let termination = try XCTUnwrap(manager.range(of: "proc.terminationHandler"))
        let handler = manager[termination.lowerBound...]
        let diagnosis = try XCTUnwrap(handler.range(of: "ConnectSignals.diagnosisForTunnelEnding("),
                                      "a failed connect must be given a name, not a bare exit status")
        let ask = handler[diagnosis.lowerBound...]
        XCTAssertTrue(ask.prefix(200).contains("lastLine: self.lastTunnelLine"),
                      "…built from the line the manager kept")
        XCTAssertTrue(ask.prefix(600).contains("self.logFailedAttempt(status: diagnosis.status)"),
                      "and the attempt is recorded either way: an unrecorded failure is how a history "
                      + "ends up full of rows that say Connecting")
    }

    /// The agent reports its own child dying, and the app must not depend on an
    /// agent being current: the in-app updater ships a `.dmg`, which carries the
    /// app and not the agent. So the same fact is also watched from here — the
    /// tunnel pid this attempt saw alive, checked by name while still connecting.
    func testAConnectThatLosesItsTunnelSaysSoWithoutWaitingForTheClock() throws {
        let manager = try strippedCode(at: "VPNConnect/VPNManager.swift")

        let start = try XCTUnwrap(manager.range(of: "func startTunnelWatchdog"),
                                  "nothing watches the tunnel the connect launched")
        let rest = manager[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    private func "),
                                "the watchdog's body has to end where the next function starts")
        let watch = rest[rest.startIndex..<end.lowerBound]

        // Started where the attempt is still open, not somewhere a failure cannot
        // reach: beside the connect timer.
        let timer = try XCTUnwrap(manager.range(of: "startConnectionTimer(timeoutSeconds:"))
        XCTAssertTrue(manager[timer.lowerBound...].prefix(300).contains("self.startTunnelWatchdog(log: log, gen: gen)"),
                      "the watch belongs to the attempt that just started")

        // A recorded pid is one this attempt *saw alive*. An empty record is not
        // evidence that anything died — the poller may not have found the tunnel
        // yet, and a pid file can be left over from someone else's connection.
        XCTAssertTrue(watch.contains("guard let pid = self.launchedTunnelPid else { return }"),
                      "the watch has nothing to say until it has seen the tunnel")
        XCTAssertTrue(watch.contains("OpenConnectProcess.isOpenConnect(pid: pid)"),
                      "by name — a died tunnel can still be a zombie, which answers kill(pid, 0) as alive")
        XCTAssertFalse(watch.contains("isRunning(pid:"),
                       "a zombie's parent that has not reaped it makes isRunning say alive")
        XCTAssertTrue(watch.contains("repeating: 3.0"),
                      "a check that runs once is a check a tunnel can die after")

        // The same name for the failure the agent path gives it, from the same line.
        XCTAssertTrue(watch.contains("ConnectSignals.diagnosisForTunnelEnding("),
                      "a lost tunnel is named, not reported as a bare exit status")
        XCTAssertTrue(watch.contains("lastLine: self.lastTunnelLine"),
                      "…from the tunnel's own last line, which failure lines also reach")
        XCTAssertTrue(watch.contains("self.logFailedAttempt(status: diagnosis.status)"),
                      "and the attempt is recorded: an unrecorded failure is a history that explains nothing")
        XCTAssertTrue(watch.contains("self.forceTerminate()"),
                      "the agent and its sudo are still there, supervising a tunnel that is gone")
        XCTAssertTrue(watch.contains("case .connecting = self.status"),
                      "never after a success: a connected tunnel's pid ending is the disconnect's business")

        // And the attempt's record of the pid is what the watch reads.
        let record = try XCTUnwrap(manager.range(of: "func recordOwnTunnelPid"),
                                   "a pid is only ever recorded after its name was verified")
        XCTAssertTrue(manager[record.upperBound...].prefix(900).contains("launchedTunnelPid = pid"),
                      "the watch has to be told the pid the attempt verified")

        // Every ending already goes through here, so the watch is cancelled here.
        let cancel = try XCTUnwrap(manager.range(of: "private func cancelConnectionTimer()"))
        XCTAssertTrue(manager[cancel.upperBound...].prefix(400).contains("tunnelWatchdogTimer?.cancel()"),
                      "an attempt that is over has nothing left to report")
    }

    // MARK: - Helpers

    private func strippedCode(at path: String) throws -> String {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
