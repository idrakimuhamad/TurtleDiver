#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif
import Combine
import Foundation

/// Backs the Setup pane: what is installed, what is missing, and installing the
/// missing tools with Homebrew.
///
/// Two rules shape it. It is **advisory** — nothing here gates the app or edits
/// the user's settings, so a tool that is absent produces a status row, not a
/// wall. And the install is a **plain `brew install` run as the user**: no
/// `sudo`, no shell, no password of ours in the command.
@MainActor
public final class ToolSetupModel: ObservableObject {

    /// One row per requirement, in `ToolRequirement.all` order.
    @Published public private(set) var statuses: [ToolStatus] = []
    @Published public private(set) var isChecking = false
    @Published public private(set) var isInstalling = false
    /// The install transcript, oldest first. Bounded — a build can print a lot.
    @Published public private(set) var transcript: [String] = []
    /// The last install's outcome, `nil` until one has been run.
    @Published public private(set) var lastResult: ToolProcessResult?
    /// Set when Homebrew itself is needed but absent, so the pane can explain.
    @Published public private(set) var installRefusal: String?

    /// Keep the pane's memory (and its scroll extent) bounded.
    static let transcriptLimit = 500

    private let doctor: ToolDoctor
    private let installer: ToolInstaller
    private let environment: [String: String]

    public init(doctor: ToolDoctor = ToolDoctor(),
                installer: ToolInstaller = ToolInstaller(),
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.doctor = doctor
        self.installer = installer
        self.environment = environment
    }

    // MARK: Derived state

    public var homebrew: ToolStatus? {
        statuses.first { $0.requirement.id == ToolRequirement.homebrew.id }
    }

    public var hasHomebrew: Bool { homebrew?.isInstalled == true }

    /// The dependencies the app cannot find — Homebrew excluded, since it is the
    /// thing that would install them.
    public var missingDependencies: [ToolRequirement] {
        statuses
            .filter { $0.requirement.formula != nil && !$0.isInstalled }
            .map(\.requirement)
    }

    /// openconnect + stoken: everything a standard VPN connection needs.
    public var isReadyForStandardConnection: Bool {
        !statuses.isEmpty && missing(for: [.openconnect, .stoken]).isEmpty
    }

    /// …plus vpn-slice, for split tunneling.
    public var isReadyForSplitTunneling: Bool {
        !statuses.isEmpty && missing(for: [.openconnect, .stoken, .vpnSlice]).isEmpty
    }

    /// The command to run by hand in Terminal. Always shown: the pane must be
    /// useful to someone who would rather not have the app spawn a process.
    public var manualCommand: String {
        "brew install " + ToolRequirement.installable.compactMap(\.formula).joined(separator: " ")
    }

    public func status(for requirement: ToolRequirement) -> ToolStatus? {
        statuses.first { $0.requirement.id == requirement.id }
    }

    private func missing(for requirements: [ToolRequirement]) -> [ToolRequirement] {
        requirements.filter { status(for: $0)?.isInstalled != true }
    }

    // MARK: Actions

    /// Re-runs the checks. Safe to call at any time; overlapping calls collapse.
    public func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        statuses = await doctor.inspect()
        isChecking = false
    }

    /// Installs `requirements` (default: everything missing) via Homebrew.
    ///
    /// Installing something that is already present is allowed and harmless:
    /// Homebrew reports it and exits 0. That is also how the pane's Install
    /// button can double as "check for a newer version".
    public func install(_ requirements: [ToolRequirement]? = nil) async {
        guard !isInstalling else { return }
        let targets = requirements ?? missingDependencies
        guard !targets.isEmpty else { return }

        guard let brewPath = doctor.locator.locate(ToolRequirement.homebrew.id) else {
            installRefusal = "Homebrew is not installed, so the app cannot install these for you. "
                + "Install it from brew.sh, then come back and press Check Again."
            return
        }
        installRefusal = nil

        guard let plan = ToolInstaller.plan(for: targets, brewPath: brewPath, environment: environment) else {
            return
        }

        isInstalling = true
        lastResult = nil
        transcript = ["$ \(plan.commandLine)"]

        let result = await installer.install(targets,
                                             brewPath: brewPath,
                                             environment: environment) { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }

        lastResult = result
        isInstalling = false
        await refresh()
    }

    private func append(_ line: String) {
        transcript.append(line)
        if transcript.count > Self.transcriptLimit {
            transcript.removeFirst(transcript.count - Self.transcriptLimit)
        }
    }
}
