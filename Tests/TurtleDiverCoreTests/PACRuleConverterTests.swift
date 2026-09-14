import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules

final class PACRuleConverterTests: XCTestCase {

    // MARK: - Helpers

    private func firstRule(_ result: PACConversionResult, _ type: RuleType, _ value: String) -> ProfileRule? {
        result.rules.first { $0.type == type && $0.value == value }
    }

    private func convert(_ body: String) -> PACConversionResult {
        PACRuleConverter.convert(pacSource: "function FindProxyForURL(url, host) {\n\(body)\n}")
    }

    // MARK: - shExpMatch

    func testShExpMatchWildcardBecomesDomainSuffix() {
        let result = convert(#"if (shExpMatch(host, "*.example.com")) return "PROXY p:8080";"#)
        XCTAssertEqual(firstRule(result, .domainSuffix, "example.com")?.policy, "p:8080")
        XCTAssertEqual(result.proxies.first?.host, "p")
        XCTAssertEqual(result.proxies.first?.port, 8080)
        XCTAssertEqual(result.proxies.first?.type, .http)
    }

    func testShExpMatchExactBecomesDomain() {
        let result = convert(#"if (shExpMatch(host, "example.com")) return "DIRECT";"#)
        XCTAssertEqual(firstRule(result, .domain, "example.com")?.policy, "DIRECT")
    }

    func testShExpMatchURLPatternStripsSchemePathAndPort() {
        let result = convert(#"if (shExpMatch(url, "*://api.example.com:8443/v1/*")) return "DIRECT";"#)
        XCTAssertEqual(firstRule(result, .domain, "api.example.com")?.policy, "DIRECT")
    }

    func testShExpMatchStarPrefixBecomesSuffix() {
        let result = convert(#"if (shExpMatch(host, "*example.com")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .domainSuffix, "example.com"))
    }

    func testShExpMatchMiddleWildcardApproximatedAsKeyword() {
        let result = convert(#"if (shExpMatch(host, "api.*.example.com")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .domainKeyword, "example.com"))
        XCTAssertTrue(result.diagnostics.contains { $0.contains("DOMAIN-KEYWORD") })
    }

    // MARK: - dnsDomainIs / localHostOrDomainIs

    func testDnsDomainIsDotPrefixBecomesSuffix() {
        let result = convert(#"if (dnsDomainIs(host, ".corp.example.com")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .domainSuffix, "corp.example.com"))
    }

    func testDnsDomainIsWithoutDotBecomesSuffix() {
        let result = convert(#"if (dnsDomainIs(host, "corp.example.com")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .domainSuffix, "corp.example.com"))
    }

    func testLocalHostOrDomainIsBecomesSuffix() {
        let result = convert(#"if (localHostOrDomainIs(host, "intranet")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .domainSuffix, "intranet"))
    }

    // MARK: - Comparisons

    func testHostEqualsLiteralBecomesDomain() {
        let result = convert(#"if (host == "exact.example.com") return "DIRECT";"#)
        XCTAssertEqual(firstRule(result, .domain, "exact.example.com")?.policy, "DIRECT")
    }

    func testLiteralEqualsHostBecomesDomain() {
        let result = convert(#"if ("exact.example.com" === host) return "DIRECT";"#)
        XCTAssertEqual(firstRule(result, .domain, "exact.example.com")?.policy, "DIRECT")
    }

    // MARK: - isInNet

    func testIsInNetHostBecomesCIDR() {
        let result = convert(#"if (isInNet(host, "10.0.0.0", "255.0.0.0")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .ipCIDR, "10.0.0.0/8"))
    }

    func testIsInNetDnsResolveBecomesCIDR() {
        let result = convert(#"if (isInNet(dnsResolve(host), "192.168.0.0", "255.255.0.0")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .ipCIDR, "192.168.0.0/16"))
    }

    func testIsInNetIPv6BecomesCIDR6() {
        let result = convert(#"if (isInNet(host, "fd00::", "ffff::")) return "DIRECT";"#)
        XCTAssertNotNil(firstRule(result, .ipCIDR6, "fd00::/16"))
    }

    func testIsInNetNonContiguousMaskIsSkipped() {
        let result = convert(#"if (isInNet(host, "10.0.0.0", "255.0.255.0")) return "DIRECT";"#)
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("contiguous") })
    }

    // MARK: - Boolean composition

    func testOrCombinationExpandsIntoTwoRules() {
        let result = convert(#"if (shExpMatch(host, "*.a.com") || shExpMatch(host, "*.b.com")) return "PROXY p:1";"#)
        XCTAssertNotNil(firstRule(result, .domainSuffix, "a.com"))
        XCTAssertNotNil(firstRule(result, .domainSuffix, "b.com"))
        XCTAssertEqual(result.rules.count, 2)
    }

    func testAndConditionIsReportedAndSkipped() {
        let result = convert(#"if (shExpMatch(host, "*.a.com") && isInNet(host, "10.0.0.0", "255.0.0.0")) return "DIRECT";"#)
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("&&") })
    }

    func testNegatedConditionIsReportedAndSkipped() {
        let result = convert(#"if (!shExpMatch(host, "*.a.com")) return "DIRECT";"#)
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("Negated") })
    }

    func testIsPlainHostNameIsReportedAndSkipped() {
        let result = convert(#"if (isPlainHostName(host)) return "DIRECT";"#)
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("isPlainHostName") })
    }

    // MARK: - Return value → policy

    func testDirectReturnUsesBuiltinPolicy() {
        let result = convert(#"if (shExpMatch(host, "*.a.com")) return "DIRECT";"#)
        XCTAssertEqual(result.rules.first?.policy, "DIRECT")
        XCTAssertTrue(result.proxies.isEmpty)
    }

    func testProxyReturnCreatesHttpProxy() {
        let result = convert(#"if (shExpMatch(host, "*.a.com")) return "PROXY proxy.example.com:3128";"#)
        XCTAssertEqual(result.proxies.count, 1)
        XCTAssertEqual(result.proxies.first?.name, "proxy.example.com:3128")
        XCTAssertEqual(result.proxies.first?.type, .http)
    }

    func testSocksReturnCreatesSocksProxy() {
        let result = convert(#"if (shExpMatch(host, "*.a.com")) return "SOCKS5 10.0.0.5:1080";"#)
        XCTAssertEqual(result.proxies.first?.type, .socks5)
        XCTAssertEqual(result.proxies.first?.port, 1080)
    }

    func testHttpsReturnCreatesHttpsProxy() {
        let result = convert(#"if (shExpMatch(host, "*.a.com")) return "HTTPS secure.example.com:443";"#)
        XCTAssertEqual(result.proxies.first?.type, .https)
    }

    func testMultiProxyReturnCreatesFallbackGroup() {
        let result = convert(#"if (shExpMatch(host, "*.a.com")) return "PROXY a:1; PROXY b:2; DIRECT";"#)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.type, .fallback)
        XCTAssertEqual(result.groups.first?.policies, ["a:1", "b:2", "DIRECT"])
        XCTAssertEqual(result.rules.first?.policy, result.groups.first?.name)
        XCTAssertEqual(result.proxies.count, 2)
    }

    func testSameEndpointsReuseOneProxyAcrossRules() {
        let source = """
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.a.com")) return "PROXY p:8080";
            if (shExpMatch(host, "*.b.com")) return "PROXY p:8080";
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)
        XCTAssertEqual(result.proxies.count, 1)
        XCTAssertEqual(Set(result.rules.map(\.policy)), ["p:8080"])
    }

    // MARK: - Default branch

    func testDefaultReturnSetsFallbackPolicy() {
        let source = """
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.a.com")) return "DIRECT";
            return "PROXY main:8080";
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)
        XCTAssertEqual(result.fallbackPolicy, "main:8080")
    }

    func testElseReturnActsAsFallback() {
        let source = """
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.a.com")) { return "DIRECT"; } else { return "PROXY main:8080"; }
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)
        XCTAssertEqual(result.fallbackPolicy, "main:8080")
        XCTAssertEqual(result.rules.count, 1)
    }

    // MARK: - Dedup / existing policies

    func testFirstMatchWinsOnDuplicateMatch() {
        let source = """
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.a.com")) return "DIRECT";
            if (shExpMatch(host, "*.a.com")) return "PROXY p:1";
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules.first?.policy, "DIRECT")
        XCTAssertTrue(result.proxies.isEmpty)
    }

    func testExistingProxyIsReusedNotDuplicated() {
        let existing = ProxyDefinition(name: "Office", type: .http, host: "proxy.example.com", port: 3128)
        let result = PACRuleConverter.convert(
            pacSource: #"function F(url, host) { if (shExpMatch(host, "*.a.com")) return "PROXY proxy.example.com:3128"; }"#,
            existingProxies: [existing]
        )
        XCTAssertTrue(result.proxies.isEmpty)
        XCTAssertEqual(result.rules.first?.policy, "Office")
    }

    // MARK: - Comments & noise

    func testCommentsAndStringsAreHandled() {
        let source = """
        // line comment with an if (shExpMatch(host, "*.nope.com")) return "DIRECT";
        /* block comment
           if (shExpMatch(host, "*.nope2.com")) return "DIRECT";
        */
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.real.com")) return "DIRECT";
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertNotNil(firstRule(result, .domainSuffix, "real.com"))
    }

    // MARK: - Apply

    func testApplyInsertsBeforeFinalAndKeepsUserRules() {
        var profile = Profile(name: "T")
        let user = ProfileRule(type: .domain, value: "keep.example.com", policy: "DIRECT")
        profile.rules = [user, ProfileRule(type: .final, value: "", policy: "DIRECT")]

        let result = convert(#"if (shExpMatch(host, "*.a.com")) return "PROXY p:1";"#)
        let updated = PACRuleConverter.apply(result, to: profile)

        XCTAssertEqual(updated.rules.count, 3)
        XCTAssertEqual(updated.rules[0].value, "keep.example.com")
        XCTAssertEqual(updated.rules[1].value, "a.com")
        XCTAssertEqual(updated.rules.last?.type, .final)
        XCTAssertEqual(updated.proxies.count, 1)
    }

    func testApplySetsFinalPolicyFromFallback() {
        var profile = Profile(name: "T")
        profile.rules = [ProfileRule(type: .final, value: "", policy: "DIRECT")]

        let source = """
        function FindProxyForURL(url, host) {
            if (shExpMatch(host, "*.a.com")) return "DIRECT";
            return "PROXY main:8080";
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)
        let updated = PACRuleConverter.apply(result, to: profile)
        XCTAssertEqual(updated.rules.last?.type, .final)
        XCTAssertEqual(updated.rules.last?.policy, "main:8080")
    }

    func testApplyIsIdempotent() {
        var profile = Profile(name: "T")
        profile.rules = [ProfileRule(type: .final, value: "", policy: "DIRECT")]
        let result = convert(#"if (shExpMatch(host, "*.a.com")) return "PROXY p:1";"#)

        let once = PACRuleConverter.apply(result, to: profile)
        let twice = PACRuleConverter.apply(result, to: once)
        XCTAssertEqual(once.rules.count, twice.rules.count)
        XCTAssertEqual(once.proxies.count, twice.proxies.count)
    }

    func testAppliedProfileValidates() {
        var profile = Profile(name: "T")
        profile.rules = [ProfileRule(type: .final, value: "", policy: "DIRECT")]
        let source = """
        function FindProxyForURL(url, host) {
            if (dnsDomainIs(host, ".corp.example.com")) return "DIRECT";
            if (shExpMatch(host, "*.web.com")) return "PROXY p:8080";
            return "PROXY p:8080; DIRECT";
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)
        let updated = PACRuleConverter.apply(result, to: profile)
        XCTAssertEqual(updated.validate(), [])
    }

    // MARK: - End to end

    func testRealisticPACEndToEnd() {
        let source = """
        function FindProxyForURL(url, host) {
            if (isPlainHostName(host)) return "DIRECT";
            if (dnsDomainIs(host, ".corp.example.com")) return "DIRECT";
            if (shExpMatch(host, "*.internal.example.com")) return "DIRECT";
            if (isInNet(host, "10.0.0.0", "255.0.0.0")) return "DIRECT";
            if (isInNet(dnsResolve(host), "192.168.0.0", "255.255.0.0")) return "DIRECT";
            if (shExpMatch(host, "*.blocked.com")) return "PROXY 127.0.0.1:1";
            if (shExpMatch(host, "*.example.org") || dnsDomainIs(host, "example.net")) return "SOCKS5 10.0.0.5:1080";
            return "PROXY proxy.office.example.com:8080; DIRECT";
        }
        """
        let result = PACRuleConverter.convert(pacSource: source)

        XCTAssertNotNil(firstRule(result, .domainSuffix, "corp.example.com"))
        XCTAssertNotNil(firstRule(result, .domainSuffix, "internal.example.com"))
        XCTAssertNotNil(firstRule(result, .ipCIDR, "10.0.0.0/8"))
        XCTAssertNotNil(firstRule(result, .ipCIDR, "192.168.0.0/16"))
        XCTAssertNotNil(firstRule(result, .domainSuffix, "example.org"))
        XCTAssertNotNil(firstRule(result, .domainSuffix, "example.net"))

        // blocked.com → dedicated http proxy; example.org/net → shared socks5.
        XCTAssertTrue(result.proxies.contains { $0.host == "127.0.0.1" && $0.port == 1 && $0.type == .http })
        XCTAssertTrue(result.proxies.contains { $0.host == "10.0.0.5" && $0.port == 1080 && $0.type == .socks5 })

        // Default fallback group over the office proxy + DIRECT.
        XCTAssertEqual(result.fallbackPolicy, "PAC Fallback")
        XCTAssertEqual(result.groups.first?.policies, ["proxy.office.example.com:8080", "DIRECT"])

        // The skipped isPlainHostName branch is surfaced, not silent.
        XCTAssertTrue(result.diagnostics.contains { $0.contains("isPlainHostName") })
    }
}
