import Foundation

/// Watches the first bytes of a relay's legs so a decision can be made about
/// them — a TLS ClientHello, an HTTP response head — **without ever changing
/// the bytes that are forwarded**.
///
/// The relay forwards unconditionally; this only *sees* data. That is the whole
/// safety argument: a probe that is wrong (or hostile) can produce a missing
/// detail row, never a corrupted stream.
///
/// Confined to the relay's serial queue (it is only ever called from
/// `RelayConnection.read`), which is what makes the unchecked `Sendable`
/// conformance sound.
public final class RelayStreamObserver: @unchecked Sendable {

    public enum Direction {
        case toDestination
        case toClient
    }

    /// Bytes kept per leg. Stops a peer that keeps sending from making the
    /// relay buffer without bound once a probe can no longer be satisfied.
    public static let limit = max(TLSClientHello.maxBytes, HTTPResponseHead.limit)

    /// Called with the accumulated prefix of the client→destination leg
    /// (tunnel data: a ClientHello, most often). Return `true` once satisfied.
    public var onClientPrefix: (([UInt8]) -> Bool)?
    /// Called with the accumulated prefix of the destination→client leg
    /// (an HTTP response head, for plain-HTTP requests).
    public var onServerPrefix: (([UInt8]) -> Bool)?

    private var clientPrefix: [UInt8] = []
    private var serverPrefix: [UInt8] = []
    private var clientDone = false
    private var serverDone = false

    /// The address the outbound leg actually reached, when the relay learned
    /// it (set once, from the relay queue, before any byte is read). For a
    /// tunnel this is the honest answer to "which server did that name mean?".
    public private(set) var peerAddress: String?

    public init() {}

    /// Called from the relay queue during setup only.
    func setPeerAddress(_ address: String?) {
        peerAddress = address
    }

    /// Whether anything is wanted in that direction — lets a caller avoid
    /// installing an observer that would buffer for nothing.
    public var wantsClientPrefix: Bool { onClientPrefix != nil && !clientDone }
    public var wantsServerPrefix: Bool { onServerPrefix != nil && !serverDone }

    func observe(chunk: [UInt8], direction: Direction) {
        switch direction {
        case .toDestination:
            guard !clientDone, let handler = onClientPrefix else { return }
            append(chunk, into: &clientPrefix)
            if clientPrefix.count >= Self.limit {
                clientDone = true // cap reached: stop buffering, keep forwarding
                return
            }
            if handler(clientPrefix) { clientDone = true }
        case .toClient:
            guard !serverDone, let handler = onServerPrefix else { return }
            append(chunk, into: &serverPrefix)
            if serverPrefix.count >= Self.limit {
                serverDone = true
                return
            }
            if handler(serverPrefix) { serverDone = true }
        }
    }

    /// Keeps at most `limit` bytes: a probe that never resolves must not grow
    /// the buffer, and the tail of a head/hello is never needed anyway.
    private func append(_ chunk: [UInt8], into buffer: inout [UInt8]) {
        let room = Self.limit - buffer.count
        guard room > 0 else { return }
        buffer.append(contentsOf: chunk.prefix(room))
    }
}
