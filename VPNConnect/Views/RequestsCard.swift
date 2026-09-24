import SwiftUI

/// The live request table, shared by the main window's expanded dashboard
/// (wide columns) and Settings → Dashboard (stacked rows, inside a `Form`).
///
/// Owns its own pause/filter/search state so both call sites behave the same:
/// pausing freezes a snapshot instead of dropping entries — the engine keeps
/// logging, the UI just stops moving.
struct RequestsCard: View {
    @ObservedObject private var controller = EngineController.shared

    /// Stacked row layout for narrow hosts (the Settings pane); the default
    /// renders the wide Time · Host · Rule · Policy · Duration · Size table.
    var compactRows: Bool = false
    /// Card background + padding. Off when embedded in a `Form` section that
    /// already provides the chrome.
    var chrome: Bool = true

    @State private var paused = false
    @State private var frozen: [RequestEntry] = []
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var confirmClear = false
    /// The row whose detail sheet is open — the copy from the moment of the
    /// click, used only as the trigger and as the fallback. The sheet renders
    /// `selectedEntry`, which re-reads the row: a request's detail lands *after*
    /// the row appears (the ClientHello is only sent once the tunnel is up), so
    /// freezing the click-time copy would show an empty sheet.
    @State private var selected: RequestEntry?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case proxied = "Proxied"
        case direct = "Direct"
        case rejected = "Rejected"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toolbar
            Divider()
            if visible.isEmpty {
                emptyState
            } else if compactRows {
                // Lazy: the log keeps up to 1000 rows in memory, and the main
                // window's ScrollView is the only viewport — offscreen rows
                // must not be built. An eager stack instantiates every row
                // (~10 Text views each) and re-lays them out on every request
                // event, which is what made scrolling the table crawl while
                // traffic flowed. (Inside a Form section the lazy stack is
                // eager in practice — the Form row has no viewport — which is
                // the Settings pane's pre-existing behaviour.)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible.reversed()) { entry in
                        StackedRequestRow(entry: entry) { selected = entry }
                    }
                }
            } else {
                columnHeader
                Divider().opacity(0.5)
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(visible.reversed().enumerated()), id: \.element.id) { index, entry in
                        WideRequestRow(entry: entry, striped: !index.isMultiple(of: 2)) { selected = entry }
                    }
                }
            }
        }
        .padding(chrome ? 12 : 0)
        .background {
            if chrome {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.secondary.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.12)))
            }
        }
        .sheet(item: $selected) { entry in
            if let live = RequestFormat.selectedEntry(in: visible, id: entry.id, fallback: entry) {
                RequestDetailSheet(entry: live)
            } else {
                Text("This request is no longer in the list.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .onChange(of: controller.requests) { _, rows in
            guard let open = selected, let live = rows.first(where: { $0.id == open.id }) else { return }
            selected = live
        }
        .alert("Clear the request log?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                controller.clearRequests()
                frozen = []
            }
        } message: {
            Text("This only clears the list shown here — routing is unaffected.")
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text("Recent Requests")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)

            Text("\(visible.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField("Search hosts, rules or policies", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: compactRows ? 120 : 190)
            }
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))

            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 96)

            Button {
                togglePause()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(paused ? Color.accentColor : Color.secondary)
            .help(paused ? "Resume — new requests are hidden while paused" : "Pause the list")

            Button {
                confirmClear = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
            .disabled(controller.requests.isEmpty)
            .help("Clear the request log")
        }
        // The hint lives on the toolbar, not on the table: a tooltip attached to
        // the rows pops up under the pointer and swallows the click that was
        // aimed at the row it describes.
        .help("Click a row to see what the engine could read from it")
    }

    private func togglePause() {
        if paused {
            paused = false
        } else {
            frozen = controller.requests // freeze at pause start
            paused = true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(paused ? "Paused — new requests are hidden" : emptyMessage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compactRows ? 18 : 26)
    }

    private var emptyMessage: String {
        if !controller.engineRunning { return "Enable the proxy engine to start routing traffic." }
        if !controller.requests.isEmpty { return "No requests match this filter." }
        return "No requests yet."
    }

    // MARK: Data

    /// While paused, keep showing the snapshot from when pause started.
    private var visible: [RequestEntry] {
        let base = paused ? frozen : controller.requests
        let bySearch: [RequestEntry]
        if query.isEmpty {
            bySearch = base
        } else {
            let needle = query.lowercased()
            bySearch = base.filter { entry in
                entry.host.lowercased().contains(needle)
                    || entry.policy.lowercased().contains(needle)
                    || (entry.rule?.value.lowercased().contains(needle) ?? false)
                    || (entry.rule?.type.rawValue.lowercased().contains(needle) ?? false)
            }
        }
        switch filter {
        case .all:
            return bySearch
        case .proxied:
            return bySearch.filter { !isBuiltin($0.policy) }
        case .direct:
            return bySearch.filter { $0.policy == BuiltinPolicy.direct.rawValue }
        case .rejected:
            return bySearch.filter { $0.policy == BuiltinPolicy.reject.rawValue }
        }
    }

    private func isBuiltin(_ policy: String) -> Bool {
        BuiltinPolicy.names.contains(policy)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("TIME").frame(width: 60, alignment: .leading)
            Text("HOST").frame(maxWidth: .infinity, alignment: .leading)
            Text("RULE").frame(width: 178, alignment: .leading)
            Text("POLICY").frame(width: 110, alignment: .leading)
            Text("DURATION").frame(width: 62, alignment: .trailing)
            Text("SIZE").frame(width: 74, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }
}

// MARK: - Wide row (main window)

private struct WideRequestRow: View {
    let entry: RequestEntry
    /// Alternating row tint, so a long list reads as rows rather than a wall.
    var striped = false
    /// Opens the detail sheet. Every row is clickable — even one with no
    /// captured detail carries the time, rule, policy and byte counts.
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(RequestFormat.time(entry.startedAt))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "\(entry.host):\(entry.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(RequestFormat.subtitle(entry))
                    .font(.system(size: 9))
                    .foregroundStyle(entry.error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                // The type token must never wrap ("DOMAIN-\nSUFFIX" read like a
                // broken cell); the value truncates instead.
                Text(RequestFormat.ruleTypeText(entry.rule) ?? "—")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                if let value = entry.rule?.value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 178, alignment: .leading)

            HStack(spacing: 5) {
                Circle()
                    .fill(RequestFormat.policyColor(entry.policy))
                    .frame(width: 6, height: 6)
                Text(entry.policy)
                    .font(.system(size: 11, weight: entry.policy == BuiltinPolicy.reject.rawValue ? .semibold : .regular))
                    .lineLimit(1)
            }
            .frame(width: 110, alignment: .leading)

            Text(RequestFormat.durationText(entry))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(RequestFormat.isLive(entry) ? Color.secondary.opacity(0.55) : Color.secondary)
                .frame(width: 62, alignment: .trailing)

            Text(RequestFormat.size(entry.bytesToDestination + entry.bytesToClient))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovering ? Color.accentColor.opacity(0.14) : rowBackground)
        .opacity(entry.endedAt == nil ? 1 : 0.9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
    }

    /// A rejected request is tinted (like a failing row in a log viewer); the
    /// rest alternate so the eye can track a row across the table.
    private var rowBackground: Color {
        if entry.policy == BuiltinPolicy.reject.rawValue { return Color.red.opacity(0.10) }
        return striped ? Color.primary.opacity(0.035) : Color.clear
    }
}

// MARK: - Stacked row (Settings)

private struct StackedRequestRow: View {
    let entry: RequestEntry
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(entry.host):\(entry.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(RequestFormat.subtitle(entry))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(entry.error == nil ? Color.secondary : Color.red)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(RequestFormat.ruleText(entry.rule))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 120, alignment: .leading)

            Text(entry.policy)
                .font(.system(size: 11, weight: entry.policy == BuiltinPolicy.reject.rawValue ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(RequestFormat.policyColor(entry.policy))
                .frame(width: 90, alignment: .leading)

            Text(RequestFormat.size(entry.bytesToDestination + entry.bytesToClient))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)

            Text(RequestFormat.durationText(entry))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(RequestFormat.isLive(entry) ? Color.secondary.opacity(0.55) : Color.secondary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .background(hovering ? Color.accentColor.opacity(0.14) : Color.clear)
    }
}

// MARK: - Detail sheet

/// Everything the engine could read from one request, with no claim of more.
///
/// Deliberately a sheet rather than an expanding row: a header list is the one
/// thing in this window whose height is set by a remote server, and a sheet
/// keeps that out of the table's layout entirely.
private struct RequestDetailSheet: View {
    let entry: RequestEntry

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var sections: [RequestFormat.DetailSection] {
        RequestFormat.detailSections(entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections) { section in
                        sectionView(section)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 540)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.policy == BuiltinPolicy.reject.rawValue
                ? "hand.raised.fill" : "arrow.left.arrow.right")
                .font(.system(size: 12))
                .foregroundStyle(RequestFormat.policyColor(entry.policy))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "\(entry.host):\(entry.port)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(RequestFormat.ruleText(entry.rule))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(entry.policy)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(RequestFormat.policyColor(entry.policy))
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(copied ? "Copied" : "Copy All") {
                let text = RequestFormat.detailText(entry)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            }
            .help("Copy every section as plain text")
            Text("Select any value to copy just that part.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sectionView(_ section: RequestFormat.DetailSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            if section.rows.isEmpty {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(section.rows) { row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 132, alignment: .leading)
                            .lineLimit(3)
                        Text(row.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(row.redacted ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let note = section.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Colour palette

extension RequestFormat {
    /// Stable colour per policy name — the dashboard's "coloured dot" idea,
    /// without hard-coding policy names. Built-ins keep their meaning: green
    /// for DIRECT, red for REJECT.
    static func policyColor(_ policy: String) -> Color {
        switch policy {
        case BuiltinPolicy.direct.rawValue:
            return .green
        case BuiltinPolicy.reject.rawValue:
            return .red
        default:
            let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]
            var hash = 5381
            for scalar in policy.unicodeScalars {
                hash = (hash &* 33) &+ Int(scalar.value)
            }
            return palette[abs(hash) % palette.count]
        }
    }
}
