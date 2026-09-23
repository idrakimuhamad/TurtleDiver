import XCTest
import TurtleDiverSystem
@testable import TurtleDiverAppGlue

/// The app's copy of the askpass helper: where it is built, what it is signed
/// as, and where it lands inside the bundle.
///
/// The app needs this program because a `pam_tid` `sudo` will not read a piped
/// password, and a Keychain grant belongs to the *program* that asks — so the
/// app cannot borrow the command line tool's copy, and a user who installed only
/// the app has no copy at all. It therefore ships one inside its own bundle, at
/// `Contents/Library/HelperTools/turtlediver-askpass`, and that is what these
/// tests are about: not "does the code compile" (the `swift test` targets build
/// the same source) but "is it actually in the app, signed, and reachable".
///
/// `swift build` never reads `project.pbxproj`, so a mistake here is invisible
/// to every other suite in the package; `XcodeProjectRegistrationTests` covers
/// the general invariants, and this file covers the ones specific to a nested
/// helper: a real target, a Copy Files phase that signs on copy, and no
/// application-only build settings leaking into a plain tool.
final class AskpassBundleTests: XCTestCase {

    private let project = "VPNConnect.xcodeproj/project.pbxproj"
    /// The app target, as named in the project.
    private let appTargetID = "1A2B3C481234567890ABCDEF"

    // MARK: - The shared names

    /// The administrator password is stored and read under one account name, and
    /// three files spell it: `AskpassProgram` (the helper), `KeychainHelper`
    /// (the app) and `KeychainSecret` (the command line tool, whose raw value has
    /// to be a literal). Two of the three are checked here; the third in
    /// `CLIAskpassTests`.
    func testTheAdministratorAccountHasOneSpellingAcrossTheApp() {
        XCTAssertEqual(KeychainHelper.adminPasswordAccount, AskpassProgram.administratorAccount)
        XCTAssertEqual(KeychainHelper.adminPasswordAccount, "adminPassword")
    }

    /// There is one Keychain read in the project, and it is `StoredSecret`.
    ///
    /// The app, the command line tool and the helper all read the same items, and
    /// three copies of the query would be three chances for one of them to ask
    /// for something the others do not — the symptom being a consent dialog
    /// nobody expected. This is the check that keeps it at one.
    func testTheKeychainQueryExistsOnce() throws {
        var callers: [String] = []
        for file in try swiftFiles(under: "VPNConnect") + swiftFiles(under: "CLI") + swiftFiles(under: "Askpass") {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("SecItemCopyMatching(query") { callers.append(file.lastPathComponent) }
        }
        XCTAssertEqual(callers, ["StoredSecret.swift"],
                       "these files query the Keychain directly; the query belongs in StoredSecret")
    }

    // MARK: - The helper is a real target

    func testTheProjectBuildsTheHelperAsItsOwnTarget() throws {
        let text = try projectText()
        XCTAssertTrue(text.contains("productType = \"com.apple.product-type.tool\";"),
                      "the helper must be a plain tool target, not an application")
        XCTAssertTrue(text.contains("\t\t\tname = turtlediver-askpass;\n"), "no target named turtlediver-askpass")
        XCTAssertTrue(text.contains("PRODUCT_NAME = \"turtlediver-askpass\";"), "the target builds under another name")
    }

    /// The helper's sources are the shared program and `Askpass/main.swift` — and
    /// the app's own `main.swift` must not be among them, or the tool would link
    /// two entry points.
    func testTheHelperTargetCompilesTheSharedProgramAndItsOwnEntryPoint() throws {
        let text = try projectText()
        let phase = try sourcesPhase(ofTargetNamed: "turtlediver-askpass", in: text)
        for name in ["main.swift", "AskpassProgram.swift", "StoredSecret.swift", "AppIdentity.swift"] {
            XCTAssertTrue(phase.contains("/* \(name) in Sources */"), "\(name) is not in the helper's Sources phase")
        }
        // The app's entry point is a *different* file with the same name, and it
        // says `NSApplicationMain`-ish things a tool must not see.
        let appPhase = try sourcesPhase(ofTargetNamed: "VPNConnect", in: text)
        XCTAssertTrue(appPhase.contains("main.swift in Sources */"))
        XCTAssertNotEqual(appPhase, phase)
    }

    /// The helper must be a *build product of this project*, not a stale copy
    /// committed into the repo or injected after signing: only Xcode's own build
    /// can sign it into the app's seal.
    func testTheHelperIsNotACheckedInBinary() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Askpass/turtlediver-askpass").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Askpass/main.swift").path))
    }

    /// Run by a person instead of by `sudo` — under any name but its installed
    /// one — the program must refuse, not print the password. The name decides the
    /// mode, and the refusal happens before anything reads the Keychain, so a
    /// stray `turtlediver-askpass` on someone's `PATH` is a usage sentence rather
    /// than a dispenser.
    func testTheEntryPointRefusesAnythingButTheHelperName() throws {
        let text = try String(contentsOf: repoRoot.appendingPathComponent("Askpass/main.swift"),
                              encoding: .utf8)
        let guardRange = try XCTUnwrap(
            text.range(of: "guard AskpassProgram.isHelperInvocation(executablePath: AskpassProgram.ownPath())"),
            "the entry point does not check the name it was started under"
        )
        XCTAssertTrue(text.contains("standardError.write"), "the refusal must go to standard error")
        XCTAssertTrue(text.contains("exit(64)"), "EX_USAGE, not success")
        XCTAssertTrue(text.contains("exit(AskpassProgram.run("), "the helper's own work goes through the shared type")

        let readRange = try XCTUnwrap(text.range(of: "StoredSecret.read(services:"))
        XCTAssertLessThan(guardRange.lowerBound, readRange.lowerBound,
                          "the Keychain is read before the program knows what it is")
    }

    // MARK: - The helper reaches the bundle, signed

    func testTheAppCopiesTheHelperIntoTheBundleAndSignsItOnCopy() throws {
        let text = try projectText()
        guard let phase = section("PBXCopyFilesBuildPhase", in: text) else {
            return XCTFail("no Copy Files phase: the helper would not be in the app")
        }
        XCTAssertTrue(phase.contains("dstSubfolderSpec = 1;"), "the helper must be copied into the wrapper")
        XCTAssertTrue(phase.contains("dstPath = Contents/Library/HelperTools;"), phase)

        // The entry in the phase is a build file, and *that* is where the sign-on
        // -copy instruction lives: a helper copied without it would keep the
        // signature it was built with, which no longer matches the app it is
        // inside, and the bundle would fail its seal check.
        guard let entry = captures("([0-9A-F]{24}) /\\* turtlediver-askpass in Embed Helper \\*/", in: phase)
            .first?.first else {
            return XCTFail("the Copy Files phase does not list the helper")
        }
        let buildFiles = section("PBXBuildFile", in: text) ?? ""
        XCTAssertTrue(
            captures("^\t\t\(entry) [^\n]*CodeSignOnCopy[^\n]*$", in: buildFiles).count == 1,
            "the copied helper is not signed on copy: \(entry)"
        )

        // …and the *app* target has to run that phase. A phase nobody runs builds
        // nothing, and the failure would only show up as a missing file at
        // runtime — or, here, as `publish.sh`'s `--deep --strict` verify.
        let appPhases = try buildPhases(ofTargetNamed: "VPNConnect", in: text)
        let copyPhaseID = captures("([0-9A-F]{24}) /\\* Embed Helper \\*/ = \\{", in: phase).first?.first
        XCTAssertNotNil(copyPhaseID)
        XCTAssertTrue(appPhases.contains(copyPhaseID ?? ""), "the app target does not run the Embed Helper phase")

        // The app must depend on the helper, or the copy races the build.
        let appTarget = try target(named: "VPNConnect", in: text)
        XCTAssertTrue(appTarget.contains("PBXTargetDependency"), "the app does not depend on the helper target")
    }

    // MARK: - It is a helper, not a second app

    /// The helper runs as the logged-in user — `sudo` starts it as the invoking
    /// user — so it is allowed inside the bundle (unlike the tunnel agent, which
    /// runs as root and is installed into `/usr/local/libexec` by the package).
    /// It must therefore carry the app's signing identity and hardened runtime,
    /// and must not inherit the app's entitlements or `Info.plist`.
    func testTheHelperSignsLikeTheAppAndKeepsNoneOfItsApplicationSettings() throws {
        let text = try projectText()
        let helper = try buildSettings(ofTargetNamed: "turtlediver-askpass", in: text)
        let app = try buildSettings(ofTargetNamed: "VPNConnect", in: text)

        XCTAssertEqual(helper["DEVELOPMENT_TEAM"], app["DEVELOPMENT_TEAM"], "a different team cannot be verified")
        XCTAssertEqual(helper["ENABLE_HARDENED_RUNTIME"], "YES")
        XCTAssertNil(helper["CODE_SIGN_ENTITLEMENTS"], "the app's entitlements are not the helper's")
        XCTAssertNil(helper["INFOPLIST_FILE"], "a tool target needs no Info.plist")
        XCTAssertEqual(app["CODE_SIGN_ENTITLEMENTS"], "VPNConnect/VPNConnect.entitlements")
    }

    // MARK: - Reading the project

    private func projectText() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(project), encoding: .utf8)
    }

    /// The whole object body of the target called `name`.
    private func target(named name: String, in text: String) throws -> String {
        let pattern = "^\t\t([0-9A-F]{24}) /\\* \(name) \\*/ = \\{\n\t\t\tisa = PBXNativeTarget;"
        guard let id = captures(pattern, in: text).first?.first,
              let body = objectBody(id: id, in: text) else {
            throw failure("no native target called \(name)")
        }
        return body
    }

    private func buildPhases(ofTargetNamed name: String, in text: String) throws -> String {
        let target = try target(named: name, in: text)
        guard let range = target.range(of: "buildPhases = (") else { return "" }
        let rest = target[range.upperBound...]
        guard let end = rest.range(of: "\n\t\t\t);") else { return "" }
        return String(rest[..<end.lowerBound])
    }

    /// The Sources phase of `name`, as text: which file names it compiles.
    private func sourcesPhase(ofTargetNamed name: String, in text: String) throws -> String {
        let phases = try buildPhases(ofTargetNamed: name, in: text)
        guard let id = captures("\t\t\t\t([0-9A-F]{24}) /\\* Sources \\*/", in: phases).first?.first,
              let body = objectBody(id: id, in: text) else {
            throw failure("\(name) has no Sources phase")
        }
        return body
    }

    /// The build settings of `name`'s Debug configuration, as a dictionary.
    private func buildSettings(ofTargetNamed name: String, in text: String) throws -> [String: String] {
        let target = try target(named: name, in: text)
        guard let listID = captures("buildConfigurationList = ([0-9A-F]{24})", in: target).first?.first,
              let list = objectBody(id: listID, in: text),
              let configID = captures("\t\t\t\t([0-9A-F]{24}) /\\* Debug \\*/", in: list).first?.first,
              let config = objectBody(id: configID, in: text),
              let range = config.range(of: "buildSettings = {") else {
            throw failure("cannot find \(name)'s Debug build settings")
        }
        let rest = config[range.upperBound...]
        guard let end = rest.range(of: "\n\t\t\t};") else { throw failure("unterminated build settings") }
        var settings: [String: String] = [:]
        for row in captures("\t\t\t\t([A-Z_]+) = ([^;]+);", in: String(rest[..<end.lowerBound])) where row.count == 2 {
            settings[row[0]] = row[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return settings
    }

    /// The whole body of the object with the given identifier.
    ///
    /// Anchored at the start of a definition line — identifiers are also
    /// *mentioned* inside other objects, at deeper indentation, and a loose
    /// search finds one of those first and returns the wrong body.
    private func objectBody(id: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "^\t\t\(id) [^\n]*= \\{\n(.*?)\n\t\t\\};",
            options: [.anchorsMatchLines, .dotMatchesLineSeparators]
        ), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private func section(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "/* Begin \(name) section */"),
              let end = text.range(of: "/* End \(name) section */") else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private func failure(_ description: String) -> Failure { Failure(description: description) }

    private func swiftFiles(under directory: String) -> [URL] {
        let root = repoRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Capture groups 1… of every match, as strings. Group 0 is dropped.
    private func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
