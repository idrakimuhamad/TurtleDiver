import Darwin
import Foundation
import TurtleDiverSystem

/// The real half of `TunnelAgentRuntime`: it spawns the tunnel in a process group
/// of its own, keeps the channel's input bounded, and ends the tunnel with the
/// smallest signal that works — then reports what it actually observed.
///
/// ## Two streams, and why they must not be one
///
/// Standard output is the protocol: fixed words, read by the app. Standard error
/// carries the tunnel's own output, which the app writes to `vpn.log` exactly as
/// it writes the launch's output today. The child is therefore given
/// **stdout redirected to stderr** (`dup2(2, 1)`), so nothing openconnect prints
/// can ever appear on the channel the app is parsing.
///
/// This was measured the hard way: the earlier throwaway agent let the child
/// inherit stdout and it looked fine only because its stand-in for openconnect
/// printed nothing at all. A stand-in that printed one line was enough to
/// corrupt the protocol.
///
/// ## A zombie is not a running tunnel
///
/// The child is the agent's own child, so when it exits it stays a zombie until
/// it is reaped — and `kill(pid, 0)`, which `OpenConnectProcess.isRunning` uses,
/// answers happily for a zombie. An agent that only asked that question would
/// see a dead tunnel as immortal and report `stubborn` over a process that had
/// already exited. So liveness here is `reaped || !isRunning`, and the reap is
/// attempted first.
final class AgentRuntime: TunnelAgentRuntime {
    private let command: String
    private let arguments: [String]
    private let searchPath: String?
    private let reader = BoundedLineReader()
    private var childPid: Int32 = -1

    init(command: String, arguments: [String], searchPath: String? = nil) {
        self.command = command
        self.arguments = arguments
        self.searchPath = searchPath
    }

    // MARK: - Starting

    func startTunnel(credentials: [String]) throws -> Int32 {
        var readEnd: Int32 = -1
        var writeEnd: Int32 = -1
        var pipeEnds: [Int32] = [0, 0]
        guard pipe(&pipeEnds) == 0 else { throw AgentRuntimeError.pipeUnavailable }
        readEnd = pipeEnds[0]
        writeEnd = pipeEnds[1]

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // The credentials arrive on the child's standard input, and the child's
        // read end is closed in the child once it has been duplicated into fd 0.
        posix_spawn_file_actions_adddup2(&fileActions, readEnd, 0)
        posix_spawn_file_actions_addclose(&fileActions, readEnd)
        // The tunnel's output goes to the log stream, never to the channel.
        posix_spawn_file_actions_adddup2(&fileActions, 2, 1)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group: openconnect may spawn helpers (vpn-slice), and a
        // group is what lets one signal reach all of them — while keeping the
        // agent itself out of it, so ending the tunnel never ends the agent.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = ([command] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        var environment: [UnsafeMutablePointer<CChar>?] = childEnvironment()
            .map { strdup("\($0.key)=\($0.value)") }
        environment.append(nil)
        defer { for pointer in environment where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, command, &fileActions, &attributes, &argv, &environment)
        // The parent's copy of the read end goes now: while any write end exists
        // the child would never see the end of its credential block.
        close(readEnd)
        guard result == 0 else {
            close(writeEnd)
            throw AgentRuntimeError.spawnFailed(result)
        }

        // The credential block, then end of input — the same bytes, in the same
        // order, that `printf '%s\n%s\n' … | openconnect` delivered before.
        let payload = Array(credentials.map { $0 + "\n" }.joined().utf8)
        var written = 0
        while written < payload.count {
            let count = payload.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(writeEnd, base + written, payload.count - written)
            }
            guard count > 0 else { break }
            written += count
        }
        close(writeEnd)

        childPid = Int32(pid)
        return Int32(pid)
    }

    /// The environment the tunnel runs in: the agent's own, with `PATH`
    /// replaced when the caller named one.
    ///
    /// The rest is inherited rather than rebuilt. The child is `openconnect`,
    /// which wants a home directory and a locale like any other program, and
    /// dropping everything to set one variable would be a larger change than the
    /// problem it solves. `PATH` is the one variable that is *known* to be wrong
    /// here — see `--path`.
    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let searchPath { environment["PATH"] = searchPath }
        return environment
    }

    // MARK: - Ending

    func endTunnel(pid: Int32) -> TunnelAgentOutcome {
        // Already gone — or not the process we started. Nothing is signalled
        // unless it is still an openconnect: a pid can be reused, and a reused
        // pid must never be signalled on the strength of a stale record.
        if hasGone(pid) { return .stopped }
        guard namesOpenConnect(pid) else { return .stubborn }

        signalGroup(pid, SIGTERM)
        if waitForExit(pid, seconds: TunnelAgent.terminateGraceSeconds) { return .stopped }

        signalGroup(pid, SIGKILL)
        if waitForExit(pid, seconds: TunnelAgent.killSettleSeconds) { return .killed }
        return .stubborn
    }

    /// Signalling the group rather than the process: openconnect's helpers share
    /// it, and the id is one this agent created (`POSIX_SPAWN_SETPGROUP` with
    /// pgroup 0 makes the child its own leader), so it cannot name a group that
    /// belongs to anyone else.
    private func signalGroup(_ pid: Int32, _ signal: Int32) {
        if killpg(pid, signal) != 0 {
            // Falling back to the process alone is safe here: it is the child
            // that was verified above, and it is the member that matters.
            _ = kill(pid, signal)
        }
    }

    private func waitForExit(_ pid: Int32, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if hasGone(pid) { return true }
            Thread.sleep(forTimeInterval: TunnelAgent.pollSeconds)
        }
        return hasGone(pid)
    }

    /// Reaped first — a zombie is not running, and `waitpid` is the only way to
    /// find out that it has stopped.
    private func hasGone(_ pid: Int32) -> Bool {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return true }
        return !OpenConnectProcess.isRunning(pid: pid)
    }

    /// The tunnel is verified by name before any signal, so a pid that has been
    /// reused by an unrelated process is left alone.
    private func namesOpenConnect(_ pid: Int32) -> Bool {
        guard let name = OpenConnectProcess.commandName(pid: pid) else { return false }
        return OpenConnectProcess.namesOpenConnect(name)
    }

    // MARK: - The channel

    func nextLine() -> String? { reader.next() }

    func write(_ word: String) {
        let bytes = Array((word + "\n").utf8)
        var written = 0
        // SIGPIPE is ignored at startup, so a channel the app has already closed
        // shows up here as EPIPE and is dropped. The loop then reads end of input
        // and ends the tunnel, which is what the app's exit means anyway.
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(1, base + written, bytes.count - written)
            }
            guard count > 0 else { return }
            written += count
        }
    }
}

/// Reads newline-delimited lines from standard input, keeping memory bounded no
/// matter what arrives.
///
/// A line is kept only up to `maximumLineBytes + 1` bytes; the rest is discarded
/// as it arrives. That is enough to be refused — a line longer than the limit is
/// by definition longer than the verb — and it means a caller cannot make the
/// agent allocate without limit. The kept prefix is real input, not a marker, so
/// nothing is invented to make the refusal work.
final class BoundedLineReader {
    private let limit = TunnelAgent.maximumLineBytes
    private var completed: [String] = []
    private var current: [UInt8] = []
    private var discarding = false
    private var atEnd = false

    func next() -> String? {
        while true {
            if !completed.isEmpty { return completed.removeFirst() }
            if atEnd {
                guard !current.isEmpty else { return nil }
                let line = String(decoding: current, as: UTF8.self)
                current.removeAll()
                return line
            }
            fill()
        }
    }

    private func fill() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(0, &chunk, chunk.count)
        guard count > 0 else {
            atEnd = true
            return
        }
        for byte in chunk[0..<count] {
            if byte == 0x0A {
                completed.append(String(decoding: current, as: UTF8.self))
                current.removeAll()
                discarding = false
            } else if discarding {
                continue
            } else if current.count > limit {
                discarding = true
            } else {
                current.append(byte)
            }
        }
    }
}

/// Refusals that come from the operating system rather than the protocol.
enum AgentRuntimeError: Error {
    case pipeUnavailable
    case spawnFailed(Int32)
}
