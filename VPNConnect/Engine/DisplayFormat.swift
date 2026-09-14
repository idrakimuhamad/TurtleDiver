import Foundation

// In the app target everything is one module; under SPM the profile types live
// in TurtleDiverCore.
#if canImport(TurtleDiverCore)
import TurtleDiverCore
#endif

/// Text formatting shared by the engine's UI surfaces (the request table and
/// the live log).
///
/// Deliberately Foundation-only and view-free, so the awkward cases are
/// unit-tested: a request that has not transferred anything yet used to render
/// as "Zero KB", an in-flight one as an orange ellipsis, and the matched rule
/// was printed twice (its value in the Rule column, its type under the host).
public enum RequestFormat {

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    public static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// Memory-style byte count ("24 KB", "1.2 MB").
    public static func bytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// The Size column. Zero means "nothing transferred yet" (an in-flight
    /// tunnel, or a rejected request) — show a dash instead of "Zero KB".
    public static func size(_ bytes: Int) -> String {
        bytes <= 0 ? "—" : self.bytes(bytes)
    }

    /// A session total. "Zero KB" reads like a bug in a header, so the zero case
    /// is normalised to the same unit the formatter would otherwise use.
    public static func totalBytes(_ bytes: Int) -> String {
        bytes <= 0 ? "0 KB" : self.bytes(bytes)
    }

    /// Whether the row is still running, so the Duration column can be dimmed
    /// rather than coloured like a warning.
    public static func isLive(_ entry: RequestEntry) -> Bool {
        entry.endedAt == nil
    }

    /// Finished requests show their total time; in-flight ones show how long
    /// they have been running for.
    public static func durationText(_ entry: RequestEntry, now: Date = Date()) -> String {
        if let duration = entry.duration {
            return String(format: "%.2fs", duration)
        }
        return String(format: "%.1fs", max(0, now.timeIntervalSince(entry.startedAt)))
    }

    /// The Rule column: "DOMAIN-SUFFIX microsoft.com", or just "FINAL" for the
    /// catch-all (its value is empty).
    public static func ruleText(_ rule: ProfileRule?) -> String {
        guard let rule else { return "—" }
        return rule.value.isEmpty ? rule.type.rawValue : "\(rule.type.rawValue) \(rule.value)"
    }

    /// The Rule column's type token, so the view can de-emphasise it next to the
    /// matched value. `nil` when there is no rule.
    public static func ruleTypeText(_ rule: ProfileRule?) -> String? {
        rule?.type.rawValue
    }

    /// Second line under a host: the transport, and the error when the relay
    /// failed. The matched rule used to be repeated here — it lives in its own
    /// column now.
    public static func subtitle(_ entry: RequestEntry) -> String {
        if let error = entry.error { return error }
        return entry.transport.rawValue.uppercased()
    }
}

// MARK: - Live log

/// One line of the VPN/engine debug output, split into the pieces the log view
/// colours: an optional timestamp, an optional `[tag]` (the debug writer emits
/// `[stdout]`, `[stderr]`, `[SEND]`, `[HANDLER]`), and the message itself.
public struct DebugLogLine: Identifiable, Equatable {
    /// Position inside the parsed window — stable, and cheap for `ForEach`.
    public let id: Int
    /// `HH:mm:ss`, or "" when the line carries no timestamp.
    public let time: String
    /// `stdout` / `stderr` / `SEND` / `HANDLER`, or "" when there is no tag.
    public let tag: String
    public let body: String
    public let severity: Severity

    public enum Severity: Equatable {
        case normal
        /// Something worth noticing without being a problem — a successful
        /// connect, a credential hand-off.
        case highlight
        case warning
        case error
    }
}

public enum DebugLogParser {

    /// Parses the tail of the log. `limit` keeps the view cheap: the underlying
    /// buffer grows for a whole session and only the end is on screen anyway.
    public static func lines(from output: String, limit: Int = 400) -> [DebugLogLine] {
        guard limit > 0 else { return [] }
        let raw = output.split(separator: "\n", omittingEmptySubsequences: true)
        return raw.suffix(limit).enumerated().map { parse(String($0.element), id: $0.offset) }
    }

    public static func parse(_ line: String, id: Int = 0) -> DebugLogLine {
        var rest = Substring(line)
        var time = ""
        var tag = ""

        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            // ISO-8601 timestamps only — a leading "[Error]" style line must not
            // be mistaken for one.
            if inner.contains("T"), inner.contains(":") {
                time = clockTime(String(inner))
                rest = rest[rest.index(after: close)...]
                rest = rest.drop(while: { $0 == " " })
            }
        }

        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            tag = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
            rest = rest.drop(while: { $0 == " " })
        }

        let body = String(rest)
        return DebugLogLine(
            id: id,
            time: time,
            tag: tag,
            body: body,
            severity: severity(tag: tag, body: body)
        )
    }

    /// "2026-09-14T11:58:14Z" → "11:58:14".
    static func clockTime(_ stamp: String) -> String {
        guard let t = stamp.firstIndex(of: "T") else { return stamp }
        let afterT = stamp[stamp.index(after: t)...]
        return String(afterT.prefix(8))
    }

    /// Content wins over the stream: openconnect writes progress to stderr, so
    /// tagging it as a warning would paint the whole log amber.
    static func severity(tag: String, body: String) -> DebugLogLine.Severity {
        let lowered = body.lowercased()
        for needle in ["error", "failed", "failure", "cannot", "unable to", "denied", "refused"] {
            if lowered.contains(needle) { return .error }
        }
        for needle in ["warning", "warn:", "deprecated"] {
            if lowered.contains(needle) { return .warning }
        }
        for needle in ["connected", "established", "success", "ready"] {
            if lowered.contains(needle) { return .highlight }
        }
        return tag == "SEND" ? .highlight : .normal
    }
}
