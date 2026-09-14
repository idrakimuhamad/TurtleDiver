import SwiftUI

// MARK: - Dashboard View

/// Live view of the proxy engine: on/off, listening ports, system proxy,
/// policy health badges, and the request table (shared with the main window's
/// expanded dashboard via `RequestsCard`).
struct DashboardView: View {
    @ObservedObject private var controller = EngineController.shared
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Form {
            engineSection
            policySection
            requestSection
        }
        .formStyle(.grouped)
        .onAppear { controller.refreshRequests() }
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

    // MARK: Requests

    private var requestSection: some View {
        Section {
            RequestsCard(compactRows: true, chrome: false)
        }
    }
}
