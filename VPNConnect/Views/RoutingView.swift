import SwiftUI
import UniformTypeIdentifiers

// MARK: - Routing View

/// A friendly, PAC-like routing screen: assign a domain or IP range to a
/// policy in one step, without touching the full rule grammar. Only the
/// "addressable" rule types appear here (DOMAIN / DOMAIN-SUFFIX /
/// DOMAIN-KEYWORD / IP-CIDR / IP-CIDR6); advanced types (PROCESS-NAME,
/// URL-REGEX, …) stay in the Rules editor.
///
/// Also hosts the **Import PAC** wizard, which converts a `FindProxyForURL`
/// script into these same assignments via `PACRuleConverter`.
struct RoutingView: View {
    @ObservedObject private var bridge = ProfileModelBridge.shared
    private var manager: ProfileManager { ProfileManager.shared }
    @ObservedObject private var controller = EngineController.shared

    /// Routing-type rules in display order (a projection of the profile).
    @State private var assignments: [ProfileRule] = []
    @State private var policyNames: [String] = []
    @State private var validationErrors: [Profile.ValidationError] = []
    @State private var searchText = ""

    // Quick-add form
    @State private var newMatch: RoutingMatch = .domainSuffix
    @State private var newValue = ""
    @State private var newPolicy = BuiltinPolicy.direct.rawValue

    @State private var showPACImport = false

    var body: some View {
        VStack(spacing: 0) {
            if !validationErrors.isEmpty { errorBanner }

            List {
                quickAddSection
                assignmentsSection
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Filter assignments")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPACImport = true
                } label: {
                    Label("Import PAC", systemImage: "square.and.arrow.down")
                }
                .help("Convert a PAC (FindProxyForURL) script into routing rules")
            }
        }
        .sheet(isPresented: $showPACImport) {
            PACImportView { load() }
        }
        .onAppear { load() }
    }

    // MARK: Sections

    private var quickAddSection: some View {
        Section {
            HStack(spacing: 8) {
                Picker("", selection: $newMatch) {
                    ForEach(RoutingMatch.allCases) { match in
                        Text(match.title).tag(match)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                TextField(newMatch.placeholder, text: $newValue)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addAssignment() }

                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Picker("", selection: $newPolicy) {
                    ForEach(policyNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                Button {
                    addAssignment()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canAdd ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!canAdd)
                .help("Add assignment")
            }
            .padding(.vertical, 2)
        } header: {
            Text("Assign")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        }
    }

    private var assignmentsSection: some View {
        Section {
            if assignments.isEmpty {
                Text("No routing assignments yet. Add a domain or IP above, or import an existing PAC.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else if filteredAssignments.isEmpty {
                Text("No assignments match “\(searchText)”.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredAssignments) { rule in
                    RoutingRowView(
                        rule: binding(for: rule),
                        policyNames: policyNames,
                        onDelete: { delete(rule) }
                    )
                }
                .onMove { source, destination in
                    moveAssignments(from: source, to: destination)
                }
            }
        } header: {
            HStack {
                Text("Assignments (\(assignments.count))")
                Spacer()
                if !searchText.isEmpty {
                    Text("\(filteredAssignments.count) matching")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        } footer: {
            Text("First match wins. Advanced types (PROCESS-NAME, URL-REGEX, …) live in Rules.")
                .font(.system(size: 10))
        }
    }

    private var errorBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(validationErrors, id: \.self) { error in
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: State

    private var filteredAssignments: [ProfileRule] {
        guard !searchText.isEmpty else { return assignments }
        let query = searchText.lowercased()
        return assignments.filter {
            $0.value.lowercased().contains(query) || $0.policy.lowercased().contains(query)
        }
    }

    private var canAdd: Bool {
        !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        let profile = manager.activeProfile
        assignments = profile.rules.filter { RoutingMatch.contains($0.type) }
        policyNames = profile.allPolicyNames
        validationErrors = profile.validate()
    }

    // MARK: Mutations

    /// Rebuilds the profile's rule list from the reordered `assignments`:
    /// existing routing slots are refilled in order, remaining slots drop,
    /// and newly-added assignments are inserted before `FINAL`. This keeps
    /// non-routing rules (and the `FINAL` position) untouched.
    private func persist() {
        var profile = manager.activeProfile
        var rebuilt: [ProfileRule] = []
        var index = 0
        for rule in profile.rules {
            if RoutingMatch.contains(rule.type) {
                if index < assignments.count {
                    rebuilt.append(assignments[index])
                    index += 1
                }
                // else: this routing slot was deleted
            } else {
                rebuilt.append(rule)
            }
        }
        if index < assignments.count {
            let leftovers = Array(assignments[index...])
            let finalIndex = rebuilt.lastIndex { $0.type == .final } ?? rebuilt.count
            rebuilt.insert(contentsOf: leftovers, at: finalIndex)
        }
        profile.rules = rebuilt

        validationErrors = profile.validate()
        _ = manager.saveAndActivate(profile)
        policyNames = manager.activeProfile.allPolicyNames
    }

    private func binding(for rule: ProfileRule) -> Binding<ProfileRule> {
        Binding(
            get: { assignments.first(where: { $0.id == rule.id }) ?? rule },
            set: { newValue in
                if let index = assignments.firstIndex(where: { $0.id == rule.id }) {
                    assignments[index] = newValue
                    persist()
                }
            }
        )
    }

    private func addAssignment() {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        assignments.append(ProfileRule(type: newMatch.ruleType, value: value, policy: newPolicy))
        newValue = ""
        persist()
    }

    private func moveAssignments(from source: IndexSet, to destination: Int) {
        assignments.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func delete(_ rule: ProfileRule) {
        assignments.removeAll { $0.id == rule.id }
        persist()
    }
}

// MARK: - Routing Match

/// The subset of rule types the Routing screen exposes, with friendly labels.
enum RoutingMatch: String, CaseIterable, Identifiable {
    case domain
    case domainSuffix
    case domainKeyword
    case ipCIDR
    case ipCIDR6

    var id: String { rawValue }

    var title: String {
        switch self {
        case .domain: return "Domain"
        case .domainSuffix: return "Domain Suffix"
        case .domainKeyword: return "Domain Keyword"
        case .ipCIDR: return "IPv4 CIDR"
        case .ipCIDR6: return "IPv6 CIDR"
        }
    }

    var placeholder: String {
        switch self {
        case .domain: return "exact.host.example"
        case .domainSuffix: return "example.com"
        case .domainKeyword: return "keyword"
        case .ipCIDR: return "10.0.0.0/8"
        case .ipCIDR6: return "fd00::/8"
        }
    }

    var ruleType: RuleType {
        switch self {
        case .domain: return .domain
        case .domainSuffix: return .domainSuffix
        case .domainKeyword: return .domainKeyword
        case .ipCIDR: return .ipCIDR
        case .ipCIDR6: return .ipCIDR6
        }
    }

    /// Whether a rule type is addressable from this screen.
    static func contains(_ type: RuleType) -> Bool {
        allCases.contains { $0.ruleType == type }
    }
}

// MARK: - Routing Row

private struct RoutingRowView: View {
    @Binding var rule: ProfileRule
    let policyNames: [String]
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .font(.system(size: 11))

            Text(matchType?.title ?? rule.type.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 96, alignment: .leading)

            Text(rule.value)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Picker("", selection: $rule.policy) {
                ForEach(policyNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 130, alignment: .leading)
            .controlSize(.small)

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove assignment")
        }
        .padding(.vertical, 2)
    }

    private var matchType: RoutingMatch? {
        RoutingMatch.allCases.first { $0.ruleType == rule.type }
    }
}

// MARK: - PAC Import View

/// Two-step import wizard: paste/choose a PAC, convert (with a preview of the
/// generated proxies, groups, and rules), then apply to the active profile.
struct PACImportView: View {
    @Environment(\.dismiss) private var dismiss
    private var manager: ProfileManager { ProfileManager.shared }
    let onApplied: () -> Void

    @State private var source = ""
    @State private var result: PACConversionResult?
    @State private var errorMessage: String?
    @State private var applied = false
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 0) {
            header

            if applied {
                successState
            } else if let result {
                previewState(result)
            } else {
                inputState
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 560)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType(filenameExtension: "pac") ?? .plainText]
        ) { outcome in
            if case .success(let url) = outcome { loadFile(url) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Import PAC")
                    .font(.system(size: 15, weight: .semibold))
                Text("Converts FindProxyForURL into routing rules and policies.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: Input

    private var inputState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PAC source")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showFilePicker = true
                } label: {
                    Label("Choose .pac…", systemImage: "folder")
                }
                .controlSize(.small)
            }

            TextEditor(text: $source)
                .font(.system(size: 11, design: .monospaced))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
    }

    // MARK: Preview

    private func previewState(_ result: PACConversionResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if result.isEmpty {
                    Label("Nothing convertible was found in this PAC.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }

                if !result.proxies.isEmpty {
                    previewSection("New proxies") {
                        ForEach(result.proxies) { proxy in
                            previewRow(
                                icon: "server.rack",
                                title: proxy.name,
                                detail: "\(proxy.type.rawValue.uppercased()) \(proxy.host):\(proxy.port)"
                            )
                        }
                    }
                }

                if !result.groups.isEmpty {
                    previewSection("New policy groups") {
                        ForEach(result.groups) { group in
                            previewRow(
                                icon: "arrow.triangle.branch",
                                title: group.name,
                                detail: "\(group.type.rawValue) · \(group.policies.joined(separator: ", "))"
                            )
                        }
                    }
                }

                if !result.rules.isEmpty {
                    previewSection("Rules (\(result.rules.count))") {
                        ForEach(result.rules) { rule in
                            previewRow(
                                icon: "arrow.turn.down.right",
                                title: "\(rule.type.rawValue), \(rule.value)",
                                detail: "→ \(rule.policy)"
                            )
                        }
                    }
                }

                if let fallback = result.fallbackPolicy {
                    previewSection("Default (FINAL)") {
                        previewRow(icon: "flag.checkered", title: fallback, detail: "unmatched traffic")
                    }
                }

                if !result.diagnostics.isEmpty {
                    previewSection("Notes (\(result.diagnostics.count))") {
                        ForEach(Array(result.diagnostics.enumerated()), id: \.offset) { _, note in
                            previewRow(icon: "info.circle", title: note, detail: nil)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private func previewSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func previewRow(icon: String, title: String, detail: String?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.accentColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
    }

    // MARK: Success

    private var successState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundColor(.green)
            Text("Applied to “\(manager.activeProfile.name)”")
                .font(.system(size: 13, weight: .medium))
            Text("The engine reloads automatically.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if result != nil && !applied {
                Button("Back") {
                    result = nil
                }
            }
            Spacer()
            Button(applied ? "Done" : "Cancel") {
                if applied { onApplied() }
                dismiss()
            }
            .keyboardShortcut(.escape)

            if !applied {
                Button(result == nil ? "Convert" : "Apply to Profile") {
                    if result == nil { convert() } else { apply() }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(result == nil && source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: Actions

    private func loadFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            source = try String(contentsOf: url, encoding: .utf8)
            result = nil
            errorMessage = nil
        } catch {
            errorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func convert() {
        let profile = manager.activeProfile
        let conversion = PACRuleConverter.convert(
            pacSource: source,
            existingProxies: profile.proxies,
            existingGroups: profile.groups
        )
        result = conversion
    }

    private func apply() {
        guard let result else { return }
        let updated = PACRuleConverter.apply(result, to: manager.activeProfile)
        _ = manager.saveAndActivate(updated)
        applied = true
    }
}
