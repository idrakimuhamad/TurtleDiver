import Foundation

/// Manages Surge-style profile files on disk and the active-profile selection.
///
/// Storage layout:
/// ```
/// ~/Library/Application Support/TurtleDiver/Profiles/<name>.conf
/// ```
/// Active profile name is persisted in UserDefaults (key `activeProfileName`),
/// alongside the legacy PAC settings in `SettingsManager` (untouched).
public final class ProfileManager: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = ProfileManager()

    // MARK: - Persistence keys

    enum DefaultsKeys {
        static let activeProfileName = "activeProfileName"
    }

    // MARK: - Published state (bridged to Combine for the app UI)

    public private(set) var activeProfile: Profile {
        didSet { objectWillChangePublisher?() }
    }
    public private(set) var diagnostics: [ProfileDiagnostic] = [] {
        didSet { objectWillChangePublisher?() }
    }
    /// Diagnostics from the last `validate()` of the active profile (policy
    /// reference errors, cycles, etc.) — separate from parse diagnostics.
    public private(set) var validationErrors: [Profile.ValidationError] = [] {
        didSet { objectWillChangePublisher?() }
    }
    /// True when the active profile's INI changed on disk but hasn't been
    /// reloaded yet (auto-reload is throttled).
    public private(set) var needsReload: Bool = false {
        didSet { objectWillChangePublisher?() }
    }

    /// Bridge so the AppKit/SwiftUI layer can attach an `ObservableObject`
    /// change publisher without making this file import Combine explicitly
    /// (keeps the engine Foundation-only for the SPM test target).
    public var objectWillChangePublisher: (() -> Void)?

    // MARK: - Paths

    public let profilesDirectory: URL
    private let defaults: UserDefaults

    /// DispatchSourceFileSystemObject watcher for the active profile file.
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watcherFD: CInt = -1
    /// Debounce for reload-on-change.
    private var reloadWorkItem: DispatchWorkItem?
    private let reloadQueue = DispatchQueue(label: "com.turtlediver.profiles.reload", qos: .utility)

    /// Lock guarding activeProfile/diagnostics mutation from concurrent saves.
    private let stateLock = NSLock()

    // MARK: - Init

    public init(
        profilesDirectory: URL? = nil,
        defaults: UserDefaults = .standard
    ) {
        if let dir = profilesDirectory {
            self.profilesDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.profilesDirectory = appSupport
                .appendingPathComponent("TurtleDiver", isDirectory: true)
                .appendingPathComponent("Profiles", isDirectory: true)
        }
        self.defaults = defaults

        try? FileManager.default.createDirectory(at: self.profilesDirectory, withIntermediateDirectories: true)

        // Placeholder so instance methods are safe to call below; replaced
        // immediately after by the saved or newly created profile.
        self.activeProfile = Profile(name: "Main")

        // Load active profile or create default.
        let savedName = defaults.string(forKey: DefaultsKeys.activeProfileName)
        let loaded = savedName.flatMap { loadProfile(named: $0) }
        if let loaded = loaded {
            activeProfile = loaded
            _ = watchActiveProfileFile()
        } else {
            let fallbackName = savedName ?? "Main"
            let created = ProfileManager.makeDefaultProfile(name: fallbackName)
            activeProfile = created
            saveProfile(created)
            defaults.set(created.name, forKey: DefaultsKeys.activeProfileName)
            _ = watchActiveProfileFile()
        }
        revalidate()
    }

    // MARK: - Profile CRUD

    /// All profile file names (without `.conf`), sorted.
    public func listProfileNames() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: profilesDirectory.path) else { return [] }
        return files
            .filter { $0.hasSuffix(".conf") }
            .map { String($0.dropLast(5)) }
            .sorted()
    }

    /// Loads and parses a profile by name. Returns nil if missing/unreadable.
    public func loadProfile(named name: String) -> Profile? {
        guard let text = try? String(contentsOf: fileURL(for: name), encoding: .utf8) else { return nil }
        return ProfileParser.parse(text, name: name).profile
    }

    /// Parses a profile and returns both model and diagnostics (for the editor UI).
    public func loadProfileWithDiagnostics(named name: String) -> (Profile, [ProfileDiagnostic])? {
        guard let text = try? String(contentsOf: fileURL(for: name), encoding: .utf8) else { return nil }
        let result = ProfileParser.parse(text, name: name)
        return (result.profile, result.diagnostics)
    }

    /// Writes the profile to disk as INI (atomic write) and returns diagnostics
    /// from re-parsing the serialized text. Does NOT switch the active profile.
    @discardableResult
    public func saveProfile(_ profile: Profile) -> [ProfileDiagnostic] {
        let text = ProfileSerializer.serialize(profile)
        let url = fileURL(for: profile.name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return [ProfileDiagnostic(line: 0, message: "Failed to write profile: \(error.localizedDescription)")]
        }
        return ProfileParser.parse(text, name: profile.name).diagnostics
    }

    /// Saves and switches the active profile to `profile` (used by the editor).
    public func saveAndActivate(_ profile: Profile) -> [ProfileDiagnostic] {
        stateLock.lock()
        defer { stateLock.unlock() }
        unwatchActiveProfileFile()
        let diags = saveProfile(profile)
        activeProfile = profile
        defaults.set(profile.name, forKey: DefaultsKeys.activeProfileName)
        revalidate()
        _ = watchActiveProfileFile()
        return diags
    }

    /// Switches the active profile to an existing one by name.
    /// Returns false when the profile doesn't exist.
    @discardableResult
    public func activateProfile(named name: String) -> Bool {
        guard loadProfile(named: name) != nil else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        unwatchActiveProfileFile()
        defaults.set(name, forKey: DefaultsKeys.activeProfileName)
        activeProfile = loadProfile(named: name)!
        revalidate()
        _ = watchActiveProfileFile()
        return true
    }

    /// Creates a new empty profile (with defaults + FINAL,DIRECT) and activates it.
    @discardableResult
    public func createProfile(named name: String) -> Profile {
        let profile = Profile(name: name)
        saveProfile(profile)
        activateProfile(named: name)
        return profile
    }

    /// Deletes a profile file. Refuses to delete the active profile.
    public func deleteProfile(named name: String) -> Bool {
        guard name != activeProfile.name else { return false }
        return (try? FileManager.default.removeItem(at: fileURL(for: name))) != nil
    }

    /// Duplicates an existing profile under a new name (does not activate).
    @discardableResult
    public func duplicateProfile(named source: String, as target: String) -> Profile? {
        guard let profile = loadProfile(named: source) else { return nil }
        var copy = profile
        copy.name = target
        saveProfile(copy)
        return copy
    }

    // MARK: - Reload & watching

    /// Re-reads the active profile from disk (external edits, e.g. hand-editing
    /// in an editor). Safe to call repeatedly.
    @discardableResult
    public func reloadActiveProfile() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let fresh = loadProfile(named: activeProfile.name) else { return false }
        activeProfile = fresh
        needsReload = false
        revalidate()
        return true
    }

    /// Starts watching the active profile file; schedules a throttled reload
    /// when it changes on disk.
    private func watchActiveProfileFile() -> Bool {
        unwatchActiveProfileFile()
        let url = fileURL(for: activeProfile.name)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        watcherFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: reloadQueue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleReload()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.watcherFD >= 0 { close(self.watcherFD); self.watcherFD = -1 }
        }
        source.resume()
        fileWatcher = source
        return true
    }

    private func unwatchActiveProfileFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        // fd is closed by the cancel handler; reset here as a fallback.
        if watcherFD >= 0 { close(watcherFD); watcherFD = -1 }
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            _ = self.reloadActiveProfile()
            self.needsReload = false
        }
        reloadWorkItem = item
        reloadQueue.asyncAfter(deadline: .now() + 0.3, execute: item)
        DispatchQueue.main.async { [weak self] in
            self?.needsReload = true
        }
        // Note: if the file was deleted externally, loadProfile fails and the
        // previous in-memory profile stays active until the app restarts.
    }

    // MARK: - Validation

    private func revalidate() {
        validationErrors = activeProfile.validate()
    }

    // MARK: - Default profile

    /// The starter profile created on first launch.
    public static func makeDefaultProfile(name: String) -> Profile {
        var profile = Profile(name: name)
        profile.rules = [
            ProfileRule(type: .final, value: "", policy: BuiltinPolicy.direct.rawValue)
        ]
        return profile
    }

    // MARK: - Helpers

    public func fileURL(for name: String) -> URL {
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return profilesDirectory.appendingPathComponent("\(safeName).conf")
    }

    // MARK: - Testing hooks

    /// Stops the file watcher (tests call this to avoid leaked watchers).
    public func stopWatchingForTests() {
        unwatchActiveProfileFile()
    }
}
