import Foundation
import TurtleDiverSystem

/// Whether a tunnel is up, and what named it.
///
/// The decision is `ExistingConnectionScanner`'s, not a fresh guess: the same
/// code the app uses to adopt a tunnel it did not start, so the CLI and the app
/// cannot disagree about whether the VPN is up. The file being non-empty is not
/// enough — it has held the pid of a process that was not an openconnect.
public struct TunnelStatus: Equatable {
    /// The verified openconnect, or nil.
    public let pid: Int32?
    /// `.pidFile`, `.ownProcessGroup`, or `.scanned`.
    public let source: String?
    /// What the pid file said, before verification. Kept separate so a stale
    /// record can be reported as stale rather than as "nothing there".
    public let pidFilePid: Int32?
    public let pidFilePath: String
    /// Pids that were considered and refused, with the reason.
    public let rejections: [String]

    public init(
        pid: Int32?,
        source: String?,
        pidFilePid: Int32?,
        pidFilePath: String,
        rejections: [String]
    ) {
        self.pid = pid
        self.source = source
        self.pidFilePid = pidFilePid
        self.pidFilePath = pidFilePath
        self.rejections = rejections
    }

    public var connected: Bool { pid != nil }

    public static func read(pidFile: URL = OpenConnectPidFile.path) -> TunnelStatus {
        let recorded = OpenConnectPidFile.recordedPid(at: pidFile)
        let detection = ExistingConnectionScanner.detect(pidFilePid: recorded)
        return TunnelStatus(
            pid: detection.pid,
            source: detection.source?.rawValue,
            pidFilePid: recorded,
            pidFilePath: pidFile.path,
            rejections: detection.rejections.map { "\($0.pid): \($0.reason.rawValue)" }
        )
    }

    /// The body `--json` prints. One shape for `status`, `connect`, and
    /// `disconnect`, so a caller parses the tunnel state the same way whichever
    /// command produced it.
    public var jsonObject: [String: Any] {
        var body: [String: Any] = [
            "ok": true,
            "connected": connected,
        ]
        if let pid { body["pid"] = Int(pid) }
        if let source { body["source"] = source }
        if let pidFilePid { body["pidFilePid"] = Int(pidFilePid) }
        body["pidFile"] = pidFilePath
        if !rejections.isEmpty { body["rejections"] = rejections }
        return body
    }

    /// The sentence a person gets. Says *why* it believes there is no tunnel
    /// when a pid file exists, because "not connected" over a file that says
    /// otherwise is the answer people file bugs about.
    public var humanLines: [String] {
        guard let pid else {
            if let recorded = pidFilePid {
                return [
                    "not connected.",
                    "note: \(pidFilePath) records pid \(recorded), which is not a live openconnect."
                        + " It is a stale record, not a tunnel.",
                ]
            }
            return ["not connected."]
        }
        var lines = ["connected: openconnect pid \(pid)"]
        if let source { lines.append("  found via: \(source)") }
        for rejection in rejections {
            lines.append("  ignored: \(rejection)")
        }
        return lines
    }
}
