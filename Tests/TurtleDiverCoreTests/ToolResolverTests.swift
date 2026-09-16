import XCTest
@testable import TurtleDiverSystem

/// The requirement table: what the app shells out to, and what it promises the
/// Setup pane can say about each one.
final class ToolRequirementTests: XCTestCase {

    func testEveryRequirementHasAUniqueIdentifier() {
        let ids = ToolRequirement.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate tool id: \(ids)")
    }

    func testTheTableCoversExactlyWhatTheAppShellsOutTo() {
        XCTAssertEqual(ToolRequirement.all.map(\.id), ["brew", "openconnect", "stoken", "vpn-slice"])
    }

    /// Homebrew is the installer; it cannot install itself, and the pane must
    /// say "install it from brew.sh" rather than offering a button that would
    /// run `brew install brew`.
    func testOnlyHomebrewCannotBeInstalledByHomebrew() {
        XCTAssertNil(ToolRequirement.homebrew.formula)
        XCTAssertEqual(ToolRequirement.installable.map(\.id), ["openconnect", "stoken", "vpn-slice"])
        for requirement in ToolRequirement.installable {
            XCTAssertEqual(requirement.formula, requirement.id,
                           "the formula and the binary are named the same for \(requirement.id)")
        }
    }

    /// Row captions, so they are sentences — but they have to fit on one line
    /// next to a path and a version pill.
    func testConsequencesAreOneTerseLine() {
        for requirement in ToolRequirement.all {
            XCTAssertFalse(requirement.consequence.isEmpty, requirement.id)
            XCTAssertFalse(requirement.consequence.contains("\n"), requirement.id)
            XCTAssertLessThanOrEqual(requirement.consequence.count, 90,
                                     "\(requirement.id) consequence is too long for a row caption")
        }
    }

    /// A missing `vpn-slice` only costs split tunneling; saying otherwise would
    /// be a lie the pane repeats.
    func testTheSplitTunnelToolIsTheOnlyOptionalOne() {
        XCTAssertTrue(ToolRequirement.vpnSlice.consequence.lowercased().contains("split tunneling"))
        XCTAssertTrue(ToolRequirement.openconnect.consequence.lowercased().contains("tunnel itself"))
        XCTAssertTrue(ToolRequirement.stoken.consequence.lowercased().contains("pin"))
    }

    func testDocumentationLinksAreHTTPS() {
        for requirement in ToolRequirement.all {
            XCTAssertTrue(requirement.documentationURL.hasPrefix("https://"),
                          "\(requirement.id) links to \(requirement.documentationURL)")
        }
        XCTAssertEqual(ToolRequirement.homebrew.documentationURL, "https://brew.sh")
    }

    func testVersionArgumentsAreJustVersionArguments() {
        for requirement in ToolRequirement.all {
            XCTAssertEqual(requirement.versionArguments, ["--version"], requirement.id)
        }
    }

    func testLookupByNameFindsEachRequirement() {
        for requirement in ToolRequirement.all {
            XCTAssertEqual(ToolRequirement.named(requirement.id), requirement)
        }
        XCTAssertNil(ToolRequirement.named("curl"))
    }
}

/// Resolution: where the app looks for a tool, and in what order.
final class ToolResolverTests: XCTestCase {

    /// A fake filesystem: only the listed paths exist and are executable.
    private func files(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    func testFindsAToolInTheFirstDirectoryThatHasIt() {
        let found = ToolResolver.path(for: "openconnect",
                                      searchPath: ["/a", "/b"],
                                      isExecutable: files(["/a/openconnect", "/b/openconnect"]))
        XCTAssertEqual(found, "/a/openconnect")
    }

    func testAToolThatIsNotThereIsNotFound() {
        XCTAssertNil(ToolResolver.path(for: "openconnect",
                                       searchPath: ["/a", "/b"],
                                       isExecutable: files(["/a/stoken"])))
    }

    func testTrailingSlashesInTheSearchPathDoNotDoubleUp() {
        let found = ToolResolver.path(for: "brew",
                                      searchPath: ["/opt/homebrew/bin/"],
                                      isExecutable: files(["/opt/homebrew/bin/brew"]))
        XCTAssertEqual(found, "/opt/homebrew/bin/brew")
    }

    /// A name with a slash is a path, not a tool name. Refusing it keeps a
    /// caller from smuggling `/etc/passwd` into an argv slot that was meant to
    /// hold a command.
    func testNamesThatArePathsAreRefused() {
        XCTAssertNil(ToolResolver.path(for: "/bin/sh", searchPath: ["/bin"], isExecutable: { _ in true }))
        XCTAssertNil(ToolResolver.path(for: "../sh", searchPath: ["/bin"], isExecutable: { _ in true }))
        XCTAssertNil(ToolResolver.path(for: "", searchPath: ["/bin"], isExecutable: { _ in true }))
    }

    // MARK: Search path

    func testPathEntriesAreKeptInOrderAndAheadOfThePrefixes() {
        let path = ToolResolver.searchPath(environment: ["PATH": "/custom/bin:/usr/bin"],
                                           home: "/Users/tester")
        XCTAssertEqual(Array(path.prefix(2)), ["/custom/bin", "/usr/bin"],
                       "the user's own PATH wins")
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
    }

    func testTheKnownPrefixesAreAllSearched() {
        let path = ToolResolver.searchPath(environment: [:], home: "/Users/tester")
        XCTAssertEqual(path, ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                              "/Users/tester/.local/bin", "/usr/bin", "/bin"])
    }

    /// The defect this replaced: the four directories the app used to try left
    /// out MacPorts, so an installed `stoken` looked absent.
    func testMacPortsIsSearchedEvenThoughItIsNotOnTheDefaultPath() {
        let path = ToolResolver.searchPath(environment: [:], home: "/Users/tester")
        XCTAssertTrue(path.contains("/opt/local/bin"))

        let found = ToolResolver.path(for: "stoken",
                                      searchPath: path,
                                      isExecutable: files(["/opt/local/bin/stoken"]))
        XCTAssertEqual(found, "/opt/local/bin/stoken")
    }

    func testLocalBinIsResolvedAgainstTheGivenHomeNotTheRealOne() {
        let path = ToolResolver.searchPath(environment: [:], home: "/Users/tester")
        XCTAssertTrue(path.contains("/Users/tester/.local/bin"))
        XCTAssertFalse(path.contains("~/.local/bin"), "the tilde must be expanded")

        let found = ToolResolver.path(for: "vpn-slice",
                                      searchPath: path,
                                      isExecutable: files(["/Users/tester/.local/bin/vpn-slice"]))
        XCTAssertEqual(found, "/Users/tester/.local/bin/vpn-slice")
    }

    func testAPathThatRepeatsADirectoryDoesNotSearchItTwice() {
        let path = ToolResolver.searchPath(environment: ["PATH": "/opt/homebrew/bin:/opt/homebrew/bin:/usr/bin"],
                                           home: "/Users/tester")
        XCTAssertEqual(path.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(Array(path.prefix(2)), ["/opt/homebrew/bin", "/usr/bin"])
    }

    func testEmptyPathEntriesAreIgnored() {
        let path = ToolResolver.searchPath(environment: ["PATH": ":/usr/bin::"], home: "/Users/tester")
        XCTAssertFalse(path.contains(""))
        XCTAssertEqual(path.first, "/usr/bin")
    }

    func testAMissingPathVariableStillYieldsThePrefixes() {
        XCTAssertEqual(ToolResolver.searchPath(environment: [:], home: "/Users/tester"),
                       ToolResolver.searchPath(environment: ["PATH": ""], home: "/Users/tester"))
    }

    func testHomebrewDirectoryIsTheDirectoryBrewLivesIn() {
        XCTAssertEqual(ToolResolver.homebrewDirectory(brewPath: "/opt/homebrew/bin/brew"),
                       "/opt/homebrew/bin")
        XCTAssertEqual(ToolResolver.homebrewDirectory(brewPath: "/usr/local/bin/brew"),
                       "/usr/local/bin")
    }

    /// The real filesystem, for one tool that is either there or not — the point
    /// is that `locate` agrees with `path(for:)`, not that this Mac has Homebrew.
    func testLocateAgreesWithPathOnThisMachine() {
        let located = ToolResolver.locate("/bin/sh")
        XCTAssertNil(located, "a path is not a tool name")

        let shell = ToolResolver.locate("sh", environment: ["PATH": "/bin"], home: "/tmp")
        XCTAssertEqual(shell, "/bin/sh")
    }
}

/// Version parsing, against the real first lines of these four tools.
final class ToolVersionTests: XCTestCase {

    func testRealVersionOutputsParse() {
        XCTAssertEqual(ToolVersion.parse("OpenConnect version v9.21\nUsing GnuTLS 3.8.13"),
                       "9.21", "the tool's own version, not the library's")
        XCTAssertEqual(ToolVersion.parse("stoken 0.93 - software token for Linux/UNIX systems"), "0.93")
        XCTAssertEqual(ToolVersion.parse("vpn-slice 0.16.1"), "0.16.1")
        XCTAssertEqual(ToolVersion.parse("Homebrew 7.0.1"), "7.0.1")
    }

    func testTheFirstVersionLookingNumberWins() {
        XCTAssertEqual(ToolVersion.parse("foo 1.2 bar 3.4"), "1.2")
    }

    func testASingleIntegerIsNotAVersion() {
        XCTAssertNil(ToolVersion.parse("openconnect version 9"))
    }

    func testATrailingDotIsNotPartOfAVersion() {
        XCTAssertEqual(ToolVersion.parse("v1.2. build 7"), "1.2")
        XCTAssertNil(ToolVersion.parse("v1."))
    }

    func testTextWithNoNumberHasNoVersion() {
        XCTAssertNil(ToolVersion.parse(""))
        XCTAssertNil(ToolVersion.parse("command not found"))
    }

    func testLeadingNoiseIsSkippedButWordsGluedToDigitsAreNot() {
        XCTAssertEqual(ToolVersion.parse("warning: using cached copy — v9.21"), "9.21")
        // "g3.8" is one token; the digits still start at 3.8, which is what a
        // user reading the line would point at.
        XCTAssertEqual(ToolVersion.parse("g3.8.1"), "3.8.1")
    }

    func testFirstLineSkipsBlankLinesAndKeepsTheRest() {
        XCTAssertEqual(ToolVersion.firstLine("\n\nHomebrew 7.0.1\nlater"), "Homebrew 7.0.1")
        XCTAssertEqual(ToolVersion.firstLine("\n  \n"), "")
    }
}

/// Whether a connection can start, and what to say when it cannot.
final class ToolPreflightTests: XCTestCase {

    private func locator(_ present: Set<String>) -> (String) -> String? {
        { present.contains($0) ? "/opt/homebrew/bin/\($0)" : nil }
    }

    func testStandardModeNeedsOpenconnectAndStokenOnly() {
        XCTAssertEqual(ToolPreflight.required(splitTunneling: false).map(\.id),
                       ["openconnect", "stoken"])
    }

    func testSplitTunnelingAlsoNeedsVpnSlice() {
        XCTAssertEqual(ToolPreflight.required(splitTunneling: true).map(\.id),
                       ["openconnect", "stoken", "vpn-slice"])
    }

    func testNothingIsMissingWhenEverythingIsPresent() {
        let missing = ToolPreflight.missing(splitTunneling: true,
                                            locate: locator(["openconnect", "stoken", "vpn-slice"]))
        XCTAssertTrue(missing.isEmpty)
        XCTAssertNil(ToolPreflight.message(for: missing))
    }

    func testMissingNamesEveryAbsentToolInOrder() {
        let missing = ToolPreflight.missing(splitTunneling: true, locate: locator(["openconnect"]))
        XCTAssertEqual(missing.map(\.id), ["stoken", "vpn-slice"])
    }

    func testASplitTunnelConnectDoesNotCareAboutAnAbsentVpnSlice() {
        let missing = ToolPreflight.missing(splitTunneling: false,
                                            locate: locator(["openconnect", "stoken"]))
        XCTAssertTrue(missing.isEmpty)
    }

    /// The whole point of the message: name the tool, and point at the pane that
    /// can install it.
    func testAMissingToolMessageNamesItAndPointsAtSetup() {
        let message = ToolPreflight.message(for: [.stoken])
        XCTAssertEqual(message, "stoken is not installed — see Settings ▸ Setup")
    }

    func testTwoMissingToolsReadAsAListOfTwo() {
        XCTAssertEqual(ToolPreflight.message(for: [.openconnect, .stoken]),
                       "openconnect and stoken are not installed — see Settings ▸ Setup")
    }

    func testThreeMissingToolsUseACommaAndAConjunction() {
        XCTAssertEqual(ToolPreflight.message(for: [.openconnect, .stoken, .vpnSlice]),
                       "openconnect, stoken and vpn-slice are not installed — see Settings ▸ Setup")
    }
}
