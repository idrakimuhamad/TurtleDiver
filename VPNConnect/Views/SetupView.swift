import AppKit
import SwiftUI

#if canImport(TurtleDiverEngine)
import TurtleDiverEngine
#endif
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// The command-line tools the app drives, and installing the missing ones.
///
/// The app is a shell around `openconnect`, `stoken` and `vpn-slice`; when one
/// of them is absent the failure used to arrive as "Failed to generate token",
/// which sends you to check your PIN and token file while the real problem is
/// that nothing is installed. This pane is where that gets answered.
///
/// It is deliberately advisory: it reports, it offers Homebrew's own installer,
/// and it never blocks the rest of the app or touches anyone's settings.
struct SetupView: View {
    @StateObject private var model = ToolSetupModel()

    var body: some View {
        SettingsPane(title: "Setup",
                     subtitle: "The command-line tools the app drives, and installing them") {
            toolsCard
            installCard
            outputCard
        }
        .task { await model.refresh() }
    }

    // MARK: Tools

    private var toolsCard: some View {
        SettingsCard("Required tools",
                     note: "Found on your PATH first, then /opt/homebrew/bin, /usr/local/bin, /opt/local/bin and ~/.local/bin — the prefixes Homebrew and MacPorts use, whether or not the app inherited them.") {
            if model.statuses.isEmpty {
                SettingsRow(label: "Checking…", isLast: true) {
                    ProgressView().controlSize(.small)
                }
            } else {
                ForEach(Array(model.statuses.enumerated()), id: \.element.id) { index, status in
                    toolRow(status, isLast: index == model.statuses.count - 1)
                }
            }
        }
    }

    private func toolRow(_ status: ToolStatus, isLast: Bool) -> some View {
        SettingsRow(label: status.requirement.displayName,
                    caption: status.requirement.consequence,
                    isLast: isLast) {
            HStack(spacing: 8) {
                if let path = status.path {
                    SettingsMonoValue(value: SettingsDisplay.abbreviateHome(path))
                }
                SettingsPill(text: status.versionSummary,
                             tone: status.isInstalled ? .ok : .warn)
                if !status.isInstalled {
                    installControl(for: status.requirement)
                }
            }
        }
    }

    /// "Install" when Homebrew is available to do it, "brew.sh" when the missing
    /// tool *is* Homebrew — the app will not install Homebrew for you.
    @ViewBuilder
    private func installControl(for requirement: ToolRequirement) -> some View {
        if requirement.id == ToolRequirement.homebrew.id {
            Button("brew.sh") { open(requirement.documentationURL) }
                .controlSize(.small)
        } else if model.hasHomebrew {
            Button("Install") {
                Task { await model.install([requirement]) }
            }
            .controlSize(.small)
            .disabled(model.isInstalling)
        } else {
            Button("brew.sh") { open(ToolRequirement.homebrew.documentationURL) }
                .controlSize(.small)
                .help("Homebrew is required before it can install \(requirement.displayName)")
        }
    }

    // MARK: Install

    private var installCard: some View {
        SettingsCard("Install",
                     note: "Homebrew runs as you, with no sudo and no password of the app's. Installing a tool you already have is safe — Homebrew simply says so.") {
            SettingsRow(label: "Missing tools") {
                HStack(spacing: 8) {
                    SettingsPill(text: missingSummary, tone: model.missingDependencies.isEmpty ? .ok : .warn)
                    Button("Install Missing") {
                        Task { await model.install() }
                    }
                    .controlSize(.small)
                    .disabled(model.isInstalling || model.missingDependencies.isEmpty || !model.hasHomebrew)
                    .help(model.hasHomebrew
                          ? "Runs brew install for the tools that are not installed"
                          : "Homebrew is required first — see brew.sh")
                }
            }
            SettingsRow(label: "By hand",
                        caption: "The same command, if you would rather run it in Terminal") {
                SettingsMonoValue(value: model.manualCommand)
            }
            if let refusal = model.installRefusal {
                SettingsRow(label: "Homebrew missing", caption: refusal) {
                    Button("brew.sh") { open(ToolRequirement.homebrew.documentationURL) }
                        .controlSize(.small)
                }
            }
            SettingsRow(label: "Re-check",
                        caption: model.isChecking ? "Checking…" : "The app resolves these afresh; restart is not needed",
                        isLast: true) {
                HStack(spacing: 8) {
                    if model.isInstalling {
                        ProgressView().controlSize(.small)
                    }
                    Button("Check Again") {
                        Task { await model.refresh() }
                    }
                    .controlSize(.small)
                    .disabled(model.isChecking || model.isInstalling)
                }
            }
        }
    }

    private var missingSummary: String {
        if model.statuses.isEmpty { return "Checking…" }
        let missing = model.missingDependencies.count
        if missing == 0 { return "All installed" }
        return missing == 1 ? "1 tool missing" : "\(missing) tools missing"
    }

    // MARK: Output

    @ViewBuilder
    private var outputCard: some View {
        if !model.transcript.isEmpty {
            SettingsCard("Homebrew output", note: outputNote) {
                console
            }
        }
    }

    private var outputNote: String? {
        if model.isInstalling { return "Running…" }
        guard let result = model.lastResult else { return nil }
        if result.succeeded { return "Finished. The tools above were checked again." }
        let detail = result.lastLine
        return detail.isEmpty
            ? "Homebrew exited with status \(result.status)."
            : "Homebrew exited with status \(result.status): \(detail)"
    }

    /// The same dark console as the main window's log, so the two read alike.
    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(DebugLogParser.lines(from: model.transcript.joined(separator: "\n"))) { line in
                        Text(verbatim: (line.time.isEmpty ? "" : line.time + " ") + line.body)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(bodyColor(line.severity))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id(consoleBottomAnchor)
                }
                .textSelection(.enabled)
                .padding(8)
            }
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.10)))
            .onAppear { proxy.scrollTo(consoleBottomAnchor, anchor: .bottom) }
            .onChange(of: model.transcript.count) { _, _ in
                proxy.scrollTo(consoleBottomAnchor, anchor: .bottom)
            }
        }
        .padding(SettingsStyle.rowPaddingH)
    }

    private let consoleBottomAnchor = "setupConsoleBottom"

    private func bodyColor(_ severity: DebugLogLine.Severity) -> Color {
        switch severity {
        case .normal: return Color(white: 0.93)
        case .highlight: return Color(red: 0.42, green: 0.85, blue: 0.5)
        case .warning: return Color(red: 1.0, green: 0.78, blue: 0.35)
        case .error: return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
    }

    private func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }
}
