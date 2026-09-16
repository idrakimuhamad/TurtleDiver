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

    /// Second line under a host: the transport, the error when the relay
    /// failed, and — when a detail was captured — what it adds at a glance (the
    /// request's real name, the response status, the negotiated protocol). The
    /// matched rule used to be repeated here; it lives in its own column now.
    public static func subtitle(_ entry: RequestEntry) -> String {
        if let error = entry.error { return error }
        let transport = entry.transport.rawValue.uppercased()
        guard let summary = detailSummary(entry) else { return transport }
        return "\(transport) · \(summary)"
    }

    /// The extra facts a row can show inline. The server name is dropped when
    /// it only repeats the host — "example.com · example.com" helps nobody.
    public static func detailSummary(_ entry: RequestEntry) -> String? {
        guard let detail = entry.detail else { return nil }
        var parts: [String] = []
        if let name = detail.serverName, !name.isEmpty, name.lowercased() != entry.host.lowercased() {
            parts.append(name)
        }
        if let statusLine = detail.statusLine, let code = RequestDetail.statusCode(in: statusLine) {
            parts.append(code)
        }
        if !detail.alpn.isEmpty { parts.append(detail.alpn.joined(separator: ", ")) }
        if let ip = detail.resolvedAddress, ip != entry.host, !parts.contains(ip) {
            parts.append("→ \(ip)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The row to render for an open detail sheet.
    ///
    /// The sheet is opened by a click and the capture lands *afterwards* — a
    /// ClientHello is only sent once the tunnel is up — so the sheet has to read
    /// the current row rather than the copy that existed at click time.
    /// `fallback` is the last copy seen, used once the log's ring buffer has
    /// trimmed the row away, so a detail being read does not vanish.
    public static func selectedEntry(
        in rows: [RequestEntry],
        id: RequestEntry.ID,
        fallback: RequestEntry?
    ) -> RequestEntry? {
        rows.first { $0.id == id } ?? fallback
    }

    // MARK: Request detail

    /// One titled group of rows in the request-detail sheet.
    public struct DetailSection: Identifiable, Equatable {
        public struct Row: Identifiable, Equatable {
            public let id: Int
            public let name: String
            public let value: String
            /// Withheld by the redactor — shown de-emphasised, never as a value.
            public let redacted: Bool
        }

        public let id: String
        public let title: String
        public let rows: [Row]
        /// Why a section is thin, or what was left out. Never a claim of data
        /// that was not captured.
        public let note: String?
    }

    /// The sheet's contents: what we know, and an honest note when a section is
    /// empty because the data is encrypted rather than absent.
    public static func detailSections(_ entry: RequestEntry) -> [DetailSection] {
        var sections: [DetailSection] = [generalSection(entry)]

        let detail = entry.detail
        var requestRows: [DetailSection.Row] = []
        if let line = detail?.requestLine {
            requestRows.append(.init(id: 0, name: "Request line", value: line, redacted: false))
        }
        requestRows.append(contentsOf: fieldRows(detail?.requestHeaders ?? [], startingAt: requestRows.count))
        sections.append(DetailSection(
            id: "request",
            title: entry.transport == .http ? "Request" : "CONNECT request",
            rows: requestRows,
            // "Not captured" would imply a head exists to capture. A SOCKS5
            // tunnel carries its destination inside the handshake and nothing
            // else, so there is no head in the stream at all.
            note: requestRows.isEmpty
                ? (entry.transport == .socks5
                    ? "A SOCKS5 tunnel carries only the destination — there is no request head in the stream."
                    : "No request head was captured.")
                : nil
        ))

        var responseRows: [DetailSection.Row] = []
        if let statusLine = detail?.statusLine {
            responseRows.append(.init(id: 0, name: "Status", value: statusLine, redacted: false))
        }
        responseRows.append(contentsOf: fieldRows(detail?.responseHeaders ?? [], startingAt: responseRows.count))
        sections.append(DetailSection(
            id: "response",
            title: "Response",
            rows: responseRows,
            // Say *why*, so an empty section is not read as a bug.
            note: responseRows.isEmpty
                ? "Only a plain-HTTP response is readable — anything inside a TLS tunnel is encrypted."
                : nil
        ))

        var tlsRows: [DetailSection.Row] = []
        if let name = detail?.serverName, !name.isEmpty {
            tlsRows.append(.init(id: 0, name: "Server name", value: name, redacted: false))
        }
        if let version = detail?.tlsVersion, !version.isEmpty {
            tlsRows.append(.init(id: tlsRows.count, name: "Version", value: version, redacted: false))
        }
        if let alpn = detail?.alpn, !alpn.isEmpty {
            tlsRows.append(.init(id: tlsRows.count, name: "ALPN", value: alpn.joined(separator: ", "), redacted: false))
        }
        sections.append(DetailSection(
            id: "tls",
            title: "TLS handshake",
            rows: tlsRows,
            note: tlsRows.isEmpty
                ? "Nothing readable was seen — the connection was not TLS, or the handshake did not start."
                : "Read from the ClientHello, which is unencrypted by design. Certificates are not (TLS 1.3 encrypts them)."
        ))

        return sections
    }

    private static func generalSection(_ entry: RequestEntry) -> DetailSection {
        var rows: [DetailSection.Row] = []
        func add(_ name: String, _ value: String) {
            rows.append(.init(id: rows.count, name: name, value: value, redacted: false))
        }
        add("Time", time(entry.startedAt))
        add("Destination", "\(entry.host):\(entry.port)")
        add("Transport", entry.transport.rawValue.uppercased())
        if let detail = entry.detail, let ip = detail.resolvedAddress, ip != entry.host {
            add("Connected to", ip)
        }
        add("Rule", ruleText(entry.rule))
        add("Policy", entry.policy)
        add("Size", "\(size(entry.bytesToDestination + entry.bytesToClient)) (\(size(entry.bytesToDestination)) up, \(size(entry.bytesToClient)) down)")
        add("Duration", durationText(entry))
        if let error = entry.error { add("Error", error) }
        var note: String?
        if let detail = entry.detail, !detail.notes.isEmpty {
            note = detail.notes.joined(separator: "; ")
        }
        return DetailSection(id: "general", title: "General", rows: rows, note: note)
    }

    private static func fieldRows(_ fields: [RequestDetail.Field], startingAt start: Int) -> [DetailSection.Row] {
        fields.enumerated().map { offset, field in
            .init(id: start + offset, name: field.name, value: field.value, redacted: field.redacted)
        }
    }

    /// The whole detail as copyable text — the same content as the sheet, in a
    /// form that pastes into a bug report.
    public static func detailText(_ entry: RequestEntry) -> String {
        var lines: [String] = []
        for section in detailSections(entry) {
            lines.append("== \(section.title) ==")
            for row in section.rows {
                lines.append("\(row.name): \(row.value)")
            }
            if let note = section.note { lines.append("(\(note))") }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
