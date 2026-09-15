import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rule Sets View

/// Remote rule lists — the "subscribe once, use like local rules" screen.
///
/// A rule set is declared in the profile's `[Rule Set]` section and referenced
/// from `[Rule]` with `RULE-SET,<name>,<policy>`; the rules themselves are
/// cached on disk and only ever parsed as text (see `RuleSetStore`). This pane
/// adds, edits and removes the declarations, and owns the one button that
/// touches the network.
///
/// Deliberately **not** a feed reader: no polling, no background fetch unless
/// the user turns on "Refresh automatically", and a failed refresh always keeps
/// the last good copy.
struct RuleSetsView: View {
    @ObservedObject private var bridge = ProfileModelBridge.shared
    @ObservedObject private var controller = EngineController.shared
    @ObservedObject private var settings = SettingsManager.shared
    private var manager: ProfileManager { ProfileManager.shared }

    // Add form
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newInterval: RuleSetInterval = .manual
    @State private var formError: String?

    @State private var editing: RemoteRuleSet?
    @State private var removing: RemoteRuleSet?
    @State private var copiedConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            if let formError { errorBanner(formError) }

            List {
                addSection
                setsSection
                cacheSection
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    controller.refreshAllRuleSets()
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(controller.ruleSetSummaries.isEmpty || !controller.ruleSetsRefreshing.isEmpty)
                .help("Download every rule set again")
            }
        }
        .sheet(item: $editing) { set in
            RuleSetEditorSheet(set: set) { edited in
                save { profile in
                    if let index = profile.ruleSets.firstIndex(where: { $0.id == set.id }) {
                        profile.ruleSets[index] = edited
                    }
                }
                // A retargeted set caches under a new file; the old body would
                // otherwise linger forever.
                if edited.url != set.url { controller.removeRuleSetCache(named: edited.name) }
                controller.reloadRuleSets(refreshStale: false)
            }
        }
        .confirmationDialog(
            removing.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { set in
            Button("Delete Rule Set", role: .destructive) { delete(set) }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { set in
            let count = referencingRules(set).count
            Text(count == 0
                 ? "The downloaded list is deleted too."
                 : "Its \(count) RULE-SET \(count == 1 ? "rule" : "rules") will be removed from [Rule] as well, and the downloaded list is deleted.")
        }
        .onAppear { controller.reloadRuleSets() }
    }

    // MARK: Sections

    private var addSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("Name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)

                TextField("https://example.com/rules.conf", text: $newURL)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addSet() }

                Picker("", selection: $newInterval) {
                    ForEach(RuleSetInterval.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                Button {
                    addSet()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(canAdd ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(!canAdd)
                .help("Add rule set")
            }
            .padding(.vertical, 2)
        } header: {
            Text("Add a rule set")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        } footer: {
            Text("https only — the list decides where your traffic goes, so it is never fetched over a plain connection, never executed, and refused above 8 MB. Adding a set does not download it.")
                .font(.system(size: 10))
        }
    }

    private var setsSection: some View {
        Section {
            if controller.ruleSetSummaries.isEmpty {
                Text("No rule sets yet. Paste a rules.conf URL above, add it, then press Refresh.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(controller.ruleSetSummaries) { summary in
                    RuleSetRowView(
                        summary: summary,
                        isRefreshing: controller.ruleSetsRefreshing.contains(summary.name),
                        onRefresh: { controller.refreshRuleSet(named: summary.name) },
                        onEdit: { editing = declaredSet(named: summary.name) },
                        onRemoveCache: { controller.removeRuleSetCache(named: summary.name) },
                        onDelete: { removing = declaredSet(named: summary.name) }
                    )
                }
            }
        } header: {
            HStack {
                Text("Rule sets (\(controller.ruleSetSummaries.count))")
                Spacer()
                if !controller.ruleSetsRefreshing.isEmpty {
                    Text("Refreshing \(controller.ruleSetsRefreshing.count)…")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        } footer: {
            Text("Reference one with a RULE-SET rule: RULE-SET,\(controller.ruleSetSummaries.first?.name ?? "Name"),SomePolicy — then it behaves exactly like the rules you wrote yourself, and a Routing assignment above it still wins.")
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cacheSection: some View {
        Section {
            Toggle(isOn: $settings.ruleSetAutoRefresh) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Refresh automatically")
                        .font(.system(size: 12))
                    Text("Only sets with an interval, on launch, in the background. Off means every download is your idea.")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Downloaded lists")
                        .font(.system(size: 12))
                    Text(SettingsDisplay.abbreviateHome(RuleSetStore.defaultDirectory().path))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Button(copiedConfirmation ? "Copied" : "Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(RuleSetStore.defaultDirectory().path, forType: .string)
                    copiedConfirmation = true
                }
                .controlSize(.small)
                SettingsRevealButton(path: RuleSetStore.defaultDirectory().path, mode: .folder, title: "Reveal")
            }
        } header: {
            Text("Cache")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundColor(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color.orange.opacity(0.12))
    }

    // MARK: State

    private var canAdd: Bool {
        !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func declaredSet(named name: String) -> RemoteRuleSet? {
        manager.activeProfile.ruleSets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func referencingRules(_ set: RemoteRuleSet) -> [ProfileRule] {
        manager.activeProfile.rules.filter {
            $0.type == .ruleSet && $0.value.caseInsensitiveCompare(set.name) == .orderedSame
        }
    }

    // MARK: Mutations

    /// Every change goes through the profile (the file is the source of truth),
    /// then back through the controller, which re-reads the cache off the main
    /// thread. The engine's own profile hook only runs while the engine is up,
    /// and this pane has to be correct with the engine stopped too.
    private func save(_ mutate: (inout Profile) -> Void) {
        var profile = manager.activeProfile
        mutate(&profile)
        _ = manager.saveAndActivate(profile)
        controller.reloadRuleSets(refreshStale: false)
    }

    private func addSet() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        formError = nil

        guard manager.activeProfile.ruleSet(named: name) == nil else {
            formError = "A rule set named “\(name)” already exists."
            return
        }
        let (parsed, error) = RemoteRuleSet.parseValue(url, name: name)
        if let error {
            formError = error
            return
        }
        guard let parsed else { return }

        var set = parsed
        set.interval = newInterval.seconds
        save { profile in profile.ruleSets.append(set) }

        newName = ""
        newURL = ""
        newInterval = .manual

        // Manual intervals are the default, but a set the user explicitly gave
        // a cadence to should not sit empty waiting for a click.
        if set.interval != nil { controller.refreshRuleSet(named: set.name) }
    }

    private func delete(_ set: RemoteRuleSet) {
        save { profile in
            profile.ruleSets.removeAll { $0.id == set.id }
            profile.rules.removeAll {
                $0.type == .ruleSet && $0.value.caseInsensitiveCompare(set.name) == .orderedSame
            }
        }
        controller.removeRuleSetCache(named: set.name)
        removing = nil
    }
}

// MARK: - Row

private struct RuleSetRowView: View {
    let summary: RuleSetSummary
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let onRemoveCache: () -> Void
    let onDelete: () -> Void

    private var status: SettingsDisplay.StatusLabel { SettingsDisplay.ruleSetStatus(summary) }

    private var tone: SettingsPill.Tone {
        switch status.tone {
        case .ok: return .ok
        case .warn: return .warn
        case .error: return .error
        case .neutral: return .neutral
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.name)
                    .font(.system(size: 12.5))
                Text(summary.url)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(verbatim: "\(SettingsDisplay.ruleSetAge(summary)) · \(SettingsDisplay.ruleSetRefresh(interval: summary.interval))"
                     + (summary.skippedCount > 0 ? " · \(summary.skippedCount) lines skipped" : ""))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                if let error = summary.error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 10)
            HStack(spacing: 8) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                }
                SettingsPill(text: status.title, tone: tone)
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Download this list now")
                Menu {
                    Button("Edit…", action: onEdit)
                    Button("Remove downloaded copy", action: onRemoveCache)
                        .disabled(!summary.isDownloaded)
                    Divider()
                    Button("Delete Rule Set", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help("More")
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Editor sheet

private struct RuleSetEditorSheet: View {
    let set: RemoteRuleSet
    let onSave: (RemoteRuleSet) -> Void

    @State private var name: String
    @State private var url: String
    @State private var interval: RuleSetInterval
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(set: RemoteRuleSet, onSave: @escaping (RemoteRuleSet) -> Void) {
        self.set = set
        self.onSave = onSave
        _name = State(initialValue: set.name)
        _url = State(initialValue: set.url)
        _interval = State(initialValue: RuleSetInterval.closest(to: set.interval))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rule Set")
                .font(.system(size: 15, weight: .semibold))

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Name").font(.system(size: 12))
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                GridRow {
                    Text("URL").font(.system(size: 12))
                    TextField("https://example.com/rules.conf", text: $url)
                        .font(.system(size: 12, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                GridRow {
                    Text("Refresh").font(.system(size: 12))
                    Picker("", selection: $interval) {
                        ForEach(RuleSetInterval.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            Text(verbatim: "Referenced from [Rule] as RULE-SET,\(name.isEmpty ? "Name" : name),<policy>.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return error = "A rule set needs a name." }

        let (parsed, message) = RemoteRuleSet.parseValue(trimmedURL, name: trimmedName)
        if let message { return error = message }
        guard var updated = parsed else { return }

        updated.id = set.id
        updated.interval = interval.seconds
        onSave(updated)
        dismiss()
    }
}
