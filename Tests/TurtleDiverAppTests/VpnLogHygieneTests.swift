import XCTest
@testable import TurtleDiverAppGlue

/// Tests for where the VPN connection log lives and who can read it.
///
/// The log holds the redacted credential lines plus raw openconnect output, and
/// it used to be `/tmp/turtlediver-vpn.log`: a predictable name in a
/// world-writable directory, created with default (world-readable) permissions.
final class VpnLogHygieneTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vpnlog-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheDefaultLogPathIsUnderLibraryLogs() {
        let path = VpnConnectionLogger.logPath

        XCTAssertTrue(path.hasSuffix("/Library/Logs/TurtleDiver/vpn.log"), path)
        XCTAssertFalse(path.hasPrefix("/tmp/"), "a predictable /tmp name is world-writable")
        XCTAssertEqual(VpnConnectionLogger.logPath, path, "the path is stable")
    }

    func testTheLogFileIsCreatedWithOwnerOnlyPermissions() throws {
        let path = directory.appendingPathComponent("nested/vpn.log").path

        let logger = VpnConnectionLogger(path: path)
        try withExtendedLifetime(logger) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
            XCTAssertEqual(mode & 0o777, 0o600, "expected 0600, got \(String(mode & 0o777, radix: 8))")
        }
    }

    func testCreatingTheLogCreatesItsDirectory() throws {
        let path = directory.appendingPathComponent("a/b/vpn.log").path

        let logger = VpnConnectionLogger(path: path)
        try withExtendedLifetime(logger) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }
    }

    func testAnExistingWorldReadableLogIsTightenedOnTheNextConnect() throws {
        let path = directory.appendingPathComponent("vpn.log").path
        FileManager.default.createFile(atPath: path, contents: nil,
                                       attributes: [.posixPermissions: 0o644])

        let logger = VpnConnectionLogger(path: path)
        try withExtendedLifetime(logger) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
            XCTAssertEqual(mode & 0o777, 0o600,
                           "an older build's world-readable log must be fixed, not inherited")
        }
    }

    /// The credentials must never reach the log in the clear — only a bullet
    /// count. (`logSend` is what VPNManager calls for each secret.)
    func testCredentialsAreRedactedToTheirLength() throws {
        let path = directory.appendingPathComponent("vpn.log").path
        let logger = VpnConnectionLogger(path: path)

        try withExtendedLifetime(logger) {
            logger.logSend("Admin password (for sudo)", value: "swordfish")
            logger.logSend("PIN (passcode+tokencode)", value: "123456")
            logger.logSend("VPN password", value: nil)
            logger.flush()

            let text = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertFalse(text.contains("swordfish"))
            XCTAssertFalse(text.contains("123456"))
            XCTAssertTrue(text.contains("[SEND] Admin password (for sudo): ••••••••• (9 chars)"))
            XCTAssertTrue(text.contains("[SEND] PIN (passcode+tokencode): •••••• (6 chars)"))
        }
    }
}
