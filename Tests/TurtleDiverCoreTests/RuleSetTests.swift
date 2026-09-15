import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules

/// `[Rule Set]` model, section-line parsing, cache identity and expansion.
final class RuleSetTests: XCTestCase {

    // MARK: - Helpers

    private func rule(_ text: String) -> ProfileRule {
        ProfileRule(type: .domain, value: text, policy: "DIRECT")
    }

    private func set(_ name: String, _ url: String, interval: Int? = nil) -> RemoteRuleSet {
        RemoteRuleSet(name: name, url: url, interval: interval)
    }

    // MARK: - Section line parsing

    func testParseValueTakesURLAndInterval() {
        let (parsed, error) = RemoteRuleSet.parseValue(
            "https://example.com/rules.conf, interval=86400", name: "Sukkaw"
        )
        XCTAssertNil(error)
        XCTAssertEqual(parsed?.url, "https://example.com/rules.conf")
        XCTAssertEqual(parsed?.interval, 86400)
        XCTAssertEqual(parsed?.name, "Sukkaw")
    }

    func testParseValueWithoutIntervalNeverGoesStale() {
        let (parsed, error) = RemoteRuleSet.parseValue("https://example.com/rules.conf", name: "A")
        XCTAssertNil(error)
        XCTAssertNil(parsed?.interval)
    }

    func testParseValueRejectsHTTP() {
        let (parsed, error) = RemoteRuleSet.parseValue("http://example.com/rules.conf", name: "A")
        XCTAssertNil(parsed)
        XCTAssertEqual(error, "Rule set \"A\" must use an https:// URL (got \"http://example.com/rules.conf\")")
    }

    func testParseValueRejectsFileAndBarePaths() {
        XCTAssertFalse(RemoteRuleSet.isAllowedURLString("file:///etc/passwd"))
        XCTAssertFalse(RemoteRuleSet.isAllowedURLString("/etc/passwd"))
        XCTAssertFalse(RemoteRuleSet.isAllowedURLString("https://"))
        XCTAssertTrue(RemoteRuleSet.isAllowedURLString("https://host/path"))
    }

    func testParseValueRejectsMissingURL() {
        let (parsed, error) = RemoteRuleSet.parseValue("", name: "A")
        XCTAssertNil(parsed)
        XCTAssertEqual(error, "Rule set \"A\" has no URL")
    }

    func testParseValueRejectsBadInterval() {
        let (parsed, error) = RemoteRuleSet.parseValue("https://e.com/r, interval=soon", name: "A")
        XCTAssertNil(parsed)
        XCTAssertEqual(error, "Rule set \"A\" has an invalid interval \"soon\" (expected seconds)")
    }

    func testParseValueRejectsUnknownOption() {
        let (parsed, error) = RemoteRuleSet.parseValue("https://e.com/r, cache=yes", name: "A")
        XCTAssertNil(parsed)
        XCTAssertEqual(error, "Rule set \"A\" has an unknown option \"cache\"")
    }

    // MARK: - Cache identity

    func testCacheFileNamesDifferForDifferentURLs() {
        let a = set("Same", "https://example.com/a.conf")
        let b = set("Same", "https://example.com/b.conf")
        XCTAssertNotEqual(a.cacheFileName, b.cacheFileName)
        XCTAssertEqual(a.cacheFileName, a.cacheFileName, "must be stable")
    }

    func testCacheFileNameIsFilesystemSafe() {
        let a = set("SukkaW's Rules / v2", "https://example.com/a.conf")
        XCTAssertFalse(a.cacheFileName.contains("'"))
        XCTAssertFalse(a.cacheFileName.contains("/"))
        XCTAssertFalse(a.cacheFileName.contains(" "))
        XCTAssertTrue(a.cacheFileName.hasPrefix("sukkaw-s-rules-v2-"))
    }

    func testCacheFileNameSlugNeverEmpty() {
        XCTAssertTrue(set("!!!", "https://e.com/r").cacheFileName.hasPrefix("set-"))
    }

    // MARK: - Age and staleness

    func testStalenessUsesTheSetsOwnInterval() {
        let now = Date()
        let entry = RuleSetCacheEntry(
            name: "A", url: "https://e.com/r", fetchedAt: now.addingTimeInterval(-7200),
            ruleCount: 1, skippedCount: 0, byteCount: 10
        )
        XCTAssertTrue(entry.isStale(interval: 3600, now: now))
        XCTAssertFalse(entry.isStale(interval: 86400, now: now))
        XCTAssertFalse(entry.isStale(interval: nil, now: now), "no interval means manual refresh only")
        XCTAssertEqual(entry.age(now: now), 7200, accuracy: 0.5)
    }

    // MARK: - Body parsing

    func testParseBodySkipsCommentsAndBlankLines() {
        let result = RuleSetParser.parse("""
        # a comment
        // another
        ; and another

        DOMAIN-SUFFIX,example.com
        """)
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules[0].type, .domainSuffix)
        XCTAssertEqual(result.rules[0].value, "example.com")
        XCTAssertTrue(result.rules[0].policy.isEmpty, "a set carries no policy unless the line does")
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testParseBodyKeepsPolicyAndNoResolve() {
        let result = RuleSetParser.parse("IP-CIDR,10.0.0.0/8,Corp,no-resolve")
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.rules[0].policy, "Corp")
        XCTAssertTrue(result.rules[0].noResolve)
    }

    func testParseBodyAcceptsTrailingSlashComment() {
        let result = RuleSetParser.parse("DOMAIN,a.com // trailing note")
        XCTAssertEqual(result.rules.first?.value, "a.com")
    }

    func testParseBodyReportsUnknownTypes() {
        let result = RuleSetParser.parse("NOT-A-TYPE,a.com\nDOMAIN,b.com")
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.skipped.count, 1)
        XCTAssertEqual(result.skipped[0].line, 1)
        XCTAssertEqual(result.skipped[0].reason, "unknown rule type \"NOT-A-TYPE\"")
    }

    func testParseBodyRejectsFinalAndNestedSets() {
        let result = RuleSetParser.parse("FINAL,DIRECT\nRULE-SET,Other,DIRECT\nDOMAIN,a.com")
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.skipped.count, 2)
        XCTAssertEqual(result.skipped[0].reason, "FINAL is not allowed in a rule set")
        XCTAssertEqual(result.skipped[1].reason, "rule sets cannot reference other rule sets")
    }

    func testParseBodyRequiresAValue() {
        let result = RuleSetParser.parse("DOMAIN\nIP-CIDR")
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertEqual(result.skipped.map(\.reason), ["DOMAIN needs a value", "IP-CIDR needs a value"])
    }

    func testParseBodyRejectsUnknownOptions() {
        let result = RuleSetParser.parse("DOMAIN,a.com,Corp,force-remote-dns")
        XCTAssertTrue(result.rules.isEmpty)
        XCTAssertEqual(result.skipped.first?.reason, "DOMAIN has unrecognised options \"force-remote-dns\"")
    }

    func testParseBodyDedupes() {
        let result = RuleSetParser.parse("DOMAIN,a.com\nDOMAIN,A.COM\nDOMAIN,a.com")
        XCTAssertEqual(result.rules.count, 1)
        XCTAssertEqual(result.duplicateCount, 2)
    }

    func testParseBodyKeepsDifferentNoResolveApart() {
        let result = RuleSetParser.parse("IP-CIDR,10.0.0.0/8\nIP-CIDR,10.0.0.0/8,no-resolve")
        XCTAssertEqual(result.rules.count, 2)
        XCTAssertEqual(result.duplicateCount, 0)
    }

    // MARK: - Expansion

    func testExpandSplicesSetRulesInPlace() {
        let rules = [
            rule("before.com"),
            ProfileRule(type: .ruleSet, value: "Ads", policy: "REJECT"),
            rule("after.com"),
        ]
        let expansion = RuleMatcher.expand(rules, ruleSets: [
            "ads": [
                ProfileRule(type: .domainSuffix, value: "ads.com", policy: ""),
                ProfileRule(type: .domain, value: "tracker.io", policy: ""),
            ]
        ])
        XCTAssertEqual(expansion.rules.map(\.value), ["before.com", "ads.com", "tracker.io", "after.com"])
        XCTAssertEqual(expansion.rules.map(\.policy), ["DIRECT", "REJECT", "REJECT", "DIRECT"])
        XCTAssertEqual(expansion.rules.map(\.ruleSet), [nil, "Ads", "Ads", nil], "provenance for the log")
        XCTAssertTrue(expansion.unresolved.isEmpty)
    }

    func testExpandLetsTheReferencePolicyWin() {
        let rules = [ProfileRule(type: .ruleSet, value: "List", policy: "ProxyA")]
        let expansion = RuleMatcher.expand(rules, ruleSets: [
            "list": [ProfileRule(type: .domain, value: "a.com", policy: "ProxyB")]
        ])
        XCTAssertEqual(expansion.rules.first?.policy, "ProxyA")
    }

    func testExpandIsCaseInsensitiveOnTheSetName() {
        let rules = [ProfileRule(type: .ruleSet, value: "SUKKAW", policy: "DIRECT")]
        let expansion = RuleMatcher.expand(rules, ruleSets: [
            "sukkaw": [ProfileRule(type: .domain, value: "a.com", policy: "")]
        ])
        XCTAssertEqual(expansion.rules.count, 1)
        XCTAssertEqual(expansion.rules.first?.ruleSet, "SUKKAW", "the reference spelling is kept")
    }

    func testExpandLeavesAnUncachedReferenceInert() {
        let rules = [
            rule("a.com"),
            ProfileRule(type: .ruleSet, value: "Missing", policy: "REJECT"),
        ]
        let expansion = RuleMatcher.expand(rules, ruleSets: [:], declared: ["missing"])
        XCTAssertEqual(expansion.rules.count, 1)
        XCTAssertEqual(expansion.unresolved, ["Missing"])
        XCTAssertTrue(expansion.undeclared.isEmpty, "declared but not downloaded is not undeclared")
    }

    func testExpandReportsUndeclaredReferences() {
        let rules = [ProfileRule(type: .ruleSet, value: "Typo", policy: "DIRECT")]
        let expansion = RuleMatcher.expand(rules, ruleSets: [:], declared: ["real"])
        XCTAssertEqual(expansion.undeclared, ["Typo"])
        XCTAssertEqual(expansion.unresolved, ["Typo"])
    }

    func testExpandIgnoresEmptySets() {
        let rules = [ProfileRule(type: .ruleSet, value: "Empty", policy: "DIRECT")]
        let expansion = RuleMatcher.expand(rules, ruleSets: ["empty": []], declared: ["empty"])
        XCTAssertTrue(expansion.rules.isEmpty)
        XCTAssertEqual(expansion.unresolved, ["Empty"])
    }

    // MARK: - Matcher integration

    func testMatcherMatchesExpandedRulesAndReportsUnresolved() {
        let profile = Profile(
            name: "T",
            rules: [
                ProfileRule(type: .ruleSet, value: "Ads", policy: "REJECT"),
                ProfileRule(type: .domain, value: "keep.me", policy: "DIRECT"),
                ProfileRule(type: .ruleSet, value: "Missing", policy: "DIRECT"),
                ProfileRule(type: .final, value: "", policy: "DIRECT"),
            ],
            ruleSets: [set("Ads", "https://e.com/ads"), set("Missing", "https://e.com/m")]
        )
        let matcher = RuleMatcher(
            profile: profile,
            resolver: FakeDNSResolver(table: [:]),
            ruleSets: ["ads": [ProfileRule(type: .domainSuffix, value: "ads.example", policy: "")]]
        )

        XCTAssertEqual(matcher.expandedRuleCount, 3, "the Ads reference becomes 1 rule; Missing becomes none")
        XCTAssertEqual(matcher.unresolvedRuleSetNames, ["Missing"])

        let blocked = try? matcher.match(MatchContext(host: "cdn.ads.example", port: 443))
        XCTAssertEqual(blocked?.policy, "REJECT")
        XCTAssertEqual(blocked?.rule?.ruleSet, "Ads")

        let allowed = try? matcher.match(MatchContext(host: "keep.me", port: 443))
        XCTAssertEqual(allowed?.policy, "DIRECT")
        XCTAssertNil(allowed?.rule?.ruleSet)

        let dangling = try? matcher.match(MatchContext(host: "anything.example", port: 443))
        XCTAssertEqual(dangling?.rule?.type, .final, "a dangling reference falls through to FINAL")
        XCTAssertNil(dangling?.rule?.ruleSet)
        XCTAssertEqual(dangling?.policy, "DIRECT")
    }

    func testUpdateProfileKeepsRuleSetsWhenNoneAreSupplied() {
        let profile = Profile(
            name: "T",
            rules: [
                ProfileRule(type: .ruleSet, value: "Ads", policy: "REJECT"),
                ProfileRule(type: .final, value: "", policy: "DIRECT"),
            ],
            ruleSets: [set("Ads", "https://e.com/ads")]
        )
        let matcher = RuleMatcher(
            profile: profile, resolver: FakeDNSResolver(table: [:]),
            ruleSets: ["ads": [ProfileRule(type: .domain, value: "ads.example", policy: "")]]
        )

        var edited = profile
        edited.rules.insert(ProfileRule(type: .domain, value: "before.example", policy: "DIRECT"), at: 0)
        matcher.updateProfile(edited)

        XCTAssertEqual(matcher.expandedRuleCount, 3, "the expansion must survive a profile edit")
        let outcome = try? matcher.match(MatchContext(host: "ads.example", port: 443))
        XCTAssertEqual(outcome?.policy, "REJECT")
    }

    func testUpdateProfileCanClearRuleSets() {
        let profile = Profile(
            name: "T",
            rules: [ProfileRule(type: .ruleSet, value: "Ads", policy: "REJECT")],
            ruleSets: [set("Ads", "https://e.com/ads")]
        )
        let matcher = RuleMatcher(
            profile: profile, resolver: FakeDNSResolver(table: [:]),
            ruleSets: ["ads": [ProfileRule(type: .domain, value: "ads.example", policy: "")]]
        )
        matcher.updateProfile(profile, ruleSets: [:])
        XCTAssertEqual(matcher.expandedRuleCount, 0)
        XCTAssertEqual(matcher.unresolvedRuleSetNames, ["Ads"])
    }

    // MARK: - Profile parsing and serialization

    func testProfileParserReadsRuleSetSection() {
        let text = """
        [General]
        http-listen = 127.0.0.1:6152

        [Rule Set]
        Sukkaw = https://example.com/surge.conf, interval=86400
        Bad = http://insecure.example.com/x

        [Rule]
        RULE-SET,Sukkaw,ProxyA
        FINAL,DIRECT
        """
        let result = ProfileParser.parse(text, name: "T")
        XCTAssertEqual(result.profile.ruleSets.count, 1)
        XCTAssertEqual(result.profile.ruleSets[0].name, "Sukkaw")
        XCTAssertEqual(result.profile.ruleSets[0].interval, 86400)
        XCTAssertEqual(result.diagnostics.count, 1, "the http line is reported")
        XCTAssertEqual(result.diagnostics[0].message, "Rule set \"Bad\" must use an https:// URL (got \"http://insecure.example.com/x\")")
        XCTAssertEqual(result.profile.referencedRuleSetNames, ["Sukkaw"])
    }

    func testRuleSetSectionRoundTrips() {
        let profile = Profile(
            name: "T",
            general: GeneralSettings(),
            proxies: [ProxyDefinition(name: "A", type: .http, host: "h", port: 1)],
            rules: [
                ProfileRule(type: .ruleSet, value: "Sukkaw", policy: "A"),
                ProfileRule(type: .final, value: "", policy: "DIRECT"),
            ],
            ruleSets: [set("Sukkaw", "https://example.com/r.conf", interval: 3600)]
        )
        let reparsed = ProfileParser.parse(ProfileSerializer.serialize(profile), name: "T").profile
        XCTAssertEqual(reparsed.ruleSets, profile.ruleSets)
        XCTAssertEqual(reparsed.rules.map(\.type), [.ruleSet, .final])
        XCTAssertEqual(reparsed.rules[0].value, "Sukkaw")
        XCTAssertEqual(reparsed.rules[0].policy, "A")
    }

    func testSerializerEmitsAnEmptyRuleSetSection() {
        let text = ProfileSerializer.serialize(Profile(name: "T"))
        XCTAssertTrue(text.contains("[Rule Set]"))
        XCTAssertTrue(text.contains("# No remote rule sets defined"))
    }

    // MARK: - Validation

    func testValidateRejectsUndeclaredRuleSetReference() {
        let profile = Profile(
            name: "T",
            rules: [ProfileRule(type: .ruleSet, value: "Nope", policy: "DIRECT")],
            ruleSets: []
        )
        XCTAssertEqual(profile.validate(), [.ruleSetUnknown(index: 0, name: "Nope")])
    }

    func testValidateRejectsDuplicateAndInsecureRuleSets() {
        let profile = Profile(
            name: "T",
            rules: [ProfileRule(type: .ruleSet, value: "A", policy: "DIRECT")],
            ruleSets: [
                set("A", "https://e.com/r"),
                set("a", "http://e.com/r"),
            ]
        )
        XCTAssertEqual(profile.validate(), [
            .ruleSetDuplicateName("a"),
            .ruleSetInsecureURL(name: "a", url: "http://e.com/r"),
        ])
    }

    func testValidateAcceptsADeclaredRuleSet() {
        let profile = Profile(
            name: "T",
            rules: [ProfileRule(type: .ruleSet, value: "Sukkaw", policy: "DIRECT")],
            ruleSets: [set("Sukkaw", "https://e.com/r")]
        )
        XCTAssertEqual(profile.validate(), [])
    }

    // MARK: - Referencing from the Rule Sets pane

    func testSetReferenceInsertsBeforeFinal() {
        var profile = Profile(name: "T", rules: [
            rule("a.com"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ])
        XCTAssertTrue(profile.setRuleSetReference(named: "Ads", policy: "REJECT"))
        XCTAssertEqual(profile.rules.map(\.type), [.domain, .ruleSet, .final])
        XCTAssertEqual(profile.rules[1].value, "Ads")
        XCTAssertEqual(profile.rules[1].policy, "REJECT")
    }

    func testSetReferenceAppendsWhenThereIsNoFinal() {
        var profile = Profile(name: "T", rules: [rule("a.com")])
        XCTAssertTrue(profile.setRuleSetReference(named: "Ads", policy: "DIRECT"))
        XCTAssertEqual(profile.rules.map(\.value), ["a.com", "Ads"])
    }

    func testSetReferenceReplacesThePolicyAndDropsDuplicates() {
        var profile = Profile(name: "T", rules: [
            ProfileRule(type: .ruleSet, value: "Ads", policy: "DIRECT"),
            rule("a.com"),
            ProfileRule(type: .ruleSet, value: "ads", policy: "DIRECT"),
            ProfileRule(type: .final, value: "", policy: "DIRECT"),
        ])
        XCTAssertTrue(profile.setRuleSetReference(named: "Ads", policy: "REJECT"))
        let references = profile.rules.filter { $0.type == .ruleSet }
        XCTAssertEqual(references.count, 1, "a set means one rule")
        XCTAssertEqual(references[0].policy, "REJECT")
        XCTAssertEqual(profile.rules.map(\.type), [.ruleSet, .domain, .final])
    }

    func testSetReferenceIsIdempotent() {
        var profile = Profile(name: "T", rules: [
            ProfileRule(type: .ruleSet, value: "Ads", policy: "REJECT"),
        ])
        XCTAssertFalse(profile.setRuleSetReference(named: "Ads", policy: "REJECT"),
                       "an unchanged reference must not rewrite the profile")
        XCTAssertFalse(profile.setRuleSetReference(named: "ads", policy: "REJECT"),
                       "the existing reference is matched case-insensitively")
        XCTAssertEqual(profile.rules[0].value, "Ads", "so the spelling is left alone")
        XCTAssertTrue(profile.setRuleSetReference(named: "ads", policy: "DIRECT"))
        XCTAssertEqual(profile.rules[0].policy, "DIRECT")
    }

    func testSetReferenceRemovesWithNil() {
        var profile = Profile(name: "T", rules: [
            ProfileRule(type: .ruleSet, value: "Ads", policy: "REJECT"),
            rule("a.com"),
        ])
        XCTAssertTrue(profile.setRuleSetReference(named: "Ads", policy: nil))
        XCTAssertEqual(profile.rules.map(\.value), ["a.com"])
        XCTAssertFalse(profile.setRuleSetReference(named: "Ads", policy: nil))
    }

    // MARK: - Failure messages

    /// A `URLError` reaches the store as a bridged `NSError`; interpolating one
    /// prints the whole `UserInfo` dictionary into a settings row.
    func testTransportErrorIsDescribedInOneSentence() {
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.cannotFindHost)), "Could not find that host")
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.dnsLookupFailed)), "Could not find that host")
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.notConnectedToInternet)), "No internet connection")
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.timedOut)), "The server took too long to answer")
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.cannotConnectToHost)), "Could not connect to that host")
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.secureConnectionFailed)),
                       "Could not establish a secure connection")
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.httpTooManyRedirects)),
                       "The server redirected too many times")
        XCTAssertEqual(RuleSetStoreError.describe(URLError(.badServerResponse)),
                       "Could not download the list (network error \(URLError.Code.badServerResponse.rawValue))")
    }

    func testTransportErrorNeverLeaksTheErrorDump() {
        let text = RuleSetStoreError.describe(URLError(.cannotFindHost))
        XCTAssertFalse(text.contains("UserInfo"))
        XCTAssertFalse(text.contains("Domain="))
        XCTAssertLessThan(text.count, 80, "it has to fit on one line in the row")
    }

    func testOtherErrorsKeepTheirOwnDescription() {
        XCTAssertEqual(RuleSetStoreError.describe(RuleSetStoreError.transport("empty response body")),
                       "empty response body")
        XCTAssertEqual(RuleSetStoreError.describe(RuleSetStoreError.notUTF8),
                       "Rule set is not valid UTF-8 text")
    }

    // MARK: - Summary → cache identity

    /// The pane holds summaries, not declarations; dropping a cached copy needs
    /// the name and the URL, which is what the cache file name is made of.
    func testSummaryRebuildsTheCacheIdentity() {
        let set = RemoteRuleSet(name: "Ads", url: "https://example.com/ads.list", interval: 3600)
        let summary = RuleSetSummary(
            name: set.name,
            url: set.url,
            interval: set.interval,
            ruleCount: 12,
            skippedCount: 1,
            fetchedAt: Date(),
            isStale: false,
            error: nil
        )
        XCTAssertEqual(summary.declaration, set)
        XCTAssertEqual(summary.declaration.cacheFileName, set.cacheFileName)
    }
}
