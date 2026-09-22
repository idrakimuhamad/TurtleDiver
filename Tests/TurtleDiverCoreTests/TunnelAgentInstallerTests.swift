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

    /// Root cannot sign for the app's team, however good the certificate is.
    ///
    /// `codesign` looks in the keychain of the user it runs as, and the private
    /// key it needs belongs to the person who installed Xcode. Run under `sudo`,
    /// every candidate identity fails, and the script used to report that as a
    /// certificate that is not in this keychain — which is a wrong diagnosis of a
    /// mistake the script can see before it starts. Measured: that is exactly what
    /// happened when `sudo packaging/install-agent.sh` was typed by hand.
    func testTheInstallerRefusesToRunAsRoot() throws {
        let script = try source("packaging/install-agent.sh")
        XCTAssertTrue(script.contains("if [ \"$(id -u)\" = 0 ]"),
                      "nothing stops the installer being run with sudo")
        XCTAssertTrue(script.contains("run this as yourself, without sudo"),
                      "the refusal has to say what to type instead")
        // Removing the agent needs root and signs nothing, so it stays allowed.
        XCTAssertTrue(script.contains("[ \"$DO_UNINSTALL\" != 1 ]"),
                      "a root uninstall is harmless and must keep working")
        // And the step that does need root asks for it itself.
        XCTAssertTrue(script.contains("sudo install -o root -g wheel -m 0755 \"$BIN\""),
                      "the install step has to elevate by itself")
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

    /// The inspection has to look at the *expanded* package, and it throws that
    /// expansion away when it is done with it.
    ///
    /// It used to throw it away first, so the agent check searched a directory
    /// that no longer existed, found nothing, and refused a package that was in
    /// fact correct — verified by expanding the payload by hand, which does
    /// contain the agent at its installed path, and watching the check say it
    /// did not. A verification that cannot pass is worse than none: it reads as
    /// "the package is wrong", and it stops every release at the last step.
    /// Nothing caught it because nothing tested this function.
    func testThePackageIsLookedIntoBeforeTheExpansionIsThrownAway() throws {
        let script = try source("publish.sh")
        let start = try XCTUnwrap(script.range(of: "verify_pkg() {"),
                                  "publish.sh no longer inspects the package it just built")
        let rest = script[start.lowerBound...]
        let end = try XCTUnwrap(rest.range(of: "\n}"),
                                "verify_pkg has no end, so this test cannot see its body")
        let body = String(rest[..<end.lowerBound])

        // Anchored on the agent check itself, not on the first `find "$expand"`
        // in the function — that one is the *app* payload check, and a loose
        // anchor there would let the deletion sit between the two and still
        // read as an ordering this test is happy with.
        let agentCheck = try XCTUnwrap(body.range(of: "agent_installed=\"$(find \"$expand\""),
                                       "verify_pkg no longer searches the expanded package for the agent")
        XCTAssertTrue(body.contains("$AGENT_INSTALL_NAME"),
                      "verify_pkg does not look for the agent by the name the app looks for")

        // Clearing an earlier expansion *before* making one is fine; deleting the
        // one the checks are reading is not. So the question is only what
        // happens after `pkgutil --expand-full`.
        let expanded = try XCTUnwrap(body.range(of: "pkgutil --expand-full"),
                                     "verify_pkg no longer expands the package it is inspecting")
        let thrownAway = body.range(of: "rm -rf \"$expand\"",
                                    range: expanded.upperBound..<body.endIndex)
        if let thrownAway {
            XCTAssertTrue(thrownAway.lowerBound > agentCheck.upperBound,
                          "publish.sh throws the expanded package away after expanding it and before it "
                          + "looks for the agent, so the agent check can only ever find nothing and every "
                          + "package is refused")
        }

        let refusal = try XCTUnwrap(body.range(of: "die \"the installer package did not pass verification\""),
                                    "verify_pkg no longer refuses a package it cannot verify")
        XCTAssertTrue(refusal.lowerBound > agentCheck.upperBound,
                      "the package is refused before the agent is looked for, which is not a check")
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
