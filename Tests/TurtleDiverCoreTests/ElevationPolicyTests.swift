import XCTest

#if canImport(TurtleDiverSystem)
import TurtleDiverSystem
#endif

/// Covers the decision that keeps a connect from feeding a `sudo` that is
/// blocked in a Touch ID dialog, and the sweep that cleans up a wrapper left
/// behind by a previous run.
///
/// The dangerous case is not "did it notice pam_tid" but "did it signal a group
/// that is still tunneling", so the sweep is tested against real processes:
/// a `sleep` in its own process group, exactly like the elevation wrapper.
final class ElevationPolicyTests: XCTestCase {

    // MARK: - Reading /etc/pam.d

    /// The literal line the Touch ID recipe adds to `/etc/pam.d/sudo_local`.
    private let pamTidLine = "auth sufficient pam_tid.so"

    func testTheTouchIDRecipeFileIsDetected() {
        let contents = """
        # sudo_local: local config file which survives system update and is included for sudo
        \(pamTidLine)
        """

        XCTAssertTrue(ElevationProbe.fileEnablesTouchID(contents))
        XCTAssertEqual(ElevationProbe.mode(pamFileContents: [contents]), .systemPrompt)
    }

    func testACommentedOutTouchIDLineIsNotEvidence() {
        let contents = """
        # sudo_local
        #\(pamTidLine)
        # \(pamTidLine)
        """

        XCTAssertFalse(ElevationProbe.fileEnablesTouchID(contents))
        XCTAssertEqual(ElevationProbe.mode(pamFileContents: [contents]), .storedPassword)
    }

    func testACommentMentioningTheModuleIsNotEvidence() {
        XCTAssertFalse(ElevationProbe.fileEnablesTouchID("# enable \(ElevationProbe.touchIDModuleName) here"))
        XCTAssertFalse(ElevationProbe.fileEnablesTouchID("auth sufficient pam_opendirectory.so"))
    }

    func testAnUnreadableOrMissingFileMeansStoredPassword() {
        XCTAssertFalse(ElevationProbe.fileEnablesTouchID(nil))
        XCTAssertEqual(ElevationProbe.mode(pamFileContents: [nil, nil]), .storedPassword)
        XCTAssertEqual(ElevationProbe.mode(pamFileContents: []), .storedPassword)
    }

    /// A stock `sudo` merely includes the local file. The include is not
    /// evidence that Touch ID is enabled — the line it includes is.
    func testTheIncludeDirectiveIsNotEvidence() {
        let stockSudo = """
        # sudo
        auth       include     sudo_local
        """
        XCTAssertFalse(ElevationProbe.fileEnablesTouchID(stockSudo))

        let enabledInSudoItself = """
        auth       include     sudo_local
        \(pamTidLine)
        """
        XCTAssertTrue(ElevationProbe.fileEnablesTouchID(enabledInSudoItself))
    }

    func testAFullModulePathIsDetected() {
        XCTAssertTrue(ElevationProbe.fileEnablesTouchID("auth       sufficient  /usr/lib/pam/pam_tid.so.2"))
    }

    func testTabSeparatedAndCRLFLinesAreDetected() {
        XCTAssertTrue(ElevationProbe.fileEnablesTouchID("auth\tsufficient\tpam_tid.so\r\nother\tline\there\r\n"))
    }

    func testTheModuleMustBeTheThirdField() {
        // `pam_tid.so` as an argument of another module is not an auth line.
        XCTAssertFalse(ElevationProbe.fileEnablesTouchID("auth sufficient pam_opendirectory.so pam_tid.so"))
    }

    /// Both files are inspected, because the older recipe edited `sudo` itself.
    func testEitherPamFileCanEnableIt() {
        let sudoLocal: String? = nil
        let sudo: String? = "auth sufficient pam_tid.so"
        XCTAssertEqual(ElevationProbe.mode(pamFileContents: [sudoLocal, sudo]), .systemPrompt)
    }

    func testTheProbeReadsBothFilesInOrderAndPassesTheTimestampThrough() {
        var read: [String] = []
        let snapshot = ElevationProbe.live(
            readFile: { path in
                read.append(path)
                return path.hasSuffix("sudo_local") ? self.pamTidLine : nil
            },
            sudoTimestampIsWarm: { false }
        )

        XCTAssertEqual(read, ElevationProbe.pamFilePaths)
        XCTAssertEqual(snapshot.pamFilesInspected, ElevationProbe.pamFilePaths)
        XCTAssertEqual(snapshot.mode, .systemPrompt)
        XCTAssertFalse(snapshot.timestampWarm)
        XCTAssertEqual(snapshot.strategy, .systemPrompt)
    }

    // MARK: - Choosing a strategy

    func testAWarmTimestampIsUsedAsIsWhateverPamSays() {
        // Nothing needs asking either way, so the safest plan is the one that
        // sends no password at all.
        XCTAssertEqual(ElevationStrategy.resolve(mode: .systemPrompt, timestampWarm: true), .warmTimestamp)
        XCTAssertEqual(ElevationStrategy.resolve(mode: .storedPassword, timestampWarm: true), .warmTimestamp)
    }

    func testAColdTimestampPicksByPamConfiguration() {
        XCTAssertEqual(ElevationStrategy.resolve(mode: .systemPrompt, timestampWarm: false), .systemPrompt)
        XCTAssertEqual(ElevationStrategy.resolve(mode: .storedPassword, timestampWarm: false), .storedPassword)
    }

    /// The whole point: the password is piped only into a stack that cannot
    /// raise a dialog, and the credential line count follows from that.
    func testOnlyTheNonTouchIDModePipesTheStoredPassword() {
        XCTAssertTrue(ElevationStrategy.storedPassword.pipesTheStoredPassword)
        XCTAssertFalse(ElevationStrategy.systemPrompt.pipesTheStoredPassword)
        XCTAssertFalse(ElevationStrategy.warmTimestamp.pipesTheStoredPassword)

        XCTAssertEqual(ElevationStrategy.storedPassword.credentialLineCount, OpenConnectCommand.credentialLineCount)
        XCTAssertEqual(ElevationStrategy.systemPrompt.credentialLineCount, OpenConnectCommand.credentialLineCount - 1)
        XCTAssertEqual(ElevationStrategy.warmTimestamp.credentialLineCount, OpenConnectCommand.credentialLineCount - 1)
    }

    func testTheTimeoutStatusNamesTouchIDOnlyForTheTouchIDMode() {
        XCTAssertEqual(ElevationStrategy.systemPrompt.timeoutHistoryStatus, ElevationFailure.touchIDStatus)
        XCTAssertEqual(ElevationStrategy.systemPrompt.timeoutHistoryStatus, "Failed - Elevation Blocked (Touch ID)")
        XCTAssertEqual(ElevationStrategy.warmTimestamp.timeoutHistoryStatus, "Connection timeout")
        XCTAssertEqual(ElevationStrategy.storedPassword.timeoutHistoryStatus, "Connection timeout")
    }

    func testTheTimeoutDetailForTouchIDNamesTheCauseAndTheRemedy() {
        let detail = ElevationStrategy.systemPrompt.timeoutDetail(timeoutSeconds: 90)

        XCTAssertTrue(detail.contains("Touch ID"))
        XCTAssertTrue(detail.contains("administrator password"))
        XCTAssertTrue(detail.contains("90s"))
        XCTAssertTrue(detail.lowercased().contains("connect again"))
        XCTAssertEqual(ElevationStrategy.storedPassword.timeoutDetail(timeoutSeconds: 90), "Connection timeout")
    }

    /// "Diagnose before the wait": the log has to say which way it will go
    /// before the connect starts waiting on a dialog.
    func testTheDiagnosisSaysWhatToExpectBeforeTheWait() {
        let touchID = ElevationStrategy.systemPrompt.debugLines(timeoutSeconds: 90).joined(separator: "\n")
        XCTAssertTrue(touchID.contains(ElevationProbe.touchIDModuleName))
        XCTAssertTrue(touchID.contains("Touch ID"))
        XCTAssertTrue(touchID.contains("90s"))

        let warm = ElevationStrategy.warmTimestamp.debugLines(timeoutSeconds: 90).joined(separator: "\n")
        XCTAssertTrue(warm.lowercased().contains("no dialog"))

        let stored = ElevationStrategy.storedPassword.debugLines(timeoutSeconds: 90).joined(separator: "\n")
        XCTAssertTrue(stored.contains("administrator password"))
        XCTAssertTrue(stored.lowercased().contains("no system dialog"))
    }

    func testEveryStrategyIsDescribed() {
        // A new case must not fall through to an empty diagnosis.
        for strategy in ElevationStrategy.allCases {
            XCTAssertFalse(strategy.debugLines(timeoutSeconds: 90).isEmpty, "\(strategy) has no diagnosis")
            XCTAssertFalse(strategy.timeoutDetail(timeoutSeconds: 90).isEmpty, "\(strategy) has no timeout detail")
            XCTAssertFalse(strategy.timeoutHistoryStatus.isEmpty)
        }
    }

    // MARK: - Failure markers

    func testEveryMarkerRoundTripsAndIsNotSharedWithAnotherReason() {
        var seen: Set<String> = []
        for reason in ElevationBlockReason.allCases {
            XCTAssertEqual(ElevationBlockReason.match(markerLine: reason.markerLine), reason)
            XCTAssertEqual(ElevationBlockReason.match(markerLine: "  \(reason.markerLine)  "), reason,
                           "trailing whitespace from the pipe must not defeat matching")
            XCTAssertTrue(seen.insert(reason.markerLine).inserted, "\(reason) shares a marker line")
            XCTAssertTrue(reason.markerLine.hasPrefix(ElevationBlockReason.markerPrefix))
            XCTAssertFalse(reason.detail.isEmpty)
        }
    }

    func testAMarkerIsMatchedExactlyAndNothingElseIs() {
        let marker = ElevationBlockReason.systemPromptUnanswered.markerLine

        XCTAssertNil(ElevationBlockReason.match(markerLine: "openconnect: \(marker)"))
        XCTAssertNil(ElevationBlockReason.match(markerLine: ElevationBlockReason.markerPrefix + "something new"))
        XCTAssertNil(ElevationBlockReason.match(markerLine: "Connected as user"))
        XCTAssertNil(ElevationBlockReason.match(markerLine: ""))
    }

    func testTheUnansweredDialogMarkerCarriesTheTouchIDStatus() {
        XCTAssertEqual(ElevationBlockReason.systemPromptUnanswered.historyStatus, ElevationFailure.touchIDStatus)
        XCTAssertEqual(ElevationBlockReason.timestampExpired.historyStatus, "Failed - Elevation Expired")
        XCTAssertEqual(ElevationBlockReason.storedPasswordRejected.historyStatus, "Failed - Admin Password")

        let statuses = Set(ElevationBlockReason.allCases.map(\.historyStatus))
        XCTAssertEqual(statuses.count, ElevationBlockReason.allCases.count, "two reasons share a History status")
    }

    // MARK: - The process-group record

    func testTheRecordLivesInTheSameRunDirectoryAsThePidFile() {
        let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support/TurtleDiver")

        XCTAssertEqual(ElevationRecord.path(inApplicationSupport: base).path,
                       "/Users/someone/Library/Application Support/TurtleDiver/run/elevation.pgid")
        XCTAssertEqual(ElevationRecord.path(inApplicationSupport: base).deletingLastPathComponent(),
                       OpenConnectPidFile.path(inApplicationSupport: base).deletingLastPathComponent())
    }

    func testTheRecordAcceptsOnlyAUsableGroup() {
        XCTAssertEqual(ElevationRecord.parse("4321\n"), 4321)
        XCTAssertEqual(ElevationRecord.parse("  4321  "), 4321)

        // 0 is the kernel and 1 is launchd; neither is ever what was meant.
        XCTAssertNil(ElevationRecord.parse("0"))
        XCTAssertNil(ElevationRecord.parse("1"))
        XCTAssertNil(ElevationRecord.parse("-5"))
        XCTAssertNil(ElevationRecord.parse(""))
        XCTAssertNil(ElevationRecord.parse("   "))
        XCTAssertNil(ElevationRecord.parse("4321 4322"))
        XCTAssertNil(ElevationRecord.parse("abc"))
        XCTAssertNil(ElevationRecord.parse("12.5"))
        XCTAssertNil(ElevationRecord.parse(nil))
        XCTAssertNil(ElevationRecord.parse("99999999999999999999"))
    }

    func testWritingAndReadingTheRecordRoundTrips() throws {
        let url = try temporaryDirectory().appendingPathComponent(ElevationRecord.fileName)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        XCTAssertTrue(ElevationRecord.write(4321, to: url))
        XCTAssertEqual(ElevationRecord.read(from: url), 4321)
        XCTAssertNil(ElevationRecord.read(from: url.deletingLastPathComponent().appendingPathComponent("absent")))

        XCTAssertFalse(ElevationRecord.write(1, to: url), "an unusable group must not be written")
        XCTAssertEqual(ElevationRecord.read(from: url), 4321)

        ElevationRecord.remove(at: url)
        XCTAssertNil(ElevationRecord.read(from: url))
    }

    // MARK: - The sweep decision

    func testNoRecordMeansNothingToDo() {
        XCTAssertEqual(ElevationSweep.decide(recordedPgid: nil, liveConnectionPid: nil,
                                             ownProcessGroup: 100, groupMembers: []), .nothingToDo)
        XCTAssertEqual(ElevationSweep.decide(recordedPgid: 1, liveConnectionPid: nil,
                                             ownProcessGroup: 100, groupMembers: []), .nothingToDo)
    }

    func testTheAppsOwnProcessGroupIsNeverSignalled() {
        // A corrupted or recycled record must not make the app kill itself.
        XCTAssertEqual(ElevationSweep.decide(recordedPgid: 4321, liveConnectionPid: nil,
                                             ownProcessGroup: 4321, groupMembers: []),
                       .leaveAlive(4321, reason: "it is this app's own process group"))
    }

    func testAGroupWithALiveConnectionIsLeftAlone() {
        let decision = ElevationSweep.decide(recordedPgid: 4321, liveConnectionPid: 999,
                                             ownProcessGroup: 100, groupMembers: ["openconnect"])
        guard case .leaveAlive(let pgid, let reason) = decision else {
            return XCTFail("a live connection must never be signalled, got \(decision)")
        }
        XCTAssertEqual(pgid, 4321)
        XCTAssertTrue(reason.contains("999"))
    }

    /// The dangerous case: no PID file, but the group still contains the tunnel.
    func testAGroupContainingOpenconnectIsLeftAloneEvenWithoutAPidFile() {
        let decision = ElevationSweep.decide(recordedPgid: 4321, liveConnectionPid: nil,
                                             ownProcessGroup: 100,
                                             groupMembers: ["/bin/bash", "/opt/homebrew/bin/openconnect"])
        guard case .leaveAlive(_, let reason) = decision else {
            return XCTFail("an openconnect member must never be signalled, got \(decision)")
        }
        XCTAssertTrue(reason.contains("openconnect"))
    }

    func testACleanGroupIsReaped() {
        XCTAssertEqual(ElevationSweep.decide(recordedPgid: 4321, liveConnectionPid: nil,
                                             ownProcessGroup: 100, groupMembers: ["/bin/bash", "sleep"]),
                       .reap(4321))
        XCTAssertEqual(ElevationSweep.decide(recordedPgid: 4321, liveConnectionPid: nil,
                                             ownProcessGroup: 100, groupMembers: []),
                       .reap(4321))
    }

    // MARK: - The sweep, against a real process group

    /// Starts `sleep` in its own process group — the same shape as the elevation
    /// wrapper — and returns its pgid. `set -m` is how bash creates the group;
    /// there is no `setsid` on this machine.
    private func startDetachedGroup() throws -> Int32 {
        let sandbox = try temporaryDirectory()
        let pgidFile = sandbox.appendingPathComponent("pgid")
        let script = "set -m; /bin/sleep 30 & ps -o pgid= -p $! | tr -d ' ' > '\(pgidFile.path)'; exit 0"

        let bash = Process()
        bash.executableURL = URL(fileURLWithPath: "/bin/bash")
        bash.arguments = ["-c", script]
        bash.standardOutput = FileHandle.nullDevice
        bash.standardError = FileHandle.nullDevice
        try bash.run()
        bash.waitUntilExit()

        let pgid = try XCTUnwrap(ElevationRecord.parse(try String(contentsOf: pgidFile, encoding: .utf8)),
                                 "the test could not start a process group")
        addTeardownBlock { killpg(pgid, SIGKILL) }
        return pgid
    }

    func testTheSweepReallyReapsAStaleGroup() throws {
        let sandbox = try temporaryDirectory()
        let recordURL = sandbox.appendingPathComponent(ElevationRecord.fileName)
        let pgid = try startDetachedGroup()
        XCTAssertTrue(ElevationRecord.write(pgid, to: recordURL))
        XCTAssertEqual(killpg(pgid, 0), 0, "the group should be alive before the sweep")

        var lines: [String] = []
        let decision = ElevationReaper.reapStaleGroup(
            recordURL: recordURL,
            pidFileURL: sandbox.appendingPathComponent("openconnect.pid"),
            ownProcessGroup: getpgrp(),
            log: { lines.append($0) }
        )

        XCTAssertEqual(decision, .reap(pgid))
        XCTAssertNotEqual(killpg(pgid, 0), 0, "the stale group is still alive")
        XCTAssertNil(ElevationRecord.read(from: recordURL), "the record must not survive the sweep")
        XCTAssertTrue(lines.joined().contains("reaping stale process group"))
    }

    /// The safety property, with real processes: a live connection in the PID
    /// file means hands off.
    func testTheSweepLeavesAGroupWithALivePidFileAlone() throws {
        let sandbox = try temporaryDirectory()
        let recordURL = sandbox.appendingPathComponent(ElevationRecord.fileName)
        let pidFile = sandbox.appendingPathComponent("openconnect.pid")
        let pgid = try startDetachedGroup()
        XCTAssertTrue(ElevationRecord.write(pgid, to: recordURL))
        try "\(getpid())\n".write(to: pidFile, atomically: true, encoding: .utf8)

        var lines: [String] = []
        let decision = ElevationReaper.reapStaleGroup(
            recordURL: recordURL,
            pidFileURL: pidFile,
            ownProcessGroup: getpgrp(),
            log: { lines.append($0) }
        )

        guard case .leaveAlive = decision else { return XCTFail("expected the group to be left alone, got \(decision)") }
        XCTAssertEqual(killpg(pgid, 0), 0, "the group was signalled while a connection was attached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidFile.path), "a live PID file must survive")
        XCTAssertEqual(ElevationRecord.read(from: recordURL), pgid, "the handle must survive for a later teardown")
        XCTAssertTrue(lines.joined().contains("leaving process group"))
    }

    func testTheSweepRemovesAStalePidFile() throws {
        let sandbox = try temporaryDirectory()
        let recordURL = sandbox.appendingPathComponent(ElevationRecord.fileName)
        let pidFile = sandbox.appendingPathComponent("openconnect.pid")
        let pgid = try startDetachedGroup()
        XCTAssertTrue(ElevationRecord.write(pgid, to: recordURL))

        // A pid that has been reaped: definitely not running any more.
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        dead.waitUntilExit()
        try "\(dead.processIdentifier)\n".write(to: pidFile, atomically: true, encoding: .utf8)

        let decision = ElevationReaper.reapStaleGroup(
            recordURL: recordURL,
            pidFileURL: pidFile,
            ownProcessGroup: getpgrp(),
            log: { _ in }
        )

        XCTAssertEqual(decision, .reap(pgid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile.path),
                       "a PID file naming a dead process is stale and must go")
    }

    func testTheSweepIsHarmlessWithNothingRecorded() throws {
        let sandbox = try temporaryDirectory()
        let decision = ElevationReaper.reapStaleGroup(
            recordURL: sandbox.appendingPathComponent(ElevationRecord.fileName),
            pidFileURL: sandbox.appendingPathComponent("openconnect.pid"),
            ownProcessGroup: getpgrp(),
            log: { _ in }
        )

        XCTAssertEqual(decision, .nothingToDo)
    }

    /// `ps -o comm= -g <pgid>` is how the sweep learns what is in a group.
    func testReadingTheGroupMembersFindsTheProcess() throws {
        let pgid = try startDetachedGroup()

        let members = ElevationReaper.defaultGroupMembers(pgid)

        XCTAssertTrue(members.contains { $0.lowercased().contains("sleep") },
                      "expected the group's sleep process, got \(members)")
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("elevation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
