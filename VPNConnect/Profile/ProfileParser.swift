import Foundation

// MARK: - Diagnostics

/// A non-fatal problem found while parsing a profile. The parser is
/// best-effort: bad lines become diagnostics instead of failing the parse,
/// so users can iterate on hand-edited profiles in the UI.
public struct ProfileDiagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable { case warning, error }

    public let line: Int      // 1-based line number
    public let message: String
    public let severity: Severity

    public init(line: Int, message: String, severity: Severity = .error) {
        self.line = line
        self.message = message
        self.severity = severity
    }
}

// MARK: - Parse Result

public struct ProfileParseResult: Sendable {
    public let profile: Profile
    public let diagnostics: [ProfileDiagnostic]

    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
}

// MARK: - Parser

/// Parses Surge-compatible INI profile text into a `Profile`.
///
/// Supported grammar (Phase 0):
/// ```
/// [General]
/// http-listen = 127.0.0.1:6152
/// socks5-listen = 127.0.0.1:6153
/// test-url = http://cp.cloudflare.com/generate_204
/// test-timeout = 5
/// test-interval = 600
/// system-proxy = false
/// skip-proxy = 127.0.0.1, 192.168.0.0/16, ...
/// loglevel = info
///
/// [Proxy]
/// Name = http, example.com, 8080, username=me, password=secret
/// Name2 = https, example.com, 443, tls=true, skip-cert-verify=true
/// Name3 = socks5, 10.0.0.1, 1080
///
/// [Proxy Group]
/// Auto = url-test, ProxyA, ProxyB, url=http://..., interval=600
/// Pick = select, Auto, DIRECT
///
/// [Rule]
/// DOMAIN-SUFFIX,apple.com,DIRECT
/// IP-CIDR,10.0.0.0/8,Corp,no-resolve
/// FINAL,SomeProxy
/// ```
public enum ProfileParser {

    /// Section names accepted (case-insensitive).
    private enum Section: String {
        case general, proxy = "proxy", proxyGroup = "proxy group", rule
    }

    public static func parse(_ text: String, name: String) -> ProfileParseResult {
        var diagnostics: [ProfileDiagnostic] = []
        var general = GeneralSettings()
        var proxies: [ProxyDefinition] = []
        var groups: [ProxyGroup] = []
        var rules: [ProfileRule] = []
        var currentSection: Section?
        var sawGeneral = false

        let lines = text.components(separatedBy: .newlines)

        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)

            // Blank lines and comments are skipped (already comment-stripped).
            if line.isEmpty { continue }

            // Section header?
            if line.hasPrefix("["), line.hasSuffix("]") {
                let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if let section = Section(rawValue: header.lowercased()) {
                    if section == .general {
                        if sawGeneral {
                            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Duplicate [General] section; values are merged with the first one", severity: .warning))
                        }
                        sawGeneral = true
                    }
                    currentSection = section
                } else {
                    diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Unknown section [\(header)]; contents ignored", severity: .warning))
                    currentSection = nil
                }
                continue
            }

            guard let section = currentSection else {
                diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Line outside any section is ignored"))
                continue
            }

            switch section {
            case .general:
                parseGeneralLine(line, lineNo: lineNo, into: &general, diagnostics: &diagnostics)

            case .proxy:
                parseProxyLine(line, lineNo: lineNo, into: &proxies, diagnostics: &diagnostics)

            case .proxyGroup:
                parseGroupLine(line, lineNo: lineNo, into: &groups, diagnostics: &diagnostics)

            case .rule:
                parseRuleLine(line, lineNo: lineNo, into: &rules, diagnostics: &diagnostics)
            }
        }

        // FINAL must be last — enforced at parse time for user convenience.
        if let finalIndex = rules.lastIndex(where: { $0.type == .final }),
           finalIndex != rules.count - 1 {
            diagnostics.append(ProfileDiagnostic(line: 0, message: "FINAL rule is not the last rule; rules after it are unreachable", severity: .warning))
        }

        let profile = Profile(
            name: name,
            general: general,
            proxies: proxies,
            groups: groups,
            rules: rules
        )
        return ProfileParseResult(profile: profile, diagnostics: diagnostics)
    }

    // MARK: Line-level helpers

    /// Removes trailing comments (`;` or `#` outside quoted values) and full
    /// comment lines. Hash inside a quoted string does not start a comment.
    static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var result = ""
        result.reserveCapacity(line.count)
        for ch in line {
            if ch == "\"" { inQuotes.toggle() }
            if (ch == ";" || ch == "#") && !inQuotes { break }
            result.append(ch)
        }
        return result
    }

    /// Splits `key = value` with the first `=` as separator.
    /// Returns nil if there is no separator or the key is empty.
    static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    /// Splits a value string on top-level commas (commas inside quotes or
    /// parentheses are preserved, e.g. `url=http://x?a=1,b` or IP-CIDR values).
    static func splitTopLevel(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuotes = false
        for ch in value {
            switch ch {
            case "\"":
                inQuotes.toggle()
                current.append(ch)
            case "(": depth += 1; current.append(ch)
            case ")": depth = max(0, depth - 1); current.append(ch)
            case "," where depth == 0 && !inQuotes:
                parts.append(unquote(current.trimmingCharacters(in: .whitespaces)))
                current = ""
            default:
                current.append(ch)
            }
        }
        parts.append(unquote(current.trimmingCharacters(in: .whitespaces)))
        return parts
    }

    /// Strips surrounding double quotes and unescapes `""` → `"`.
    /// Unquoted values pass through unchanged.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// Extracts `key=value` params from trailing parts. A part like
    /// `url=http://x` becomes (`url`, `http://x`). Parts without `=` are left
    /// in the returned remainder list.
    static func extractParams(_ parts: [String]) -> (params: [String: String], remainder: [String]) {
        var params: [String: String] = [:]
        var remainder: [String] = []
        for part in parts {
            if let eq = part.firstIndex(of: "=") {
                let key = part[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    params[key] = unquote(value)
                    continue
                }
            }
            remainder.append(part)
        }
        return (params, remainder)
    }

    static func boolValue(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    // MARK: Section parsers

    private static func parseGeneralLine(
        _ line: String, lineNo: Int,
        into general: inout GeneralSettings,
        diagnostics: inout [ProfileDiagnostic]
    ) {
        guard let (key, value) = splitKeyValue(line) else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Malformed general line (expected key = value): \(line)"))
            return
        }
        switch key.lowercased() {
        case "http-listen":            general.httpListen = value
        case "socks5-listen":          general.socks5Listen = value
        case "test-url":               general.testURL = value
        case "test-timeout":           general.testTimeout = Int(value) ?? general.testTimeout
        case "test-interval":          general.testInterval = Int(value) ?? general.testInterval
        case "system-proxy":           general.systemProxy = boolValue(value) ?? general.systemProxy
        case "skip-proxy":
            general.skipProxy = value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        case "loglevel":
            if ["info", "debug"].contains(value.lowercased()) {
                general.logLevel = value.lowercased()
            } else {
                diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Unknown loglevel \"\(value)\" (expected info or debug); keeping \(general.logLevel)", severity: .warning))
            }
        default:
            // Surge profiles carry many options we do not model yet — warn.
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Unknown general option \"\(key)\" ignored", severity: .warning))
        }
    }

    private static func parseProxyLine(
        _ line: String, lineNo: Int,
        into proxies: inout [ProxyDefinition],
        diagnostics: inout [ProfileDiagnostic]
    ) {
        guard let (name, value) = splitKeyValue(line) else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Malformed proxy line (expected Name = type, host, port, ...): \(line)"))
            return
        }

        let parts = splitTopLevel(value)
        guard let typePart = parts.first else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Proxy \"\(name)\" is missing its type"))
            return
        }
        guard let type = ProxyType(rawValue: typePart.lowercased()) else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Proxy \"\(name)\" has unknown type \"\(typePart)\" (expected http, https, or socks5)"))
            return
        }
        guard parts.count >= 3 else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Proxy \"\(name)\" needs at least type, host and port"))
            return
        }

        let host = parts[1]
        guard let port = Int(parts[2]), (1...65535).contains(port) else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Proxy \"\(name)\" has invalid port \"\(parts[2])\""))
            return
        }

        let (params, _) = extractParams(Array(parts.dropFirst(3)))

        let def = ProxyDefinition(
            name: name,
            type: type,
            host: host,
            port: port,
            username: params["username"],
            password: params["password"],
            tls: type == .https || boolValue(params["tls"] ?? "") == true,
            skipCertVerify: boolValue(params["skip-cert-verify"] ?? "") == true
        )
        if proxies.contains(where: { $0.name == name }) {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Duplicate proxy name \"\(name)\"; the later entry wins", severity: .warning))
            if let idx = proxies.firstIndex(where: { $0.name == name }) {
                proxies[idx] = def
            }
        } else {
            proxies.append(def)
        }
    }

    private static func parseGroupLine(
        _ line: String, lineNo: Int,
        into groups: inout [ProxyGroup],
        diagnostics: inout [ProfileDiagnostic]
    ) {
        guard let (name, value) = splitKeyValue(line) else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Malformed group line (expected Name = type, policy, ...): \(line)"))
            return
        }

        let parts = splitTopLevel(value)
        guard let typePart = parts.first else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Group \"\(name)\" is missing its type"))
            return
        }
        guard let type = ProxyGroupType(rawValue: typePart.lowercased()) else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Group \"\(name)\" has unknown type \"\(typePart)\" (expected select, url-test, fallback, or load-balance)"))
            return
        }

        let (params, memberParts) = extractParams(Array(parts.dropFirst(1)))
        let members = memberParts.filter { !$0.isEmpty }
        if members.isEmpty {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Group \"\(name)\" has no member policies"))
            return
        }

        let interval = params["interval"].flatMap(Int.init)
        let group = ProxyGroup(
            name: name,
            type: type,
            policies: members,
            testURL: params["url"],
            interval: interval
        )
        if let idx = groups.firstIndex(where: { $0.name == name }) {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Duplicate group name \"\(name)\"; the later entry wins", severity: .warning))
            groups[idx] = group
        } else {
            groups.append(group)
        }
    }

    private static func parseRuleLine(
        _ line: String, lineNo: Int,
        into rules: inout [ProfileRule],
        diagnostics: inout [ProfileDiagnostic]
    ) {
        let parts = splitTopLevel(line)
        guard let typePart = parts.first else { return }
        guard let type = RuleType(rawValue: typePart.uppercased()) else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Unknown rule type \"\(typePart)\""))
            return
        }

        if type == .final {
            // FINAL takes only a policy: `FINAL,policy`
            guard parts.count >= 2 else {
                diagnostics.append(ProfileDiagnostic(line: lineNo, message: "FINAL rule needs a policy"))
                return
            }
            let policy = parts[1]
            let noResolve = parts.count >= 3 && parts[2].lowercased() == "no-resolve"
            if parts.count > 3 {
                diagnostics.append(ProfileDiagnostic(line: lineNo, message: "FINAL rule has extra options; they were ignored", severity: .warning))
            }
            rules.append(ProfileRule(type: .final, value: "", policy: policy, noResolve: noResolve))
            return
        }

        // All other types: TYPE,value,policy[,no-resolve]
        guard parts.count >= 3 else {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Rule \"\(typePart)\" needs a value and a policy"))
            return
        }
        let value = parts[1]
        let policy = parts[2]
        let noResolve = parts.count >= 4 && parts[3].lowercased() == "no-resolve"
        if parts.count > 4 {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Rule \"\(typePart)\" has extra options; they were ignored", severity: .warning))
        }

        // Value shape validation (cheap, per-type).
        switch type {
        case .ipCIDR, .ipCIDR6, .srcIP:
            if value.split(separator: "/").count != 2 || Int(value.split(separator: "/")[1]) == nil {
                diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Rule \"\(typePart)\" value \"\(value)\" is not valid CIDR (expected a.b.c.d/prefix)", severity: .warning))
            }
        case .destPort:
            let ok = value.split(separator: ",").allSatisfy { chunk in
                if chunk.contains("-") {
                    let range = chunk.split(separator: "-")
                    return range.count == 2 && range.allSatisfy({ Int($0) != nil })
                }
                return Int(chunk) != nil
            }
            if value.isEmpty || !ok {
                diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Rule \"\(typePart)\" value \"\(value)\" is not a port, range, or comma-separated list", severity: .warning))
            }
        case .geoIP:
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "GEOIP rules are reserved and not matched yet", severity: .warning))
        default:
            break
        }

        if value.isEmpty {
            diagnostics.append(ProfileDiagnostic(line: lineNo, message: "Rule \"\(typePart)\" has an empty value"))
            return
        }

        rules.append(ProfileRule(type: type, value: value, policy: policy, noResolve: noResolve))
    }
}
