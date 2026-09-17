#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif
import Combine
import Foundation

/// Backs the Updates pane, the menu-bar row and the check that runs at launch.
///
/// One instance is shared (`shared`) because three things want the same answer:
/// the pane, the status-item menu and the main window's banner. The launch check
/// fills it in once, and the other two read it.
///
/// Two rules shape it. The check is **off the main actor** — the transport waits
/// on a socket, and a check that freezes the interface for twenty seconds is
/// worse than no check at all. And it is **silent about failure in the
/// interface**: a machine with no internet is not a problem the app should
/// interrupt anyone about, so a failed check produces one line of text in one
/// pane and nothing else.
@MainActor
public final class UpdateModel: ObservableObject {

    /// Where the check has got to. Six states rather than a handful of booleans,
    /// because "not asked yet", "asking" and "asked and told nothing usable" are
    /// different things to show.
    public enum Phase: Equatable {
        case idle
        case checking
        case upToDate(ReleaseVersion)
        case available(UpdateOffer)
        case withheld(String)
        case failed(String)
    }

    /// The pill beside the version: three tones, because an available update is
    /// neither a success nor an error.
    public enum StatusTone: String, Sendable {
        case ok
        case attention
        case neutral
    }

    /// Where an install has got to. Separate from `Phase`, because the check and
    /// the install are two different questions and the pane has to be able to
    /// show both answers at once (a newer release may be known *and* installing).
    public enum InstallPhase: Equatable {
        case idle
        case downloading
        case installing
        /// The app on disk is the new one; this process is still the old one.
        case installed(ReleaseVersion)
        /// Verified, but the app could not replace itself where it lives.
        case revealed(version: ReleaseVersion, imageURL: URL)
        /// A deliberate no, with the reason.
        case refused(String)
        case failed(String)
    }

    public static let shared = UpdateModel()

    @Published public private(set) var phase: Phase = .idle
    /// When a check last *succeeded*. A failed check deliberately leaves this
    /// alone, so "Last checked" never reads as a success beside a failure.
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var installPhase: InstallPhase = .idle

    /// The version this build reports about itself, from the bundle.
    public let runningVersion: ReleaseVersion?

    private let checker: UpdateChecker
    private let downloader: UpdateDownloader
    private let installer: any UpdateInstalling
    private let now: () -> Date

    public init(checker: UpdateChecker = UpdateChecker(),
                downloader: UpdateDownloader = UpdateDownloader(),
                installer: any UpdateInstalling = UpdateInstaller(),
                runningVersion: ReleaseVersion? = UpdateFeed.runningVersion(
                    fromShortVersionString: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
                now: @escaping () -> Date = Date.init) {
        self.checker = checker
        self.downloader = downloader
        self.installer = installer
        self.runningVersion = runningVersion
        self.now = now
    }

    // MARK: Derived state

    public var isChecking: Bool { phase == .checking }

    /// The newer release, when there is one — what the banner and the menu row
    /// key off.
    public var offer: UpdateOffer? {
        if case .available(let offer) = phase { return offer }
        return nil
    }

    /// The pill's word. Uppercased by `SettingsPill`, so it is written plainly.
    public var statusText: String {
        switch phase {
        case .idle: return "Not checked"
        case .checking: return "Checking"
        case .upToDate: return "Up to date"
        case .available: return "Available"
        case .withheld: return "No update"
        case .failed: return "Not checked"
        }
    }

    public var statusTone: StatusTone {
        switch phase {
        case .upToDate: return .ok
        case .available: return .attention
        case .idle, .checking, .withheld, .failed: return .neutral
        }
    }

    /// The one line that says what happened, or what to do about it.
    public var summary: String {
        switch phase {
        case .idle:
            return "This build has not asked GitHub yet"
        case .checking:
            return "Asking GitHub for the newest release…"
        case .upToDate(let version):
            return "TurtleDiver \(version) is the newest release"
        case .available(let offer):
            return offer.canInstall
                ? "Version \(offer.version) is available"
                : "Version \(offer.version) is available, but not as a download"
        case .withheld(let reason):
            return reason
        case .failed(let reason):
            return reason
        }
    }

    /// "Checked just now" / "Never" — a pure formatter, so it can be tested
    /// without waiting for time to pass.
    ///
    /// The instant is a parameter because the pane draws this line once and
    /// then hands it a fresh date on every tick: a window left open all day
    /// must not go on claiming the check was "just now".
    public func checkedText(at date: Date) -> String {
        SettingsDisplay.updateChecked(lastChecked, now: date)
    }

    /// The same line, as of the moment the model last read the clock.
    public var checkedText: String {
        checkedText(at: now())
    }

    // MARK: The install, as the pane sees it

    /// True while the button must be busy and unpressable.
    public var isInstalling: Bool {
        installPhase == .downloading || installPhase == .installing
    }

    /// The version waiting for a relaunch, when the app on disk is already new.
    public var waitingVersion: ReleaseVersion? {
        if case .installed(let version) = installPhase { return version }
        return nil
    }

    /// The verified installer to point out, when the app could not install it.
    public var revealedImage: URL? {
        if case .revealed(_, let url) = installPhase { return url }
        return nil
    }

    /// The pill beside the buttons, while something is happening or after it.
    public var installStatusText: String? {
        switch installPhase {
        case .idle: return nil
        case .downloading: return "Downloading"
        case .installing: return "Installing"
        case .installed: return "Ready to restart"
        case .revealed: return "Installer ready"
        case .refused, .failed: return "Not installed"
        }
    }

    public var installStatusTone: StatusTone {
        switch installPhase {
        case .installed, .revealed: return .ok
        case .refused, .failed: return .attention
        case .idle, .downloading, .installing: return .neutral
        }
    }

    /// One sentence about the install, or `nil` when there is nothing to say.
    public var installMessage: String? {
        switch installPhase {
        case .idle, .downloading, .installing:
            return nil
        case .installed(let version):
            return "TurtleDiver \(version) is installed. It takes effect when the app restarts."
        case .revealed(_, let url):
            return "The verified installer \(url.lastPathComponent) is in the Finder: "
                + "this app cannot replace itself where it lives."
        case .refused(let reason):
            return reason
        case .failed(let reason):
            return reason
        }
    }

    // MARK: Actions

    /// The launch check. It takes the setting rather than reading it: that keeps
    /// the gate testable, and keeps this type out of everyone's user defaults.
    public func checkIfEnabled(_ enabled: Bool) async {
        guard enabled else { return }
        await check()
    }

    /// Asks the feed what the newest release is.
    ///
    /// Overlapping calls collapse — a second press while the first is in flight
    /// is ignored rather than queued.
    public func check() async {
        guard !isChecking else { return }
        guard let running = runningVersion else {
            phase = .failed("This build does not say what version it is, so there is nothing to compare")
            return
        }
        phase = .checking

        let checker = self.checker
        // Detached, so the request cannot run on the main actor: `get(_:)` waits
        // on a semaphore, and the interface must keep painting while it does.
        let outcome = await Task.detached(priority: .utility) { () -> Result<UpdateDecision, UpdateFeedError> in
            do {
                return .success(try checker.check(running: running))
            } catch let error as UpdateFeedError {
                return .failure(error)
            } catch {
                // The transport normalises its failures, so this only catches a
                // surprise — and it still has to arrive as a sentence.
                return .failure(.transport(UpdateFeedError.describe(error)))
            }
        }.value

        switch outcome {
        case .success(let decision):
            lastChecked = now()
            switch decision {
            case .upToDate(let version): phase = .upToDate(version)
            case .available(let offer): phase = .available(offer)
            case .withheld(let reason): phase = .withheld(reason)
            }
        case .failure(let error):
            phase = .failed(error.errorDescription ?? "Could not check for updates")
        }
    }

    /// Downloads a verified release and installs it, or explains why it will not.
    ///
    /// The tunnel state is a parameter rather than a read of `VPNManager`: this
    /// type is unit-tested and stays out of the connection's business. Installing
    /// means quitting, and quitting drops the tunnel, so a connected app refuses
    /// — the caller that *did* ask for a disconnect passes `false`, because that
    /// click was the instruction to end the tunnel.
    public func install(isTunnelUp: Bool) async {
        guard !isInstalling else { return }
        guard let running = runningVersion else {
            installPhase = .failed("This build does not say what version it is, "
                                   + "so there is nothing to install over it")
            return
        }
        guard let offer else {
            installPhase = .refused("There is no release to install")
            return
        }
        guard offer.canInstall else {
            installPhase = .refused(offer.withheldReason
                                    ?? "That release has no download this app can verify")
            return
        }
        guard !isTunnelUp else {
            installPhase = .refused("Disconnect the VPN first: installing quits the app, "
                                    + "and quitting ends the tunnel")
            return
        }

        installPhase = .downloading
        let downloader = self.downloader
        let download = await Task.detached(priority: .utility) { () -> Result<DownloadedUpdate, Error> in
            do {
                return .success(try downloader.fetch(offer))
            } catch {
                return .failure(error)
            }
        }.value

        let downloaded: DownloadedUpdate
        switch download {
        case .success(let file):
            downloaded = file
        case .failure(let error):
            installPhase = .failed(Self.sentence(for: error))
            return
        }

        installPhase = .installing
        let installer = self.installer
        let install = await Task.detached(priority: .utility) { () -> Result<InstallOutcome, Error> in
            do {
                return .success(try installer.install(downloaded, running: running))
            } catch {
                return .failure(error)
            }
        }.value

        switch install {
        case .success(.replaced(let version)):
            installPhase = .installed(version)
        case .success(.revealed(let version, let imageURL)):
            installPhase = .revealed(version: version, imageURL: imageURL)
        case .failure(let error):
            installPhase = .failed(Self.sentence(for: error))
        }
    }

    /// Every refusal in this feature reaches the interface as a whole sentence:
    /// the artifact and bundle errors carry their own, and a surprise is at
    /// least described rather than swallowed. A bridged `NSError` is not a
    /// `LocalizedError`, which is why the last line is not redundant.
    static func sentence(for error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        return error.localizedDescription
    }
}
