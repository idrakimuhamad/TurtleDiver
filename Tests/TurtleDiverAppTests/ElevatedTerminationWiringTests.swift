import XCTest
@testable import TurtleDiverAppGlue
@testable import TurtleDiverSystem

/// The wiring for ending a tunnel that root owns.
///
/// The decision table is pinned in `ElevatedTerminationTests`; these pin the
/// call sites in `VPNManager`, because that is where the observable defect was:
/// a Disconnect that raised a signal the kernel refused, reported "Disconnected"
/// regardless, and left a root-owned `openconnect` holding the tunnel — and a
/// quit that could not end it either.
///
/// Every assertion is a source scan against the *branch* it is about: the method
/// contains several discards and several status writes, and an assertion over
/// the whole body would pass for the wrong reason.
final class ElevatedTerminationWiringTests: XCTestCase {

    // MARK: - The signal is elevated, and asked for in one place

    /// A root-owned process refuses both signals from this user, so the owner is
    /// read *before* anything is sent — not inferred from a `kill` that was
    /// never going to land.
    func testTheOwnerIsReadBeforeAnythingIsSignalled() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let body = try body(of: "private func terminateGracefully(", in: code)
        XCTAssertLessThan(body.count, 4_000, "the body looks unbounded: \(body.count) characters")

        let owner = try XCTUnwrap(body.range(of: "ProcessOwner.belongsToAnotherUser(pid)"))
        let signal = try XCTUnwrap(body.range(of: "_ = kill(pid, SIGTERM)"))
        XCTAssertLessThan(owner.lowerBound, signal.lowerBound,
                          "the owner must be read before a signal that is certain to be refused")

        // And the owner check must come *after* the verification, so a pid that
        // is not an openconnect is never even looked up.
        let verify = try XCTUnwrap(body.range(of: "guard OpenConnectProcess.isOpenConnect(pid: pid)"))
        XCTAssertLessThan(verify.lowerBound, owner.lowerBound)
    }

    /// One function raises the signal, and it is the one that verifies. The
    /// elevation hangs off that function rather than off each caller, which is
    /// what makes all four call sites safe at once.
    func testTheElevationIsReachedOnlyThroughTheVerifyingTerminator() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let calls = code.components(separatedBy: "terminateWithElevation(pid: pid,").count - 1
        let body = try body(of: "private func terminateGracefully(", in: code)
        XCTAssertEqual(body.components(separatedBy: "terminateWithElevation(pid: pid,").count - 1, calls,
                       "every elevated signal must come from the function that verified the pid first")
        XCTAssertGreaterThanOrEqual(calls, 2, "expected a path for a known root owner and one for a refused signal")
    }

    /// `mayPrompt` decides whether a system dialog may appear, and the quit path
    /// may not have one: a dialog nothing answers is what leaves a blocked root
    /// `sudo` behind. There is no default, so a new call site cannot inherit the
    /// prompting answer by accident.
    func testEveryCallSiteSaysWhetherADialogIsAllowed() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")

        XCTAssertFalse(code.contains("mayPrompt: Bool = "),
                       "a default would let a caller silently mean `you may ask`")
        let calls = code.components(separatedBy: "terminateGracefully(pid: pid").count - 1
        let explicit = code.components(separatedBy: "terminateGracefully(pid: pid,").count - 1
        XCTAssertEqual(calls, explicit, "every call must pass its own mayPrompt")

        // The two paths a person is present for may raise a dialog. `disconnect()`
        // delegates to `performTunnelShutdown`, which is where the switch lives.
        for function in ["private func performTunnelShutdown(", "private func terminateExistingOpenConnect() async"] {
            let body = try body(of: function, in: code)
            XCTAssertTrue(body.contains("mayPrompt: true"), "\(function) is answered by a person, so it may ask")
            XCTAssertFalse(body.contains("mayPrompt: false"), "\(function) may ask: a refusal here is user-visible")
        }

        // The two paths where nobody is there to answer may not.
        for function in ["func cleanupOnTermination()", "private func forceTerminate()"] {
            let body = try body(of: function, in: code)
            XCTAssertTrue(body.contains("mayPrompt: false"),
                          "\(function) must not put a dialog in front of a quit that cannot wait for it")
            XCTAssertFalse(body.contains("mayPrompt: true"), "\(function) must never raise a dialog")
        }
    }

    /// The launch sweep deliberately leaves a group that still holds an
    /// openconnect, so it was never the thing that ended one of those tunnels.
    /// Nothing may claim otherwise.
    func testTheLaunchSweepIsNotClaimedAsTheThingThatEndsARootTunnel() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let body = try body(of: "func cleanupOnTermination()", in: code)

        XCTAssertFalse(code.contains("reaps the process group the connect recorded, which is what ends"),
                       "the sweep leaves a live tunnel's group alone; the comment that said otherwise was false")
        XCTAssertTrue(body.contains("leaving the process-group record"),
                      "the quit must say what it left behind and why")
    }

    // MARK: - A failed disconnect is reported as one

    /// The bug the user hit. `status = .disconnected` was written unconditionally
    /// after a signal the kernel had refused, so a live tunnel was reported as a
    /// finished one, both on screen and in the history.
    func testDisconnectOnlyClaimsSuccessWhenTheTunnelIsGone() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        // The teardown lives in the function both entry points share; `disconnect()`
        // itself is only the status flip and the resolve-then-teardown hop.
        let body = try body(of: "private func performTunnelShutdown(", in: code)
        XCTAssertLessThan(body.count, 8_000, "the body looks unbounded: \(body.count) characters")

        let refused = try branch(".notPermitted", in: body)
        XCTAssertTrue(refused.contains("tunnelEnded = false"),
                      "a refused signal has to be recorded, because everything below reads it")
        XCTAssertFalse(refused.contains("OpenConnectPidFile.discard()"),
                       "the record is the only handle on a live tunnel, so it must survive a failed disconnect")

        // Both the status and the history row come after the attempt, and both
        // are conditional on it.
        let switchRange = try XCTUnwrap(body.range(of: "switch terminateGracefully(pid: pid, mayPrompt: true)"))
        let statusRange = try XCTUnwrap(body.range(of: "if tunnelEnded {\n            status = .disconnected"))
        let historyRange = try XCTUnwrap(body.range(of: "status: tunnelEnded ? \"Disconnected\" : \"Failed - Still Connected\""))
        XCTAssertLessThan(switchRange.lowerBound, statusRange.lowerBound)
        XCTAssertLessThan(switchRange.lowerBound, historyRange.lowerBound)
        XCTAssertLessThan(historyRange.lowerBound, statusRange.lowerBound,
                          "the history row is written before the screen, so a crash between them costs the row not the truth")

        // `.error` is the wrong answer for a live tunnel: it renames the hero
        // button "Reconnect" and invites a second tunnel on top of this one.
        XCTAssertFalse(body.contains("status = .error"), "a surviving tunnel is still connected, not an error")
        XCTAssertTrue(body.contains("status = .connected"),
                      "the honest state for a tunnel that is still up is `.connected`")

        // And the record is only cleared on the branch that ended something.
        let ended = try branch(".endedWithElevation", in: body)
        XCTAssertTrue(ended.contains("OpenConnectPidFile.discard()"))
        let clearedFile = try XCTUnwrap(body.range(of: "if tunnelEnded {\n            OpenConnectPidFile.discard()"))
        XCTAssertLessThan(switchRange.lowerBound, clearedFile.lowerBound)
    }

    /// The quit path cannot fix a root-owned tunnel, and that is a documented
    /// outcome rather than a silent one — the record has to stay so the next
    /// Disconnect (or connect) can still end it.
    func testTheQuitLeavesTheHandleItCouldNotUse() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let body = try body(of: "func cleanupOnTermination()", in: code)

        let refused = try branch(".notPermitted", in: body)
        XCTAssertFalse(refused.contains("OpenConnectPidFile.discard()"),
                       "discarding the record on quit is what let a live tunnel be forgotten")
        XCTAssertTrue(refused.contains("root-owned"), "the quit must name what it could not end")

        // The elevation the quit *may* use still gets its turn: `sudo -n` and a
        // stored password are both silent, so they are allowed here — and when
        // one of them did end it, the record goes.
        let ended = try branch(".endedWithElevation", in: body)
        XCTAssertTrue(ended.contains("OpenConnectPidFile.discard()"))
    }

    /// Every call site has to handle the outcome that means "elevation ended it",
    /// exactly as it handles the two user-signalled outcomes.
    func testEveryCallSiteHandlesTheElevatedOutcome() throws {
        let code = try strippedCode(at: "VPNConnect/VPNManager.swift")
        let branches = code.components(separatedBy: "case .endedWithElevation").count - 1
        XCTAssertEqual(branches, 4, "expected disconnect, quit, pre-connect cleanup and force-terminate")

        let existing = try strippedCode(at: "VPNConnect/System/ExistingConnection.swift")
        XCTAssertTrue(existing.contains("case endedWithElevation"),
                      "the outcome has to be part of the type, or a caller can forget it")
        // The doc comment is read unstripped, because that is where a case's
        // meaning is written down: the record is a handle, not the ender.
        let existingDoc = try rawText(at: "VPNConnect/System/ExistingConnection.swift")
        XCTAssertTrue(existingDoc.contains("not the thing that ends it"),
                      "say at the declaration that the group record is a handle, not the ender")
    }

    // MARK: - One owner for the quit

    /// `applicationWillTerminate` owns the quit-time teardown, and `quitApp()` does
    /// not get a second one. It used to call `disconnect()` first, which duplicated
    /// the work when that call was synchronous and blocking; now that a disconnect
    /// resolves asynchronously it would race the terminate instead. What the quit
    /// needs — bounded, prompt-free, synchronous — is what
    /// `cleanupOnTermination()` already is.
    func testTheQuitDoesNotStartASecondTearDown() throws {
        let code = try strippedCode(at: "VPNConnect/AppDelegate.swift")
        let start = try XCTUnwrap(code.range(of: "@objc private func quitApp()"))
        let end = try XCTUnwrap(code.range(of: "@objc private func toggleEngine",
                                           range: start.upperBound..<code.endIndex))
        let quit = code[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(quit.contains("NSApp.terminate(nil)"),
                      "the quit is still the ordinary AppKit terminate")
        XCTAssertFalse(quit.contains("disconnect()"),
                       "and it must not start a teardown of its own")

        let willTerminate = try body(of: "func applicationWillTerminate", in: code)
        XCTAssertTrue(willTerminate.contains("cleanupOnTermination()"),
                      "the documented owner is what has to do it")
    }

    // MARK: - Helpers

    /// The statements of one `case` in a switch, from its label to the next one.
    private func branch(_ label: String, in body: Substring) throws -> Substring {
        let start = try XCTUnwrap(body.range(of: "case \(label)"), "\(label) not found")
        let rest = body[start.upperBound...]
        guard let end = rest.range(of: "\n            case ") ?? rest.range(of: "\n            }") else { return rest }
        return rest[..<end.lowerBound]
    }

    /// The text of one function, from its declaration to the next declaration at
    /// the same indentation — the nearest one, so a `private func` inside the
    /// slice cannot make an assertion pass for the wrong reason.
    private func body(of function: String, in code: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: function), "\(function) not found")
        let rest = code[start.upperBound...]
        let anchors = ["\n    func ", "\n    private func ", "\n    static func ", "\n    public func ", "\n    @objc func "]
        let ends = anchors.compactMap { rest.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return rest }
        return rest[..<end]
    }

    private func strippedCode(at path: String) throws -> String {
        let text = try rawText(at: path)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The file as written, comments included — for assertions *about* the prose.
    private func rawText(at path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
