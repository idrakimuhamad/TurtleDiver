import XCTest
@testable import TurtleDiverCore

final class ProfileManagerTests: XCTestCase {

    private var tempDir: URL!
    private var profilesDir: URL!
    private var backupsDir: URL!
    private var tempDefaults: UserDefaults!
    private var suiteName: String!
    private var lastManager: ProfileManager?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurtleDiverTests-\(UUID().uuidString)", isDirectory: true)
        profilesDir = tempDir.appendingPathComponent("Profiles", isDirectory: true)
        backupsDir = tempDir.appendingPathComponent("ProfileBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)

        suiteName = "TurtleDiverTests-\(UUID().uuidString)"
        tempDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        lastManager?.stopWatchingForTests()
        if let suiteName = suiteName {
            tempDefaults.removePersistentDomain(forName: suiteName)
        }
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private func makeManager() -> ProfileManager {
        let manager = ProfileManager(
            profilesDirectory: profilesDir,
            defaults: tempDefaults,
            backupsDirectory: backupsDir
        )
        lastManager = manager
        return manager
    }

    /// Polls a condition on the main run loop (the watcher reloads on a
    /// utility queue after a 0.3 s debounce).
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private func profileText(proxyName: String, port: Int) -> String {
        """
        [Proxy]
        \(proxyName) = http, proxy.example.com, \(port)

        [Rule]
        FINAL,DIRECT
        """
    }

    // MARK: - Creation & activation

    func testFirstLaunchCreatesDefaultProfile() {
        let manager = makeManager()
        XCTAssertEqual(manager.activeProfile.name, "Main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profilesDir.appendingPathComponent("Main.conf").path))
        // Default profile has the starter rule and validates cleanly.
        XCTAssertEqual(manager.activeProfile.rules.map(\.type), [.final])
        XCTAssertEqual(manager.validationErrors, [])
    }

    func testWipedPreferencesKeepExistingMainProfile() throws {
        let existing = "[General]\nhttp-listen = 127.0.0.1:7000\n\n[Rule]\nDOMAIN-SUFFIX,example.com,DIRECT\nFINAL,DIRECT\n"
        let url = profilesDir.appendingPathComponent("Main.conf")
        try existing.write(to: url, atomically: true, encoding: .utf8)

        let manager = makeManager()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), existing, "must not overwrite the user's profile")
        XCTAssertEqual(manager.activeProfile.rules.count, 2)
        XCTAssertEqual(tempDefaults.string(forKey: "activeProfileName"), "Main")
    }

    func testCreateProfileAndActivate() {
        let manager = makeManager()
        manager.createProfile(named: "Work")

        XCTAssertEqual(manager.listProfileNames(), ["Main", "Work"])
        XCTAssertEqual(manager.activeProfile.name, "Work", "createProfile activates the new profile")

        XCTAssertTrue(manager.activateProfile(named: "Main"))
        XCTAssertEqual(manager.activeProfile.name, "Main")
        XCTAssertEqual(tempDefaults.string(forKey: "activeProfileName"), "Main")
    }

    func testActivateMissingProfileFails() {
        let manager = makeManager()
        XCTAssertFalse(manager.activateProfile(named: "Nope"))
        XCTAssertEqual(manager.activeProfile.name, "Main")
    }

    func testDeleteProfileRefusesActive() {
        let manager = makeManager()
        manager.createProfile(named: "Work")
        XCTAssertTrue(manager.deleteProfile(named: "Main")) // not active
        XCTAssertFalse(manager.deleteProfile(named: "Work")) // active
        XCTAssertEqual(manager.listProfileNames(), ["Work"])
    }

    func testDuplicateProfile() {
        let manager = makeManager()
        manager.createProfile(named: "Source")
        let copy = manager.duplicateProfile(named: "Source", as: "Copy")
        XCTAssertEqual(copy?.name, "Copy")
        XCTAssertEqual(manager.listProfileNames(), ["Copy", "Main", "Source"])
    }

    // MARK: - Persistence across instances

    func testProfileSurvivesAcrossManagerInstances() {
        let first = makeManager()
        var profile = first.activeProfile
        profile.proxies = [ProxyDefinition(name: "Persisted", type: .http, host: "h", port: 8080)]
        _ = first.saveAndActivate(profile)
        lastManager = first

        // New instance over the same directory must load the saved profile.
        let second = makeManager()
        XCTAssertEqual(second.activeProfile.name, profile.name)
        XCTAssertEqual(second.activeProfile.proxies.first?.name, "Persisted")
    }

    func testActiveProfileNameSurvivesAcrossInstances() {
        let first = makeManager()
        first.createProfile(named: "Other")
        first.activateProfile(named: "Main")

        let second = makeManager()
        XCTAssertEqual(second.activeProfile.name, "Main")
    }

    // MARK: - External edits & reload

    func testReloadPicksUpExternalEdit() throws {
        let manager = makeManager()

        // Simulate an external editor changing the file on disk.
        let edited = """
        [Proxy]
        External = socks5, 10.1.1.1, 1080

        [Rule]
        DOMAIN-SUFFIX,example.com,External
        FINAL,DIRECT
        """
        try edited.write(to: profilesDir.appendingPathComponent("Main.conf"), atomically: true, encoding: .utf8)

        XCTAssertTrue(manager.reloadActiveProfile())
        XCTAssertEqual(manager.activeProfile.proxies.first?.name, "External")
        XCTAssertEqual(manager.activeProfile.rules.first?.type, .domainSuffix)
    }

    func testFileWatcherReloadsAfterEdit() throws {
        let manager = makeManager()

        let edited = """
        [Proxy]
        Watched = http, 10.2.2.2, 3128

        [Rule]
        FINAL,Watched
        """
        let url = profilesDir.appendingPathComponent("Main.conf")
        try edited.write(to: url, atomically: true, encoding: .utf8)

        // The watcher debounce is 0.3s on a utility queue; poll up to 5s.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if manager.activeProfile.proxies.first?.name == "Watched" { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(manager.activeProfile.proxies.first?.name, "Watched", "watcher should auto-reload the profile")
    }

    // MARK: - Validation surfaced

    func testValidationErrorsSurfacedByManager() {
        let manager = makeManager()
        var profile = manager.activeProfile
        profile.groups = [ProxyGroup(name: "G", type: .select, policies: ["MISSING"])]
        _ = manager.saveAndActivate(profile)
        XCTAssertTrue(manager.validationErrors.contains { $0 == .groupUnknownMember(group: "G", member: "MISSING") })
    }

    // MARK: - Filename safety

    func testFileURLSanitizesUnsafeNames() {
        let manager = makeManager()
        let url = manager.fileURL(for: "we/ird:name")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(url.lastPathComponent.contains(":"))
        XCTAssertTrue(url.lastPathComponent.hasSuffix(".conf"))
    }

    // MARK: - Backups

    func testSaveRecordsByteExactBackupOfPreviousContent() throws {
        let manager = makeManager()
        let original = try String(contentsOf: manager.fileURL(for: "Main"), encoding: .utf8)

        var changed = manager.activeProfile
        changed.proxies = [ProxyDefinition(name: "Edge", type: .http, host: "proxy.example.com", port: 8080)]
        _ = manager.saveAndActivate(changed)

        let backups = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0].url, encoding: .utf8), original)
        XCTAssertEqual(backups[0].profileName, "Main")
        XCTAssertEqual(backups[0].ruleCount, 1)
        XCTAssertEqual(backups[0].proxyCount, 0)
        XCTAssertEqual(backups[0].byteCount, original.utf8.count)
        XCTAssertLessThan(abs(backups[0].date.timeIntervalSinceNow), 10)
        // Backups never appear among profiles.
        XCTAssertEqual(manager.listProfileNames(), ["Main"])
    }

    func testUnchangedSaveDoesNotRecordBackup() {
        let manager = makeManager()
        _ = manager.saveProfile(manager.activeProfile)
        XCTAssertTrue(manager.listBackups(forProfile: "Main").isEmpty)
    }

    func testRecordBackupFalseSkipsButKeepsBaselineCurrent() throws {
        let manager = makeManager()

        var second = manager.activeProfile
        second.proxies = [ProxyDefinition(name: "One", type: .http, host: "proxy.example.com", port: 8080)]
        _ = manager.saveAndActivate(second, recordBackup: false)
        XCTAssertTrue(manager.listBackups(forProfile: "Main").isEmpty,
                      "engine-driven saves must not create backups")
        let secondText = try String(contentsOf: manager.fileURL(for: "Main"), encoding: .utf8)

        var third = second
        third.proxies[0].port = 9090
        _ = manager.saveAndActivate(third)

        let backups = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0].url, encoding: .utf8), secondText,
                       "a recordBackup:false save must still update the last-known baseline")
    }

    func testRetentionKeepsNewestTwentyBackups() {
        let manager = makeManager()
        var profile = manager.activeProfile
        for index in 0..<25 {
            profile.proxies = [
                ProxyDefinition(name: "P\(index)", type: .http, host: "proxy.example.com", port: 8000 + index)
            ]
            _ = manager.saveAndActivate(profile)
        }
        let backups = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(backups.count, ProfileManager.maxBackupsPerProfile)
        XCTAssertEqual(backups.count, 20)

        // The newest backup is the version from the second-to-last save.
        let newestText = try? String(contentsOf: backups[0].url, encoding: .utf8)
        XCTAssertTrue(newestText?.contains("8023") ?? false,
                      "newest backup should hold the previous save (port 8023)")
    }

    func testDeleteRecordsBackupBeforeRemoving() throws {
        let manager = makeManager()
        manager.createProfile(named: "Work")
        var work = try XCTUnwrap(manager.loadProfile(named: "Work"))
        work.proxies = [ProxyDefinition(name: "Office", type: .http, host: "proxy.example.com", port: 8080)]
        _ = manager.saveAndActivate(work)
        manager.activateProfile(named: "Main")

        let onDisk = try String(contentsOf: manager.fileURL(for: "Work"), encoding: .utf8)
        XCTAssertTrue(manager.deleteProfile(named: "Work"))

        let backups = manager.listBackups(forProfile: "Work")
        XCTAssertFalse(backups.isEmpty, "delete must leave a backup behind")
        XCTAssertEqual(try String(contentsOf: backups[0].url, encoding: .utf8), onDisk)
    }

    func testRestoreActiveProfileUpdatesMemoryAndIsUndoable() throws {
        let manager = makeManager()

        var second = manager.activeProfile
        second.proxies = [ProxyDefinition(name: "First", type: .http, host: "proxy.example.com", port: 8080)]
        _ = manager.saveAndActivate(second)

        var third = second
        third.proxies = [ProxyDefinition(name: "Second", type: .https, host: "proxy.example.com", port: 443)]
        _ = manager.saveAndActivate(third)
        XCTAssertEqual(manager.activeProfile.proxies.first?.name, "Second")

        let backups = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(backups.count, 2)
        let secondVersion = backups[0] // newest backup holds the "First" version
        XCTAssertTrue(try String(contentsOf: secondVersion.url, encoding: .utf8).contains("First"))

        XCTAssertTrue(manager.restoreBackup(secondVersion))
        XCTAssertEqual(manager.activeProfile.proxies.first?.name, "First",
                       "restoring the active profile reloads it in memory")
        XCTAssertEqual(
            try String(contentsOf: manager.fileURL(for: "Main"), encoding: .utf8),
            try String(contentsOf: secondVersion.url, encoding: .utf8),
            "restore writes the backup bytes exactly"
        )

        // The replaced version was backed up, so the restore is undoable.
        let afterRestore = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(afterRestore.count, 3)
        XCTAssertTrue(try String(contentsOf: afterRestore[0].url, encoding: .utf8).contains("Second"))

        XCTAssertTrue(manager.restoreBackup(afterRestore[0]))
        XCTAssertEqual(manager.activeProfile.proxies.first?.name, "Second")
    }

    func testRestoreInactiveProfileOnlyWritesTheFile() throws {
        let manager = makeManager()
        manager.createProfile(named: "Work")
        var work = try XCTUnwrap(manager.loadProfile(named: "Work"))
        work.proxies = [ProxyDefinition(name: "Office", type: .http, host: "proxy.example.com", port: 8080)]
        _ = manager.saveAndActivate(work)
        manager.activateProfile(named: "Main")

        var changed = work
        changed.proxies = [ProxyDefinition(name: "Changed", type: .https, host: "proxy.example.com", port: 443)]
        _ = manager.saveProfile(changed)
        let changedText = try String(contentsOf: manager.fileURL(for: "Work"), encoding: .utf8)

        // Newest backup is the "Office" version; the older one is the empty
        // profile created by `createProfile`.
        let workBackups = manager.listBackups(forProfile: "Work")
        XCTAssertEqual(workBackups.count, 2)
        let officeBackup = workBackups[0]
        XCTAssertTrue(try String(contentsOf: officeBackup.url, encoding: .utf8).contains("Office"))

        XCTAssertTrue(manager.restoreBackup(officeBackup))
        XCTAssertEqual(manager.activeProfile.name, "Main", "restoring an inactive profile must not activate it")
        XCTAssertEqual(manager.loadProfile(named: "Work")?.proxies.first?.name, "Office")
        let restored = try String(contentsOf: manager.fileURL(for: "Work"), encoding: .utf8)
        XCTAssertEqual(restored, try String(contentsOf: officeBackup.url, encoding: .utf8))
        XCTAssertNotEqual(restored, changedText)
        XCTAssertEqual(manager.listBackups(forProfile: "Work").count, 3,
                       "the replaced version is backed up first, so restore is undoable")
    }

    func testExternalEditBacksUpLastKnownContent() throws {
        let manager = makeManager()
        let original = try String(contentsOf: manager.fileURL(for: "Main"), encoding: .utf8)

        try profileText(proxyName: "External", port: 1080)
            .write(to: manager.fileURL(for: "Main"), atomically: true, encoding: .utf8)

        XCTAssertTrue(waitUntil { manager.activeProfile.proxies.first?.name == "External" })
        let backups = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0].url, encoding: .utf8), original)
    }

    func testWatcherRearmsAfterAtomicReplace() throws {
        let manager = makeManager()
        let url = manager.fileURL(for: "Main")

        try profileText(proxyName: "One", port: 1080).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { manager.activeProfile.proxies.first?.name == "One" })

        // A second atomic replace produces a new inode; the watcher must have
        // re-armed after the first one or this never reloads.
        try profileText(proxyName: "Two", port: 1081).write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(waitUntil { manager.activeProfile.proxies.first?.name == "Two" })

        let backups = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(backups.count, 2, "both external versions must be backed up")
        XCTAssertTrue(try String(contentsOf: backups[0].url, encoding: .utf8).contains("One"))
    }

    func testBackupIdenticalToNewestIsSkipped() throws {
        let manager = makeManager()

        var second = manager.activeProfile
        second.proxies = [ProxyDefinition(name: "Kept", type: .http, host: "proxy.example.com", port: 8080)]
        _ = manager.saveAndActivate(second) // backs up the default profile
        XCTAssertEqual(manager.listBackups(forProfile: "Main").count, 1)

        // Revert the file to content that is already the newest backup, with
        // the watcher out of the way so the reload cannot back anything up.
        manager.stopWatchingForTests()
        let original = try String(contentsOf: manager.listBackups(forProfile: "Main")[0].url, encoding: .utf8)
        try original.write(to: manager.fileURL(for: "Main"), atomically: true, encoding: .utf8)

        var third = second
        third.proxies = [ProxyDefinition(name: "Changed", type: .http, host: "proxy.example.com", port: 9090)]
        _ = manager.saveProfile(third)

        XCTAssertEqual(manager.listBackups(forProfile: "Main").count, 1,
                       "a backup identical to the newest one must be skipped")
    }

    func testRecordBackupFalsePreservesUnobservedExternalEdit() throws {
        let manager = makeManager()
        // An editor saved while the watcher's 300 ms debounce was still
        // pending: the manager has not reloaded, so `lastKnown` is stale.
        manager.stopWatchingForTests()
        let external = profileText(proxyName: "External", port: 1080)
        try external.write(to: manager.fileURL(for: "Main"), atomically: true, encoding: .utf8)

        // An engine-driven save (recordBackup: false) must not erase the edit
        // silently; it backs the disk bytes up even though backups are off.
        _ = manager.saveAndActivate(manager.activeProfile, recordBackup: false)

        let backups = manager.listBackups(forProfile: "Main")
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0].url, encoding: .utf8), external)
    }

    func testSaveAndActivateSwitchingProfileResetsBaseline() throws {
        let manager = makeManager()
        manager.createProfile(named: "Work")
        manager.activateProfile(named: "Main")
        let work = try XCTUnwrap(manager.loadProfile(named: "Work"))

        // Switching with backups off leaves the old profile's baseline behind
        // unless saveAndActivate adopts the new file explicitly.
        _ = manager.saveAndActivate(work, recordBackup: false)
        XCTAssertEqual(manager.activeProfile.name, "Work")

        _ = manager.saveAndActivate(manager.activeProfile, recordBackup: false)
        XCTAssertTrue(manager.listBackups(forProfile: "Work").isEmpty,
                      "the new active file's own bytes must be the baseline")
    }

    func testInjectedProfilesDirectoryDerivesPrivateBackupsDirectory() {
        let firstDir = tempDir.appendingPathComponent("First", isDirectory: true)
        let secondDir = tempDir.appendingPathComponent("Second", isDirectory: true)

        let first = ProfileManager(profilesDirectory: firstDir, defaults: tempDefaults)
        let second = ProfileManager(profilesDirectory: secondDir, defaults: tempDefaults)
        defer {
            first.stopWatchingForTests()
            second.stopWatchingForTests()
        }

        XCTAssertEqual(
            first.backupsDirectory,
            firstDir.appendingPathComponent(ProfileManager.derivedBackupsDirectoryName, isDirectory: true)
        )
        XCTAssertNotEqual(first.backupsDirectory, second.backupsDirectory,
                          "fixtures must not share one backups directory")
        XCTAssertEqual(first.listProfileNames(), ["Main"], "the backups directory is not a profile")
    }
}
