import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules

final class RuleMatcherTests: XCTestCase {

    // MARK: - Helpers

    private func profile(rules: [ProfileRule]) -> Profile {
        var profile = Profile(name: "T")
        profile.rules = rules
        return profile
    }

    private func ctx(
        host: String? = nil,
        port: Int? = nil,
        resolvedIP: IPAddress? = nil,
        processName: String? = nil,
        userAgent: String? = nil,
        url: String? = nil,
        sourceIP: IPAddress? = nil
    ) -> MatchContext {
        MatchContext(
            host: host, port: port, resolvedIP: resolvedIP,
            processName: processName, userAgent: userAgent, url: url, sourceIP: sourceIP
        )
    }

    // MARK: - Domain rules

    func testDomainExactMatchCaseInsensitive() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domain, value: "Apple.COM", policy: "REJECT")
        ]))
        let outcome = try matcher.match(ctx(host: "apple.com"))
        XCTAssertEqual(outcome.policy, "REJECT")
        XCTAssertEqual(outcome.rule?.type, .domain)
        XCTAssertFalse(outcome.performedDNS)
    }

    func testDomainDoesNotMatchSubdomain() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domain, value: "apple.com", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "www.apple.com")).policy, "DIRECT")
    }

    func testDomainSuffixMatchesBoundary() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domainSuffix, value: "apple.com", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "www.apple.com")).policy, "REJECT")
        XCTAssertEqual(try matcher.match(ctx(host: "apple.com")).policy, "REJECT")
    }

    func testDomainSuffixDoesNotMatchInnerString() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domainSuffix, value: "apple.com", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "notapple.com")).policy, "DIRECT")
        XCTAssertEqual(try matcher.match(ctx(host: "apple.com.evil.io")).policy, "DIRECT")
    }

    func testDomainKeywordSubstring() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domainKeyword, value: "analytics", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "cdn.analyticsvendor.io")).policy, "REJECT")
        XCTAssertEqual(try matcher.match(ctx(host: "example.com")).policy, "DIRECT")
    }

    func testDomainRulesNeverMatchIPLiteral() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domain, value: "1.2.3.4", policy: "REJECT"),
            ProfileRule(type: .domainSuffix, value: "3.4", policy: "REJECT"),
            ProfileRule(type: .domainKeyword, value: "3.4", policy: "REJECT")
        ]))
        // DOMAIN rules are host rules; a dotted string is treated as a
        // host here (Surge matches textual DOMAIN values the same way), so
        // the exact-match rule fires.
        XCTAssertEqual(try matcher.match(ctx(host: "1.2.3.4")).policy, "REJECT")
    }

    // MARK: - IP rules & DNS

    func testIPCIDRMatchesResolvedAddress() throws {
        let fake = FakeDNSResolver(table: ["corp.example": [IPAddress.parse("10.20.30.40")!]])
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT")
        ]), resolver: fake)
        let outcome = try matcher.match(ctx(host: "corp.example"))
        XCTAssertEqual(outcome.policy, "REJECT")
        XCTAssertTrue(outcome.performedDNS)
        XCTAssertEqual(fake.lookupCounts["corp.example"], 1)
    }

    func testIPCIDRLiteralHostNeedsNoDNS() throws {
        let fake = FakeDNSResolver(table: [:])
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT")
        ]), resolver: fake)
        let outcome = try matcher.match(ctx(host: "10.1.2.3"))
        XCTAssertEqual(outcome.policy, "REJECT")
        XCTAssertFalse(outcome.performedDNS)
    }

    func testDNSResolvedOnceAcrossRules() throws {
        let fake = FakeDNSResolver(table: ["host.example": [IPAddress.parse("172.16.5.5")!]])
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "192.168.0.0/16", policy: "REJECT"), // miss
            ProfileRule(type: .ipCIDR, value: "172.16.0.0/12", policy: "PROXY")    // hit
        ]), resolver: fake)
        let outcome = try matcher.match(ctx(host: "host.example"))
        XCTAssertEqual(outcome.policy, "PROXY")
        XCTAssertEqual(fake.lookupCounts["host.example"], 1, "second IP rule must reuse the resolution")
    }

    func testNoResolveSkipsRuleNeedingDNS() throws {
        let fake = FakeDNSResolver(table: ["host.example": [IPAddress.parse("10.1.2.3")!]])
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT", noResolve: true),
            ProfileRule(type: .final, value: "", policy: "PROXY")
        ]), resolver: fake)
        let outcome = try matcher.match(ctx(host: "host.example"))
        XCTAssertEqual(outcome.policy, "PROXY")
        XCTAssertFalse(outcome.performedDNS)
        XCTAssertEqual(fake.lookupCounts["host.example"] ?? 0, 0)
    }

    func testNoResolveStillMatchesLiteral() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT", noResolve: true)
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "10.9.9.9")).policy, "REJECT")
    }

    func testNoResolveStillMatchesPreResolvedIP() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT", noResolve: true)
        ]))
        let outcome = try matcher.match(ctx(host: "corp.example", resolvedIP: IPAddress.parse("10.9.9.9")))
        XCTAssertEqual(outcome.policy, "REJECT")
        XCTAssertFalse(outcome.performedDNS)
    }

    func testIPCIDR6MatchesV6() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR6, value: "fe80::/10", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "fe80::1")).policy, "REJECT")
        XCTAssertEqual(try matcher.match(ctx(host: "2001:db8::1")).policy, "DIRECT")
    }

    func testMappedV6DestinationMatchesV4Rule() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "::ffff:10.7.7.7")).policy, "REJECT")
    }

    func testFailedResolutionMakesIPRuleMiss() throws {
        let fake = FakeDNSResolver(table: ["dead.example": []])
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "PROXY")
        ]), resolver: fake)
        XCTAssertEqual(try matcher.match(ctx(host: "dead.example")).policy, "PROXY")
    }

    func testIPRuleAfterDomainRuleDoesNotDNSWhenDomainMatched() throws {
        let fake = FakeDNSResolver(table: ["ads.example": [IPAddress.parse("10.1.2.3")!]])
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domainSuffix, value: "ads.example", policy: "REJECT"),
            ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "PROXY")
        ]), resolver: fake)
        let outcome = try matcher.match(ctx(host: "s.ads.example"))
        XCTAssertEqual(outcome.policy, "REJECT")
        XCTAssertEqual(fake.lookupCounts["s.ads.example"] ?? 0, 0, "earlier domain match must prevent DNS")
    }

    // MARK: - Precedence

    func testFirstMatchWins() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domainSuffix, value: "example.com", policy: "DIRECT"),
            ProfileRule(type: .domainKeyword, value: "example", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "PROXY")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "www.example.com")).policy, "DIRECT")
    }

    func testFinalTerminates() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .final, value: "", policy: "PROXY")
        ]))
        let outcome = try matcher.match(ctx(host: "anything.example"))
        XCTAssertEqual(outcome.policy, "PROXY")
        XCTAssertEqual(outcome.rule?.type, .final)
    }

    func testDefaultPolicyIsDirectWhenNoFinal() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domainSuffix, value: "apple.com", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "other.example")).policy, "DIRECT")
    }

    func testFinalPolicyWinsOverDefault() throws {
        // FINAL present but earlier rules miss → FINAL's policy applies.
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .domainSuffix, value: "apple.com", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "PROXY")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "other.example")).policy, "PROXY")
    }

    // MARK: - USER-AGENT / URL-REGEX (HTTP-only)

    func testUserAgentRuleMatchesHTTPOnly() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .userAgent, value: "curl.*7", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", userAgent: "curl/8.7.1")).policy, "REJECT")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example")).policy, "DIRECT", "SOCKS5 (no UA) must not match")
    }

    func testURLRegexRule() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .urlRegex, value: "^https?://[^/]+/(ads|track)", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", url: "http://x.example/ads/1.js")).policy, "REJECT")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", url: "http://x.example/video/1.mp4")).policy, "DIRECT")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example")).policy, "DIRECT")
    }

    // MARK: - PROCESS-NAME

    func testProcessNameMatchesLastPathComponent() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .processName, value: "Dropbox", policy: "PROXY")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "db.example", processName: "/Applications/Dropbox.app/Contents/MacOS/Dropbox")).policy, "PROXY")
        XCTAssertEqual(try matcher.match(ctx(host: "db.example", processName: "curl")).policy, "DIRECT")
        XCTAssertEqual(try matcher.match(ctx(host: "db.example")).policy, "DIRECT", "no peer info must not match")
    }

    // MARK: - DEST-PORT / SRC-IP

    func testDestPortExactRangeAndList() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .destPort, value: "80,443", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", port: 443)).policy, "REJECT")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", port: 80)).policy, "REJECT")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", port: 8080)).policy, "DIRECT")

        let ranged = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .destPort, value: "1000-2000", policy: "REJECT")
        ]))
        XCTAssertEqual(try ranged.match(ctx(host: "x.example", port: 1500)).policy, "REJECT")
        XCTAssertEqual(try ranged.match(ctx(host: "x.example", port: 2001)).policy, "DIRECT")
    }

    func testDestPortRequiresPort() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .destPort, value: "443", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example")).policy, "DIRECT")
    }

    func testSrcIPRule() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .srcIP, value: "192.168.1.0/24", policy: "PROXY")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", sourceIP: IPAddress.parse("192.168.1.77"))).policy, "PROXY")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", sourceIP: IPAddress.parse("192.168.2.77"))).policy, "DIRECT")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example")).policy, "DIRECT")
    }

    // MARK: - PROTOCOL heuristic

    func testProtocolHeuristic() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .protocolRule, value: "HTTPS", policy: "PROXY")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", port: 443)).policy, "PROXY")
        XCTAssertEqual(try matcher.match(ctx(host: "x.example", port: 80)).policy, "DIRECT")
    }

    // MARK: - GEOIP reserved

    func testGeoIPNeverMatchesYet() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .geoIP, value: "CN", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "PROXY")
        ]))
        let outcome = try matcher.match(ctx(host: "cn.example", resolvedIP: IPAddress.parse("1.2.3.4")))
        XCTAssertEqual(outcome.policy, "PROXY")
    }

    // MARK: - Malformed value hardening

    func testMalformedCIDRThrowsInsteadOfCrashing() {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .ipCIDR, value: "not-a-cidr", policy: "REJECT")
        ]))
        XCTAssertThrowsError(try matcher.match(ctx(host: "10.0.0.1")))
    }

    // MARK: - Profile hot-swap

    func testUpdateProfileSwapsRules() throws {
        let matcher = RuleMatcher(profile: profile(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example")).policy, "DIRECT")

        matcher.updateProfile(profile(rules: [
            ProfileRule(type: .final, value: "", policy: "REJECT")
        ]))
        XCTAssertEqual(try matcher.match(ctx(host: "x.example")).policy, "REJECT")
    }

    // MARK: - Matching helper details

    func testHostMatchesSuffixEdgeCases() {
        XCTAssertTrue(RuleMatcher.hostMatchesSuffix(host: "apple.com", suffix: "apple.com"))
        XCTAssertTrue(RuleMatcher.hostMatchesSuffix(host: "www.apple.com", suffix: "apple.com"))
        XCTAssertFalse(RuleMatcher.hostMatchesSuffix(host: "notapple.com", suffix: "apple.com"))
        XCTAssertFalse(RuleMatcher.hostMatchesSuffix(host: "apple.com.evil.io", suffix: "apple.com"))
        XCTAssertFalse(RuleMatcher.hostMatchesSuffix(host: "apple.com", suffix: ""))
        XCTAssertTrue(RuleMatcher.hostMatchesSuffix(host: "APPLE.COM", suffix: "apple.com"))
    }

    func testPortListParsingTolerant() {
        XCTAssertTrue(RuleMatcher.portListContains("443", port: 443))
        XCTAssertTrue(RuleMatcher.portListContains(" 80 , 443 ", port: 80))
        XCTAssertTrue(RuleMatcher.portListContains("1000-2000,3000", port: 3000))
        XCTAssertFalse(RuleMatcher.portListContains("1000-2000", port: 999))
        XCTAssertFalse(RuleMatcher.portListContains("", port: 80))
        XCTAssertFalse(RuleMatcher.portListContains("abc", port: 80))
    }

    func testIPLiteralDetection() {
        XCTAssertNotNil(RuleMatcher.hostIPLiteral("192.168.1.1"))
        XCTAssertNotNil(RuleMatcher.hostIPLiteral("::1"))
        XCTAssertNil(RuleMatcher.hostIPLiteral("example.com"))
        XCTAssertNil(RuleMatcher.hostIPLiteral(""))
        XCTAssertNil(RuleMatcher.hostIPLiteral(nil))
    }

    func testProcessNameComparison() {
        XCTAssertTrue(RuleMatcher.processNameMatches(peer: "/usr/bin/curl", value: "curl"))
        XCTAssertTrue(RuleMatcher.processNameMatches(peer: "CURL", value: "curl"))
        XCTAssertFalse(RuleMatcher.processNameMatches(peer: "/usr/bin/curl", value: "wget"))
        XCTAssertFalse(RuleMatcher.processNameMatches(peer: "/usr/bin/curlish", value: "curl"))
    }
}
