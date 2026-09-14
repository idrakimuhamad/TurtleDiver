import SwiftUI

// MARK: - Profiles View

/// Profile management: list, create, duplicate, delete, activate, open in
/// external editor. File watching (auto-reload) is handled by ProfileManager.
struct ProfilesView: View {
    @ObservedObject private var bridge = ProfileModelBridge.shared
    private var manager: ProfileManager { ProfileManager.shared }

    @State private var profileNames: [String] = []
    @State private var showNewAlert = false
    @State private var newName = ""
    @State private var duplicateSource: String?
    @State private var duplicateName = ""
    @State private var deletingProfile: String?
    @State private var showDeleteAlert = false

    var body: some View {
        Form {
            if profileNames.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundColor(.tertiary)
                        Text("No profiles")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else {
                Section {
                    ForEach(profileNames, id: \.self) { name in
                        profileRow(name)
                    }
                } header: {
                    Text("Profiles (\(profileNames.count))")
                        .font(.system(size: 12, weight: .regular))
                        .textCase(.uppercase)
                }
            }

            Section {
                HStack {
                    Button("+ New Profile") { showNewAlert = true }
                    Button("Duplicate") { duplicateSource = nil; duplicateName = ""; showNewAlert = true }
                        .disabled(manager.activeProfile.name.isEmpty)
                    Spacer()
                    Button("Open in External Editor") { openInEditor(manager.activeProfile.name) }
                    Button("Reload") { reloadActive() }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Profiles")
        .onAppear { refresh() }
        .alert("New Profile", isPresented: $showNewAlert) {
            TextField("Profile name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                if let source = duplicateSource {
                    _ = manager.duplicateProfile(named: source, as: name)
                } else {
                    _ = manager.createProfile(named: name)
                }
                newName = ""
                duplicateSource = nil
                refresh()
            }
            Button("Cancel", role: .cancel) { duplicateSource = nil }
        } message: {
            Text(duplicateSource != nil ? "Duplicate \"\(duplicateSource!)\" as:" : "Name for the new profile:")
        }
        .alert("Delete Profile?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let name = deletingProfile {
                    _ = manager.deleteProfile(named: name)
                }
                deletingProfile = nil
                refresh()
            }
            Button("Cancel", role: .cancel) { deletingProfile = nil }
        } message: {
            Text("Delete \"\(deletingProfile ?? "")\"? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func profileRow(_ name: String) -> some View {
        let isActive = name == manager.activeProfile.name
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    if isActive {
                        Text("ACTIVE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor))
                    }
                }
                let profile = manager.loadProfile(named: name)
                Text(profile.map { "\($0.proxies.count) proxies · \($0.groups.count) groups · \($0.rules.count) rules" } ?? "unreadable")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !isActive {
                Button("Activate") {
                    _ = manager.activateProfile(named: name)
                    refresh()
                }
                .controlSize(.small)
            }

            Menu {
                Button("Duplicate…") {
                    duplicateSource = name
                    duplicateName = ""
                    showNewAlert = true
                }
                Button("Open in External Editor") { openInEditor(name) }
                Divider()
                Button("Delete…", role: .destructive) {
                    deletingProfile = name
                    showDeleteAlert = true
                }
                .disabled(isActive)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func refresh() {
        profileNames = manager.listProfileNames()
    }

    private func reloadActive() {
        _ = manager.reloadActiveProfile()
    }

    private func openInEditor(_ name: String) {
        let url = manager.fileURL(for: name)
        NSWorkspace.shared.open(url)
    }
}
