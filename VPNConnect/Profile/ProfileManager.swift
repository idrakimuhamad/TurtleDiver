import Foundation

/// A snapshot of a profile file kept by `ProfileManager`.
///
/// Backups are byte-for-byte copies of the profile file at the moment before it
/// was changed. They live outside `Profiles/`, so they are never listed as
/// profiles, and are pruned newest-first per profile.
public struct ProfileBackup: Identifiable, Equatable, Sendable {
    /// Location of the backup file on disk.
    public let url: URL
    /// The profile this backup belongs to (the name used when it was recorded).
    public let profileName: String
    /// When the backup was taken, parsed from the file name (UTC).
    public let date: Date
    /// Rules in the backed-up text (`0` when the text does not parse).
    public let ruleCount: Int
    /// Proxies in the backed-up text (`0` when the text does not parse).
    public let proxyCount: Int
    /// Size of the backup file in bytes.
    public let byteCount: Int

    public var id: String { url.path }

    public init(
        url: URL,
        profileName: String,
        date: Date,
        ruleCount: Int,
        proxyCount: Int,
        byteCount: Int
    ) {
        self.url = url
        self.profileName = profileName
        self.date = date
        self.ruleCount = ruleCount
        self.proxyCount = proxyCount
        self.byteCount = byteCount
    }
}

/// Manages Surge-style profile files on disk and the active-profile selection.
///
/// Storage layout:
/// ```
/// ~/Library/Application Support/TurtleDiver/Profiles/<name>.conf
/// ~/Library/Application Support/TurtleDiver/ProfileBackups/<name>/<timestamp>.conf
/// ```
/// Active profile name is persisted in UserDefaults (key `activeProfileName`),
/// alongside the legacy PAC settings in `SettingsManager` (untouched).
///
/// Backups are byte-exact copies of the *previous* on-disk content, recorded
/// before a save that changes the file, before a delete, and when the file
/// watcher notices an external edit. The newest `maxBackupsPerProfile` are
/// kept per profile. A backup failure never blocks the write it precedes.
public final class ProfileManager: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared: ProfileManager = {
        sharedInstantiationCountForTests += 1
        return ProfileManager()
    }()

    /// Test hook: how many times the `.shared` singleton has been constructed
    /// in this process. Touching `.shared` initialises it, so this lets a test
    /// prove that constructing engine glue with an injected manager never
    /// reaches the real profiles directory.
    public private(set) static var sharedInstantiationCountForTests = 0

    // MARK: - Persistence keys

    enum DefaultsKeys {
        static let activeProfileName = "activeProfileName"
    }

    /// How many backups are kept per profile; older ones are pruned.
    static let maxBackupsPerProfile = 20

    /// Directory (inside an injected profile directory) used for backups when
    /// the caller did not supply one. Dot-prefixed, so neither the app's
    /// listing nor the CLI's profile directory sees it.
    static let derivedBackupsDirectoryName = ".backups"

    /// Backup file-name timestamp: sortable UTC, millisecond precision.
    private static let backupTimestampFormat = "yyyyMMdd-HHmmss-SSS"
    private static let backupTimestampLength = 19

    // MARK: - Published state (bridged to Combine for the app UI)

    public private(set) var activeProfile: Profile {
        didSet { notifyChange() }
    }
    public private(set) var diagnostics: [ProfileDiagnostic] = [] {
        didSet { notifyChange() }
    }
    /// Diagnostics from the last `validate()` of the active profile (policy
    /// reference errors, cycles, etc.) — separate from parse diagnostics.
    public private(set) var validationErrors: [Profile.ValidationError] = [] {
        didSet { notifyChange() }
    }
    /// True when the active profile's INI changed on disk but hasn't been
    /// reloaded yet (auto-reload is throttled).
    public private(set) var needsReload: Bool = false {
        didSet { notifyChange() }
    }

    /// Bridge so the AppKit/SwiftUI layer can attach an `ObservableObject`
    /// change publisher without making this file import Combine explicitly
    /// (keeps the engine Foundation-only for the SPM test target).
    public var objectWillChangePublisher: (() -> Void)?

    // MARK: - Paths

    public let profilesDirectory: URL
    /// Root of the per-profile backup directories.
    public let backupsDirectory: URL
    /// Reads and writes the active-profile name and other manager state.
    /// Exposed so the engine can gate its one-shot migrations on the same
    /// domain the manager uses (tests inject a suite).
    public let defaults: UserDefaults
    /// Coalescing bridges registered by consumers that cannot use the single
    /// `objectWillChangePublisher` slot (the engine, several views).
    private var changeObservers: [UUID: () -> Void] = [:]

    /// DispatchSourceFileSystemObject watcher for the active profile file.
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var watcherFD: CInt = -1
    /// Debounce for reload-on-change.
    private var reloadWorkItem: DispatchWorkItem?
    private let reloadQueue = DispatchQueue(label: "com.turtlediver.profiles.reload", qos: .utility)

    /// Byte-exact content last observed on disk for the active profile. Used to
    /// back up external edits (the watcher only tells us *that* it changed).
    private var lastKnownActiveFileData: Data?

    /// Lock guarding activeProfile/diagnostics mutation from concurrent saves.
    /// Recursive because `saveAndActivate` funnels into `saveProfile`, and both
    /// take it.
    private let stateLock = NSRecursiveLock()

    // MARK: - Init

    /// - Parameters:
    ///   - profilesDirectory: Overrides the profile directory (tests).
    ///   - defaults: UserDefaults suite holding `activeProfileName` (tests).
    ///   - backupsDirectory: Overrides the backup root (tests). When omitted it
    ///     is derived next to `profilesDirectory` if one was supplied, otherwise
    ///     `~/Library/Application Support/TurtleDiver/ProfileBackups`.
    public init(
        profilesDirectory: URL? = nil,
        defaults: UserDefaults = .standard,
        backupsDirectory: URL? = nil
    ) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let dir = profilesDirectory {
            self.profilesDirectory = dir
        } else {
            self.profilesDirectory = appSupport
                .appendingPathComponent("TurtleDiver", isDirectory: true)
                .appendingPathComponent("Profiles", isDirectory: true)
        }
        if let dir = backupsDirectory {
            self.backupsDirectory = dir
        } else if profilesDirectory != nil {
            // Injected profile directories are fixtures (and, at worst, a
            // user-chosen folder). Derive the backups inside them rather than
            // as a sibling: siblings of unique temp directories would all be
            // `NSTemporaryDirectory()/ProfileBackups` and share fixtures.
            self.backupsDirectory = self.profilesDirectory
                .appendingPathComponent(Self.derivedBackupsDirectoryName, isDirectory: true)
        } else {
            self.backupsDirectory = appSupport
                .appendingPathComponent("TurtleDiver", isDirectory: true)
                .appendingPathComponent("ProfileBackups", isDirectory: true)
        }
        self.defaults = defaults

        try? FileManager.default.createDirectory(at: self.profilesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.backupsDirectory, withIntermediateDirectories: true)

        // Placeholder so instance methods are safe to call below; replaced
        // immediately after by the saved or newly created profile.
        self.activeProfile = Profile(name: "Main")

        let savedName = defaults.string(forKey: DefaultsKeys.activeProfileName)
        let fallbackName = savedName ?? "Main"
        if let loaded = loadProfile(named: fallbackName) {
            activeProfile = loaded
            lastKnownActiveFileData = try? Data(contentsOf: fileURL(for: fallbackName))
            if savedName == nil {
                defaults.set(loaded.name, forKey: DefaultsKeys.activeProfileName)
            }
            _ = watchActiveProfileFile()
        } else {
            let created = ProfileManager.makeDefaultProfile(name: fallbackName)
            activeProfile = created
            saveProfile(created)
            lastKnownActiveFileData = try? Data(contentsOf: fileURL(for: created.name))
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
    ///
    /// When `recordBackup` is true and the file already exists with different
    /// bytes, the current on-disk content is copied to the backup store first.
    /// Backup failures surface as diagnostics but never prevent the write.
    @discardableResult
    public func saveProfile(_ profile: Profile, recordBackup: Bool = true) -> [ProfileDiagnostic] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let text = ProfileSerializer.serialize(profile)
        guard let data = text.data(using: .utf8) else {
            return [ProfileDiagnostic(line: 0, message: "Failed to write profile: text is not UTF-8")]
        }
        let url = fileURL(for: profile.name)
        var diagnostics: [ProfileDiagnostic] = []
        if let current = try? Data(contentsOf: url) {
            var stale: Data?
            if recordBackup {
                if current != data { stale = current }
            } else if profile.name == activeProfile.name,
                      let baseline = lastKnownActiveFileData,
                      current != baseline {
                // The watcher reloads on a 300 ms debounce. A save that opted
                // out of backups would otherwise overwrite an external edit
                // the app has not observed yet — keep those bytes.
                stale = current
            }
            if let stale, let error = writeBackup(data: stale, profileName: profile.name) {
                diagnostics.append(
                    ProfileDiagnostic(line: 0, message: "Failed to write profile backup: \(error)")
                )
            }
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            diagnostics.append(
                ProfileDiagnostic(line: 0, message: "Failed to write profile: \(error.localizedDescription)")
            )
            return diagnostics
        }
        // Keep the watcher's baseline current even when no backup was wanted
        // (the engine's overlay writes pass `recordBackup: false`).
        if profile.name == activeProfile.name {
            lastKnownActiveFileData = data
        }
        diagnostics += ProfileParser.parse(text, name: profile.name).diagnostics
        return diagnostics
    }

    /// Saves and switches the active profile to `profile` (used by the editor).
    ///
    /// `recordBackup: false` is for engine-driven writes (proxy overlay rules,
    /// system-proxy intent) that must not fill the user's backup history.
    public func saveAndActivate(_ profile: Profile, recordBackup: Bool = true) -> [ProfileDiagnostic] {
        stateLock.lock()
        defer { stateLock.unlock() }
        unwatchActiveProfileFile()
        let diags = saveProfile(profile, recordBackup: recordBackup)
        activeProfile = profile
        // The baseline is per-file: after switching names it must describe the
        // new active file, or an external edit of that file would be compared
        // against the previous profile's bytes.
        if let written = try? Data(contentsOf: fileURL(for: profile.name)) {
            lastKnownActiveFileData = written
        }
        defaults.set(profile.name, forKey: DefaultsKeys.activeProfileName)
        revalidate()
        _ = watchActiveProfileFile()
        return diags
    }

    /// Switches the active profile to an existing one by name.
    /// Returns false when the profile doesn't exist.
    @discardableResult
    public func activateProfile(named name: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let url = fileURL(for: name)
        guard
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return false }
        unwatchActiveProfileFile()
        defaults.set(name, forKey: DefaultsKeys.activeProfileName)
        let result = ProfileParser.parse(text, name: name)
        activeProfile = result.profile
        diagnostics = result.diagnostics
        lastKnownActiveFileData = data
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
    /// The last on-disk content is backed up first.
    public func deleteProfile(named name: String) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard name != activeProfile.name else { return false }
        let url = fileURL(for: name)
        if let current = try? Data(contentsOf: url) {
            if let error = writeBackup(data: current, profileName: name) {
                NSLog("TurtleDiver: failed to back up profile %@ before delete: %@", name, error)
            }
        }
        return (try? FileManager.default.removeItem(at: url)) != nil
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

    // MARK: - Backups

    /// Backups for `name`, newest first.
    public func listBackups(forProfile name: String) -> [ProfileBackup] {
        stateLock.lock()
        defer { stateLock.unlock() }
        let dir = backupDirectory(for: name)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }

        var backups: [ProfileBackup] = []
        for file in files where file.hasSuffix(".conf") {
            let url = dir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { continue }
            let date = Self.backupDate(fromFileName: file)
                ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            var ruleCount = 0
            var proxyCount = 0
            if let text = String(data: data, encoding: .utf8) {
                let profile = ProfileParser.parse(text, name: name).profile
                ruleCount = profile.rules.count
                proxyCount = profile.proxies.count
            }
            backups.append(
                ProfileBackup(
                    url: url,
                    profileName: name,
                    date: date,
                    ruleCount: ruleCount,
                    proxyCount: proxyCount,
                    byteCount: data.count
                )
            )
        }
        backups.sort { lhs, rhs in
            let left = Self.backupOrdering(fromFileName: lhs.url.lastPathComponent)
            let right = Self.backupOrdering(fromFileName: rhs.url.lastPathComponent)
            if left.date != right.date { return left.date > right.date }
            if left.collision != right.collision { return left.collision > right.collision }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
        return backups
    }

    /// Restores a backup's bytes exactly (atomic write).
    ///
    /// The current on-disk version is backed up first, so a restore is itself
    /// undoable. Restoring the active profile reloads it in memory and re-arms
    /// the file watcher; the engine hot-swaps through the `activeProfile`
    /// publisher as for any other save.
    ///
    /// - Returns: `true` when the bytes were written.
    @discardableResult
    public func restoreBackup(_ backup: ProfileBackup) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let data = try? Data(contentsOf: backup.url) else { return false }

        let name = backup.profileName
        let url = fileURL(for: name)
        let isActive = (name == activeProfile.name)
        if isActive { unwatchActiveProfileFile() }

        if let current = try? Data(contentsOf: url), current != data {
            if let error = writeBackup(data: current, profileName: name) {
                NSLog("TurtleDiver: failed to back up profile %@ before restore: %@", name, error)
            }
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("TurtleDiver: failed to restore profile %@: %@", name, error.localizedDescription)
            if isActive { _ = watchActiveProfileFile() }
            return false
        }

        if isActive {
            lastKnownActiveFileData = data
            if let text = String(data: data, encoding: .utf8) {
                let result = ProfileParser.parse(text, name: name)
                activeProfile = result.profile
                diagnostics = result.diagnostics
            }
            revalidate()
            _ = watchActiveProfileFile()
        }
        return true
    }

    /// Copies `data` into the profile's backup directory. Returns an error
    /// description on failure, `nil` on success or when the content is already
    /// identical to the newest backup.
    private func writeBackup(data: Data, profileName: String) -> String? {
        let dir = backupDirectory(for: profileName)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }

        // A backup identical to the newest one adds nothing but noise.
        if let newest = newestBackupURL(in: dir),
           let existing = try? Data(contentsOf: newest),
           existing == data {
            return nil
        }

        let stamp = Self.backupTimestamp(for: Date())
        var url = dir.appendingPathComponent("\(stamp).conf")
        var collision = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stamp)-\(collision).conf")
            collision += 1
        }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return error.localizedDescription
        }
        pruneBackups(in: dir)
        return nil
    }

    private func newestBackupURL(in dir: URL) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        guard let newest = files.filter({ $0.hasSuffix(".conf") }).sorted(by: Self.backupFileNameIsNewer).first
        else { return nil }
        return dir.appendingPathComponent(newest)
    }

    private func pruneBackups(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let names = files.filter { $0.hasSuffix(".conf") }.sorted(by: Self.backupFileNameIsNewer)
        guard names.count > Self.maxBackupsPerProfile else { return }
        for name in names.dropFirst(Self.maxBackupsPerProfile) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Reload & watching

    /// Re-reads the active profile from disk (external edits, e.g. hand-editing
    /// in an editor). Safe to call repeatedly.
    ///
    /// When the content differs from the last content observed for this
    /// profile, that last-known content is backed up first.
    @discardableResult
    public func reloadActiveProfile() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let url = fileURL(for: activeProfile.name)
        guard
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return false }

        if let lastKnown = lastKnownActiveFileData, lastKnown != data {
            if let error = writeBackup(data: lastKnown, profileName: activeProfile.name) {
                NSLog(
                    "TurtleDiver: failed to back up external edit of profile %@: %@",
                    activeProfile.name, error
                )
            }
        }
        lastKnownActiveFileData = data

        let result = ProfileParser.parse(text, name: activeProfile.name)
        activeProfile = result.profile
        diagnostics = result.diagnostics
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
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let flags = source.data
            // An atomic replace (editor save, `Data.write(options: .atomic)`)
            // unlinks the watched inode. Without re-opening the path the
            // watcher would be dead for every later edit.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.scheduleReArm(of: source)
            }
            self.scheduleReload()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileWatcher = source
        return true
    }

    private func unwatchActiveProfileFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        // The source's cancel handler closes the descriptor it was created with,
        // so a freshly opened fd is never closed by a stale cancel.
        watcherFD = -1
    }

    /// Re-opens the profile path after the watched inode was replaced. Skips
    /// when this source is no longer the current watcher.
    private func scheduleReArm(of source: DispatchSourceFileSystemObject) {
        reloadQueue.async { [weak self, weak source] in
            guard let self else { return }
            // Identity check and replacement happen under the same lock main
            // thread operations use; otherwise a stale source can re-arm after
            // a profile switch and the watcher follows the wrong file.
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard let source, self.fileWatcher === source else { return }
            _ = self.watchActiveProfileFile()
        }
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

    // MARK: - Observers

    /// Registers an additional change observer. `objectWillChangePublisher`
    /// only holds one slot, which cannot serve the engine and several views at
    /// once; observers registered here are additive and instance-scoped.
    ///
    /// The closure may fire on any thread.
    /// - Returns: a token for `removeChangeObserver(_:)`.
    public func addChangeObserver(_ observer: @escaping () -> Void) -> UUID {
        stateLock.lock()
        defer { stateLock.unlock() }
        let id = UUID()
        changeObservers[id] = observer
        return id
    }

    public func removeChangeObserver(_ id: UUID) {
        stateLock.lock()
        defer { stateLock.unlock() }
        changeObservers[id] = nil
    }

    private func notifyChange() {
        stateLock.lock()
        let publisher = objectWillChangePublisher
        let observers = Array(changeObservers.values)
        stateLock.unlock()
        publisher?()
        for observer in observers { observer() }
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
        profilesDirectory.appendingPathComponent("\(Self.sanitizedComponent(name)).conf")
    }

    private func backupDirectory(for name: String) -> URL {
        backupsDirectory.appendingPathComponent(Self.sanitizedComponent(name), isDirectory: true)
    }

    private static func sanitizedComponent(_ name: String) -> String {
        var safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        if safe.isEmpty || safe == "." || safe == ".." {
            safe = "_" + safe
        }
        return safe
    }

    private static func backupTimestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = backupTimestampFormat
        return formatter.string(from: date)
    }

    private static func backupDate(fromFileName name: String) -> Date? {
        let stem = name.hasSuffix(".conf") ? String(name.dropLast(5)) : name
        guard stem.count >= backupTimestampLength else { return nil }
        let stamp = String(stem.prefix(backupTimestampLength))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = backupTimestampFormat
        return formatter.date(from: stamp)
    }

    /// Orders backup file names newest-first; ties (same millisecond) use the
    /// collision suffix created by `recordBackup`, so `stamp-2` is newer than
    /// `stamp-1`, which is newer than `stamp`.
    private static func backupFileNameIsNewer(_ lhs: String, _ rhs: String) -> Bool {
        let left = backupOrdering(fromFileName: lhs)
        let right = backupOrdering(fromFileName: rhs)
        if left.date != right.date { return left.date > right.date }
        if left.collision != right.collision { return left.collision > right.collision }
        return lhs > rhs
    }

    private static func backupOrdering(fromFileName name: String) -> (date: Date, collision: Int) {
        let date = backupDate(fromFileName: name) ?? .distantPast
        let stem = name.hasSuffix(".conf") ? String(name.dropLast(5)) : name
        guard stem.count > backupTimestampLength else { return (date, 0) }
        let suffix = stem.dropFirst(backupTimestampLength)
        guard suffix.hasPrefix("-"), let collision = Int(suffix.dropFirst()) else { return (date, 0) }
        return (date, collision)
    }

    // MARK: - Testing hooks

    /// Stops the file watcher (tests call this to avoid leaked watchers).
    public func stopWatchingForTests() {
        stateLock.lock()
        defer { stateLock.unlock() }
        unwatchActiveProfileFile()
    }
}
