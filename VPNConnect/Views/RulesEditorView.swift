import SwiftUI

// MARK: - Rules Editor View

/// Ordered rule list for the active profile: drag to reorder, per-type value
/// fields, inline policy picker, search filter, add/remove. Edits are saved
/// through `ProfileManager.saveAndActivate` so the engine hot-swaps.
struct RulesEditorView: View {
    @ObservedObject private var bridge = ProfileModelBridge.shared
    private var manager: ProfileManager { ProfileManager.shared }
    @State private var rules: [ProfileRule] = []
    @State private var policyNames: [String] = []
    @State private var searchText = ""
    @State private var validationErrors: [Profile.ValidationError] = []

    var body: some View {
        VStack(spacing: 0) {
            if !validationErrors.isEmpty {
                errorBanner
            }

            List {
                Section {
                    ForEach(filteredRules) { rule in
                        RuleRowView(
                            rule: binding(for: rule),
                            policyNames: policyNames,
                            onDelete: { delete(rule) }
                        )
                    }
                    .onMove { from, to in
                        moveRules(from: from, to: to)
                    }
                } header: {
                    HStack {
                        Text("Rules (\(rules.count))")
                        Spacer()
                        if !searchText.isEmpty {
                            Text("\(filteredRules.count) matching")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .searchable(text: $searchText, placement: .toolbar, prompt: "Filter rules")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addRule()
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
        }
        .onAppear { load() }
    }

    // MARK: Error banner

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

    // MARK: Filtering

    private var filteredRules: [ProfileRule] {
        guard !searchText.isEmpty else { return rules }
        let query = searchText.lowercased()
        return rules.filter {
            $0.value.lowercased().contains(query)
                || $0.policy.lowercased().contains(query)
                || $0.type.rawValue.lowercased().contains(query)
        }
    }

    // MARK: Binding plumbing (identity-safe editing over the filtered list)

    private func binding(for rule: ProfileRule) -> Binding<ProfileRule> {
        Binding(
            get: {
                rules.first(where: { $0.id == rule.id }) ?? rule
            },
            set: { newValue in
                if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                    rules[index] = newValue
                    persist()
                }
            }
        )
    }

    // MARK: Mutations

    private func load() {
        rules = manager.activeProfile.rules
        policyNames = manager.activeProfile.allPolicyNames
        validationErrors = manager.activeProfile.validate()
    }

    private func persist() {
        var profile = manager.activeProfile
        profile.rules = rules
        validationErrors = profile.validate()
        _ = manager.saveAndActivate(profile)
        policyNames = manager.activeProfile.allPolicyNames
    }

    private func addRule() {
        // Insert before FINAL so the catch-all stays last; FINAL itself is
        // created lazily if the list is empty.
        let index = rules.lastIndex(where: { $0.type == .final }) ?? rules.count
        let rule = ProfileRule(
            type: .domainSuffix,
            value: "example.com",
            policy: policyNames.contains("PROXY") ? "PROXY" : BuiltinPolicy.direct.rawValue
        )
        rules.insert(rule, at: index)
        persist()
    }

    private func moveRules(from source: IndexSet, to destination: Int) {
        guard destination >= 0, destination <= rules.count else { return }
        // Adjust destination when moving items downward past FINAL — keep
        // FINAL last by clamping after the move instead of forbidding it.
        rules.move(fromOffsets: source, toOffset: destination)
        clampFinalLast()
        persist()
    }

    /// Ensures at most one FINAL exists and it is the last rule (profile
    /// validation requires it; the drag can violate it).
    private func clampFinalLast() {
        if let finalIndex = rules.lastIndex(where: { $0.type == .final }) {
            if finalIndex != rules.count - 1 {
                let final = rules.remove(at: finalIndex)
                rules.append(final)
            }
        }
    }

    private func delete(_ rule: ProfileRule) {
        rules.removeAll { $0.id == rule.id }
        persist()
    }
}

// MARK: - Rule Row

private struct RuleRowView: View {
    @Binding var rule: ProfileRule
    let policyNames: [String]
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.secondary)
                .font(.system(size: 11))

            Picker("", selection: $rule.type) {
                ForEach(RuleType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 140, alignment: .leading)
            .controlSize(.small)

            if rule.type == .final {
                Text("—")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(valuePlaceholder, text: $rule.value)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Picker("", selection: $rule.policy) {
                ForEach(policyNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 120, alignment: .leading)
            .controlSize(.small)

            if needsNoResolve {
                Toggle("no-resolve", isOn: $rule.noResolve)
                    .font(.system(size: 10))
                    .toggleStyle(.checkbox)
                    .help("Skip this rule when matching would require a DNS lookup")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove rule")
        }
        .padding(.vertical, 2)
    }

    private var valuePlaceholder: String {
        switch rule.type {
        case .domain: return "exact.host.example"
        case .domainSuffix: return "example.com"
        case .domainKeyword: return "keyword"
        case .ipCIDR, .ipCIDR6: return "10.0.0.0/8"
        case .geoIP: return "CN"
        case .userAgent: return "curl/*"
        case .urlRegex: return "^https?://…"
        case .processName: return "curl"
        case .destPort: return "443, 8000-9000"
        case .srcIP: return "192.168.1.0/24"
        case .protocolRule: return "https"
        case .final: return ""
        }
    }

    /// Rule types whose value is an IP (matching may need DNS).
    private var needsNoResolve: Bool {
        rule.type == .ipCIDR || rule.type == .ipCIDR6 || rule.type == .geoIP || rule.type == .srcIP
    }
}
