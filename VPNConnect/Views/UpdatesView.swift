import AppKit
import SwiftUI

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Whether a newer TurtleDiver exists.
///
/// This is the *check*, and only the check: it asks, and it reports what it
/// found. Nothing here downloads or installs, which is why the one row that acts
/// is "Open Release Page" — a thing that does exactly what it says, today.
struct UpdatesView: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var model = UpdateModel.shared

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
                        isLast: true) {
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
        }
    }

    private func offerNote(_ offer: UpdateOffer) -> String {
        offer.canInstall
            ? "This pane checks; it does not download or install. Open the release page to get it."
            : "This release has nothing this app would install, so the release page is all there is."
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
