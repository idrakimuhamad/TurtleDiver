import XCTest
@testable import TurtleDiverCore

final class ProfileManagerTests: XCTestCase {

    private var tempDir: URL!
    private var profilesDir: URL!
    private var tempDefaults: UserDefaults!
    private var suiteName: String!
    private var lastManager: ProfileManager?

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurtleDiverTests-\(UUID().uuidString)", isDirectory: true)
        profilesDir = tempDir.appendingPathComponent("Profiles", isDirectory: true)
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
        let manager = ProfileManager(profilesDirectory: profilesDir, defaults: tempDefaults)
        lastManager = manager
        return manager
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
}
