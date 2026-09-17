import AppKit
import SwiftUI

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Whether a newer TurtleDiver exists, and getting it.
///
/// The check asks and reports. The install is the user's second decision: it
/// downloads the release over HTTPS, checks it against the published SHA-256 and
/// against its own code signature, and only then touches the app on disk — or,
/// where the app is not the user's to replace, hands the verified installer to the
/// Finder. Nothing is ever downloaded on its own, and nothing is installed while
/// the VPN is up, because installing means quitting and quitting ends the tunnel.
struct UpdatesView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var model = UpdateModel.shared
    @ObservedObject private var vpn = VPNManager.shared

    /// Set by the first click when a tunnel is up, so that the second click is a
    /// second decision rather than a surprise.
    @State private var confirmingDisconnect = false

    var body: some View {
        SettingsPane(title: "Updates",
                     subtitle: "Check for a newer release of the app itself") {
            versionCard
            checkCard
            if let offer = model.offer {
                offerCard(offer)
            }
        }
    }

    // MARK: Version

    private var versionCard: some View {
        SettingsCard("TurtleDiver", note: feedNote) {
            SettingsRow(label: "Installed", caption: model.summary, isLast: true) {
                HStack(spacing: 8) {
                    SettingsMonoValue(value: model.runningVersion?.description ?? "unknown")
                    SettingsPill(text: model.statusText, tone: pillTone)
                }
            }
        }
    }

    /// Where the answer comes from, named: an update check is a supply chain, and
    /// the user is entitled to know whose.
    private var feedNote: String {
        "Version numbers and release files come from the public release list of "
            + "github.com/idrakimuhamad/TurtleDiver. The check sends no credentials, "
            + "no account and nothing about this machine."
    }

    private var pillTone: SettingsPill.Tone {
        switch model.statusTone {
        case .ok: return .ok
        case .attention: return .warn
        case .neutral: return .neutral
        }
    }

    // MARK: Check

    private var checkCard: some View {
        SettingsCard("When to check",
                     note: "One request when TurtleDiver starts. Off means the app never asks "
                        + "unless you press Check Now.") {
            SettingsToggleRow(label: "Check for updates at launch",
                              caption: "The check is off the main thread, so a slow reply never "
                                    + "holds up the window",
                              isOn: $settings.updatesCheckEnabled)
            // Drawn once per render, so it is drawn again on a clock: a pane
            // left open overnight must not still be saying "Checked just now".
            TimelineView(.periodic(from: .now, by: 30)) { context in
                SettingsRow(label: "Last checked",
                            caption: model.checkedText(at: context.date),
                            isLast: true) {
                    HStack(spacing: 8) {
                        if model.isChecking {
                            ProgressView().controlSize(.small)
                        }
                        Button("Check Now") {
                            Task { await model.check() }
                        }
                        .controlSize(.small)
                        .disabled(model.isChecking)
                    }
                }
            }
        }
    }

    // MARK: Offer

    /// Shown only when there is a newer release. `withheldReason` is a sentence
    /// the model was given by `UpdateFeed`, so this pane never has to invent an
    /// explanation for a release the app will not download.
    private func offerCard(_ offer: UpdateOffer) -> some View {
        SettingsCard("Newer release", note: offerNote(offer)) {
            SettingsRow(label: "Version \(offer.version)",
                        caption: offer.withheldReason ?? "Tagged \(offer.tag)",
                        isLast: !offer.canInstall) {
                HStack(spacing: 8) {
                    if let installer = offer.installer {
                        SettingsMonoValue(value: installer.name)
                    }
                    Button("Open Release Page") {
                        open(offer.pageURL)
                    }
                    .controlSize(.small)
                    .disabled(offer.pageURL == nil)
                    .help(offer.pageURL.map(\.absoluteString) ?? "This release has no page URL")
                }
            }
            // A release with nothing this app would install keeps the release-page
            // row alone: there is no install to offer, so no install row appears.
            if offer.canInstall {
                SettingsRow(label: "Install",
                            caption: installCaption(offer),
                            isLast: true) {
                    installControls
                }
            }
        }
    }

    private func offerNote(_ offer: UpdateOffer) -> String {
        offer.canInstall
            ? "Anything downloaded is checked against the release's published SHA-256 and its "
                + "code signature before a single file on disk is touched, and nothing is ever "
                + "downloaded unless you ask for it."
            : "This release has nothing this app would install, so the release page is all there is."
    }

    // MARK: Installing

    /// What the row says. The install's own sentence wins as soon as there is one;
    /// until then this explains what the button is about to do.
    private func installCaption(_ offer: UpdateOffer) -> String {
        if let message = model.installMessage { return message }
        if isConnected {
            return "Installing quits the app, and quitting ends the VPN tunnel, so this "
                + "disconnects first."
        }
        return "Downloads \(offer.installer?.name ?? "the release"), checks it, and replaces "
            + "this app — or puts it in the Finder if this app cannot replace itself."
    }

    @ViewBuilder
    private var installControls: some View {
        HStack(spacing: 8) {
            if let text = model.installStatusText {
                SettingsPill(text: text, tone: installTone)
            }
            if model.isInstalling {
                ProgressView().controlSize(.small)
            }
            if model.waitingVersion != nil {
                // The app on disk is already the new one; this process is not.
                Button("Restart Now") { restart() }
                    .controlSize(.small)
            } else if let image = model.revealedImage {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([image])
                }
                .controlSize(.small)
            } else {
                installButton
            }
        }
    }

    @ViewBuilder
    private var installButton: some View {
        if isConnected && !confirmingDisconnect {
            Button("Disconnect and Update…") { confirmingDisconnect = true }
                .controlSize(.small)
                .disabled(model.isInstalling)
        } else if isConnected {
            Button("Disconnect and Install") { startInstall(disconnecting: true) }
                .controlSize(.small)
                .disabled(model.isInstalling)
        } else {
            Button("Download and Install") { startInstall(disconnecting: false) }
                .controlSize(.small)
                .disabled(model.isInstalling)
        }
    }

    private var installTone: SettingsPill.Tone {
        switch model.installStatusTone {
        case .ok: return .ok
        case .attention: return .warn
        case .neutral: return .neutral
        }
    }

    private var isConnected: Bool { vpn.status == .connected }

    /// `disconnecting` is true only when the user asked for both, in two clicks.
    ///
    /// The tunnel state the model is given is the user's *intent*, not a status
    /// read: `VPNManager.disconnect()` returns before the process is gone, so
    /// reading the status here would race the disconnect this very click asked
    /// for. A connected app that was *not* told to disconnect passes `true`, and
    /// the model refuses — which is the promise the tests pin.
    private func startInstall(disconnecting: Bool) {
        if disconnecting { vpn.disconnect() }
        confirmingDisconnect = false
        Task { await model.install(isTunnelUp: !disconnecting) }
    }

    /// Quits into the build that was just installed. The waiter is started before
    /// the quit, and if it cannot start the app stays put: leaving the user with
    /// nothing open would be worse than leaving them on the old build.
    private func restart() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.relaunchAfterUpdate(at: URL(fileURLWithPath: Bundle.main.bundlePath))
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
