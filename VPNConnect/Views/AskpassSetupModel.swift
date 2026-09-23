// The app target compiles these files into one module; the SPM target
// `TurtleDiverAppGlue` compiles them standalone, so the engine modules are
// imported only when they exist as modules (see Package.swift).
#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif
import Combine
import Foundation

/// Backs Settings ▸ VPN's "unattended elevation" row: whether this app can
/// elevate through its own askpass helper, and the one action that changes it.
///
/// Two moments, deliberately separate. **Preparing** runs the helper once, from
/// here, so the Keychain dialog macOS raises the first time that program asks
/// appears where the user is looking — and then records which program was
/// approved. **Connecting** uses the helper only while that record still matches
/// the helper in the bundle (`AskpassSetup`). Without the first moment the second
/// one raises the same dialog in the middle of a connect, possibly a connect
/// nobody is watching: the launch waits on it and times out.
///
/// The password never passes through this type. The helper reads the Keychain
/// item itself; what happens here is that `sudo` is pointed at the helper, once,
/// on purpose — the only thing that makes macOS ask about *that* program.
@MainActor
public final class AskpassSetupModel: ObservableObject {

    /// The three states the row can be in.
    public enum Status: Equatable {
        /// This build carries the helper and its recorded approval is current.
        case ready
        /// The helper is here but nothing has been approved — or what was
        /// approved is not the program in the bundle any more (a rebuild).
        case notPrepared
        /// This build carries no helper, so the route does not exist at all.
        case unavailable
    }

    /// The step this model runs, injectable so a test can answer without a
    /// dialog and without a login Keychain.
    public typealias Step = (
        _ arguments: [String],
        _ stdin: Data?,
        _ timeout: TimeInterval,
        _ environment: [String: String]
    ) -> TunnelAgentChannel.SudoStepRunner.Result

    @Published public private(set) var status: Status = .unavailable
    @Published public private(set) var isPreparing = false
    /// What the last attempt amounted to, in the user's words. `nil` until one
    /// has been made.
    @Published public private(set) var outcome: String?

    /// How long the helper is given before this gives up on it. Generous,
    /// because the dialog waits for a person and that person may be hunting for
    /// the window: a preparation that times out while the user is reading the
    /// dialog would be the worst of both.
    public static let preparationTimeout: TimeInterval = 180

    private let settings: SettingsManager
    private let helperPath: String?
    private let step: Step
    private let fingerprint: (String) -> String?

    /// Internal, not public: `SettingsManager` is a member of this module in the
    /// app target and of `TurtleDiverAppGlue` under `swift test`, and it is not a
    /// public type in either. Nothing outside the app builds one of these.
    init(settings: SettingsManager = .shared,
         bundleURL: URL = Bundle.main.bundleURL,
         step: Step? = nil,
         fingerprint: @escaping (String) -> String? = AskpassSetup.fingerprint(ofProgramAt:)) {
        self.settings = settings
        self.helperPath = AskpassSetup.bundledHelperPath(bundleURL: bundleURL)
        self.fingerprint = fingerprint
        self.step = step ?? { arguments, stdin, timeout, environment in
            TunnelAgentChannel.SudoStepRunner().run(
                arguments: arguments,
                stdin: stdin,
                timeout: timeout,
                environment: environment
            )
        }
        refresh()
    }

    // MARK: What the row shows

    /// The helper's path, for a caption that can be checked by hand. `nil` when
    /// this build carries none.
    public var helperPathShown: String? { helperPath }

    public var canPrepare: Bool { helperPath != nil && !isPreparing }

    /// Forgetting is offered only when there is something to forget.
    public var canForget: Bool { status == .ready && !isPreparing }

    /// Re-reads the recorded approval and compares it with the helper on disk.
    /// Cheap and silent by construction: one file read, no prompt, no Keychain.
    public func refresh() {
        guard let helperPath else {
            status = .unavailable
            return
        }
        status = AskpassSetup.isPrepared(helperPath: helperPath,
                                        recorded: settings.askpassHelperRequirement,
                                        fingerprint: fingerprint) ? .ready : .notPrepared
    }

    /// The row's one-line state.
    public static func caption(for status: Status) -> String {
        switch status {
        case .ready:
            return "Ready — \(AskpassProgram.installedName) may read the stored administrator password"
        case .notPrepared:
            return "Not set up — connects ask the system for approval"
        case .unavailable:
            return "Not available in this build"
        }
    }

    /// What the state means, and what the button does about it.
    public static func explanation(for status: Status) -> String {
        switch status {
        case .ready:
            return "A connect hands the administrator password to this helper instead of raising the system "
                + "approval dialog. The approval is remembered as the helper's own signature requirement, so a "
                + "newer build signed by the same developer keeps working — a build signed differently asks you "
                + "to prepare again rather than raising that dialog during a connect."
        case .notPrepared:
            return "On a Mac whose sudo asks with Touch ID, a connect cannot be left to run on its own: the "
                + "dialog waits for someone. Preparing runs this helper once so macOS can ask about it while "
                + "you are here, and connects then need nobody. A build signed differently from the one that was "
                + "approved also shows up here, and preparing again is what fixes it."
        case .unavailable:
            return "This build has no askpass helper in its bundle, so connects ask the system for approval."
        }
    }

    // MARK: Actions

    /// Runs the helper once, on purpose, so the Keychain's question is asked
    /// here — and records what was approved.
    public func prepare() async {
        guard let helperPath, !isPreparing else { return }
        isPreparing = true
        outcome = nil
        defer { isPreparing = false }

        let result = await Self.runOffTheMainThread(
            helperPath: helperPath,
            timeout: Self.preparationTimeout,
            step: step
        )
        // A dialog nobody answers is not an error in the helper: it is a
        // preparation that did not happen, and it says so differently from a
        // password that was refused.
        guard result.succeeded else {
            outcome = Self.refusalText(result)
            refresh()
            return
        }
        guard let record = AskpassSetup.recordToStore(helperPath: helperPath, fingerprint: fingerprint) else {
            outcome = "The helper answered, but its signature could not be read, so nothing was recorded. "
                + "Only a signed build can be approved this way; a development build signed on the spot "
                + "cannot."
            refresh()
            return
        }
        settings.askpassHelperRequirement = record
        outcome = "Approved. Connects hand the administrator password to \(AskpassProgram.installedName) "
            + "instead of asking the system."
        refresh()
    }

    /// Stops using the helper. The Keychain's own entry for the program is not
    /// this app's to remove — the record here is the only thing a connect
    /// consults — so the sentence says exactly what changed.
    public func forget() {
        settings.askpassHelperRequirement = ""
        outcome = "Connects ask the system for approval again."
        refresh()
    }

    // MARK: The step, and what it means

    /// The command that makes macOS ask. It is a connect's own warm-up — `sudo
    /// -A -v` with this app's helper in `SUDO_ASKPASS` — run deliberately:
    /// `-v` refreshes the timestamp and starts nothing, and the askpass form is
    /// what makes `sudo` start the helper, which is what puts the question to
    /// the user.
    public static func preparationArguments() -> [String] {
        TunnelAgentChannel.Launch.warmupArguments(.systemPrompt, delivery: .askpass)
    }

    /// The helper's *path*, and nothing else. The password is printed by that
    /// program out of the Keychain, so it is never in this child's environment.
    public static func preparationEnvironment(helperPath: String) -> [String: String] {
        TunnelAgentChannel.Launch.askpassEnvironment(helperPath: helperPath)
    }

    /// The step off the main thread: it waits for a person, and the window must
    /// stay alive while it does.
    private static func runOffTheMainThread(
        helperPath: String,
        timeout: TimeInterval,
        step: @escaping Step
    ) async -> TunnelAgentChannel.SudoStepRunner.Result {
        let arguments = preparationArguments()
        let environment = preparationEnvironment(helperPath: helperPath)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: step(arguments, nil, timeout, environment))
            }
        }
    }

    /// What to say when the preparation did not succeed.
    ///
    /// `sudo`'s own words win when it has any: they name the real cause (a wrong
    /// password, a helper that exited) better than a sentence written here could.
    /// The app's sentence covers the cases where `sudo` said nothing, which are
    /// exactly the quiet ones a user would otherwise have to guess at.
    public static func refusalText(_ result: TunnelAgentChannel.SudoStepRunner.Result) -> String {
        if result.timedOut {
            return "The helper did not finish. If macOS asked whether \(AskpassProgram.installedName) may "
                + "read the password while you were reading this, prepare again and answer it."
        }
        if let error = result.launchError {
            return "The helper could not be started: \(error)"
        }
        let said = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !said.isEmpty { return "The helper did not supply the password. \(said)" }
        return "The helper did not supply the password (sudo exited \(result.terminationStatus)). "
            + "Check the administrator password above, then prepare again."
    }
}
