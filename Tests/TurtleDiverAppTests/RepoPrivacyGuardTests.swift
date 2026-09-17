import Foundation
import XCTest

/// A tripwire for employer and personal identifiers creeping back in.
///
/// A privacy sweep that only deletes is a sweep that gets undone. The values
/// forbidden here are *boring* — a hostname, a home directory, an employee
/// number, a certificate id — which is exactly why they survived for so long in
/// a public repository: nothing in a build, a test run or a compiler objects to
/// a hostname. The only durable fix is to assert their absence, so this scans
/// the repository's own text files and fails with the file, the line and the
/// marker that matched.
///
/// Two properties make the scan trustworthy rather than merely reassuring:
///
///  * It is a property of the *source tree*, not of the machine. It walks from
///    the file this test lives in, and never shells out (so it cannot be
///    influenced by `$PATH`, a working copy somewhere else, or `git` config).
///  * Build output is skipped deliberately. `.build/`, `build/` and `dist/`
///    hold generated JSON and YAML full of absolute `/Users/...` paths, so
///    scanning them would fail the guard for reasons that have nothing to do
///    with the source and cannot be fixed in the source.
///
/// It walks the *working tree* rather than `git ls-files`, which is a trade-off
/// worth naming: a stray copy in an untracked scratch file is worth knowing
/// about (and by the time it is committed it is too late), but it does mean a
/// local, uncommitted file can fail the suite. Delete that file, or allow-list
/// the value here if it is genuinely load-bearing.
final class RepoPrivacyGuardTests: XCTestCase {

    // MARK: - The scheme

    /// Values that must not appear anywhere in the tree.
    ///
    /// Every entry is matched case-insensitively against every line of every
    /// scanned file. This list is the whole extension point: add the value, give
    /// it a reason (the reason is what the failure message shows), re-run.
    private static let deniedMarkers: [(marker: String, why: String)] = [
        // The employer.
        ("rhbgroup", "the employer's registered domain"),
        ("rhb", "the employer's initials"),
        ("10.164.1.148", "an employer proxy address"),
        ("10.186.145.101", "an employer proxy address"),

        // The person this repository belongs to.
        ("idraki", "the author's name, home directory and Apple ID"),
        ("idrakimuhamad@gmail.com", "the author's personal email"),
        ("451799", "a real employee VPN username"),

        // Signing identities. Even a team certificate names one person.
        ("WGJR368TV3", "a real certificate id"),
        ("TDBMW53WY6", "a real certificate id"),
        ("8EPYD478G7", "an Apple account identifier from the signing certificate"),

        // Values *shaped* like credentials. These were test fixtures rather than
        // live secrets, but a fixture that looks like a credential is how one
        // eventually gets copied into something that is not a fixture. Note that
        // the scanner that flagged the first of these was not wrong to do so.
        ("1q2w3e4r", "a keyboard walk a secret scanner reports as a password"),
        ("1qa2ws309418", "a keyboard walk shaped like the real passcode"),
        ("vymTip", "a fragment of the real VPN password"),
        ("vedju1", "a fragment of the real VPN password"),
    ]

    /// Literals that are allowed to contain a denied marker.
    ///
    /// Every occurrence is blanked out before the markers are searched for. Both
    /// entries are load-bearing facts rather than leaks:
    ///
    ///  * `com.idraki.turtle.vpn` is the *legacy* Keychain service name. The
    ///    credential migration reads it and an external script the user runs
    ///    reads it, so it cannot be renamed without losing existing credentials.
    ///  * `github.com/idrakimuhamad` is the repository owner's own account. It
    ///    is already named by the clone URL, so it is public by construction,
    ///    and the README links to a sibling project of theirs.
    ///  * `api.github.com/repos/idrakimuhamad` is the release feed the app asks
    ///    for its own newest version. The same account again, through the API's
    ///    host rather than the web one.
    ///
    /// Anything else that contains a marker is a finding, not an exemption.
    private static let permittedLiterals: [String] = [
        "com.idraki.turtle.vpn",
        "github.com/idrakimuhamad",
        "api.github.com/repos/idrakimuhamad",
    ]

    /// The one file that has to contain the markers, because it is the list of
    /// them. It is therefore exempt from its own scan — and it is the only
    /// exemption, which `testTheScanReachesTheSourceAndSkipsTheBuildTrees` pins.
    private static let exemptFile = "Tests/TurtleDiverAppTests/RepoPrivacyGuardTests.swift"

    // MARK: - The scan

    func testNoTrackedTextFileMentionsAnEmployerOrPersonalIdentifier() {
        var offences: [String] = []
        for file in Self.textFiles(in: Self.repoRoot) where file.path != Self.exemptFile {
            offences += Self.offences(in: file.text, file: file.path)
        }

        // A guard that fails with four hundred lines of output gets deleted
        // rather than fixed, so cap the report and say how many were dropped.
        let shown = offences.prefix(25)
        var message = "the repository mentions an employer or personal identifier:"
        message += "\n" + shown.joined(separator: "\n")
        if offences.count > shown.count {
            message += "\n… and \(offences.count - shown.count) more"
        }
        message += "\n\nFix the file, or — if the value is genuinely load-bearing —"
        message += "\nadd it to `permittedLiterals` with a reason."

        XCTAssertTrue(offences.isEmpty, message)
    }

    /// A guard that scans nothing passes for the wrong reason: an empty walk, a
    /// wrong root, or a build tree that swallowed the source would all report
    /// success. Pin the shape of the walk, and pin that it stops at build output.
    func testTheScanReachesTheSourceAndSkipsTheBuildTrees() {
        let paths = Set(Self.textFiles(in: Self.repoRoot).map(\.path))

        XCTAssertGreaterThan(paths.count, 100,
                             "the walk found \(paths.count) files — it is not reaching the tree")

        for expected in [
            "README.md",
            "Package.swift",
            "build.sh",
            "publish.sh",
            "docs/ELEVATION.md",
            "docs/DISTRIBUTION.md",
            "docs/MANUAL_TEST_CHECKLIST.md",
            "VPNConnect/VPNManager.swift",
            "VPNConnect/System/AppIdentity.swift",
            "Tests/TurtleDiverAppTests/SecretHygieneTests.swift",
            Self.exemptFile,
        ] {
            XCTAssertTrue(paths.contains(expected), "the walk missed \(expected)")
        }

        for buildTree in [".build/", "build/", "dist/", ".git/"] {
            XCTAssertFalse(paths.contains { $0.hasPrefix(buildTree) },
                           "the walk descended into \(buildTree), which is generated")
        }
    }

    /// The exemption exists for exactly one literal, so prove it excuses that
    /// literal and nothing else. Without this, a masking bug that blanked whole
    /// lines would look identical to a clean repository.
    func testTheLegacyServiceNameIsExcusedButTheMarkerIsCaughtElsewhere() {
        XCTAssertTrue(
            Self.offences(in: #"keychain(service: "com.idraki.turtle.vpn")"#, file: "synthetic").isEmpty,
            "the legacy Keychain service name must stay allowed: the migration reads it"
        )
        XCTAssertFalse(
            Self.offences(in: #"let home = "/Users/idraki/Documents""#, file: "synthetic").isEmpty,
            "a marker outside a permitted literal must still be caught"
        )
    }

    /// The guard is only worth having if it would catch the values this sweep
    /// removed, so feed every marker back through the matcher. This is also the
    /// negative check, kept: it fails if the matcher is ever neutered, and it
    /// rejects an empty marker (which would match every line of every file).
    func testEveryDeniedMarkerIsCaughtByTheMatcher() {
        XCTAssertGreaterThan(Self.deniedMarkers.count, 8, "the marker list has been emptied")

        for (marker, why) in Self.deniedMarkers {
            XCTAssertFalse(marker.isEmpty, "an empty marker matches every line of every file")
            XCTAssertGreaterThanOrEqual(marker.count, 3, "a \(marker.count)-character marker is noise")
            XCTAssertFalse(
                Self.offences(in: "a line mentioning \(marker) in passing", file: "synthetic").isEmpty,
                "the matcher does not match \"\(marker)\" (\(why)) — the guard has stopped guarding"
            )
        }
    }

    // MARK: - The matcher

    /// Pure: what in `text` is forbidden, as human-readable findings.
    ///
    /// `file` is only ever used to build the message, which is what keeps the
    /// message precise enough to act on.
    private static func offences(in text: String, file: String) -> [String] {
        let readable = blankingPermittedLiterals(in: text)
            .replacingOccurrences(of: "\r\n", with: "\n")   // Swift folds CRLF into one Character
        let lines = readable.split(separator: "\n", omittingEmptySubsequences: false)

        var found: [String] = []
        for (index, line) in lines.enumerated() {
            let haystack = line.lowercased()
            for (marker, why) in deniedMarkers where haystack.contains(marker.lowercased()) {
                found.append("\(file):\(index + 1) contains \"\(marker)\" — \(why)")
            }
        }
        return found
    }

    /// Replace every permitted literal with as many `x`s, so that a marker inside
    /// one is invisible to the search while line numbering is untouched.
    private static func blankingPermittedLiterals(in text: String) -> String {
        var blanked = text
        for literal in permittedLiterals {
            blanked = blanked.replacingOccurrences(
                of: literal,
                with: String(repeating: "x", count: literal.count),
                options: [.caseInsensitive]
            )
        }
        return blanked
    }

    // MARK: - The tree

    private static func textFiles(in root: URL) -> [(path: String, text: String)] {
        let skippedDirectories: Set<String> = [
            ".git", ".build", ".swiftpm", "build", "dist", "DerivedData", "xcuserdata",
        ]
        let binaryExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "icns", "pdf", "zip", "gz", "dmg", "pkg",
            "o", "a", "so", "dylib", "swiftmodule", "swiftdoc", "bin", "xcuserstate",
        ]

        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return []
        }

        var files: [(path: String, text: String)] = []
        for case let url as URL in walker {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if skippedDirectories.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard !binaryExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // Anything that will not decode as UTF-8 is not source, a document or
            // a script — `.DS_Store` being the one that is always present.
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files.append((path: relativePath(of: url, in: root), text: text))
        }
        return files
    }

    private static func relativePath(of url: URL, in root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }

    /// …/Tests/TurtleDiverAppTests/RepoPrivacyGuardTests.swift -> repository root.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
