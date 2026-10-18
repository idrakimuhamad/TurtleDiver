import Foundation
import Darwin

// The app target compiles this file into one module; the SPM target
// `TurtleDiverSystem` compiles it standalone, so the only requirements are
// Foundation and the POSIX network headers.
//
// "Share with a device" needs the machine's LAN IPv4 address: the phone on the
// same Wi-Fi points its manual HTTP proxy at `<Mac LAN IPv4>:<http port>`. That
// address must be the one on an interface the phone can reach — the machine's
// Wi-Fi or wired Ethernet, not a tunnel, not loopback.

/// Finds the machine's primary LAN IPv4 address.
///
/// The selection is split in two on purpose: `liveInterfaces()` is the only part
/// that touches `getifaddrs`, and every decision is a pure function over plain
/// values, so the *policy* is testable without a real network.
public enum LANAddress {

    /// One interface as `getifaddrs` reports it, reduced to the fields the
    /// selection needs. `Equatable` so tests can build fake inputs.
    public struct Interface: Equatable, Sendable {
        public let name: String
        public let address: String
        public let isUp: Bool
        public let isLoopback: Bool

        public init(name: String, address: String, isUp: Bool, isLoopback: Bool) {
            self.name = name
            self.address = address
            self.isUp = isUp
            self.isLoopback = isLoopback
        }
    }

    /// What an interface is, narrowed to the kinds that matter here.
    public enum InterfaceKind: Equatable, Sendable {
        case wifi
        case wiredEthernet
        /// Anything a phone on the same network cannot reach: a tunnel, a
        /// cellular link, loopback.
        case other
    }

    /// One entry of the system's ordered interface list
    /// (`NWPath.availableInterfaces`), reduced to name and kind.
    public struct PathInterface: Equatable, Sendable {
        public let name: String
        public let kind: InterfaceKind

        public init(name: String, kind: InterfaceKind) {
            self.name = name
            self.kind = kind
        }
    }

    /// Interface-name prefixes that never carry the address a phone should be
    /// pointed at: VPN tunnels, IPsec, PPP, loopback, and the peer-to-peer
    /// Wi-Fi (AirDrop/AWDL) and low-latency WLAN (llw) links.
    private static let excludedPrefixes = ["utun", "ipsec", "ppp", "lo", "awdl", "llw"]

    // MARK: - Selection

    /// The names worth sharing over, in the order the system prefers them.
    ///
    /// Wi-Fi and wired Ethernet only: those are the links a device on the same
    /// network can reach, and `NWPath.availableInterfaces` already orders them
    /// by the system's own preference (the one carrying the default route
    /// first).
    ///
    /// - Parameter pathInterfaces: the path's interfaces, in the order
    ///   `NWPathMonitor` reported them.
    public static func preferredNames(from pathInterfaces: [PathInterface]) -> [String] {
        pathInterfaces
            .filter { $0.kind == .wifi || $0.kind == .wiredEthernet }
            .map(\.name)
    }

    /// Picks the address to hand a phone.
    ///
    /// The first preferred name that has a usable IPv4 address wins: it is the
    /// interface the machine would actually route through, which is the one the
    /// phone can reach. When none of them is usable — an interface is up but has
    /// no address yet, or the path list is still empty before the monitor's
    /// first update — `primaryLANIPv4(from:)` decides.
    ///
    /// - Parameters:
    ///   - preferredNames: ordered interface names from ``preferredNames(from:)``.
    ///   - interfaces: what `getifaddrs` reported.
    public static func primaryLANIPv4(preferredNames: [String], from interfaces: [Interface]) -> String? {
        for name in preferredNames {
            if let match = interfaces.first(where: { $0.name == name && isUsable($0) }) {
                return match.address
            }
        }
        return primaryLANIPv4(from: interfaces)
    }

    /// The fallback heuristic, used when the network path names no interface.
    ///
    /// Eligible interfaces are up, non-loopback IPv4 interfaces named `en*` or
    /// `bridge*`, without a link-local (`169.254.0.0/16`) address. Among them
    /// `en*` wins over `bridge*`, and within a group the lowest name wins —
    /// which lands on `en0`, the built-in interface the default route almost
    /// always uses, on a typical Mac.
    public static func primaryLANIPv4(from interfaces: [Interface]) -> String? {
        interfaces
            .filter(isEligible)
            .min { lhs, rhs in
                let left = rank(lhs.name), right = rank(rhs.name)
                if left != right { return left < right }
                return lhs.name < rhs.name
            }?
            .address
    }

    // MARK: - Live enumeration

    /// Reads the live interface list and selects by the system's own preference.
    ///
    /// - Parameter preferredNames: ordered interface names from
    ///   ``preferredNames(from:)`` — the caller's `NWPathMonitor` knows them.
    public static func primaryLANIPv4(preferredNames: [String]) -> String? {
        primaryLANIPv4(preferredNames: preferredNames, from: liveInterfaces())
    }

    /// Reads the live interface list and applies the fallback heuristic.
    public static func primaryLANIPv4() -> String? {
        primaryLANIPv4(from: liveInterfaces())
    }

    /// Every IPv4 interface `getifaddrs` reports, as ``Interface`` values.
    static func liveInterfaces() -> [Interface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [Interface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            let ifa = node.pointee
            cursor = ifa.ifa_next

            guard let sockaddr = ifa.ifa_addr,
                  sockaddr.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let flags = Int32(bitPattern: ifa.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin -> String in
                var raw = sin.pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
                return String(cString: buffer)
            }
            guard !address.isEmpty else { continue }

            result.append(Interface(
                name: String(cString: ifa.ifa_name),
                address: address,
                isUp: isUp,
                isLoopback: isLoopback
            ))
        }
        return result
    }

    // MARK: - Policy

    /// An address a phone could be pointed at: IPv4 (the list is already
    /// filtered to that), up, not loopback, and not self-assigned.
    ///
    /// `169.254.0.0/16` is the "no DHCP" address; advertising it would send the
    /// phone somewhere nothing answers.
    private static func isUsable(_ interface: Interface) -> Bool {
        guard interface.isUp, !interface.isLoopback else { return false }
        return !interface.address.hasPrefix("169.254.")
    }

    /// Whether the fallback heuristic may consider an interface at all.
    private static func isEligible(_ interface: Interface) -> Bool {
        guard isUsable(interface) else { return false }
        guard interface.name.hasPrefix("en") || interface.name.hasPrefix("bridge") else { return false }
        guard !excludedPrefixes.contains(where: { interface.name.hasPrefix($0) }) else { return false }
        return true
    }

    /// Lower is better: the built-in `en*` interfaces first, bridges next.
    private static func rank(_ name: String) -> Int {
        if name.hasPrefix("en") { return 0 }
        if name.hasPrefix("bridge") { return 1 }
        return 2
    }
}
