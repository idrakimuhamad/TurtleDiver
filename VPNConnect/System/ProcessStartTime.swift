import Foundation

/// How long a process has been running, read with a deadline and without asking
/// for anything the machine's locale is free to restyle.
///
/// The obvious field to ask for is `lstart`, but that is a *formatted date*: its
/// day and month names come from `LC_TIME`, so a machine running under a
/// non-English locale answers `Mi. 16 Sep. 19:34:34 2026` — measured — and a
/// fixed-format parser cannot read that, however carefully its own locale is
/// pinned. The elapsed field is digits, colons and at most one dash, and cannot
/// be localised at all.
///
/// Measured on macOS 27.0 (build 26A428): `MM:SS` under an hour, `HH:MM:SS`
/// under a day, and `DD-HH:MM:SS` above it with the day zero-padded —
/// `06-06:05:52` for launchd against `01:16:49` for something up an hour and
/// `00:00` for a shell started a moment ago.
/// `etimes` — the integer form — does not exist here: `ps: etimes: keyword not
/// found`.
public enum ProcessStartTime {
    public static let psExecutable = URL(fileURLWithPath: "/bin/ps")

    /// The trailing `=` in the field name suppresses `ps`'s header row, so a
    /// successful read is the number and nothing else.
    public static func arguments(pid: Int32) -> [String] {
        ["-o", "etime=", "-p", "\(pid)"]
    }

    /// Seconds elapsed, from one `ps -o etime=` field. Nil for anything that is
    /// not a shape this parser knows, so an unexpected answer becomes "no
    /// duration" rather than a wrong one.
    public static func elapsedSeconds(fromETime field: String) -> TimeInterval? {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        /// Only digits: `Double("1e3")` would otherwise pass for a number, and
        /// `Double("-2")` for a sane-looking field.
        func number(_ text: Substring) -> Double? {
            guard !text.isEmpty, text.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
            return Double(text)
        }

        // Days are the only part that sits behind a dash.
        var days: Double = 0
        var clock: Substring
        let dayParts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        switch dayParts.count {
        case 1:
            clock = dayParts[0]
        case 2:
            guard let parsedDays = number(dayParts[0]) else { return nil }
            days = parsedDays
            clock = dayParts[1]
        default:
            return nil
        }

        let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds: Double = 0
        for part in parts {
            guard let value = number(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }

    /// When a process that has been up for `elapsed` started, given the clock
    /// reading taken when the field was printed.
    public static func startDate(now: Date, elapsed: TimeInterval) -> Date {
        now.addingTimeInterval(-elapsed)
    }
}

/// Reads a process's start time, with a deadline.
///
/// Reading it means spawning `ps`, and this runs on the main thread while a
/// tunnel is being adopted — on the launch path. A spawn can block on a loaded
/// machine, so it is bounded here rather than waited on: `SystemBoundedProcessRunner`
/// gives the child a deadline, then `SIGTERM`, then a grace, then `SIGKILL`.
///
/// The runner is injectable so the bound can be proved without depending on a
/// real `ps` deciding to hang.
public struct ProcessStartTimeReader: Sendable {
    /// Generous next to a `ps` that answers in milliseconds. The bound is only
    /// here so a wedged one cannot hold up the launch.
    public static let defaultTimeout: TimeInterval = 3

    public let executableURL: URL
    public let timeout: TimeInterval
    private let runner: any BoundedProcessRunning

    public init(
        executableURL: URL = ProcessStartTime.psExecutable,
        timeout: TimeInterval = ProcessStartTimeReader.defaultTimeout,
        runner: any BoundedProcessRunning = SystemBoundedProcessRunner()
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.runner = runner
    }

    /// Nil when the process is gone, the read failed, the read ran out of time,
    /// or the field was not one this parser knows.
    public func startTime(pid: Int32, now: Date = Date()) -> Date? {
        guard pid > 1 else { return nil }
        guard let result = try? runner.run(
            executable: executableURL,
            arguments: ProcessStartTime.arguments(pid: pid),
            timeout: timeout
        ) else {
            return nil
        }
        // A timed-out child's status says nothing about what it printed.
        guard !result.timedOut, result.terminationStatus == 0 else { return nil }
        guard let elapsed = ProcessStartTime.elapsedSeconds(fromETime: result.stdout) else { return nil }
        return ProcessStartTime.startDate(now: now, elapsed: elapsed)
    }
}
