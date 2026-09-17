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

    public static let shared = UpdateModel()

    @Published public private(set) var phase: Phase = .idle
    /// When a check last *succeeded*. A failed check deliberately leaves this
    /// alone, so "Last checked" never reads as a success beside a failure.
    @Published public private(set) var lastChecked: Date?

    /// The version this build reports about itself, from the bundle.
    public let runningVersion: ReleaseVersion?

    private let checker: UpdateChecker
    private let now: () -> Date

    public init(checker: UpdateChecker = UpdateChecker(),
                runningVersion: ReleaseVersion? = UpdateFeed.runningVersion(
                    fromShortVersionString: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
                now: @escaping () -> Date = Date.init) {
        self.checker = checker
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
    public var checkedText: String {
        SettingsDisplay.updateChecked(lastChecked, now: now())
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
}
