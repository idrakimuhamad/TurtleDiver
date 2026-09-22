import XCTest

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// The installer, the package and the app have to agree about one string.
///
/// `TunnelAgent.installedPath` is where the app looks. `packaging/install-agent.sh`
/// and `publish.sh` are what put something there. If those drift, the app
/// concludes the agent is not installed and quietly does what it does today —
/// no error, no crash, just a feature that stops working, and nothing else in
/// the suite or in a live run would say a word about it. That silence is why
/// this file exists.
///
/// It reads files, so it is a structure test, not a behaviour test. What it
/// pins is that four places still spell the same path.
final class TunnelAgentInstallerTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - The path itself

    func testTheInstalledPathIsAbsoluteAndOutsideEveryWritablePlace() {
        let path = TunnelAgent.installedPath

        XCTAssertTrue(path.hasPrefix("/"), "the agent path is not absolute")
        XCTAssertEqual(path, TunnelAgent.installDirectory + "/" + TunnelAgent.executableName)
        XCTAssertFalse(path.hasSuffix("/"), "a trailing slash would make two paths that differ")
        XCTAssertFalse(path.contains(".."), "the path walks somewhere else")

        // The whole point of the location: the user who installed the app can
        // rewrite anything under their home, and almost anything in /Applications.
        XCTAssertFalse(path.hasPrefix("/Users/"), "the agent would live in a user's home")
        XCTAssertFalse(path.hasPrefix("/Applications/"), "the agent would live in the app's own directory")
        XCTAssertFalse(path.contains(".app/"), "the agent would live inside a bundle")
        XCTAssertFalse(path.hasPrefix("/tmp/"), "the agent would live in a world-writable directory")

        // The executable name is also what the app looks for, and what a
        // process's `comm` would read as. Two names, one string.
        XCTAssertEqual((path as NSString).lastPathComponent, TunnelAgent.executableName)
        XCTAssertTrue(TunnelAgent.mayStart(command: path + "-not-an-openconnect") == false,
                      "the agent's own path must not pass the rule for starting a tunnel")
    }

    // MARK: - The two files that install it

    func testTheInstallScriptsAgreeWithTheProtocol() throws {
        let script = try source("packaging/install-agent.sh")

        XCTAssertTrue(script.contains("INSTALL_DIR=\"\(TunnelAgent.installDirectory)\""),
                      "install-agent.sh installs the agent somewhere else")
        XCTAssertTrue(script.contains("INSTALL_NAME=\"\(TunnelAgent.executableName)\""),
                      "install-agent.sh installs the agent under another name")
        XCTAssertTrue(script.contains("TEAM_ID=\"\(AppIdentity.updateTeamIdentifier)\""),
                      "install-agent.sh does not check the team the app will check")
        // The verification is the only reason the location is safe to exec from.
        XCTAssertTrue(script.contains("codesign --verify --strict \"$INSTALLED\""))
    }

    /// The signature's name has to be the installed name, not the build product's.
    ///
    /// The app asks the signature what file it is (`Identifier`), and compares the
    /// answer with `TunnelAgent.executableName`. `codesign` names a bare binary
    /// after the file it was handed — the SwiftPM product, `TurtleDiverAgent` — so
    /// without this flag the app refuses the agent that was just installed, and
    /// the teardown silently goes back to prompting. Measured on this machine
    /// before the flag was added: `Identifier=TurtleDiverAgent`.
    func testTheInstallersSignTheAgentUnderItsInstalledName() throws {
        let installer = try source("packaging/install-agent.sh")
        XCTAssertTrue(installer.contains("--sign \"$candidate\" --identifier \"$INSTALL_NAME\""),
                      "the installed agent's signature would be named after the build product")
        XCTAssertTrue(installer.contains("signature_field \"$BIN\" Identifier"),
                      "the installer never reads back the name it signed under")
        XCTAssertTrue(installer.contains("signature_field \"$INSTALLED\" Identifier"),
                      "what was installed is not checked for the name the app looks for")

        let publisher = try source("publish.sh")
        XCTAssertTrue(publisher.contains("--sign \"$SIGN_ID\" --identifier \"$AGENT_INSTALL_NAME\""),
                      "the packaged agent's signature would be named after the build product")
        XCTAssertTrue(publisher.contains("sed -n 's/^Identifier=//p'"),
                      "the package is never checked for the name the app looks for")
    }

    func testThePackageAgreesWithTheProtocol() throws {
        let script = try source("publish.sh")

        // A package payload is relative to the install root, which is `/`, so the
        // same directory is written there without its leading slash. That is the
        // one place the two spellings differ, and it is the place worth asserting
        // precisely rather than loosely.
        let payloadDirectory = String(TunnelAgent.installDirectory.dropFirst())
        XCTAssertTrue(script.contains("AGENT_INSTALL_DIR=\"\(payloadDirectory)\""),
                      "publish.sh stages the agent in a different directory")
        XCTAssertTrue(script.contains("AGENT_INSTALL_NAME=\"\(TunnelAgent.executableName)\""),
                      "publish.sh stages the agent under another name")
        XCTAssertTrue(script.contains("\"$pkgroot/$AGENT_INSTALL_DIR/$AGENT_INSTALL_NAME\""),
                      "publish.sh never puts the agent into the package payload")
        XCTAssertTrue(script.contains("codesign --verify --strict \"$agent_installed\""),
                      "the package is never checked to contain a working agent")
    }

    func testEveryInstalledNameInTheRepositoryAgrees() throws {
        // A search rather than a list of files, so a third installer added later
        // cannot quietly disagree. The name is distinctive enough that anything
        // containing it is talking about this same file.
        let name = TunnelAgent.executableName
        var mentions: [String] = []

        let walker = FileManager.default.enumerator(
            at: repoRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        let skipped: Set<String> = [".git", ".build", "build", "dist", "DerivedData", "xcuserdata", "screenshots"]
        while let url = walker?.nextObject() as? URL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skipped.contains(url.lastPathComponent) { walker?.skipDescendants() }
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            guard text.contains(name) else { continue }
            let relative = url.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            mentions.append(relative)
        }

        // The constant, the two installers, the package, and the document that
        // tells a user where it went. Every one of them is about the same file,
        // and each is read by a test above or beside this one.
        XCTAssertTrue(mentions.contains("VPNConnect/System/TunnelAgentProtocol.swift"), "\(mentions)")
        XCTAssertTrue(mentions.contains("packaging/install-agent.sh"), "\(mentions)")
        XCTAssertTrue(mentions.contains("publish.sh"), "\(mentions)")
        XCTAssertTrue(mentions.contains("packaging/README_INSTALL.txt"), "\(mentions)")
    }
}
