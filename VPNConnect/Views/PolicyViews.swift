import SwiftUI

// MARK: - Policies View

/// Policy management for the active profile: proxy CRUD (secrets to Keychain),
/// group editor, per-policy latency test, select-group override.
struct PoliciesView: View {
    @ObservedObject private var bridge = ProfileModelBridge.shared
    private var manager: ProfileManager { ProfileManager.shared }
    @ObservedObject private var controller = EngineController.shared
    @State private var proxies: [ProxyDefinition] = []
    @State private var groups: [ProxyGroup] = []
    @State private var editingProxy: ProxyDefinition?
    @State private var editingGroup: ProxyGroup?
    @State private var showAddGroupSheet = false

    var body: some View {
        List {
            proxiesSection
            groupsSection
        }
        .navigationTitle("Policies")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.engine.policyStore.testAllPolicies()
                } label: {
                    Label("Test All", systemImage: "bolt.horizontal")
                }
                .help("Measure latency for every proxy (Test URL from profile)")
            }
        }
        .onAppear { load() }
        .sheet(item: $editingProxy) { proxy in
            ProxyEditorSheet(proxy: proxy) { updated in
                upsertProxy(updated)
            }
        }
        .sheet(item: $editingGroup) { group in
            GroupEditorSheet(group: group, allPolicyNames: manager.activeProfile.allPolicyNames) { updated in
                upsertGroup(updated)
            }
        }
    }

    // MARK: Proxies

    private var proxiesSection: some View {
        Section {
            ForEach(proxies) { proxy in
                Button {
                    editingProxy = proxy
                } label: {
                    policyRow(
                        title: proxy.name,
                        subtitle: "\(proxy.type.rawValue.uppercased()) \(proxy.host):\(proxy.port)",
                        systemImage: "server.rack"
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { editingProxy = proxy }
                    Divider()
                    Button("Delete", role: .destructive) { deleteProxy(proxy) }
                }
            }

            if proxies.isEmpty {
                Text("No proxies defined.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Button {
                editingProxy = ProxyDefinition(name: suggestProxyName(), type: .socks5, host: "127.0.0.1", port: 1080)
            } label: {
                Label("Add Proxy", systemImage: "plus")
            }
        } header: {
            Text("Proxies")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        }
    }

    // MARK: Groups

    private var groupsSection: some View {
        Section {
            ForEach(groups) { group in
                Button {
                    editingGroup = group
                } label: {
                    policyRow(
                        title: group.name,
                        subtitle: groupSubtitle(group),
                        systemImage: groupIcon(group.type)
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit") { editingGroup = group }
                    Divider()
                    Button("Delete", role: .destructive) { deleteGroup(group) }
                }
            }

            if groups.isEmpty {
                Text("No policy groups defined.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Button {
                editingGroup = ProxyGroup(name: suggestGroupName(), type: .select, policies: [BuiltinPolicy.direct.rawValue])
            } label: {
                Label("Add Group", systemImage: "plus")
            }
        } header: {
            Text("Policy Groups")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        }
    }

    // MARK: Rows

    private func policyRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundColor(.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            healthBadge(for: title)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func healthBadge(for name: String) -> some View {
        if let summary = controller.policySummaries.first(where: { $0.name == name }) {
            switch summary.health.lastResult {
            case .notProbed:
                Text("–")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            case .success(let ms):
                Text(String(format: "%.0f ms", ms))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.green)
            case .failure:
                Text("fail")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red)
            case .timeout:
                Text("timeout")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.orange)
            }
        }
    }

    private func groupSubtitle(_ group: ProxyGroup) -> String {
        var parts = [group.type.rawValue, group.policies.joined(separator: ", ")]
        if let url = group.testURL { parts.append(url) }
        return parts.joined(separator: " · ")
    }

    private func groupIcon(_ type: ProxyGroupType) -> String {
        switch type {
        case .select: return "hand.tap"
        case .urlTest: return "speedometer"
        case .fallback: return "arrow.triangle.branch"
        case .loadBalance: return "arrow.left.arrow.right"
        }
    }

    // MARK: Load / persist

    private func load() {
        proxies = manager.activeProfile.proxies
        groups = manager.activeProfile.groups
    }

    private func persist() {
        var profile = manager.activeProfile
        profile.proxies = proxies
        profile.groups = groups
        _ = manager.saveAndActivate(profile)
        load()
    }

    private func upsertProxy(_ proxy: ProxyDefinition) {
        if let index = proxies.firstIndex(where: { $0.id == proxy.id }) {
            proxies[index] = proxy
        } else {
            proxies.append(proxy)
        }
        persist()
    }

    private func upsertGroup(_ group: ProxyGroup) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
        persist()
    }

    private func deleteProxy(_ proxy: ProxyDefinition) {
        proxies.removeAll { $0.id == proxy.id }
        persist()
    }

    private func deleteGroup(_ group: ProxyGroup) {
        groups.removeAll { $0.id == group.id }
        persist()
    }

    // MARK: Naming

    private func suggestProxyName() -> String {
        var n = 1
        while proxies.contains(where: { $0.name == "Proxy \(n)" }) { n += 1 }
        return "Proxy \(n)"
    }

    private func suggestGroupName() -> String {
        var n = 1
        while groups.contains(where: { $0.name == "Group \(n)" }) { n += 1 }
        return "Group \(n)"
    }
}

// MARK: - Proxy Editor Sheet

struct ProxyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var proxy: ProxyDefinition
    let onSave: (ProxyDefinition) -> Void

    @State private var password = ""
    @State private var showPassword = false
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $proxy.name)
                }
                Section("Server") {
                    Picker("Type", selection: $proxy.type) {
                        ForEach(ProxyType.allCases, id: \.self) { type in
                            Text(type.rawValue.uppercased()).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Host", text: $proxy.host)
                    TextField("Port", value: $proxy.port, format: .number)
                    Toggle("TLS", isOn: $proxy.tls)
                    Toggle("Skip Certificate Verify", isOn: $proxy.skipCertVerify)
                }
                Section("Authentication (optional)") {
                    TextField("Username", text: Binding(
                        get: { proxy.username ?? "" },
                        set: { proxy.username = $0.isEmpty ? nil : $0 }
                    ))
                    HStack {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Stored in the Keychain; the profile file keeps only a reference.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 440, height: 460)
        .onAppear {
            password = KeychainHelper.retrieve(account: keychainAccount) ?? ""
        }
        .alert("Invalid Proxy", isPresented: Binding(
            get: { validationError != nil },
            set: { if !$0 { validationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(validationError ?? "")
        }
    }

    private var keychainAccount: String {
        "proxy.\(proxy.id.uuidString)"
    }

    private func save() {
        let name = proxy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { validationError = "Name is required"; return }
        guard (1...65535).contains(proxy.port) else { validationError = "Port must be 1–65535"; return }
        guard !proxy.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            validationError = "Host is required"
            return
        }

        var updated = proxy
        updated.name = name
        updated.password = nil // profile keeps no secret text

        if password.isEmpty {
            KeychainHelper.delete(account: keychainAccount)
        } else {
            KeychainHelper.store(password: password, account: keychainAccount)
        }

        onSave(updated)
        dismiss()
    }
}

// MARK: - Group Editor Sheet

struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var group: ProxyGroup
    let allPolicyNames: [String]
    let onSave: (ProxyGroup) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    TextField("Name", text: $group.name)
                    Picker("Type", selection: $group.type) {
                        ForEach(ProxyGroupType.allCases, id: \.self) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Members (in priority order)") {
                    ForEach(group.policies, id: \.self) { member in
                        HStack {
                            Text(member)
                                .font(.system(size: 12, design: .monospaced))
                            Spacer()
                            Button(role: .destructive) {
                                group.policies.removeAll { $0 == member }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove { from, to in
                        group.policies.move(fromOffsets: from, toOffset: to)
                    }

                    Picker("Add member", selection: Binding(
                        get: { "" },
                        set: { if !$0.isEmpty, !group.policies.contains($0) { group.policies.append($0) } }
                    )) {
                        Text("Add…").tag("")
                        ForEach(availableMembers, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()
                }

                if group.type != .select {
                    Section("Health Check") {
                        TextField("Test URL", text: Binding(
                            get: { group.testURL ?? "" },
                            set: { group.testURL = $0.isEmpty ? nil : $0 }
                        ))
                        TextField("Interval (seconds)", value: Binding(
                            get: { group.interval ?? 600 },
                            set: { group.interval = $0 }
                        ), format: .number)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { save() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 460, height: 480)
    }

    private var availableMembers: [String] {
        allPolicyNames.filter { !group.policies.contains($0) && $0 != group.name }
    }

    private func save() {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        group.name = name
        guard !group.policies.isEmpty else { return }
        onSave(group)
        dismiss()
    }
}
