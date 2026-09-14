import XCTest
@testable import TurtleDiverCore

final class ProfileParserTests: XCTestCase {

    // MARK: - General

    func testGeneralSectionParsing() throws {
        let text = """
        [General]
        http-listen = 127.0.0.1:6152
        socks5-listen = 127.0.0.1:6153
        test-url = http://cp.cloudflare.com/generate_204
        test-timeout = 5
        test-interval = 600
        system-proxy = true
        skip-proxy = 127.0.0.1, 192.168.0.0/16, 10.0.0.0/8
        loglevel = debug
        """
        let result = ProfileParser.parse(text, name: "Test")
        XCTAssertFalse(result.hasErrors, "Diagnostics: \(result.diagnostics)")

        let g = result.profile.general
        XCTAssertEqual(g.httpListen, "127.0.0.1:6152")
        XCTAssertEqual(g.socks5Listen, "127.0.0.1:6153")
        XCTAssertEqual(g.testURL, "http://cp.cloudflare.com/generate_204")
        XCTAssertEqual(g.testTimeout, 5)
        XCTAssertEqual(g.testInterval, 600)
        XCTAssertTrue(g.systemProxy)
        XCTAssertEqual(g.skipProxy, ["127.0.0.1", "192.168.0.0/16", "10.0.0.0/8"])
        XCTAssertEqual(g.logLevel, "debug")
    }

    func testGeneralDefaultsWhenEmpty() {
        let result = ProfileParser.parse("[General]\n", name: "Test")
        XCTAssertEqual(result.profile.general, GeneralSettings())
    }

    func testUnknownGeneralOptionWarns() {
        let result = ProfileParser.parse("[General]\nunknown-option = 1\n", name: "Test")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("unknown-option") })
    }

    // MARK: - Proxy

    func testProxyHTTPParsing() throws {
        let result = ProfileParser.parse(
            "[Proxy]\nCorp = http, proxy.corp.com, 8080, username=alice, password=s3cret\n",
            name: "Test"
        )
        XCTAssertFalse(result.hasErrors, "\(result.diagnostics)")
        XCTAssertEqual(result.profile.proxies.count, 1)
        let proxy = try XCTUnwrap(result.profile.proxies.first)
        XCTAssertEqual(proxy.name, "Corp")
        XCTAssertEqual(proxy.type, .http)
        XCTAssertEqual(proxy.host, "proxy.corp.com")
        XCTAssertEqual(proxy.port, 8080)
        XCTAssertEqual(proxy.username, "alice")
        XCTAssertEqual(proxy.password, "s3cret")
        XCTAssertFalse(proxy.tls)
        XCTAssertFalse(proxy.skipCertVerify)
    }

    func testProxyHTTPSImpliesTLS() throws {
        let result = ProfileParser.parse("[Proxy]\nS = https, p.example.com, 443\n", name: "Test")
        let proxy = try XCTUnwrap(result.profile.proxies.first)
        XCTAssertEqual(proxy.type, .https)
        XCTAssertTrue(proxy.tls, "https type must imply tls=true")
    }

    func testProxySOCKS5() throws {
        let result = ProfileParser.parse("[Proxy]\nS = socks5, 10.0.0.1, 1080\n", name: "Test")
        let proxy = try XCTUnwrap(result.profile.proxies.first)
        XCTAssertEqual(proxy.type, .socks5)
        XCTAssertEqual(proxy.host, "10.0.0.1")
        XCTAssertEqual(proxy.port, 1080)
        XCTAssertNil(proxy.username)
    }

    func testProxyExplicitTLSFlag() throws {
        let result = ProfileParser.parse("[Proxy]\nT = http, p.example.com, 80, tls=true, skip-cert-verify=true\n", name: "Test")
        let proxy = try XCTUnwrap(result.profile.proxies.first)
        XCTAssertTrue(proxy.tls)
        XCTAssertTrue(proxy.skipCertVerify)
    }

    func testProxyInvalidPortReportsDiagnostic() {
        let result = ProfileParser.parse("[Proxy]\nBad = http, p.example.com, 99999\n", name: "Test")
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.diagnostics.first?.message.contains("invalid port") == true)
    }

    func testProxyUnknownTypeReportsDiagnostic() {
        let result = ProfileParser.parse("[Proxy]\nBad = ss, p.example.com, 8388\n", name: "Test")
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.diagnostics.first?.message.contains("unknown type") == true)
    }

    func testProxyDuplicateNameWarnsAndLaterWins() throws {
        let result = ProfileParser.parse(
            """
            [Proxy]
            A = http, one.example.com, 8080
            A = http, two.example.com, 9090
            """,
            name: "Test"
        )
        XCTAssertEqual(result.profile.proxies.count, 1)
        XCTAssertEqual(result.profile.proxies.first?.host, "two.example.com")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("Duplicate proxy name") })
    }

    // MARK: - Groups

    func testGroupSelectParsing() throws {
        let result = ProfileParser.parse(
            "[Proxy Group]\nPick = select, Corp, DIRECT\n",
            name: "Test"
        )
        XCTAssertFalse(result.hasErrors, "\(result.diagnostics)")
        let group = try XCTUnwrap(result.profile.groups.first)
        XCTAssertEqual(group.name, "Pick")
        XCTAssertEqual(group.type, .select)
        XCTAssertEqual(group.policies, ["Corp", "DIRECT"])
    }

    func testGroupURLTestWithParams() throws {
        let result = ProfileParser.parse(
            "[Proxy Group]\nAuto = url-test, A, B, url=http://cp.cloudflare.com/generate_204, interval=300\n",
            name: "Test"
        )
        let group = try XCTUnwrap(result.profile.groups.first)
        XCTAssertEqual(group.type, .urlTest)
        XCTAssertEqual(group.policies, ["A", "B"])
        XCTAssertEqual(group.testURL, "http://cp.cloudflare.com/generate_204")
        XCTAssertEqual(group.interval, 300)
    }

    func testGroupUnknownTypeReportsDiagnostic() {
        let result = ProfileParser.parse("[Proxy Group]\nBad = smart, A, B\n", name: "Test")
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.diagnostics.first?.message.contains("unknown type") == true)
    }

    func testGroupEmptyMembershipReportsDiagnostic() {
        let result = ProfileParser.parse("[Proxy Group]\nEmpty = select\n", name: "Test")
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.diagnostics.first?.message.contains("no member policies") == true)
    }

    // MARK: - Rules

    func testRuleParsingAllCommonTypes() throws {
        let text = """
        [Rule]
        DOMAIN,exact.example.com,DIRECT
        DOMAIN-SUFFIX,apple.com,ProxyUS
        DOMAIN-KEYWORD,github,ProxyUS
        IP-CIDR,10.0.0.0/8,Corp,no-resolve
        IP-CIDR6,fd00::/8,Corp
        DEST-PORT,443,ProxyTLS
        PROCESS-NAME,ssh,DIRECT
        USER-AGENT,curl*,DIRECT
        URL-REGEX,^https?://ads\\.,REJECT
        FINAL,ProxyUS
        """
        let result = ProfileParser.parse(text, name: "Test")
        XCTAssertFalse(result.hasErrors, "\(result.diagnostics)")

        let rules = result.profile.rules
        XCTAssertEqual(rules.count, 10)
        XCTAssertEqual(rules[0].type, .domain)
        XCTAssertEqual(rules[0].value, "exact.example.com")
        XCTAssertEqual(rules[0].policy, "DIRECT")
        XCTAssertEqual(rules[3].type, .ipCIDR)
        XCTAssertEqual(rules[3].noResolve, true)
        XCTAssertEqual(rules[4].type, .ipCIDR6)
        XCTAssertEqual(rules[4].noResolve, false)
        XCTAssertEqual(rules[9].type, .final)
        XCTAssertEqual(rules[9].policy, "ProxyUS")
        XCTAssertEqual(rules[9].value, "")
    }

    func testRuleTypeCaseInsensitive() throws {
        let result = ProfileParser.parse("[Rule]\ndomain-suffix,example.com,DIRECT\n", name: "Test")
        XCTAssertEqual(try XCTUnwrap(result.profile.rules.first).type, .domainSuffix)
    }

    func testRuleMissingPolicyReportsDiagnostic() {
        let result = ProfileParser.parse("[Rule]\nDOMAIN-SUFFIX,example.com\n", name: "Test")
        XCTAssertTrue(result.hasErrors)
    }

    func testRuleUnknownTypeReportsDiagnostic() {
        let result = ProfileParser.parse("[Rule]\nNOT-A-TYPE,x,DIRECT\n", name: "Test")
        XCTAssertTrue(result.hasErrors)
    }

    func testRuleInvalidCIDRWarns() {
        let result = ProfileParser.parse("[Rule]\nIP-CIDR,notacidr,DIRECT\n", name: "Test")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("CIDR") })
    }

    func testRuleGEOIPWarnsReserved() {
        let result = ProfileParser.parse("[Rule]\nGEOIP,CN,ProxyCN\n", name: "Test")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("GEOIP") })
    }

    func testFinalNotLastWarns() {
        let result = ProfileParser.parse(
            "[Rule]\nFINAL,DIRECT\nDOMAIN-SUFFIX,example.com,DIRECT\n",
            name: "Test"
        )
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("FINAL") })
    }

    // MARK: - Robustness

    func testCommentsAndBlankLinesIgnored() {
        let text = """
        # Full line comment
        ; Semicolon comment

        [General]  ; trailing comment

        [Rule]
        DOMAIN-SUFFIX,example.com,DIRECT ; trailing comment
        """
        let result = ProfileParser.parse(text, name: "Test")
        XCTAssertEqual(result.profile.rules.count, 1)
        XCTAssertTrue(result.profile.general == GeneralSettings())
    }

    func testLineOutsideSectionIsError() {
        let result = ProfileParser.parse("stray = line\n", name: "Test")
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.diagnostics.first?.message.contains("outside any section") == true)
    }

    func testUnknownSectionIgnoredWithWarning() {
        let result = ProfileParser.parse("[Host]\nsomething = 1\n", name: "Test")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("Unknown section") })
        XCTAssertTrue(result.profile.proxies.isEmpty)
    }

    func testCommasInsideQuotesPreserved() throws {
        // URL params contain commas inside quotes.
        let result = ProfileParser.parse(
            "[Proxy Group]\nG = url-test, A, url=\"http://x/?a=1,b\"\n",
            name: "Test"
        )
        let group = try XCTUnwrap(result.profile.groups.first)
        XCTAssertEqual(group.testURL, "http://x/?a=1,b")
    }

    func testHashInsideQuotesNotComment() throws {
        let result = ProfileParser.parse("[Proxy]\nP = http, host, 8080, password=\"ab#cd\"\n", name: "Test")
        let proxy = try XCTUnwrap(result.profile.proxies.first)
        XCTAssertEqual(proxy.password, "ab#cd")
    }

    func testDuplicateGeneralSectionMerges() throws {
        let text = """
        [General]
        loglevel = debug
        [General]
        http-listen = 127.0.0.1:9999
        """
        let result = ProfileParser.parse(text, name: "Test")
        XCTAssertEqual(result.profile.general.logLevel, "debug")
        XCTAssertEqual(result.profile.general.httpListen, "127.0.0.1:9999")
        XCTAssertTrue(result.diagnostics.contains { $0.severity == .warning && $0.message.contains("Duplicate [General]") })
    }
}
