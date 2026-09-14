import Foundation

// MARK: - IP Address

/// A parsed IPv4 or IPv6 address value (16-byte representation for both, so
/// comparisons and CIDR containment are uniform).
public struct IPAddress: Equatable, Hashable, Sendable {
    /// Network byte order bytes: 4 for IPv4, 16 for IPv6.
    public let bytes: [UInt8]

    /// True when this is an IPv4 address (or an IPv4-mapped IPv6 address,
    /// which is normalized to IPv4 at parse time).
    public var isIPv4: Bool { bytes.count == 4 }

    /// Builds from network byte order bytes (4 for IPv4, 16 for IPv6).
    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    /// Parses a textual IPv4 address (`a.b.c.d`). Strict: no shorthand,
    /// no octal, no leading zeros, all four octets required.
    public static func parseIPv4(_ text: String) -> IPAddress? {
        let octets = text.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for octet in octets {
            // Digits only (rejects "+1", "-1", "0x10", " 1", "1 ", "").
            guard !octet.isEmpty, octet.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            guard octet.count <= 3, octet.first != "0" || octet.count == 1 else { return nil }
            guard let value = UInt8(octet) else { return nil }
            bytes.append(value)
        }
        return IPAddress(bytes: bytes)
    }

    /// Parses a textual IPv6 address (RFC 4291 forms: full, `::`-compressed,
    /// and trailing IPv4-mapped). IPv4-mapped addresses are normalized to
    /// their IPv4 form so `::ffff:10.0.0.1` matches `IP-CIDR,10.0.0.0/8`.
    public static func parseIPv6(_ text: String) -> IPAddress? {
        var input = Substring(text)

        // Strip a zone identifier (fe80::1%en0).
        if let percent = input.firstIndex(of: "%") {
            input = input[..<percent]
        }

        // Rewrite an embedded IPv4 tail (`::ffff:1.2.3.4`) as two hextets so
        // the rest of the parser deals with pure hex-group syntax.
        if let lastColon = input.lastIndex(of: ":") {
            let tail = input[input.index(after: lastColon)...]
            if tail.contains(".") {
                guard let v4 = parseIPv4(String(tail)) else { return nil }
                let b = v4.bytes
                let hextets = String((UInt16(b[0]) << 8) | UInt16(b[1]), radix: 16)
                    + ":" + String((UInt16(b[2]) << 8) | UInt16(b[3]), radix: 16)
                input = input[..<lastColon] + ":" + hextets
            }
        }

        // Split on the compression marker (at most one `::` allowed).
        let halves = input.split(separator: "::", omittingEmptySubsequences: false)
        switch halves.count {
        case 1:
            // No `::` compression: explicit groups must fill all 16 bytes.
            guard let bytes = expandGroups(halves[0]), bytes.count == 16 else { return nil }
            return Self.normalizingIPv4Mapped(bytes)
        case 2:
            guard let left = expandGroups(halves[0]), let right = expandGroups(halves[1]) else { return nil }
            // `::` stands for at least one group of zeros (RFC 4291 §2.2).
            let pad = 16 - (left.count + right.count)
            guard pad >= 2, pad % 2 == 0 else { return nil }
            return Self.normalizingIPv4Mapped(left + [UInt8](repeating: 0, count: pad) + right)
        default:
            return nil // more than one `::`
        }
    }

    /// Builds an address from 16 bytes, collapsing IPv4-mapped IPv6
    /// (::ffff:a.b.c.d) to its 4-byte IPv4 form.
    private static func normalizingIPv4Mapped(_ bytes: [UInt8]) -> IPAddress? {
        if let v4 = unwrapIPv4Mapped(bytes) {
            return IPAddress(bytes: v4)
        }
        return IPAddress(bytes: bytes)
    }

    /// Expands `:`-separated hextet groups to [UInt8] pairs. Returns nil on
    /// malformed groups (empty, >4 hex digits, bad characters).
    private static func expandGroups(_ text: Substring) -> [UInt8]? {
        if text.isEmpty { return [] }
        var bytes: [UInt8] = []
        for group in text.split(separator: ":", omittingEmptySubsequences: false) {
            guard !group.isEmpty, group.count <= 4,
                  group.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
            guard let value = UInt16(group, radix: 16) else { return nil }
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        }
        return bytes
    }


    /// Parses either IPv4 or IPv6 text.
    public static func parse(_ text: String) -> IPAddress? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.contains(":") {
            return parseIPv6(trimmed)
        }
        return parseIPv4(trimmed)
    }

    /// Presentation form (dotted quad / standard IPv6 text).
    public var text: String {
        if isIPv4 {
            return bytes.map { String($0) }.joined(separator: ".")
        }
        // inet_ntop gives canonical compressed form (e.g. ::1).
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { dst in
            dst.copyBytes(from: bytes)
        }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var addrCopy = addr
        let result = inet_ntop(AF_INET6, &addrCopy, &buffer, socklen_t(INET6_ADDRSTRLEN))
        guard result != nil else {
            return bytes.map { String($0, radix: 16) }.joined(separator: ":")
        }
        return String(cString: buffer)
    }

    /// Convert an IPv6 byte array holding an IPv4-mapped address to 4 bytes.
    static func unwrapIPv4Mapped(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 16 else { return nil }
        let prefix: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF]
        guard Array(bytes[0..<12]) == prefix else { return nil }
        return Array(bytes[12..<16])
    }
}

// MARK: - CIDR

/// An IP CIDR block (`a.b.c.d/prefix` or `x::/prefix`). Matching uses prefix
/// comparison on the uniform 16-byte representation, so the same code handles
/// IPv4 and IPv6 (IPv4 prefixes are offset by 96 bits).
public struct CIDRBlock: Equatable, Sendable {
    public let address: IPAddress
    /// Prefix length in bits (0–32 for IPv4, 0–128 for IPv6).
    public let prefixLength: Int

    public init?(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let slash = trimmed.firstIndex(of: "/") else { return nil }
        let addrText = String(trimmed[..<slash])
        let prefixText = trimmed[trimmed.index(after: slash)...]
        guard let addr = IPAddress.parse(addrText) else { return nil }
        guard prefixText.allSatisfy({ $0.isASCII && $0.isNumber }), !prefixText.isEmpty,
              let prefix = Int(prefixText) else { return nil }
        let maxPrefix = addr.isIPv4 ? 32 : 128
        guard (0...maxPrefix).contains(prefix) else { return nil }
        self.address = addr
        self.prefixLength = prefix
    }

    public init(address: IPAddress, prefixLength: Int) {
        let maxPrefix = address.isIPv4 ? 32 : 128
        self.address = address
        self.prefixLength = min(max(prefixLength, 0), maxPrefix)
    }

    public var text: String { "\(address.text)/\(prefixLength)" }

    /// Whether `ip` falls inside this block. IPv4-mapped IPv6 inputs are
    /// normalized to IPv4 so they can match IPv4 blocks.
    public func contains(_ ip: IPAddress) -> Bool {
        if address.isIPv4 != ip.isIPv4 {
            // ::ffff:a.b.c.d → a.b.c.d
            if !ip.isIPv4, let v4 = IPAddress.unwrapIPv4Mapped(ip.bytes) {
                return contains(IPAddress(bytes: v4)!)
            }
            if !address.isIPv4, let v4 = IPAddress.unwrapIPv4Mapped(address.bytes) {
                return CIDRBlock(address: IPAddress(bytes: v4)!, prefixLength: prefixLength).contains(ip)
            }
            return false
        }

        let bitCount = ip.bytes.count * 8
        let prefix = min(prefixLength, bitCount)
        // Compare whole bytes, then the partial-bit remainder.
        let fullBytes = prefix / 8
        let remainderBits = prefix % 8
        for i in 0..<fullBytes where address.bytes[i] != ip.bytes[i] {
            return false
        }
        if remainderBits > 0 {
            let mask = UInt8(0xFF) << (8 - remainderBits)
            if address.bytes[fullBytes] & mask != ip.bytes[fullBytes] & mask {
                return false
            }
        }
        return true
    }

    /// Whether `other` is fully contained in this block (used by tests and
    /// potential future overlap warnings).
    public func contains(_ other: CIDRBlock) -> Bool {
        prefixLength <= other.prefixLength && contains(other.address)
    }

    // MARK: Tests-only surface

    /// For unit tests: whether the bit at `index` (0 = most significant of
    /// the first byte) is set.
    static func bit(at index: Int, in bytes: [UInt8]) -> Bool {
        guard index >= 0, index < bytes.count * 8 else { return false }
        let byte = bytes[index / 8]
        let shift = 7 - (index % 8)
        return (byte >> shift) & 1 == 1
    }
}

// MARK: - Parsing helpers shared with the matcher

extension IPAddress {
    /// Parses a rule value that may be a bare IP or a CIDR block.
    public static func parseAddressOrBlock(_ text: String) -> (ip: IPAddress, prefix: Int)? {
        if let cidr = CIDRBlock(text: text) {
            return (cidr.address, cidr.prefixLength)
        }
        if let ip = IPAddress.parse(text) {
            return (ip, ip.isIPv4 ? 32 : 128)
        }
        return nil
    }
}
