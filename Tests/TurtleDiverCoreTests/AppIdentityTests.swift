import XCTest
@testable import TurtleDiverSystem

/// The bundle identifier is a storage key in two places at once (`UserDefaults`
/// and the Keychain service), so these tests guard the invariants that keep the
/// app from reading its own data back under a name that no longer matches.
final class AppIdentityTests: XCTestCase {

    // MARK: Identity

    func testTheBundleIdentifierIsTheRenamedOne() {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.xvii.kurakura.vpn")
    }

    func testTheLegacyIdentifiersAreTheOnesThatShippedBefore() {
        XCTAssertEqual(AppIdentity.legacyBundleIdentifiers,
                       ["com.idraki.turtle.vpn", "com.turtlediver"])
        XCTAssertFalse(AppIdentity.legacyBundleIdentifiers.contains(AppIdentity.bundleIdentifier))
    }

    /// The invariant the whole type exists for: the current identifier must not
    /// also be in the legacy list, or a migration would copy the new data onto
    /// itself (and the "already present" check would hide the real bug).
    func testTheServiceChainStartsWithTheCurrentIdentifierAndHasNoDuplicates() {
        let chain = AppIdentity.keychainServiceChain
        XCTAssertEqual(chain.first, AppIdentity.bundleIdentifier)
        XCTAssertEqual(chain.count, Set(chain).count, "duplicate service in chain: \(chain)")
        XCTAssertEqual(chain, [AppIdentity.bundleIdentifier] + AppIdentity.legacyBundleIdentifiers)
    }

    // MARK: Project agreement

    /// `KeychainHelper` stores under `AppIdentity.bundleIdentifier`, while
    /// macOS scopes the app's preferences and keychain ACLs to
    /// `PRODUCT_BUNDLE_IDENTIFIER`. If the two ever drift, the app writes
    /// credentials under a name the system does not associate with it — the
    /// exact class of failure the migration above exists to repair. There is no
    /// runtime check that can see the Xcode project, so it is checked here.
    func testTheProjectBuildsUnderTheIdentifierTheAppStoresSecretsWith() throws {
        let project = try String(contentsOf: pbxprojURL, encoding: .utf8)
        let declared = project
            .components(separatedBy: "PRODUCT_BUNDLE_IDENTIFIER = ")
            .dropFirst()
            .compactMap { $0.components(separatedBy: ";").first }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        XCTAssertFalse(declared.isEmpty, "no PRODUCT_BUNDLE_IDENTIFIER found in the project")
        for identifier in declared {
            XCTAssertEqual(identifier, AppIdentity.bundleIdentifier,
                           "the Xcode project and AppIdentity disagree about the bundle identifier")
        }
    }

    /// The rename must not leave a hard-coded copy of the previous *bundle*
    /// identifier in the sources: a stale literal is how a migration silently
    /// becomes dead code (the Keychain service and the preferences domain are
    /// both named by it). `com.turtlediver` is deliberately not scanned for —
    /// it namespaces dispatch queues and log subsystems, which have nothing to
    /// do with where data is stored and are free to keep the old spelling.
    func testNoSourceHardCodesThePreviousBundleIdentifierOutsideAppIdentity() throws {
        let sources = repoRoot.appendingPathComponent("VPNConnect")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []

        for file in files where file.lastPathComponent != "AppIdentity.swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("com.idraki.turtle.vpn"),
                           "\(file.lastPathComponent) hard-codes the previous bundle identifier")
        }
    }

    private var repoRoot: URL {
        // …/Tests/TurtleDiverCoreTests/AppIdentityTests.swift -> repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var pbxprojURL: URL {
        repoRoot
            .appendingPathComponent("VPNConnect.xcodeproj")
            .appendingPathComponent("project.pbxproj")
    }
}
