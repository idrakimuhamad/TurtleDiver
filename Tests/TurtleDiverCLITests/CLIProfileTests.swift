import XCTest
@testable import TurtleDiverCLIKit
import TurtleDiverCore

/// The read-only commands against a real directory: listing, validating, and
/// explaining a rule. A fixture profile on disk, so the parser, the matcher, and
/// the policy store are all the real ones.
final class CLIProfileTests: XCTestCase {

    private var directory: URL!

    private let validProfile = """
    [Proxy]
    Corp = http, proxy.corp.example, 8080
    Other = socks5, socks.corp.example, 1080

    [Proxy Group]
    Auto = select, Corp, Other

    [Rule]
    DOMAIN-SUFFIX,corp.example,Auto
    DOMAIN-KEYWORD,github,DIRECT
    FINAL,Corp
    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turtlediver-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private var profiles: ProfileDirectory { ProfileDirectory(directory: directory) }

    private func write(_ text: String, as name: String) throws {
        try text.write(to: profiles.fileURL(for: name), atomically: true, encoding: .utf8)
    }

    // MARK: - Listing

    func testListingMarksTheActiveProfile() throws {
        try write(validProfile, as: "Main")
        try write(validProfile, as: "Work")

        let listing = ProfileListing.read(directory: profiles, activeName: "Work")
        XCTAssertEqual(listing.entries.map(\.name), ["Main", "Work"])
        XCTAssertEqual(listing.entries.map(\.active), [false, true])
        XCTAssertEqual(listing.entries[0].ruleCount, 3)
        XCTAssertEqual(listing.entries[0].proxyCount, 2)
        XCTAssertEqual(listing.entries[0].groupCount, 1)
        XCTAssertEqual(listing.entries[0].parseErrors, 0)
    }

    func testListingCountsParseErrors() throws {
        // A rule with no policy is a parse error, not a warning.
        try write("[Rule]\nDOMAIN-SUFFIX,example.com\n", as: "Broken")
        let listing = ProfileListing.read(directory: profiles, activeName: nil)
        XCTAssertEqual(listing.entries.first?.parseErrors, 1)
    }

    func testListingAnEmptyDirectoryIsNotAnError() {
        let listing = ProfileListing.read(directory: profiles, activeName: nil)
        XCTAssertTrue(listing.entries.isEmpty)
        XCTAssertEqual(listing.humanLines, ["no profiles in \(directory.path)"])
    }

    func testResolveDefaultUsesTheActiveNameThenASingleProfile() throws {
        try write(validProfile, as: "Main")
        XCTAssertEqual(profiles.resolveDefault(activeName: "Main"), "Main")
        // The active name points at a profile that is gone; one profile is left,
        // so it is the answer.
        XCTAssertEqual(profiles.resolveDefault(activeName: "Deleted"), "Main")

        try write(validProfile, as: "Work")
        // Two profiles and no usable active name: refuse to guess.
        XCTAssertNil(profiles.resolveDefault(activeName: "Deleted"))
    }

    // MARK: - Validation

    func testValidateAcceptsAGoodProfile() throws {
        try write(validProfile, as: "Main")
        let validation = try ProfileValidation.validate(name: "Main", directory: profiles, ruleSets: [:])
        XCTAssertTrue(validation.isValid)
        XCTAssertEqual(validation.policyCount, 3)
        XCTAssertEqual(validation.ruleCount, 3)
        XCTAssertTrue(validation.validationErrors.isEmpty)
        XCTAssertTrue(validation.diagnostics.isEmpty)
        XCTAssertEqual(validation.unresolvedRuleSets, [])
    }

    func testValidateReportsADuplicatePolicyName() throws {
        let text = """
        [Proxy]
        Corp = http, a.example, 8080

        [Proxy Group]
        Corp = select, Corp
        """
        try write(text, as: "Dup")
        let validation = try ProfileValidation.validate(name: "Dup", directory: profiles, ruleSets: [:])
        XCTAssertFalse(validation.isValid)
        XCTAssertTrue(
            validation.validationErrors.contains { $0.lowercased().contains("duplicate") },
            "\(validation.validationErrors)"
        )
    }

    func testValidateAMissingProfileIsNotConfigured() {
        XCTAssertThrowsError(try ProfileValidation.validate(name: "Nope", directory: profiles, ruleSets: [:])) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .notConfigured)
        }
    }

    // MARK: - Rules explain

    func testExplainMatchesADomainSuffixThroughAGroup() throws {
        try write(validProfile, as: "Main")
        let explanation = try RulesExplanation.explain(
            host: "git.corp.example",
            port: nil,
            profileName: "Main",
            directory: profiles,
            defaults: nil,
            ruleSets: [:]
        )
        XCTAssertEqual(explanation.matched?.type, "DOMAIN-SUFFIX")
        XCTAssertEqual(explanation.matched?.value, "corp.example")
        XCTAssertEqual(explanation.policy, "Auto")
        XCTAssertEqual(explanation.decision, "http proxy.corp.example:8080")
        XCTAssertEqual(explanation.selectedMember, "Corp")
    }

    func testExplainAFinalRule() throws {
        try write(validProfile, as: "Main")
        let explanation = try RulesExplanation.explain(
            host: "elsewhere.example",
            port: nil,
            profileName: "Main",
            directory: profiles,
            defaults: nil,
            ruleSets: [:]
        )
        XCTAssertEqual(explanation.matched?.type, "FINAL")
        XCTAssertEqual(explanation.policy, "Corp")
        XCTAssertEqual(explanation.decision, "http proxy.corp.example:8080")
    }

    func testExplainADirectKeyword() throws {
        try write(validProfile, as: "Main")
        let explanation = try RulesExplanation.explain(
            host: "github.com",
            port: nil,
            profileName: "Main",
            directory: profiles,
            defaults: nil,
            ruleSets: [:]
        )
        XCTAssertEqual(explanation.matched?.type, "DOMAIN-KEYWORD")
        XCTAssertEqual(explanation.decision, "DIRECT")
    }

    func testExplainAnEmptyHostIsUsage() throws {
        try write(validProfile, as: "Main")
        XCTAssertThrowsError(try RulesExplanation.explain(
            host: "  ", port: nil, profileName: "Main", directory: profiles, defaults: nil, ruleSets: [:]
        )) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .usage)
        }
    }

    func testExplainReportsUnresolvedRuleSets() throws {
        let text = """
        [Rule Set]
        Ads = https://rules.example/ads.txt, 24

        [Proxy]
        Corp = http, proxy.corp.example, 8080

        [Rule]
        RULE-SET,Ads,REJECT
        FINAL,Corp
        """
        try write(text, as: "Main")
        // No cached rules for "Ads", so the reference cannot match — and it is
        // reported rather than silently skipped.
        let explanation = try RulesExplanation.explain(
            host: "ads.example", port: nil, profileName: "Main",
            directory: profiles, defaults: nil, ruleSets: [:]
        )
        XCTAssertEqual(explanation.unresolvedRuleSets, ["Ads"])
        XCTAssertEqual(explanation.matched?.type, "FINAL")
    }

    func testExplainUsesCachedRuleSetRules() throws {
        let text = """
        [Rule Set]
        Ads = https://rules.example/ads.txt, 24

        [Proxy]
        Corp = http, proxy.corp.example, 8080

        [Rule]
        RULE-SET,Ads,REJECT
        FINAL,Corp
        """
        try write(text, as: "Main")
        let cached = [ProfileRule(type: .domainSuffix, value: "ads.example", policy: "", ruleSet: nil)]
        let explanation = try RulesExplanation.explain(
            host: "ads.example", port: nil, profileName: "Main",
            directory: profiles, defaults: nil, ruleSets: ["ads": cached]
        )
        XCTAssertEqual(explanation.matched?.policy, "REJECT")
        XCTAssertEqual(explanation.decision, "REJECT")
        XCTAssertEqual(explanation.matched?.ruleSet, "Ads")
    }

    // MARK: - Profile name resolution

    func testResolveProfileNamePrefersTheFlagThenTheAppActiveProfile() throws {
        try write(validProfile, as: "Main")
        try write(validProfile, as: "Work")
        let settings = AppSettings(activeProfileName: "Work")

        let explicit = try TurtleDiverCLI.resolveProfileName(
            ParsedCommandLine(command: "rules", positional: ["explain", "x"], options: ["profile": "Main"]),
            directory: profiles, settings: settings
        )
        XCTAssertEqual(explicit, "Main")

        let fromApp = try TurtleDiverCLI.resolveProfileName(
            ParsedCommandLine(command: "rules", positional: ["explain", "x"]),
            directory: profiles, settings: settings
        )
        XCTAssertEqual(fromApp, "Work")
    }

    func testResolveProfileNameRefusesToGuessAmongSeveral() throws {
        try write(validProfile, as: "Main")
        try write(validProfile, as: "Work")
        XCTAssertThrowsError(try TurtleDiverCLI.resolveProfileName(
            ParsedCommandLine(command: "rules", positional: ["explain", "x"]),
            directory: profiles, settings: AppSettings()
        )) { error in
            let message = (error as? CLIFailure)?.message ?? ""
            XCTAssertEqual((error as? CLIFailure)?.code, .notConfigured)
            XCTAssertTrue(message.contains("Main"), message)
            XCTAssertTrue(message.contains("Work"), message)
        }
    }

    func testResolveProfileNameRejectsAnUnknownName() {
        XCTAssertThrowsError(try TurtleDiverCLI.resolveProfileName(
            ParsedCommandLine(command: "rules", positional: ["explain", "x"], options: ["profile": "Ghost"]),
            directory: profiles, settings: AppSettings()
        )) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .notConfigured)
        }
    }
}
