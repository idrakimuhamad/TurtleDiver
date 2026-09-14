import XCTest

#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif
#if canImport(TurtleDiverRules)
import TurtleDiverRules
#endif
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

final class VPNRuleGeneratorTests: XCTestCase {

    // MARK: Target shapes

    func testCIDRTargetBecomesIPCIDRRule() {
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8"])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].type, .ipCIDR)
        XCTAssertEqual(rules[0].value, "10.0.0.0/8")
        XCTAssertEqual(rules[0].policy, "DIRECT")
        XCTAssertEqual(rules[0].noResolve, false)
    }

    func testBareIPv4BecomesHostRoute() {
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: ["10.20.30.40"])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(rules[0].type, .ipCIDR)
        XCTAssertEqual(rules[0].value, "10.20.30.40/32")
    }

    func testBareIPv6BecomesHostRoute() {
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: ["fd00::1"])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(rules[0].type, .ipCIDR6)
        XCTAssertEqual(rules[0].value, "fd00::1/128")
    }

    func testIPv6CIDRTarget() {
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: ["fd00::/8"])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(rules[0].type, .ipCIDR6)
        XCTAssertEqual(rules[0].value, "fd00::/8")
    }

    func testWildcardHostnameBecomesDomainSuffix() {
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: ["*.corp.example.com"])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(rules[0].type, .domainSuffix)
        XCTAssertEqual(rules[0].value, "corp.example.com")
    }

    func testPlainHostnameBecomesDomainRule() {
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: ["vpn.corp.example.com"])
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(rules[0].type, .domain)
        XCTAssertEqual(rules[0].value, "vpn.corp.example.com")
    }

    func testInvalidTargetsReportedAndSkipped() {
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: [
            "not a host!", "", "  ", "#comment", "10.0.0.0/33", "999.1.2.3",
        ])
        XCTAssertEqual(rules.count, 0)
        // "", "  ", "#comment" are skipped silently; the rest are reported.
        XCTAssertEqual(Set(errors), ["not a host!", "10.0.0.0/33", "999.1.2.3"])
    }

    func testDuplicateTargetsDeduplicated() {
        let (rules, _) = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8", "10.0.0.0/8", "VPN.corp.com", "vpn.corp.com"])
        XCTAssertEqual(rules.count, 2)
    }

    func testCustomPolicyName() {
        let (rules, _) = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8"], policy: "CORP-DIRECT")
        XCTAssertEqual(rules[0].policy, "CORP-DIRECT")
    }

    // MARK: Merge behavior

    private func makeProfile(rules: [ProfileRule]) -> Profile {
        var profile = Profile(name: "Test")
        profile.rules = rules
        return profile
    }

    func testMergeInsertsGeneratedRulesAtTop() {
        let userRule = ProfileRule(type: .domainSuffix, value: "example.com", policy: "PROXY")
        let profile = makeProfile(rules: [userRule])
        let generated = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8"]).rules

        let merged = VPNRuleGenerator.merge(generated: generated, replacing: [], into: profile)

        XCTAssertEqual(merged.rules.count, 2)
        XCTAssertEqual(merged.rules.first?.type, .ipCIDR)
        XCTAssertEqual(merged.rules.last, userRule)
    }

    func testMergeReplacesPreviousGeneration() {
        let userRule = ProfileRule(type: .domainSuffix, value: "example.com", policy: "PROXY")
        let first = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8"]).rules
        var profile = makeProfile(rules: [userRule])
        profile = VPNRuleGenerator.merge(generated: first, replacing: [], into: profile)
        XCTAssertEqual(profile.rules.count, 2)

        // Tunnel config changed: new subnet replaces the old one.
        let second = VPNRuleGenerator.rules(forTargets: ["172.16.0.0/12"]).rules
        profile = VPNRuleGenerator.merge(generated: second, replacing: first, into: profile)

        XCTAssertEqual(profile.rules.count, 2)
        XCTAssertFalse(profile.rules.contains { $0.value.contains("10.0.0.0") })
        XCTAssertTrue(profile.rules.contains { $0.value.contains("172.16.0.0") })
        XCTAssertEqual(profile.rules.last, userRule) // user rule never displaced
    }

    func testMergeIsIdempotent() {
        let generated = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8", "*.corp.example.com"]).rules
        var profile = makeProfile(rules: [])

        profile = VPNRuleGenerator.merge(generated: generated, replacing: [], into: profile)
        let afterFirst = profile.rules
        profile = VPNRuleGenerator.merge(generated: generated, replacing: generated, into: profile)

        XCTAssertEqual(profile.rules, afterFirst)
    }

    func testMergeSkipsRulesAlreadyPresent() {
        let existing = ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT")
        let profile = makeProfile(rules: [existing])
        let generated = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8"]).rules

        let merged = VPNRuleGenerator.merge(generated: generated, replacing: [], into: profile)
        XCTAssertEqual(merged.rules.filter { $0.value == "10.0.0.0/8" }.count, 1)
    }

    // MARK: Main-thread loop regression (EngineController change-guards)

    /// The hang bug: `VPNRuleGenerator.rules()` mints fresh UUIDs per call, so
    /// `merged.rules != profile.rules` stayed true forever and
    /// save → change-notification → save looped the main thread.
    func testRepeatedGenerationProducesEqualRules() {
        let targets = ["10.0.0.0/8", "*.corp.example.com", "vpn.corp.com"]
        let first = VPNRuleGenerator.rules(forTargets: targets).rules
        var profile = makeProfile(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])

        profile = VPNRuleGenerator.merge(generated: first, replacing: [], into: profile)
        let applied = first

        // Simulate the next change-notification pass: regenerate + re-merge.
        let second = VPNRuleGenerator.rules(forTargets: targets).rules
        let merged = VPNRuleGenerator.merge(generated: second, replacing: applied, into: profile)

        // The guard must now see "no change" even though UUIDs differ.
        XCTAssertTrue(VPNRuleGenerator.sameRules(merged.rules, profile.rules))
        // And identity is preserved so plain `==` also holds (defense in depth).
        XCTAssertEqual(merged.rules, profile.rules)
    }

    func testSameRulesIgnoresIdentityUUIDs() {
        let a = ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT")
        var b = a
        b.id = UUID()
        XCTAssertTrue(VPNRuleGenerator.sameRule(a, b))
        XCTAssertTrue(VPNRuleGenerator.sameRules([a], [b]))

        // Value/policy differences still count.
        var c = a
        c.policy = "PROXY"
        XCTAssertFalse(VPNRuleGenerator.sameRule(a, c))
        var d = a
        d.noResolve = true
        XCTAssertFalse(VPNRuleGenerator.sameRule(a, d))
    }

    func testSameRulesDetectsReorderingAndCount() {
        let one = ProfileRule(type: .domain, value: "a.com", policy: "DIRECT")
        let two = ProfileRule(type: .domain, value: "b.com", policy: "DIRECT")
        XCTAssertFalse(VPNRuleGenerator.sameRules([one, two], [two, one]))
        XCTAssertFalse(VPNRuleGenerator.sameRules([one], [one, two]))
    }

    func testClearGuardSeesNoChangeWhenOverlayAlreadyGone() {
        // EngineController.clearVPNRules regenerates with an empty target list;
        // when nothing was applied the guard must treat the result as equal.
        let profile = makeProfile(rules: [ProfileRule(type: .final, value: "", policy: "DIRECT")])
        let merged = VPNRuleGenerator.merge(generated: [], replacing: [], into: profile)
        XCTAssertTrue(VPNRuleGenerator.sameRules(merged.rules, profile.rules))
        XCTAssertEqual(merged.rules, profile.rules)
    }

    func testMergeClearsWhenGeneratedEmpty() {
        let previous = VPNRuleGenerator.rules(forTargets: ["10.0.0.0/8"]).rules
        let userRule = ProfileRule(type: .final, value: "", policy: "DIRECT")
        var profile = makeProfile(rules: [userRule])
        profile = VPNRuleGenerator.merge(generated: previous, replacing: [], into: profile)

        profile = VPNRuleGenerator.merge(generated: [], replacing: previous, into: profile)
        XCTAssertEqual(profile.rules, [userRule])
    }

    // MARK: Hostname validation

    func testValidHostnameEdgeCases() {
        XCTAssertTrue(VPNRuleGenerator.validHostname("a.b"))
        XCTAssertTrue(VPNRuleGenerator.validHostname("vpn-gw.corp.example.com"))
        XCTAssertFalse(VPNRuleGenerator.validHostname("-bad.example.com"))
        XCTAssertFalse(VPNRuleGenerator.validHostname("bad..example.com"))
        XCTAssertFalse(VPNRuleGenerator.validHostname("example com"))
        XCTAssertFalse(VPNRuleGenerator.validHostname(""))
        XCTAssertFalse(VPNRuleGenerator.validHostname("10.0.0.1"))
    }

    func testGeneratedRulesRoundTripThroughParser() {
        // The rules we generate must be accepted by the profile parser and
        // serialize back identically.
        let (rules, errors) = VPNRuleGenerator.rules(forTargets: [
            "10.0.0.0/8", "172.16.0.0/12", "fd00::/8", "*.corp.example.com", "vpn.corp.com",
        ])
        XCTAssertTrue(errors.isEmpty)

        var profile = Profile(name: "RoundTrip")
        profile.rules = rules + [ProfileRule(type: .final, value: "", policy: "DIRECT")]
        XCTAssertEqual(profile.validate(), [])

        let text = ProfileSerializer.serialize(profile)
        let reparsed = ProfileParser.parse(text, name: "RoundTrip").profile
        XCTAssertEqual(reparsed.rules.count, profile.rules.count)
        for (a, b) in zip(reparsed.rules, profile.rules) {
            XCTAssertEqual(a.type, b.type)
            XCTAssertEqual(a.value, b.value)
            XCTAssertEqual(a.policy, b.policy)
        }
    }
}
