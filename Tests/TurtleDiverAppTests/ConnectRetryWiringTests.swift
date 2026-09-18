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
