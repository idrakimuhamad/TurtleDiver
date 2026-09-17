import XCTest

/// `project.pbxproj` is the only record of what the app is built from, and it
/// fails quietly: an ID that is *mentioned* but never *defined* — a build file
/// whose definition was edited away while the Sources phase still lists it —
/// leaves a source file out of the binary with no warning from Xcode, and the
/// only symptom is `cannot find type 'X' in scope` in whichever file used it.
///
/// `swift build` never reads this file (the SPM targets come from
/// `Package.swift`), so nothing else in the test suite would notice. These three
/// invariants are what a registration has to satisfy.
final class XcodeProjectRegistrationTests: XCTestCase {

    private let project = "VPNConnect.xcodeproj/project.pbxproj"
    /// The one Sources phase in the one app target.
    private let sourcesPhase = "1A2B3C451234567890ABCDEF"
    /// Where the app's own sources live.
    private let appTargetDirectory = "VPNConnect"

    // MARK: - The invariants

    /// Every 24-digit identifier the project mentions must be defined somewhere
    /// in it. A mention with no definition is a dead reference.
    func testEveryIdentifierTheProjectMentionsIsDefined() throws {
        let text = try projectText()

        let mentioned = Set(captures("([0-9A-F]{24})", in: text).compactMap { $0.first })
        let defined = Set(captures("^\t\t([0-9A-F]{24})[^\n]*= \\{", in: text).compactMap { $0.first })

        let dangling = mentioned.subtracting(defined).sorted()
        XCTAssertTrue(dangling.isEmpty,
                      "these identifiers are referenced but never defined, so whatever names "
                        + "them is quietly not built: \(dangling.joined(separator: ", "))")
    }

    /// Every file the Sources phase lists must resolve, through its build file
    /// and its file reference, to a file that is on disk under `VPNConnect`.
    func testEverySourceFileEntryResolvesToAFileOnDisk() throws {
        let text = try projectText()

        let buildFiles = dictionary(from: captures(
            "^\t\t([0-9A-F]{24}) /\\* .+? in Sources \\*/ = \\{isa = PBXBuildFile; fileRef = ([0-9A-F]{24})",
            in: text))
        let fileRefs = dictionary(from: captures(
            "^\t\t([0-9A-F]{24}) /\\* .+? \\*/ = \\{isa = PBXFileReference;[^\n]*path = ([^;]+);",
            in: text))

        let entries = sourcesEntries(in: text)
        XCTAssertGreaterThan(entries.count, 40, "the Sources phase should list the whole app")

        let onDisk = try swiftFilesByName()
        for (id, name) in entries {
            guard let ref = buildFiles[id] else {
                return XCTFail("\(name) is in the Sources phase with no PBXBuildFile definition")
            }
            guard let path = fileRefs[ref] else {
                return XCTFail("\(name) points at \(ref), which is not a file reference")
            }
            XCTAssertEqual(onDisk[path]?.count, 1,
                           "\(name) resolves to \(path), which matches "
                            + "\(onDisk[path]?.count ?? 0) files on disk")
        }
    }

    /// And the other direction: a source file that is not in the phase is not in
    /// the app. This is the check that catches a new file nobody registered.
    func testEverySwiftFileUnderVPNConnectIsInTheBuildPhase() throws {
        let text = try projectText()

        let registered = Set(sourcesEntries(in: text).map(\.name))
        let onDisk = Set(try swiftFilesByName().keys)

        let unregistered = onDisk.subtracting(registered).sorted()
        XCTAssertTrue(unregistered.isEmpty,
                      "these files exist but are not in the Sources phase, so the app is not "
                        + "built from them: \(unregistered.joined(separator: ", "))")
    }

    // MARK: - Reading the project

    private func projectText() throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(project), encoding: .utf8)
    }

    /// `ID /* Name in Sources */,` lines, but only inside the Sources phase.
    private func sourcesEntries(in text: String) -> [(id: String, name: String)] {
        guard let start = text.range(of: "\(sourcesPhase) /\u{2A} Sources \u{2A}/ = {") else { return [] }
        let rest = text[start.upperBound...]
        guard let files = rest.range(of: "files = ("),
              let end = rest.range(of: "\n\t\t\t);") else { return [] }
        let block = String(rest[files.upperBound..<end.lowerBound])
        return captures("\t\t\t\t([0-9A-F]{24}) /\\* (.+?) in Sources \\*/", in: block)
            .compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil }
    }

    /// Every `.swift` file under the app target, by file name. Bounded to that
    /// directory on purpose: the build trees are not the app.
    private func swiftFilesByName() throws -> [String: [URL]] {
        let root = repoRoot.appendingPathComponent(appTargetDirectory)
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var result: [String: [URL]] = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            result[url.lastPathComponent, default: []].append(url)
        }
        return result
    }

    private func dictionary(from rows: [[String]]) -> [String: String] {
        var result: [String: String] = [:]
        for row in rows where row.count == 2 {
            result[row[0]] = row[1]
        }
        return result
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
