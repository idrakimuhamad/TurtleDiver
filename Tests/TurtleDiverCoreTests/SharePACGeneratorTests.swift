import XCTest
import CryptoKit
@testable import TurtleDiverCore
@testable import TurtleDiverRules

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

/// The PAC file a shared device fetches. The generator is pure, so every case
/// here runs the real JavaScript through JavaScriptCore and asserts the string
/// the phone would get — not the Swift model behind it.
final class SharePACGeneratorTests: XCTestCase {

    // MARK: - Harness

    private func pac(
        host: String = "192.168.1.20",
        port: Int = 6152,
        mode: SharePACGenerator.TunnelMode = .split(targets: ["unrelated.corp.example.com"]),
        rules: [SharePACGenerator.Rule] = [],
        finalUsesProxy: Bool = false
    ) -> String {
        SharePACGenerator.pac(SharePACGenerator.Configuration(
            proxyHost: host,
            proxyPort: port,
            mode: mode,
            rules: rules,
            finalUsesProxy: finalUsesProxy
        ))
    }

    private func rule(_ kind: SharePACGenerator.Rule.Kind, _ value: String, proxy: Bool) -> SharePACGenerator.Rule {
        SharePACGenerator.Rule(kind: kind, value: value, usesProxy: proxy)
    }

    /// Evaluates the generated PAC exactly as a client would. The context has
    /// no `dnsResolve`, so a PAC that calls it fails the test with a script
    /// error.
    private func resolve(
        _ document: String,
        host: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        #if canImport(JavaScriptCore)
        guard let context = JSContext() else {
            XCTFail("could not create a JSContext", file: file, line: line)
            return ""
        }
        var exception: String?
        context.exceptionHandler = { _, error in exception = error?.toString() }
        XCTAssertFalse(document.contains("dnsResolve"),
                       "the PAC must not depend on the phone's DNS", file: file, line: line)
        context.evaluateScript(document)
        guard let function = context.objectForKeyedSubscript("FindProxyForURL") else {
            XCTFail("the PAC has no FindProxyForURL", file: file, line: line)
            return ""
        }
        let result = function.call(withArguments: ["http://\(host)/", host])
        if let exception {
            XCTFail("PAC threw for \(host): \(exception)", file: file, line: line)
        }
        return result?.toString() ?? ""
        #else
        XCTFail("JavaScriptCore is unavailable", file: file, line: line)
        return ""
        #endif
    }

    /// A resolver that answers from a fixed table, for differential tests
    /// against the real `RuleMatcher`.
    private final class FixedDNS: DNSResolving, @unchecked Sendable {
        private let table: [String: [String]]

        init(_ table: [String: [String]]) {
            self.table = Dictionary(uniqueKeysWithValues: table.map { ($0.key.lowercased(), $0.value) })
        }

        func resolve(host: String) -> [IPAddress] {
            (table[host.lowercased()] ?? []).compactMap { IPAddress.parse($0) }
        }
    }

    private let proxy = "PROXY 192.168.1.20:6152"

    // MARK: - Token and URL

    func testTokenIsTheFirst24HexOfAPrefixedSHA256() {
        let password = "secret-password"
        let digest = SHA256.hash(data: Data("turtlediver-pac:\(password)".utf8))
        let expected = digest.map { String(format: "%02x", $0) }.joined().prefix(24)

        XCTAssertEqual(SharePACGenerator.token(password: password), String(expected))
        XCTAssertEqual(SharePACGenerator.token(password: password).count, 24)
        XCTAssertNotEqual(SharePACGenerator.token(password: "one"),
                          SharePACGenerator.token(password: "two"))
    }

    func testPACURLIsBuiltFromHostPortAndToken() {
        let url = SharePACGenerator.pacURL(host: "10.0.0.5", port: 6152, password: "pw")
        XCTAssertEqual(url, "http://10.0.0.5:6152/\(SharePACGenerator.token(password: "pw"))/proxy.pac")
    }

    // MARK: - Basic decisions

    /// Plain hosts and `localhost` are not special-cased: the Mac evaluates
    /// them against the rules, so the PAC does too.
    func testPlainHostnamesAreEvaluatedLikeAnyOtherHost() {
        let document = pac(
            rules: [rule(.domain, "intranet", proxy: true)],
            finalUsesProxy: false
        )
        XCTAssertEqual(resolve(document, host: "intranet"), proxy)
        XCTAssertEqual(resolve(document, host: "router"), "DIRECT")
        XCTAssertEqual(resolve(document, host: "localhost"), "DIRECT")

        let proxiedFinal = pac(finalUsesProxy: true)
        XCTAssertEqual(resolve(proxiedFinal, host: "localhost"), proxy)
    }

    func testFullTunnelSendsEverythingToTheProxy() {
        let document = pac(mode: .fullTunnel, rules: [], finalUsesProxy: false)
        XCTAssertEqual(resolve(document, host: "example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "10.1.2.3"), proxy)
        XCTAssertFalse(document.contains("dnsResolve"))
        XCTAssertFalse(document.contains("isInNet"))
    }

    /// A split list with nothing usable is the same routing as a full tunnel.
    func testEmptyOrInvalidSplitListBehavesAsFullTunnel() {
        for mode in [SharePACGenerator.TunnelMode.split(targets: []),
                     .split(targets: ["not a target", "300.1.2.3/8"])] {
            let document = pac(mode: mode, rules: [
                rule(.domain, "direct.example.com", proxy: false),
            ])
            XCTAssertEqual(resolve(document, host: "example.com"), proxy, "\(mode)")
            XCTAssertEqual(resolve(document, host: "direct.example.com"), proxy, "\(mode)")
        }
    }

    func testFinalDirectAndFinalProxy() {
        XCTAssertEqual(resolve(pac(finalUsesProxy: false), host: "example.com"), "DIRECT")
        XCTAssertEqual(resolve(pac(finalUsesProxy: true), host: "example.com"), proxy)
    }

    func testRulePoliciesMapToDirectOrProxy() {
        let document = pac(rules: [
            rule(.domain, "direct.example.com", proxy: false),
            rule(.domain, "reject.example.com", proxy: true), // REJECT also goes to the Mac
        ])
        XCTAssertEqual(resolve(document, host: "direct.example.com"), "DIRECT")
        XCTAssertEqual(resolve(document, host: "reject.example.com"), proxy)
    }

    // MARK: - Full tunnel detection

    func testResolvedModeTreatsStandardVpnAndEmptySplitListsAsFullTunnel() {
        XCTAssertEqual(
            SharePACGenerator.resolvedMode(useTunneling: false, targets: ["vpn.example.com"]),
            .fullTunnel,
            "Standard VPN carries everything even if a stale split list is saved"
        )
        XCTAssertEqual(
            SharePACGenerator.resolvedMode(useTunneling: true, targets: []),
            .fullTunnel
        )
        XCTAssertEqual(
            SharePACGenerator.resolvedMode(useTunneling: true, targets: ["not a target", "300.1.2.3/8"]),
            .fullTunnel,
            "a list of junk narrows nothing"
        )
        XCTAssertEqual(
            SharePACGenerator.resolvedMode(useTunneling: true, targets: ["not-an-ip:garbage"]),
            .fullTunnel,
            "a colon does not make an IPv6 target; a bad one must not split the tunnel"
        )
        XCTAssertEqual(
            SharePACGenerator.resolvedMode(useTunneling: true, targets: ["vpn.example.com"]),
            .split(targets: ["vpn.example.com"])
        )
        XCTAssertEqual(
            SharePACGenerator.resolvedMode(useTunneling: true, targets: ["10.0.0.0/8", "fd00::/8"]),
            .split(targets: ["10.0.0.0/8", "fd00::/8"])
        )
    }

    // MARK: - Rule kinds and ordering

    func testFirstMatchingRuleWins() {
        let document = pac(
            rules: [
                rule(.domainSuffix, "example.com", proxy: true),
                rule(.domainKeyword, "example", proxy: false),
            ],
            finalUsesProxy: false
        )
        XCTAssertEqual(resolve(document, host: "www.example.com"), proxy)
    }

    func testDomainSuffixRespectsTheLabelBoundaryAndKeepsTrailingDots() {
        let document = pac(rules: [rule(.domainSuffix, "example.com", proxy: true)])
        XCTAssertEqual(resolve(document, host: "example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "www.example.com"), proxy)
        // `RuleMatcher` lowercases but does not strip a trailing root dot, so
        // `example.com.` must not match an `example.com` suffix.
        XCTAssertEqual(resolve(document, host: "EXAMPLE.COM."), "DIRECT")
        XCTAssertEqual(resolve(document, host: "evil-example.com"), "DIRECT")
        XCTAssertEqual(resolve(document, host: "notexample.com"), "DIRECT")
    }

    func testDomainIsExactAndCaseInsensitive() {
        let document = pac(rules: [rule(.domain, "example.com", proxy: true)])
        XCTAssertEqual(resolve(document, host: "example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "Example.Com"), proxy)
        XCTAssertEqual(resolve(document, host: "Example.Com."), "DIRECT", "RuleMatcher does not strip the dot")
        XCTAssertEqual(resolve(document, host: "www.example.com"), "DIRECT")
    }

    func testDomainKeywordIsASubstring() {
        let document = pac(rules: [rule(.domainKeyword, "tracker", proxy: true)])
        XCTAssertEqual(resolve(document, host: "ads.tracker.example.net"), proxy)
        XCTAssertEqual(resolve(document, host: "example.net"), "DIRECT")
    }

    func testIPv4CIDRRuleSendsHostnamesToTheProxy() {
        let document = pac(rules: [rule(.ipCIDR, "10.0.0.0/8", proxy: true)])

        XCTAssertEqual(resolve(document, host: "10.1.2.3"), proxy)
        XCTAssertEqual(resolve(document, host: "10.255.255.255"), proxy)
        XCTAssertEqual(resolve(document, host: "11.0.0.1"), "DIRECT")
        // The phone cannot know whether a name lands in the block (the Mac's
        // VPN DNS may differ), so it goes to the Mac.
        XCTAssertEqual(resolve(document, host: "ten.example.com"), proxy)
        XCTAssertFalse(document.contains("dnsResolve"))
        XCTAssertFalse(document.contains("isInNet"))
    }

    /// A resolving rule terminates a hostname even when it is DIRECT: its own
    /// outcome plus everything after it decides. With no later non-DIRECT rule
    /// the answer is safe as DIRECT; with a later REJECT it must be PROXY.
    func testResolvingCIDRRuleEvaluatesTheRestOfTheRules() {
        let allDirect = pac(rules: [rule(.ipCIDR, "10.0.0.0/8", proxy: false)], finalUsesProxy: false)
        XCTAssertEqual(resolve(allDirect, host: "ten.example.com"), "DIRECT")

        let laterReject = pac(
            rules: [
                rule(.ipCIDR, "10.0.0.0/8", proxy: false),
                rule(.domainKeyword, "ten", proxy: true),
            ],
            finalUsesProxy: false
        )
        XCTAssertEqual(resolve(laterReject, host: "ten.example.com"), proxy)

        let laterFinalReject = pac(
            rules: [rule(.ipCIDR, "10.0.0.0/8", proxy: false)],
            finalUsesProxy: true
        )
        XCTAssertEqual(resolve(laterFinalReject, host: "ten.example.com"), proxy)
    }

    /// `no-resolve` rules never touch a hostname before a resolving rule.
    func testNoResolveCIDRRuleIsLiteralOnly() {
        let document = pac(rules: [
            SharePACGenerator.Rule(kind: .ipCIDR, value: "10.0.0.0/8", usesProxy: true, noResolve: true),
        ])
        XCTAssertFalse(document.contains("dnsResolve"))
        XCTAssertEqual(resolve(document, host: "10.1.2.3"), proxy)
        XCTAssertEqual(
            resolve(document, host: "ten.example.com"),
            "DIRECT",
            "no-resolve means the Mac skips the rule for a hostname, so the PAC must too"
        )
    }

    func testIPv4CIDRZeroPrefixAndFullPrefix() {
        let all = pac(rules: [rule(.ipCIDR, "0.0.0.0/0", proxy: true)])
        XCTAssertEqual(resolve(all, host: "203.0.113.9"), proxy)

        let one = pac(rules: [rule(.ipCIDR, "203.0.113.9/32", proxy: true)])
        XCTAssertEqual(resolve(one, host: "203.0.113.9"), proxy)
        XCTAssertEqual(resolve(one, host: "203.0.113.10"), "DIRECT")
    }

    /// IPv6 literals (including IPv4-mapped ones) always go to the Mac: a
    /// v4-mapped address would otherwise evade IPv4 rules, and the PAC does
    /// not evaluate IPv6.
    func testIPv6LiteralsAlwaysGoToTheProxy() {
        let document = pac(
            mode: .split(targets: ["unrelated.corp.example.com"]),
            rules: [rule(.domainSuffix, "corp.example.com", proxy: true)],
            finalUsesProxy: false
        )
        XCTAssertEqual(resolve(document, host: "2001:db8::1"), proxy)
        XCTAssertEqual(resolve(document, host: "::ffff:10.1.2.3"), proxy)
    }

    /// An IPv6 VPN target makes every hostname address-dependent too.
    func testIPv6VPNTargetSendsIPv6LiteralsAndHostnamesToTheProxy() {
        let document = pac(mode: .split(targets: ["fd00::/8", "unrelated.corp.example.com"]))
        XCTAssertEqual(resolve(document, host: "fd00::1"), proxy)
        XCTAssertEqual(resolve(document, host: "2001:db8::1"), proxy)
        XCTAssertEqual(resolve(document, host: "example.com"), proxy)
    }

    // MARK: - VPN targets

    func testVPNTargetsWinOverAProfileDirectRule() {
        let document = pac(
            mode: .split(targets: ["vpn.corp.example.com"]),
            rules: [rule(.domain, "vpn.corp.example.com", proxy: false)],
            finalUsesProxy: false
        )
        XCTAssertEqual(resolve(document, host: "vpn.corp.example.com"), proxy)
    }

    /// A single-label target is matched before any rule evaluation.
    func testSingleLabelVPNTargetMatchesBeforeRules() {
        let document = pac(mode: .split(targets: ["Intranet."]))
        XCTAssertEqual(resolve(document, host: "intranet"), proxy)
        XCTAssertEqual(resolve(document, host: "INTRANET."), proxy)
        XCTAssertEqual(resolve(document, host: "router"), "DIRECT")
    }

    func testVPNTargetShapes() {
        let document = pac(
            mode: .split(targets: [
                "vpn.corp.example.com",
                "*.apps.example.com",
                "10.20.0.0/16",
                "192.168.50.7",
            ]),
            finalUsesProxy: false
        )
        XCTAssertEqual(resolve(document, host: "vpn.corp.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "api.apps.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "apps.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "10.20.9.9"), proxy)
        XCTAssertEqual(resolve(document, host: "192.168.50.7"), proxy)
        XCTAssertEqual(resolve(document, host: "10.21.9.9"), "DIRECT")
        // An address target makes every hostname address-dependent, so even a
        // name outside the suffix goes to the Mac.
        XCTAssertEqual(resolve(document, host: "evil-apps.example.com"), proxy)
    }

    /// Case is normalized before values reach the JavaScript; rule dots are
    /// not, because `RuleMatcher` does not strip them.
    func testRuleAndTargetValuesAreNormalized() {
        let document = pac(
            mode: .split(targets: ["VPN.Corp.Example.COM."]),
            rules: [
                rule(.domain, "Direct.Example.COM", proxy: false),
                rule(.domainSuffix, "Suffix.Example.COM", proxy: true),
                rule(.domainKeyword, "KeyWord", proxy: true),
            ],
            finalUsesProxy: false
        )
        XCTAssertEqual(resolve(document, host: "vpn.corp.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "direct.example.com"), "DIRECT")
        XCTAssertEqual(resolve(document, host: "a.SUFFIX.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "has-keyword.example.net"), proxy)
        XCTAssertFalse(document.contains("Direct.Example"), document)
        XCTAssertFalse(document.contains("VPN.Corp"), document)
    }

    /// `DOMAIN-KEYWORD,corp.,DIRECT` must not be turned into `corp` — that
    /// would match `evilcorpx.example` and turn a REJECT into DIRECT.
    func testKeywordTrailingDotIsNotStripped() {
        let document = pac(
            rules: [rule(.domainKeyword, "corp.", proxy: false)],
            finalUsesProxy: true
        )
        XCTAssertEqual(resolve(document, host: "evilcorpx.example"), proxy)
        XCTAssertEqual(resolve(document, host: "host.corp.example"), "DIRECT")
    }

    /// With an address target, every hostname goes to the Mac: the phone's
    /// resolver is not evidence of the Mac's VPN DNS (split horizon).
    func testNetworkTargetSendsEveryHostnameToTheProxy() {
        let document = pac(mode: .split(targets: ["10.20.0.0/16"]), finalUsesProxy: false)
        XCTAssertFalse(document.contains("dnsResolve"))
        XCTAssertEqual(resolve(document, host: "vpn.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "public.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "unresolvable.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "10.20.5.5"), proxy)
        XCTAssertEqual(resolve(document, host: "203.0.113.5"), "DIRECT")
    }

    /// The same applies to single-label names, which are not shortcut to
    /// DIRECT: a target such as `10.20.0.0/16` can contain an intranet name.
    func testAddressTargetPrecedesTheRules() {
        let document = pac(mode: .split(targets: ["10.20.0.0/16"]))
        XCTAssertEqual(resolve(document, host: "intranet"), proxy)
        XCTAssertEqual(resolve(document, host: "router"), proxy)
    }

    /// Only address targets force DNS: a pure hostname split profile stays
    /// DNS-free.
    func testPureHostnameProfileEmitsNoDNS() {
        let document = pac(
            mode: .split(targets: ["vpn.corp.example.com"]),
            rules: [rule(.domain, "other.example.com", proxy: true)]
        )
        XCTAssertFalse(document.contains("dnsResolve"))
    }

    // MARK: - Injection safety

    func testHostileRuleValuesCannotBreakOutOfTheirLiteral() {
        let hostile = "a\"});alert(1)//.example.com"
        let document = pac(
            rules: [
                rule(.domain, hostile, proxy: true),
                rule(.domainKeyword, "line\u{2028}break", proxy: true),
                rule(.domainSuffix, "back\\slash.example.com", proxy: true),
            ],
            finalUsesProxy: false
        )

        // The whole document still parses and runs; the hostile value is data.
        XCTAssertEqual(resolve(document, host: "example.com"), "DIRECT")
        XCTAssertEqual(resolve(document, host: hostile.lowercased()), proxy)
        XCTAssertTrue(document.contains(#"a\"});alert(1)//"#), "the value must stay escaped inside its literal")
        XCTAssertFalse(document.contains(#""a"});alert(1)//.example.com"#), "the literal must not be closed early")
    }

    func testUnsupportedNonDirectRuleStopsTheScan() {
        let profileRules = [
            ProfileRule(type: .destPort, value: "443", policy: "REJECT"),
            ProfileRule(type: .domain, value: "later.example.com", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        let pacRules = SharePACGenerator.rules(from: profileRules) { $0.uppercased() == "DIRECT" }
        XCTAssertEqual(pacRules.map(\.kind), [.barrier, .domain, .barrier])

        let document = pac(rules: pacRules, finalUsesProxy: false)
        // A host the later DIRECT rule would have matched still goes to the
        // Mac: the phone cannot evaluate DEST-PORT, and the Mac may reject 443.
        XCTAssertEqual(resolve(document, host: "later.example.com"), proxy)
        XCTAssertEqual(resolve(document, host: "example.net"), proxy)
    }

    func testUnsupportedDirectRuleIsDropped() {
        let profileRules = [
            ProfileRule(type: .destPort, value: "443", policy: "DIRECT"),
            ProfileRule(type: .domain, value: "kept.example.com", policy: "PROXY"),
        ]
        let pacRules = SharePACGenerator.rules(from: profileRules) { $0.uppercased() == "DIRECT" }
        XCTAssertEqual(pacRules.map(\.kind), [.domain])

        let document = pac(rules: pacRules, finalUsesProxy: false)
        XCTAssertEqual(resolve(document, host: "unrelated.example.com"), "DIRECT")
        XCTAssertEqual(resolve(document, host: "kept.example.com"), proxy)
    }

    /// A group may pick any member, so it is DIRECT only when every member is.
    func testGroupEffectIsDirectOnlyWhenEveryMemberIs() {
        var profile = Profile(name: "effects")
        profile.proxies = [ProxyDefinition(name: "upstream", type: .http, host: "10.0.0.9", port: 8080)]
        profile.groups = [
            ProxyGroup(name: "all-direct", type: .select, policies: ["DIRECT", "DIRECT"]),
            ProxyGroup(name: "mixed", type: .select, policies: ["DIRECT", "upstream"]),
            ProxyGroup(name: "loop-a", type: .select, policies: ["loop-b"]),
            ProxyGroup(name: "loop-b", type: .select, policies: ["loop-a"]),
        ]
        let store = PolicyStore(profile: profile, defaults: nil, autoStartTesting: false)

        XCTAssertEqual(store.effect(of: "DIRECT"), .direct)
        XCTAssertEqual(store.effect(of: "direct"), .direct)
        XCTAssertEqual(store.effect(of: "REJECT"), .nonDirect)
        XCTAssertEqual(store.effect(of: "upstream"), .nonDirect)
        XCTAssertEqual(store.effect(of: "all-direct"), .direct)
        XCTAssertEqual(store.effect(of: "mixed"), .nonDirect)
        XCTAssertEqual(store.effect(of: "loop-a"), .nonDirect)
        XCTAssertEqual(store.effect(of: "missing"), .nonDirect)
    }

    /// Classification feeds `rules(from:)`, and only DIRECT outcomes may be
    /// dropped; a REJECT final still sends the phone to the Mac.
    func testFinalRejectSendsEverythingToTheProxy() {
        let document = pac(rules: [], finalUsesProxy: true)
        XCTAssertEqual(resolve(document, host: "example.com"), proxy)
    }

    /// The barrier is not invented policy: on a port rule the real matcher
    /// rejects what the PAC sends to the Mac, and the PAC never sends a host
    /// DIRECT where the matcher would have rejected or proxied it.
    func testBarrierAgreesWithTheRealMatcherOnAPortRule() throws {
        var profile = Profile(name: "compare")
        profile.rules = [
            ProfileRule(type: .destPort, value: "443", policy: "REJECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ]
        let matcher = RuleMatcher(profile: profile)
        XCTAssertEqual(try matcher.match(MatchContext(host: "example.com", port: 443)).policy, "REJECT")
        XCTAssertEqual(try matcher.match(MatchContext(host: "example.com", port: 80)).policy, "DIRECT")

        let pacRules = SharePACGenerator.rules(from: matcher.expandedRules) { $0 == "DIRECT" }
        let document = pac(rules: pacRules, finalUsesProxy: false)
        XCTAssertEqual(resolve(document, host: "example.com"), proxy,
                       "the port rule cannot be evaluated, so the Mac decides")
    }

    /// The PAC may be conservative (PROXY where the Mac would go DIRECT), but
    /// it must never be more direct than the Mac: a host the matcher rejects or
    /// proxies has to reach the Mac.
    private func assertNeverMoreDirect(
        _ profileRules: [ProfileRule],
        hosts: [String],
        dns: [String: [String]] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        var profile = Profile(name: "differential")
        profile.rules = profileRules
        let matcher = RuleMatcher(profile: profile, resolver: FixedDNS(dns))
        let pacRules = SharePACGenerator.rules(from: matcher.expandedRules) { $0 == "DIRECT" }
        let document = pac(
            rules: pacRules,
            finalUsesProxy: matcher.defaultPolicyName != "DIRECT"
        )

        for host in hosts {
            let outcome = try matcher.match(MatchContext(host: host)).policy
            let result = resolve(document, host: host, file: file, line: line)
            if outcome != "DIRECT" {
                XCTAssertEqual(
                    result, proxy,
                    "PAC sent \(host) DIRECT but the matcher says \(outcome)",
                    file: file, line: line
                )
            }
            if result == "DIRECT" {
                XCTAssertEqual(
                    outcome, "DIRECT",
                    "PAC sent \(host) DIRECT but the matcher says \(outcome)",
                    file: file, line: line
                )
            }
        }
    }

    /// A hostname reaching an address-bearing split target goes to the Mac;
    /// the phone's DNS (which may be split-horizon) is never consulted.
    func testSplitHorizonHostnameGoesToTheProxy() {
        let document = pac(mode: .split(targets: ["10.42.0.0/16"]))
        XCTAssertFalse(document.contains("dnsResolve"))
        // The Mac would resolve this via VPN DNS to 10.42.1.2; a phone might
        // see 203.0.113.5. Either way the PAC cannot decide, so it proxies.
        XCTAssertEqual(resolve(document, host: "corp.example.com"), proxy)
    }

    /// A table of profiles where normalization or DNS could have made the PAC
    /// disagree with the engine in the unsafe direction.
    func testPACIsNeverMoreDirectThanTheRealMatcher() throws {
        let finalReject = ProfileRule(type: .final, value: "", policy: "REJECT")
        let finalDirect = ProfileRule(type: .final, value: "", policy: "DIRECT")

        // DOMAIN-KEYWORD with a trailing dot: the old normalization stripped
        // it and matched `evilcorpx.example` to a DIRECT rule.
        try assertNeverMoreDirect(
            [ProfileRule(type: .domainKeyword, value: "corp.", policy: "DIRECT"), finalReject],
            hosts: ["evilcorpx.example", "host.corp.example"]
        )

        // DOMAIN and DOMAIN-SUFFIX with a trailing dot on either side.
        try assertNeverMoreDirect(
            [ProfileRule(type: .domain, value: "example.com", policy: "DIRECT"), finalReject],
            hosts: ["example.com", "Example.Com", "example.com.", "www.example.com"]
        )
        try assertNeverMoreDirect(
            [
                ProfileRule(type: .domainSuffix, value: "example.com", policy: "PROXY"),
                finalDirect,
            ],
            hosts: ["example.com", "www.example.com", "evil-example.com", "example.com."]
        )

        // A resolving IP-CIDR: a hostname cannot be placed without the Mac.
        let dns = ["vpn.example.com": ["10.1.2.3"], "public.example.com": ["203.0.113.5"]]
        try assertNeverMoreDirect(
            [ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT"), finalDirect],
            hosts: ["vpn.example.com", "public.example.com", "10.5.5.5", "unresolved.example.com"],
            dns: dns
        )

        // A resolving DIRECT rule populates DNS for a later `no-resolve` rule,
        // so the hostname must stop at the resolving rule (PROXY), not here.
        try assertNeverMoreDirect(
            [
                ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT"),
                ProfileRule(type: .ipCIDR, value: "192.0.2.0/24", policy: "REJECT", noResolve: true),
                finalDirect,
            ],
            hosts: ["corp.example.com", "10.1.2.3"],
            dns: ["corp.example.com": ["192.0.2.5"]]
        )

        // An IPv4-mapped IPv6 literal must not slip past IPv4 rules.
        try assertNeverMoreDirect(
            [ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT"), finalDirect],
            hosts: ["::ffff:10.1.2.3"]
        )

        // no-resolve: the Mac skips the rule for a hostname, so must the PAC.
        try assertNeverMoreDirect(
            [
                ProfileRule(type: .ipCIDR, value: "10.0.0.0/8", policy: "REJECT", noResolve: true),
                finalDirect,
            ],
            hosts: ["vpn.example.com", "10.1.2.3"],
            dns: dns
        )

        // GEOIP never matches, but the Mac still resolves for it, populating
        // the cache a later `no-resolve` IP rule uses.
        try assertNeverMoreDirect(
            [
                ProfileRule(type: .geoIP, value: "CN", policy: "DIRECT"),
                ProfileRule(type: .ipCIDR, value: "192.0.2.0/24", policy: "REJECT", noResolve: true),
                finalDirect,
            ],
            hosts: ["corp.example.com", "192.0.2.5"],
            dns: ["corp.example.com": ["192.0.2.5"]]
        )

        // With `no-resolve`, GEOIP neither resolves nor matches, so it is not
        // a termination point and the later no-resolve rule stays literal-only.
        try assertNeverMoreDirect(
            [
                ProfileRule(type: .geoIP, value: "CN", policy: "DIRECT", noResolve: true),
                ProfileRule(type: .ipCIDR, value: "192.0.2.0/24", policy: "REJECT", noResolve: true),
                finalDirect,
            ],
            hosts: ["corp.example.com"],
            dns: ["corp.example.com": ["192.0.2.5"]]
        )

        // Plain hostnames and localhost are evaluated like any other host.
        try assertNeverMoreDirect(
            [ProfileRule(type: .domain, value: "intranet", policy: "REJECT"), finalDirect],
            hosts: ["intranet", "localhost", "router"]
        )

        // A FINAL in the middle is terminal on the Mac; so it is in the PAC.
        try assertNeverMoreDirect(
            [
                ProfileRule(type: .domain, value: "direct.example.com", policy: "DIRECT"),
                finalReject,
                ProfileRule(type: .domain, value: "later.example.com", policy: "DIRECT"),
            ],
            hosts: ["direct.example.com", "later.example.com", "other.example.com"]
        )
    }
}
