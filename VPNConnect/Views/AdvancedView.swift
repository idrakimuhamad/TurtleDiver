import SwiftUI
import AppKit

/// Engine ports, log files, storage, and the one destructive button.
///
/// Everything here is read-only information plus a single reset: it is the pane
/// you open when something is wrong and you need to see where things live.
struct AdvancedView: View {
    @ObservedObject private var engine = EngineController.shared
    @ObservedObject private var settings = SettingsManager.shared

    @State private var showResetAlert = false
    /// Which credentials exist in the Keychain — never their values.
    @State private var presentCredentials: Set<String> = []
    @State private var didReset = false

    private var profilesDirectory: String { ProfileManager.shared.profilesDirectory.path }
    private var profileNames: [String] { ProfileManager.shared.listProfileNames() }

    var body: some View {
        SettingsPane(title: "Advanced", subtitle: "Engine ports, log files, storage and reset") {
            engineGroup
            filesGroup
            storageGroup
            resetGroup
        }
        .task { refreshCredentials() }
    }

    // MARK: Engine

    private var engineGroup: some View {
        SettingsCard("Proxy engine", note: "The listeners come from the active profile's [General] section. The engine itself is switched on from the main window.") {
            SettingsRow(label: "Status") {
                HStack(spacing: 8) {
                    SettingsPill(text: engine.engineRunning ? "Running" : "Stopped",
                                 tone: engine.engineRunning ? .ok : .neutral)
                    if let error = engine.lastError, !error.isEmpty {
                        SettingsPill(text: "Error", tone: .error)
                            .help(error)
                    }
                }
            }
            SettingsRow(label: "HTTP listener", caption: engine.engineRunning ? nil : "Starts with the engine") {
                SettingsMonoValue(value: SettingsDisplay.listener(port: engine.httpPort))
            }
            SettingsRow(label: "SOCKS5 listener", caption: engine.engineRunning ? nil : "Starts with the engine") {
                SettingsMonoValue(value: SettingsDisplay.listener(port: engine.socks5Port))
            }
            SettingsRow(label: "Policies in this profile", isLast: true) {
                Text("\(engine.policySummaries.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Files

    private var filesGroup: some View {
        SettingsCard("Files") {
            SettingsRow(label: "VPN connection log",
                        caption: "openconnect output; credentials redacted") {
                HStack(spacing: 8) {
                    SettingsMonoValue(value: SettingsDisplay.abbreviateHome(VpnConnectionLogger.logPath))
                    SettingsRevealButton(path: VpnConnectionLogger.logPath)
                }
            }
            SettingsRow(label: "Launch log", caption: "Written while the app starts up") {
                HStack(spacing: 8) {
                    SettingsMonoValue(value: SettingsDisplay.abbreviateHome(StartupLog.logPath))
                    SettingsRevealButton(path: StartupLog.logPath)
                }
            }
            SettingsRow(label: "Profiles folder",
                        caption: "\(profileNames.count) profile\(profileNames.count == 1 ? "" : "s") on disk",
                        isLast: true) {
                HStack(spacing: 8) {
                    SettingsMonoValue(value: SettingsDisplay.abbreviateHome(profilesDirectory))
                    SettingsRevealButton(path: profilesDirectory, mode: .folder, title: "Open")
                }
            }
        }
    }

    // MARK: Storage

    private var storageGroup: some View {
        SettingsCard("Storage", note: "Credentials live in your login Keychain — the preferences file only holds settings, ports and paths.") {
            SettingsRow(label: "Preferences") {
                SettingsMonoValue(value: Bundle.main.bundleIdentifier ?? "com.idraki.turtle.vpn")
            }
            SettingsRow(label: "VPN password") {
                credentialPill(for: KeychainHelper.vpnPasswordAccount)
            }
            SettingsRow(label: "Passcode") {
                credentialPill(for: KeychainHelper.vpnPasscodeAccount)
            }
            SettingsRow(label: "Administrator password", isLast: true) {
                credentialPill(for: KeychainHelper.adminPasswordAccount)
            }
        }
    }

    private func credentialPill(for account: String) -> some View {
        SettingsPill(text: presentCredentials.contains(account) ? "In Keychain" : "Not set",
                     tone: presentCredentials.contains(account) ? .ok : .warn)
    }

    /// Only ever asks *whether* an item exists; the value is never read into
    /// the UI (and `retrieve` returns a `String?` we deliberately discard).
    private func refreshCredentials() {
        presentCredentials = Set(KeychainHelper.credentialAccounts.filter {
            !(KeychainHelper.retrieve(account: $0) ?? "").isEmpty
        })
    }

    // MARK: Reset

    private var resetGroup: some View {
        SettingsCard("Reset") {
            SettingsRow(label: "Reset all settings",
                        caption: "Clears saved preferences and deletes the three Keychain credentials. Profiles on disk are kept.",
                        isLast: true) {
                Button("Reset…", role: .destructive) {
                    showResetAlert = true
                }
                .controlSize(.small)
            }
        }
        .alert("Reset all settings?", isPresented: $showResetAlert) {
            Button("Reset", role: .destructive) {
                Task {
                    await SettingsManager.shared.resetAllSettings()
                    refreshCredentials()
                    didReset = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Settings and stored credentials will be deleted. Profiles in \(SettingsDisplay.abbreviateHome(profilesDirectory)) are not touched.")
        }
        .overlay(alignment: .bottomLeading) {
            if didReset {
                Text("Settings reset.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .offset(y: 16)
            }
        }
    }
}
