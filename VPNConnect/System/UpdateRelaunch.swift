import Foundation

// MARK: - The plan

/// The command that reopens the app once this one has gone.
///
/// Split into a value so the *whole* command can be asserted in a test without
/// spawning anything: what matters is that the pid and the bundle path are
/// arguments, and that the script never mentions either.
public struct RelaunchPlan: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The script text, which is the first argument after `-c`.
    public var script: String { arguments.count > 1 ? arguments[1] : "" }
    public var pid: String? { arguments.count > 4 ? arguments[3] : nil }
    public var appPath: String? { arguments.count > 4 ? arguments[4] : nil }
}

public enum UpdateRelaunchError: LocalizedError, Equatable {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return "Could not arrange for the app to reopen: \(detail)"
        }
    }
}

/// A process that is meant to outlive the one starting it.
public protocol ProcessLaunching: Sendable {
    func launchDetached(_ plan: RelaunchPlan) throws
}

public struct DetachedProcessLauncher: ProcessLaunching {
    public init() {}

    public func launchDetached(_ plan: RelaunchPlan) throws {
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        // Nothing to read, nothing to write: the waiter is silent, and a child
        // holding a terminal would keep this process's descriptors alive.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateRelaunchError.launchFailed(error.localizedDescription)
        }
        // Deliberately not waited for. It exists to outlive this process.
    }
}

// MARK: - Relaunching

/// Reopening the app after it has replaced its own bundle.
///
/// The app cannot relaunch itself: the process that has to be gone before the
/// new bundle runs is the one that would be doing the launching. So a small
/// detached shell waits for this pid to disappear and then asks the Finder to
/// open the new bundle — bounded, so a pid that somehow outlives the wait cannot
/// leave a shell spinning forever.
///
/// The wait is the reason this is not simply `open -a`: `open -a` against a
/// bundle being swapped underneath it is a race, and losing it means the user is
/// left with no window at all.
public struct UpdateRelaunch: Sendable {
    /// `/bin/sh`, by path — never a shell found on the user's `PATH`.
    public static let shell = URL(fileURLWithPath: "/bin/sh")
    /// Sixty seconds, in tenths.
    public static let waitTicks = 600
    public static let tickSeconds = 0.1

    public let launcher: any ProcessLaunching

    public init(launcher: any ProcessLaunching = DetachedProcessLauncher()) {
        self.launcher = launcher
    }

    /// The command, as one `sh -c` argument.
    ///
    /// The pid and the bundle path are *arguments*, never interpolated into the
    /// script: a path is a path, and a string substitution that can carry a
    /// quote into a shell script is a substitution that can run a command. The
    /// script is a constant, and its text is the same for every user.
    public static func plan(pid: Int32, appURL: URL) -> RelaunchPlan {
        let script = """
        pid="$1"; app="$2"; waited=0
        while kill -0 "$pid" 2>/dev/null; do
            waited=$((waited + 1))
            [ "$waited" -ge \(waitTicks) ] && exit 0
            sleep \(tickSeconds)
        done
        exec open -a "$app"
        """
        return RelaunchPlan(executable: shell,
                            arguments: ["-c", script, "sh", String(pid), appURL.path])
    }

    public func relaunch(pid: Int32, appURL: URL) throws {
        try launcher.launchDetached(Self.plan(pid: pid, appURL: appURL))
    }
}
