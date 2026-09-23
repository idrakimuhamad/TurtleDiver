import Foundation
import TurtleDiverCore
import TurtleDiverRules

/// `profile list` — what is on disk, and which one the app is using.
public struct ProfileListing {
    public struct Entry: Equatable {
        public let name: String
        public let active: Bool
        public let path: String
        public let ruleCount: Int
        public let proxyCount: Int
        public let groupCount: Int
        /// Parse diagnostics with `severity == .error`; a profile with any is not
        /// usable, so the list says so rather than waiting for `validate`.
        public let parseErrors: Int

        public var jsonObject: [String: Any] {
            [
                "name": name,
                "active": active,
                "path": path,
                "ruleCount": ruleCount,
                "proxyCount": proxyCount,
                "groupCount": groupCount,
                "parseErrors": parseErrors,
            ]
        }
    }

    public let directory: String
    public let entries: [Entry]

    public static func read(directory: ProfileDirectory = ProfileDirectory(), activeName: String?) -> ProfileListing {
        let entries = directory.names().map { name -> Entry in
            guard let parsed = directory.load(named: name) else {
                return Entry(name: name, active: name == activeName, path: directory.fileURL(for: name).path,
                             ruleCount: 0, proxyCount: 0, groupCount: 0, parseErrors: 1)
            }
            return Entry(
                name: name,
                active: name == activeName,
                path: directory.fileURL(for: name).path,
                ruleCount: parsed.profile.rules.count,
                proxyCount: parsed.profile.proxies.count,
                groupCount: parsed.profile.groups.count,
                parseErrors: parsed.diagnostics.filter { $0.severity == .error }.count
            )
        }
        return ProfileListing(directory: directory.directory.path, entries: entries)
    }

    public var jsonObject: [String: Any] {
        ["ok": true, "directory": directory, "profiles": entries.map(\.jsonObject)]
    }

    public var humanLines: [String] {
        guard !entries.isEmpty else { return ["no profiles in \(directory)"] }
        return entries.map { entry in
            let mark = entry.active ? "*" : " "
            let problems = entry.parseErrors > 0 ? "  (\(entry.parseErrors) parse error(s))" : ""
            return "\(mark) \(entry.name)  rules \(entry.ruleCount), proxies \(entry.proxyCount), groups \(entry.groupCount)\(problems)"
        }
    }
}

/// `profile validate` — parse it, then resolve every policy it names.
///
/// Two different failures, reported separately because they have different
/// fixes: a *parse* diagnostic names a line to edit, a *validation* error names
/// a reference that points at nothing, and an unresolved rule set is neither —
/// it is a download the app has not done.
public struct ProfileValidation {
    public struct Diagnostic: Equatable {
        public let line: Int
        public let severity: String
        public let message: String

        public var jsonObject: [String: Any] {
            ["line": line, "severity": severity, "message": message]
        }
    }

    public let name: String
    public let path: String
    public let diagnostics: [Diagnostic]
    public let validationErrors: [String]
    public let unresolvedRuleSets: [String]
    public let policyCount: Int
    public let ruleCount: Int

    public var isValid: Bool {
        validationErrors.isEmpty && !diagnostics.contains { $0.severity == "error" }
    }

    public static func validate(
        name: String,
        directory: ProfileDirectory = ProfileDirectory(),
        ruleSets: [String: [ProfileRule]]? = nil
    ) throws -> ProfileValidation {
        guard let parsed = directory.load(named: name) else {
            throw CLIFailure.notConfigured("no profile named \"\(name)\" in \(directory.directory.path)")
        }
        let profile = parsed.profile
        let cached = ruleSets ?? RuleSetStore().rulesBySet(for: profile)
        // Constructing the matcher is also the check that every group cycle and
        // unknown reference in the rules is caught; validation below is the
        // profile-level half (proxy ports, duplicate names, group cycles).
        let matcher = RuleMatcher(profile: profile, ruleSets: cached)

        return ProfileValidation(
            name: name,
            path: directory.fileURL(for: name).path,
            diagnostics: parsed.diagnostics.map {
                Diagnostic(line: $0.line, severity: $0.severity.rawValue, message: $0.message)
            },
            validationErrors: profile.validate().map { $0.errorDescription ?? "\($0)" },
            unresolvedRuleSets: matcher.unresolvedRuleSetNames,
            policyCount: profile.proxies.count + profile.groups.count,
            ruleCount: profile.rules.count
        )
    }

    public var jsonObject: [String: Any] {
        var body: [String: Any] = [
            "ok": true,
            "valid": isValid,
            "name": name,
            "path": path,
            "policyCount": policyCount,
            "ruleCount": ruleCount,
            "diagnostics": diagnostics.map(\.jsonObject),
            "validationErrors": validationErrors,
        ]
        if !unresolvedRuleSets.isEmpty { body["unresolvedRuleSets"] = unresolvedRuleSets }
        return body
    }

    public var humanLines: [String] {
        var lines = ["\(name): \(isValid ? "valid" : "invalid")  (\(policyCount) policies, \(ruleCount) rules)"]
        for diagnostic in diagnostics {
            lines.append("  \(diagnostic.severity) line \(diagnostic.line): \(diagnostic.message)")
        }
        for error in validationErrors {
            lines.append("  error: \(error)")
        }
        if !unresolvedRuleSets.isEmpty {
            lines.append("  warning: no cached rules for: \(unresolvedRuleSets.joined(separator: ", "))")
        }
        return lines
    }
}
