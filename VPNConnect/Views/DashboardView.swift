import SwiftUI

// MARK: - Dashboard View

/// Live view of the proxy engine: on/off, listening ports, system proxy,
/// policy health badges, and the request table (shared with the main window's
/// expanded dashboard via `RequestsCard`).
struct DashboardView: View {
    @ObservedObject private var controller = EngineController.shared
    @ObservedObject private var settings = SettingsManager.shared
    @State private var revealSharePassword = false
    @State private var confirmPasswordReset = false
    @State private var showSetupSteps = false

    var body: some View {
        Form {
            engineSection
            shareSection
            policySection
            detailSection
            requestSection
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshRequests() }
    }

    // MARK: Share with a device

    private var shareSection: some View {
        Section {
            Toggle("Share with a device", isOn: $settings.shareWithDevice)
                .padding(.vertical, 4)

            if settings.shareWithDevice {
                Label(shareStatus, systemImage: shareStatusSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(shareStatusColor)

                if case let .active(host, port) = controller.shareState {
                    LabeledContent("Server") { shareCopyValue(host) }
                    LabeledContent("Port") { shareCopyValue(String(port)) }
                    if let setupURL = controller.sharePACURL {
                        LabeledContent("Setup URL") { shareCopyValue(setupURL) }
                    }
                    LabeledContent("Username") {
                        Text(controller.shareUsername).font(.system(size: 11, design: .monospaced))
                    }
                    LabeledContent("Password") {
                        if let password = controller.sharePassword {
                            HStack(spacing: 6) {
                                Text(revealSharePassword ? password : String(repeating: "•", count: 10))
                                    .font(.system(size: 11, design: .monospaced))
                                Button { revealSharePassword.toggle() } label: {
                                    Image(systemName: revealSharePassword ? "eye.slash" : "eye")
                                }.help(revealSharePassword ? "Hide password" : "Show password")
                                Button { copyShareValue(password) } label: {
                                    Image(systemName: "doc.on.doc")
                                }.help("Copy password")
                                Button("Regenerate…") { confirmPasswordReset = true }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10))
                        } else {
                            Label(controller.sharePasswordError ?? "Password unavailable.", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.orange)
                        }
                    }
                    if controller.sharePassword != nil, let error = controller.sharePasswordError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }

                    DisclosureGroup("Setup instructions", isExpanded: $showSetupSteps) {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Automatic (recommended): On the phone, open Wi-Fi settings for this network, choose Proxy › Automatic / Auto-config, then paste the Setup URL. Only traffic that needs the VPN goes through the Mac; the rest goes direct from the phone.")
                            Text("Manual: Choose Proxy › Manual and enter the Server and Port above. On iPhone or iPad, turn on Authentication and enter the username and password.")
                            Text("Android can't save a proxy password: open any site on the phone, then allow it below. On iPhone or iPad, enter the username and password when asked the first time.")
                            Text("If the Mac sleeps or sharing stops, iPhones may lose connection until it is back; Android goes direct. Regenerating the password changes the Setup URL, so update it on the phone.")
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 5)
                    }
                    .font(.system(size: 11, weight: .medium))

                    if !controller.shareRefusedClients.isEmpty {
                        Text("NEEDS APPROVAL").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        ForEach(controller.shareRefusedClients, id: \.address) { client in
                            HStack(spacing: 7) {
                                Text(client.address).font(.system(size: 10, design: .monospaced))
                                Text("· \(client.attempts) \(client.attempts == 1 ? "attempt" : "attempts") · \(client.lastAttempt, style: .relative) ago")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                Button("Allow") { controller.allowShareClient(client.address) }.controlSize(.small)
                            }
                        }
                    }
                    if !settings.shareAllowedClients.isEmpty {
                        Text("ALLOWED DEVICES").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        ForEach(settings.shareAllowedClients, id: \.self) { address in
                            HStack {
                                Text(address).font(.system(size: 10, design: .monospaced))
                                Spacer()
                                Button("Remove") { controller.removeShareClient(address) }
                                    .controlSize(.small).buttonStyle(.borderless)
                            }
                        }
                    }
                    Text("Only traffic that uses the Wi-Fi proxy is routed. Browsers and most apps do; some games and apps ignore it.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Share with a device").font(.system(size: 12, weight: .regular)).textCase(.uppercase)
        }
        .alert("Regenerate the share password?", isPresented: $confirmPasswordReset) {
            Button("Cancel", role: .cancel) {}
            Button("Regenerate", role: .destructive) { controller.regenerateSharePassword() }
        } message: {
            Text("Update the password and Setup URL on any phones using this share.")
        }
    }

    private var shareStatus: String {
        switch controller.shareState {
        case .off: return "Starting…"
        case .waitingForEngine: return "Waiting for the proxy engine"
        case .waitingForTunnel: return "Waiting for VPN connection"
        case .noNetwork: return "No Wi-Fi or Ethernet address found"
        case .active: return "Ready on your local network"
        case .failed(let message): return "Sharing failed: \(message)"
        }
    }

    private var shareStatusSymbol: String {
        if case .active = controller.shareState { return "checkmark.circle.fill" }
        if case .failed = controller.shareState { return "exclamationmark.triangle.fill" }
        return "hourglass"
    }

    private var shareStatusColor: Color {
        if case .active = controller.shareState { return .green }
        if case .failed = controller.shareState { return .orange }
        return .secondary
    }

    private func shareCopyValue(_ value: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 11, design: .monospaced))
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
            Button { copyShareValue(value) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy")
        }
    }

    private func copyShareValue(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    // MARK: Engine controls

    private var engineSection: some View {
        Section {
            Toggle("Proxy Engine", isOn: Binding(
                get: { controller.engineRunning },
                set: { controller.setEngineEnabled($0) }
            ))
            .padding(.vertical, 4)

            Toggle("Use as System Proxy", isOn: Binding(
                get: { controller.systemProxyOn },
                set: { on in
                    Task { await controller.setSystemProxyEnabled(on) }
                }
            ))
            .disabled(!controller.engineRunning || controller.systemProxyBusy)
            .padding(.vertical, 4)

            if controller.systemProxyBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Applying proxy settings…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if controller.engineRunning {
                LabeledContent("HTTP") {
                    Text(verbatim: controller.httpPort.map { "127.0.0.1:\($0)" } ?? "off")
                        .font(.system(size: 12, design: .monospaced))
                }
                LabeledContent("SOCKS5") {
                    Text(verbatim: controller.socks5Port.map { "127.0.0.1:\($0)" } ?? "off")
                        .font(.system(size: 12, design: .monospaced))
                }
            }

            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
        } header: {
            Text("Engine")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        }
    }

    // MARK: Policies

    private var policySection: some View {
        Section {
            if controller.policySummaries.isEmpty {
                Text("No policies defined in the active profile.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(controller.policySummaries, id: \.name) { summary in
                    HStack {
                        Text(summary.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(kindDescription(summary.kind))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Spacer()
                        policyBadge(summary)
                    }
                    .padding(.vertical, 2)
                }
            }
            selectGroupOverrides
        } header: {
            Text("Policies")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        }
    }

    /// One-tap override pickers for `select` groups (persisted by PolicyStore).
    @ViewBuilder
    private var selectGroupOverrides: some View {
        let groups = ProfileManager.shared.activeProfile.groups.filter { $0.type == .select }
        ForEach(groups) { group in
            Picker(group.name, selection: Binding(
                get: {
                    controller.engine.policyStore.selection(forGroup: group.name)
                        ?? group.policies.first
                        ?? BuiltinPolicy.direct.rawValue
                },
                set: { newValue in
                    controller.engine.policyStore.setSelection(newValue, forGroup: group.name)
                }
            )) {
                ForEach(group.policies, id: \.self) { member in
                    Text(member).tag(member)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func kindDescription(_ kind: PolicySummary.Kind) -> String {
        switch kind {
        case .builtin:
            return "built-in"
        case .proxy(let type, let host, let port):
            return "\(type.rawValue) \(host):\(port)"
        case .group(let type, let members):
            return "\(type.rawValue) · \(members.joined(separator: ", "))"
        }
    }

    @ViewBuilder
    private func policyBadge(_ summary: PolicySummary) -> some View {
        let health = summary.health
        switch health.lastResult {
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

    // MARK: Request details

    /// Two switches, because they answer two different questions: whether to
    /// keep detail at all, and whether to keep the parts of it that are
    /// somebody's credentials. The second one is off until asked for.
    private var detailSection: some View {
        Section {
            Toggle("Record request details", isOn: Binding(
                get: { settings.recordRequestDetails },
                set: { on in
                    settings.recordRequestDetails = on
                    controller.refreshRequestDetailSettings()
                }
            ))
            .padding(.vertical, 4)

            Toggle("Show sensitive header values", isOn: Binding(
                get: { settings.revealSensitiveHeaders },
                set: { on in
                    settings.revealSensitiveHeaders = on
                    controller.refreshRequestDetailSettings()
                }
            ))
            .disabled(!settings.recordRequestDetails)
            .help("Applies to requests made from now on: a value hidden at capture time is not kept anywhere to reveal later.")
            .padding(.vertical, 4)
        } header: {
            Text("Request details")
                .font(.system(size: 12, weight: .regular))
                .textCase(.uppercase)
        } footer: {
            // Short: macOS renders section footers on one line and truncates.
            Text("Memory only, never in the debug log. Sensitive values stay hidden unless allowed.")
                .font(.system(size: 11))
        }
    }

    // MARK: Requests

    private var requestSection: some View {
        Section {
            RequestsCard(compactRows: true, chrome: false)
        }
    }
}
