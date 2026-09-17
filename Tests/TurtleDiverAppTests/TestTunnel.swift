import Combine
import Foundation
@testable import TurtleDiverAppGlue

/// A tunnel that does not exist, for tests that build an `EngineController`.
///
/// Injecting this is what keeps a test process away from `VPNManager.shared`:
/// creating that singleton performs the launch-time adoption of a tunnel the app
/// did not start, so a test used to adopt the *machine's* own openconnect, write
/// the user's pid file, and take a different rule-set path depending on what
/// happened to be running.
final class StubTunnelStatus: TunnelStatusSource {

    private let changes = PassthroughSubject<VPNStatus, Never>()

    /// Lines the controller asked to have logged, so a test can assert on the
    /// diagnostic it produced without touching the real manager's output.
    private(set) var logged: [String] = []

    /// What `status` answers until `set(_:)` says otherwise.
    var current: VPNStatus = .disconnected

    var status: VPNStatus { current }

    var statusChanges: AnyPublisher<VPNStatus, Never> { changes.eraseToAnyPublisher() }

    func log(_ line: String) { logged.append(line) }

    /// Moves the tunnel to `status` and publishes it, the way the real manager
    /// does — both halves, because a caller may read either.
    func set(_ status: VPNStatus) {
        current = status
        changes.send(status)
    }
}
