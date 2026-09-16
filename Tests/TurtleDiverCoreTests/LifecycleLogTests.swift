import XCTest
@testable import TurtleDiverSystem

/// `applicationWillTerminate` is not guaranteed to run — `kill`, `SIGTERM` and a
/// crash all skip it — and until this log existed nothing recorded a quit at
/// all, so a run that skipped its cleanup looked exactly like a clean one.
/// `StartupLog` cannot serve here: it truncates at every launch and writes
/// asynchronously, and at quit the process can be gone before its queue drains.
final class LifecycleLogTests: XCTestCase {

    // MARK: - The line

    func testALineNamesTheEventThePidAndTheClock() {
        let line = LifecycleLog.line(.launch, pid: 4_242, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(line, "1970-01-01T00:00:00Z launch pid=4242\n")

        // UTC, and locale-free: a log read on another machine must not need to
        // guess the writer's time zone.
        let later = LifecycleLog.line(.willTerminateEnded, pid: 1,
                                      now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(later, "2027-01-15T08:00:00Z will-terminate-ended pid=1\n")
    }

    /// The invariant that makes this log safe to write from anywhere: there is
    /// no way to put free-form text — a host name, a path, a credential — into
    /// it. A `String` parameter would be exactly where that starts.
    func testEveryLineShapesIdenticallyWhateverTheEvent() {
        let shape = try! NSRegularExpression(
            pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z (launch|will-terminate-began|will-terminate-ended) pid=\d+\n$"#
        )
        for event in LifecycleEvent.allCases {
            let line = LifecycleLog.line(event, pid: 42, now: Date(timeIntervalSince1970: 0))
            let range = NSRange(line.startIndex..., in: line)
            XCTAssertEqual(shape.numberOfMatches(in: line, range: range), 1,
                           "unexpected line for \(event): \(line.debugDescription)")
        }
        XCTAssertEqual(LifecycleEvent.allCases.count, 3,
                       "a new event means a new line shape: check what it can carry")
    }

    // MARK: - Appending

    func testAppendingKeepsWhatWasAlreadyThere() throws {
        let file = try sandbox().appendingPathComponent("lifecycle.log")

        LifecycleLog.append(.launch, pid: 100, now: Date(timeIntervalSince1970: 0), to: file)
        LifecycleLog.append(.willTerminateBegan, pid: 100, now: Date(timeIntervalSince1970: 1), to: file)
        LifecycleLog.append(.willTerminateEnded, pid: 100, now: Date(timeIntervalSince1970: 2), to: file)

        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(contents, """
        1970-01-01T00:00:00Z launch pid=100
        1970-01-01T00:00:01Z will-terminate-began pid=100
        1970-01-01T00:00:02Z will-terminate-ended pid=100

        """)
    }

    func testAppendingCreatesTheDirectoryAndTheFileOwnerOnly() throws {
        let nested = try sandbox().appendingPathComponent("a/b/lifecycle.log")
        LifecycleLog.append(.launch, pid: 7, to: nested)

        let attributes = try FileManager.default.attributesOfItem(atPath: nested.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600,
                       "the pid is nobody else's business")
    }

    /// A quit must not fail for a log, so every failure path is swallowed —
    /// including one where the directory cannot be created at all.
    func testAPathThatCannotBeWrittenIsSwallowed() throws {
        let root = try sandbox()
        let blocker = root.appendingPathComponent("not-a-directory")
        try "x".write(to: blocker, atomically: true, encoding: .utf8)

        // A regular file in the way of the directory component.
        LifecycleLog.append(.launch, pid: 7, to: blocker.appendingPathComponent("lifecycle.log"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blocker.path))
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "x")
    }

    // MARK: - Rotation

    func testASmallLogIsLeftAlone() throws {
        let file = try sandbox().appendingPathComponent("lifecycle.log")
        try "1970-01-01T00:00:00Z launch pid=1\n".write(to: file, atomically: true, encoding: .utf8)

        LifecycleLog.append(.launch, pid: 2, now: Date(timeIntervalSince1970: 0), to: file)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), """
        1970-01-01T00:00:00Z launch pid=1
        1970-01-01T00:00:00Z launch pid=2

        """)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".1"))
    }

    func testALogThatHasOutgrownItselfIsKeptAsThePreviousGeneration() throws {
        let file = try sandbox().appendingPathComponent("lifecycle.log")
        let big = String(repeating: "x", count: LifecycleLog.rotationLimit + 1)
        try big.write(to: file, atomically: true, encoding: .utf8)

        LifecycleLog.append(.launch, pid: 3, now: Date(timeIntervalSince1970: 0), to: file)

        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: file.path + ".1"), encoding: .utf8), big)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "1970-01-01T00:00:00Z launch pid=3\n")
    }

    /// The second rotation onwards is the normal case, and `moveItem` refuses an
    /// existing destination — so the previous generation must be removed first.
    func testTheSecondRotationReplacesThePreviousGeneration() throws {
        let file = try sandbox().appendingPathComponent("lifecycle.log")

        try String(repeating: "old", count: 10).write(to: file, atomically: true, encoding: .utf8)
        LifecycleLog.rotateIfNeeded(at: file, limit: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try String(repeating: "new", count: 10).write(to: file, atomically: true, encoding: .utf8)
        LifecycleLog.rotateIfNeeded(at: file, limit: 10)

        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: file.path + ".1"), encoding: .utf8),
                       String(repeating: "new", count: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Rotation happens at launch, where a couple of file operations cost
    /// nothing — never at quit.
    func testAQuitNeverRotates() throws {
        let file = try sandbox().appendingPathComponent("lifecycle.log")
        let big = String(repeating: "x", count: LifecycleLog.rotationLimit + 1)
        try big.write(to: file, atomically: true, encoding: .utf8)

        LifecycleLog.append(.willTerminateEnded, pid: 4, now: Date(timeIntervalSince1970: 0), to: file)

        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix(big),
                      "the big log must still be there, with the line added after it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".1"))
    }

    // MARK: - Where it lives

    func testTheLogSitsNextToTheConnectionLog() {
        // Not `/tmp`, whose names another user can pre-create.
        XCTAssertEqual(LifecycleLog.defaultURL.path,
                       FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/TurtleDiver/lifecycle.log").path)
    }

    // MARK: Helpers

    private func sandbox() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
