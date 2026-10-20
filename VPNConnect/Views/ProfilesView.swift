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
    @State private var backupProfile: String?
    @State private var backups: [ProfileBackup] = []
    @State private var selectedBackup: ProfileBackup?
    @State private var showBackupSheet = false
    @State private var showRestoreConfirmation = false
    @State private var restoreMessage: String?
    @State private var restoreSucceeded = false
    @State private var deletedProfileNames: [String] = []
    @State private var deletingBackupsFor: String?
    @State private var backupDeleteCount = 0
    @State private var showDeleteBackupsConfirmation = false

    var body: some View {
        Form {
            if profileNames.isEmpty {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
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

            if !deletedProfileNames.isEmpty {
                Section {
                    ForEach(deletedProfileNames, id: \.self) { name in
                        deletedProfileRow(name)
                    }
                } header: {
                    Text("Deleted profiles")
                        .font(.system(size: 12, weight: .regular))
                        .textCase(.uppercase)
                }
            }

            if let restoreMessage, !showBackupSheet {
                Section {
                    Label(restoreMessage, systemImage: restoreSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(restoreSucceeded ? Color.green : Color.red)
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
            Text("A backup is kept. You can restore this profile from Deleted profiles below.")
        }
        .sheet(isPresented: $showBackupSheet) { backupSheet }
        .alert("Restore backup?", isPresented: $showRestoreConfirmation) {
            Button("Restore", role: .destructive) { restoreSelectedBackup() }
            Button("Cancel", role: .cancel) { selectedBackup = nil }
        } message: {
            Text("The current version of \(selectedBackup?.profileName ?? "this profile") will be saved as a backup first.")
        }
        .alert("Delete backups?", isPresented: $showDeleteBackupsConfirmation) {
            Button("Delete Backups", role: .destructive) { deleteBackups() }
            Button("Cancel", role: .cancel) { deletingBackupsFor = nil }
        } message: {
            Text("This removes \(backupDeleteCount) \(backupDeleteCount == 1 ? "backup" : "backups") of \(deletingBackupsFor.map { "\"\($0)\"" } ?? "this profile") and cannot be undone.")
        }
    }

    private var backupSheet: some View {
        NavigationStack {
            Group {
                if backups.isEmpty {
                    ContentUnavailableView("No backups", systemImage: "clock.arrow.circlepath",
                                           description: Text("Backups are created automatically before profile changes."))
                } else {
                    List(backups) { backup in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(backup.date, style: .relative).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(backup.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                Label("^[\(backup.ruleCount) rule](inflect: true)", systemImage: "line.3.horizontal")
                                Label("^[\(backup.proxyCount) proxy](inflect: true)", systemImage: "point.3.connected.trianglepath.dotted")
                                Text(ByteCountFormatter.string(fromByteCount: Int64(backup.byteCount), countStyle: .file))
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                            HStack {
                                Spacer()
                                Button("Restore…") {
                                    selectedBackup = backup
                                    showRestoreConfirmation = true
                                }
                                .buttonStyle(.bordered).controlSize(.small)
                            }
                        }.padding(.vertical, 4)
                    }.listStyle(.inset)
                }
            }
            .navigationTitle("Backups — \(backupProfile ?? "Profile")")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showBackupSheet = false } }
            }
            .safeAreaInset(edge: .bottom) {
                if let restoreMessage {
                    Label(restoreMessage, systemImage: restoreSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(restoreSucceeded ? Color.green : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(.bar)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 390)
    }

    private func restoreSelectedBackup() {
        guard let backup = selectedBackup else { return }
        let succeeded = manager.restoreBackup(backup)
        backups = manager.listBackups(forProfile: backup.profileName)
        restoreSucceeded = succeeded
        restoreMessage = succeeded ? "Backup restored." : "Could not restore this backup."
        selectedBackup = nil
        refresh()
    }

    @ViewBuilder
    private func deletedProfileRow(_ name: String) -> some View {
        let profileBackups = manager.listBackups(forProfile: name)
        if let latest = profileBackups.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(latest.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Restore") { restoreDeletedProfile(from: latest) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Text("\(profileBackups.count) \(profileBackups.count == 1 ? "backup" : "backups")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Menu("More") {
                        Button("Choose older backup…") {
                            backupProfile = name
                            backups = profileBackups
                            restoreMessage = nil
                            showBackupSheet = true
                        }
                        Button("Delete Backups…", role: .destructive) {
                            deletingBackupsFor = name
                            backupDeleteCount = profileBackups.count
                            showDeleteBackupsConfirmation = true
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func restoreDeletedProfile(from backup: ProfileBackup) {
        let succeeded = manager.restoreBackup(backup)
        restoreSucceeded = succeeded
        restoreMessage = succeeded ? "\(backup.profileName) restored." : "Could not restore \(backup.profileName)."
        backups = manager.listBackups(forProfile: backup.profileName)
        refresh()
    }

    private func deleteBackups() {
        guard let name = deletingBackupsFor else { return }
        let succeeded = manager.deleteBackups(forProfile: name)
        restoreSucceeded = succeeded
        restoreMessage = succeeded ? "Backups for \(name) deleted." : "Could not delete backups for \(name)."
        deletingBackupsFor = nil
        refresh()
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
                Text(verbatim: profile.map {
                    SettingsDisplay.profileSummary(proxies: $0.proxies.count,
                                                   groups: $0.groups.count,
                                                   rules: $0.rules.count)
                } ?? "unreadable")
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
                Button("Restore from Backup…") {
                    backupProfile = name
                    backups = manager.listBackups(forProfile: name)
                    restoreMessage = nil
                    showBackupSheet = true
                }
                Divider()
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
        deletedProfileNames = manager.deletedProfileNamesWithBackups()
    }

    private func reloadActive() {
        _ = manager.reloadActiveProfile()
    }

    private func openInEditor(_ name: String) {
        let url = manager.fileURL(for: name)
        NSWorkspace.shared.open(url)
    }
}
