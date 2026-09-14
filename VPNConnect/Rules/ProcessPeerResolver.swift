import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Peer Resolver Protocol

/// Resolves the local peer behind an accepted listener socket to an
/// executable name for PROCESS-NAME rules. Best-effort by design: some
/// lookups will fail (permission, kernel state, non-socket descriptors), and
/// callers must treat nil as "cannot determine".
public protocol ProcessPeerResolving: AnyObject, Sendable {
    func executableName(forSocket fd: Int32) -> String?
}

// MARK: - Darwin Implementation

/// libproc-based peer resolution:
/// 1. `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` reads the remote address actually
///    stored in the peer's socket — no DNS involved.
/// 2. `proc_listallpids` + `proc_pidfdinfo` finds which process owns the
///    connection whose foreign address equals that peer endpoint.
/// 3. `proc_pidpath` yields the executable path.
///
/// All three calls may fail or return stale data; every failure path returns
/// nil. This is inherently best-effort — the kernel does not guarantee the
/// remote socket stays connected between step 1 and step 2.
public final class ProcessPeerResolver: ProcessPeerResolving {
    public init() {}

    public func executableName(forSocket fd: Int32) -> String? {
        guard let peer = peerEndpoint(fd: fd) else { return nil }
        guard let owner = ownerOfConnection(peer: peer) else { return nil }
        return executablePath(pid: owner)
    }

    // MARK: Step 1 — read our socket's peer endpoint

    private func peerEndpoint(fd: Int32) -> PeerEndpoint? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let size = proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &buffer, Int32(buffer.count))
        guard size >= MemoryLayout<socket_fdinfo>.size else { return nil }

        let info = buffer.withUnsafeBytes { raw -> socket_fdinfo in
            raw.load(as: socket_fdinfo.self)
        }
        guard Int32(info.psi.soi_family) == AF_INET || Int32(info.psi.soi_family) == AF_INET6 else {
            return nil
        }

        // The connection may be represented as a TCP entry (pri_tcp) or an
        // IN entry (pri_in); both start with the same in_sockinfo layout, so
        // reading via pri_in is valid for either. Cross-check the family via
        // soi_family and the vflag for the address bytes.
        let socketInfo = info.psi
        let vflag = Int32(socketInfo.soi_proto.pri_in.insi_vflag)
        let isIPv4 = vflag & INI_IPV4 != 0
        let isIPv6 = vflag & INI_IPV6 != 0
        guard isIPv4 || isIPv6 else { return nil }

        let foreignPortBE = UInt16(UInt16(bitPattern: Int16(socketInfo.soi_proto.pri_in.insi_fport)))
        let port = Int(CFSwapInt16(foreignPortBE))
        guard port != 0 else { return nil }

        var rawAddress: [UInt8]
        if isIPv4 {
            rawAddress = withUnsafeBytes(of: socketInfo.soi_proto.pri_in.insi_faddr.ina_46.i46a_addr4) {
                Array($0.prefix(4))
            }
        } else {
            rawAddress = withUnsafeBytes(of: socketInfo.soi_proto.pri_in.insi_faddr.ina_6) {
                Array($0.prefix(16))
            }
        }
        return PeerEndpoint(bytes: rawAddress, port: port)
    }

    // MARK: Step 2 — find the process owning a connection to that endpoint

    private func ownerOfConnection(peer: PeerEndpoint) -> pid_t? {
        let expected = peer.key
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let actual = pids.withUnsafeMutableBufferPointer { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard actual > 0 else { return nil }

        for pid in pids.prefix(Int(actual)) where pid != getpid() {
            guard let endpoints = socketEndpoints(pid: pid) else { continue }
            if endpoints.contains(expected) {
                return pid
            }
        }
        return nil
    }

    /// Collects the foreign endpoints of every TCP socket owned by `pid`.
    private func socketEndpoints(pid: pid_t) -> Set<String>? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var endpoints: Set<String> = []
        var sawAny = false
        // PIDs vanish between listing and probing; proc_pidfdinfo returning 0
        // for fd 0 distinguishes "gone" from "has fds".
        let probe = proc_pidfdinfo(pid, 0, PROC_PIDFDSOCKETINFO, &buffer, Int32(buffer.count))
        _ = probe // fd 0 may legitimately not be a socket; only used as a cheap validity probe

        for fd in Int32(0)...Int32(63) {
            let size = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &buffer, Int32(buffer.count))
            guard size >= MemoryLayout<socket_fdinfo>.size else { continue }
            let info = buffer.withUnsafeBytes { raw -> socket_fdinfo in
                raw.load(as: socket_fdinfo.self)
            }
            guard Int32(info.psi.soi_family) == AF_INET || Int32(info.psi.soi_family) == AF_INET6 else { continue }
            guard Int32(info.psi.soi_type) == SOCK_STREAM else { continue }

            let s = info.psi
            let vflag = Int32(s.soi_proto.pri_in.insi_vflag)
            let isIPv4 = vflag & INI_IPV4 != 0
            let isIPv6 = vflag & INI_IPV6 != 0
            guard isIPv4 || isIPv6 else { continue }

            let fportBE = UInt16(UInt16(bitPattern: Int16(s.soi_proto.pri_in.insi_fport)))
            let port = Int(CFSwapInt16(fportBE))
            guard port != 0 else { continue } // 0 = unconnected/listening

            let bytes: [UInt8]
            if isIPv4 {
                bytes = withUnsafeBytes(of: s.soi_proto.pri_in.insi_faddr.ina_46.i46a_addr4) {
                    Array($0.prefix(4))
                }
            } else {
                bytes = withUnsafeBytes(of: s.soi_proto.pri_in.insi_faddr.ina_6) {
                    Array($0.prefix(16))
                }
            }
            sawAny = true
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            endpoints.insert("\(hex):\(port)")
        }
        return sawAny ? endpoints : nil
    }

    // MARK: Step 3 — executable path

    private func executablePath(pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else { return nil }
        return String(cString: pathBuffer)
    }
}

// MARK: - Endpoint Key

private struct PeerEndpoint {
    let bytes: [UInt8]
    let port: Int

    /// Canonical string key used to match foreign endpoints across processes.
    /// IPv4 endpoints get a 4-byte key; IPv6 a 16-byte key; an IPv4-mapped
    /// IPv6 address normalizes to the 4-byte form so both sides agree.
    var key: String {
        let effectiveBytes: [UInt8]
        if bytes.count == 16, let v4 = IPAddress.unwrapIPv4Mapped(bytes) {
            effectiveBytes = v4
        } else if bytes.count == 16 {
            // Normalize IPv6 presentation for matching (bytes already canonical).
            effectiveBytes = bytes
        } else {
            effectiveBytes = bytes
        }
        let hex = effectiveBytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex):\(port)"
    }
}

// MARK: - Caching Wrapper

/// Caches fd→executable-name lookups briefly. The key is the fd, which is
/// safe only because the TTL is shorter than a typical connection and the
/// value is best-effort anyway; a stale hit after fd reuse can at worst name
/// the previous owner of that socket for a few seconds.
public final class CachedProcessPeerResolver: ProcessPeerResolving, @unchecked Sendable {
    private let underlying: ProcessPeerResolving
    private let ttl: TimeInterval
    private let maxEntries: Int

    private let lock = NSLock()
    private var cache: [Int32: (name: String?, expiresAt: Date)] = [:]

    public init(underlying: ProcessPeerResolving = ProcessPeerResolver(), ttl: TimeInterval = 5, maxEntries: Int = 256) {
        self.underlying = underlying
        self.ttl = ttl
        self.maxEntries = max(16, maxEntries)
    }

    public func executableName(forSocket fd: Int32) -> String? {
        let now = Date()
        lock.lock()
        if let hit = cache[fd], hit.expiresAt > now {
            lock.unlock()
            return hit.name
        }
        lock.unlock()

        let name = underlying.executableName(forSocket: fd)
        lock.lock()
        if cache.count >= maxEntries {
            cache = cache.filter { $0.value.expiresAt > now }
        }
        if cache.count >= maxEntries {
            cache.removeAll()
        }
        cache[fd] = (name, now.addingTimeInterval(ttl))
        lock.unlock()
        return name
    }
}
