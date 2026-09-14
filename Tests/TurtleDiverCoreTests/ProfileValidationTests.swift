import XCTest
@testable import TurtleDiverCore

final class ProfileValidationTests: XCTestCase {

    // MARK: - Policy names

    func testDuplicatePolicyNameDetected() {
        var profile = Profile(name: "V")
        profile.proxies = [ProxyDefinition(name: "A", type: .http, host: "h", port: 80)]
        profile.groups = [ProxyGroup(name: "A", type: .select, policies: ["DIRECT"])]
        let errors = profile.validate()
        XCTAssertTrue(errors.contains { $0 == .duplicatePolicyName("A") }, "\(errors)")
    }

    func testInvalidPolicyNamesDetected() {
        var profile = Profile(name: "V")
        profile.proxies = [
            ProxyDefinition(name: "", type: .http, host: "h", port: 80),
            ProxyDefinition(name: "Bad,Name", type: .http, host: "h", port: 80),
            ProxyDefinition(name: "FINAL", type: .http, host: "h", port: 80)
        ]
        XCTAssertTrue(profile.validate().contains { $0 == .invalidPolicyName("") })
        XCTAssertTrue(profile.validate().contains { $0 == .invalidPolicyName("Bad,Name") })
        XCTAssertTrue(profile.validate().contains { $0 == .invalidPolicyName("FINAL") })
    }

    func testReservedBuiltinNamesRemainValid() {
        var profile = Profile(name: "V")
        profile.rules = [ProfileRule(type: .final, value: "", policy: "DIRECT")]
        XCTAssertEqual(profile.validate(), [])
        XCTAssertTrue(BuiltinPolicy.names.contains("DIRECT"))
        XCTAssertTrue(BuiltinPolicy.names.contains("REJECT"))
    }

    // MARK: - Ports & general

    func testInvalidProxyPortDetected() {
        var profile = Profile(name: "V")
        profile.proxies = [ProxyDefinition(name: "A", type: .http, host: "h", port: 0)]
        XCTAssertTrue(profile.validate().contains { $0 == .invalidPort(name: "A", port: 0) })

        profile.proxies = [ProxyDefinition(name: "A", type: .http, host: "h", port: 70000)]
        XCTAssertTrue(profile.validate().contains { $0 == .invalidPort(name: "A", port: 70000) })
    }

    func testInvalidListenerDetected() {
        var profile = Profile(name: "V")
        profile.general.httpListen = "no-port-here"
        XCTAssertTrue(profile.validate().contains { $0 == .invalidListener("no-port-here") })

        profile.general.httpListen = "127.0.0.1:0"
        XCTAssertTrue(profile.validate().contains { $0 == .invalidListener("127.0.0.1:0") })
    }

    func testInvalidLogLevelDetected() {
        var profile = Profile(name: "V")
        profile.general.logLevel = "verbose"
        XCTAssertTrue(profile.validate().contains { $0 == .invalidLogLevel("verbose") })
    }

    // MARK: - Group references & cycles

    func testGroupUnknownMemberDetected() {
        var profile = Profile(name: "V")
        profile.groups = [ProxyGroup(name: "G", type: .select, policies: ["MISSING"])]
        XCTAssertTrue(profile.validate().contains { $0 == .groupUnknownMember(group: "G", member: "MISSING") })
    }

    func testGroupSelfReferenceDetected() {
        var profile = Profile(name: "V")
        profile.groups = [ProxyGroup(name: "G", type: .select, policies: ["G"])]
        XCTAssertTrue(profile.validate().contains { $0 == .groupSelfReference("G") })
    }

    func testGroupEmptyDetected() {
        var profile = Profile(name: "V")
        profile.groups = [ProxyGroup(name: "G", type: .select, policies: [])]
        XCTAssertTrue(profile.validate().contains { $0 == .groupEmpty("G") })
    }

    func testGroupTwoNodeCycleDetected() {
        var profile = Profile(name: "V")
        profile.groups = [
            ProxyGroup(name: "A", type: .select, policies: ["B"]),
            ProxyGroup(name: "B", type: .select, policies: ["A"])
        ]
        let errors = profile.validate()
        XCTAssertTrue(errors.contains { error in
            if case .groupCycle = error { return true }
            return false
        }, "\(errors)")
    }

    func testGroupThreeNodeCycleDetected() {
        var profile = Profile(name: "V")
        profile.groups = [
            ProxyGroup(name: "A", type: .select, policies: ["B"]),
            ProxyGroup(name: "B", type: .select, policies: ["C"]),
            ProxyGroup(name: "C", type: .select, policies: ["A"])
        ]
        XCTAssertTrue(profile.validate().contains { error in
            if case .groupCycle = error { return true }
            return false
        })
    }

    func testDiamondDependencyNotACycle() {
        // A → B, A → C, B → D, C → D — legal DAG, must not be flagged.
        var profile = Profile(name: "V")
        profile.proxies = [ProxyDefinition(name: "P", type: .http, host: "h", port: 80)]
        profile.groups = [
            ProxyGroup(name: "D", type: .select, policies: ["P"]),
            ProxyGroup(name: "B", type: .select, policies: ["D"]),
            ProxyGroup(name: "C", type: .select, policies: ["D"]),
            ProxyGroup(name: "A", type: .select, policies: ["B", "C"])
        ]
        XCTAssertEqual(profile.validate(), [], "\(profile.validate())")
    }

    // MARK: - Rules

    func testRuleUnknownPolicyDetected() {
        var profile = Profile(name: "V")
        profile.rules = [ProfileRule(type: .domainSuffix, value: "x.com", policy: "NOPE")]
        XCTAssertTrue(profile.validate().contains { $0 == .ruleUnknownPolicy(index: 0, policy: "NOPE") })
    }

    func testDuplicateFinalDetected() {
        var profile = Profile(name: "V")
        profile.rules = [
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "REJECT")
        ]
        XCTAssertTrue(profile.validate().contains { $0 == .duplicateRuleID(1) })
    }

    func testFinalNotLastDetected() {
        var profile = Profile(name: "V")
        profile.rules = [
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
            ProfileRule(type: .domainSuffix, value: "x.com", policy: "REJECT")
        ]
        XCTAssertTrue(profile.validate().contains { $0 == .duplicateRuleID(0) })
    }

    func testValidProfilePasses() {
        var profile = Profile(name: "V")
        profile.proxies = [ProxyDefinition(name: "P", type: .socks5, host: "h", port: 1080)]
        profile.groups = [ProxyGroup(name: "G", type: .urlTest, policies: ["P", "DIRECT"], testURL: "http://x/", interval: 300)]
        profile.rules = [
            ProfileRule(type: .domainSuffix, value: "corp.com", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "G")
        ]
        XCTAssertEqual(profile.validate(), [])
    }
}
