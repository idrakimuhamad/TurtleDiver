import Foundation

/// The events a run of the app leaves behind, so that a quit which never ran
/// its cleanup can be told apart from one that did.
///
/// `applicationWillTerminate` is not guaranteed to be called: `kill`, `SIGTERM`
/// and a crash all skip it, and until now *nothing* recorded a quit, so a run
/// that skipped its cleanup — leaving the system proxy pointing at a dead
/// engine, or a privileged group behind — looked exactly like a clean one.
///
/// Typed cases rather than a message string, deliberately: a free-form `String`
/// is where a host name or a credential eventually gets written by accident.
/// Every line this log can produce is an event name, a pid and a timestamp.
public enum LifecycleEvent: String, CaseIterable, Sendable {
    /// Written as the first statement of `applicationDidFinishLaunching`, before
    /// anything that could block. A launch line with no matching quit pair is
    /// how a silent, unclean exit is recognised.
    case launch = "launch"
    /// Written before any shutdown work starts. Its presence without an `ended`
    /// line is a quit that hung or was killed part-way through cleanup.
    case willTerminateBegan = "will-terminate-began"
    /// Written after cleanup returns. A `launch`/`began`/`ended` triple is a
    /// clean quit.
    case willTerminateEnded = "will-terminate-ended"
}

/// An append-only record of when the app started and when it stopped cleanly.
///
/// Separate from `StartupLog` on purpose. `StartupLog` truncates its file at
/// every launch, so it can only ever describe the run that is happening now, and
/// it writes asynchronously on a queue — at quit the process can be gone before
/// the queue is drained, which is precisely the moment this log exists for.
/// Writes here are synchronous, one small `O_APPEND` write, and a failure is
/// swallowed: nothing about the quit may depend on a log file.
public enum LifecycleLog {

    public static let fileName = "lifecycle.log"

    /// Next to `launch.log` and the connection log, for the same reasons: not
    /// `/tmp`, whose names another user can pre-create, and `~/Library/Logs` is
    /// where Console.app looks.
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/TurtleDiver", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Rotated at launch, never at quit: a launch is not in a hurry and a quit
    /// must do as little as possible.
    public static let rotationLimit = 64 * 1024

    /// The exact text of one line. Pure, so what gets written can be asserted
    /// without touching a file.
    public static func line(_ event: LifecycleEvent, pid: Int32, now: Date) -> String {
        "\(ISO8601DateFormatter().string(from: now)) \(event.rawValue) pid=\(pid)\n"
    }

    /// Appends one line, synchronously.
    ///
    /// The file is opened with `O_APPEND`, so two writers cannot lose each
    /// other's lines, and with `0600`, because the pid is nobody's business.
    /// Silent on every failure path — including a path that cannot be created —
    /// because a quit must not fail for a log.
    public static func append(
        _ event: LifecycleEvent,
        pid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        now: Date = Date(),
        to url: URL = LifecycleLog.defaultURL
    ) {
        if event == .launch {
            rotateIfNeeded(at: url)
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { return }
        let bytes = Array(line(event, pid: pid, now: now).utf8)
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                write(descriptor, buffer.baseAddress!.advanced(by: written), bytes.count - written)
            }
            // A partial write is possible in principle; a failure is not worth
            // retrying at quit. Either way the line is dropped rather than
            // half-written and retried forever.
            guard count > 0 else { break }
            written += count
        }
        close(descriptor)
    }

    /// Moves a log that has outgrown itself aside, keeping one previous
    /// generation. The file this replaces is removed first: `moveItem` refuses
    /// an existing destination, and `lifecycle.log.1` existing is the normal
    /// case from the second rotation onwards.
    public static func rotateIfNeeded(at url: URL, limit: Int = LifecycleLog.rotationLimit) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size > limit else { return }

        let previous = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
}
