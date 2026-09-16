import Foundation

/// What a TLS handshake says in the clear, before any key is agreed.
public struct TLSClientHelloSummary: Equatable, Sendable {
    /// The SNI `host_name` — the reason this exists at all: a proxy that only
    /// saw `CONNECT 1.2.3.4:443` can report the name the client asked for.
    public var serverName: String?
    /// Advertised ALPN protocols, in the client's order (`h2`, `http/1.1`).
    public var alpn: [String] = []
    /// Highest version the client offered, e.g. "TLS 1.3".
    public var version: String?
}

public enum TLSClientHelloProbe: Equatable {
    /// Not enough bytes yet — the caller should keep the stream prefix coming.
    case incomplete
    /// This is not a TLS handshake; do not buffer any more of it.
    case notTLS
    case parsed(TLSClientHelloSummary)
}

/// A hand-written reader for the TLS ClientHello.
///
/// The first flight of a TLS handshake is plaintext by design (the server has
/// to read the server name before it can pick a certificate), so this needs no
/// certificate, no key and no interception. It is deliberately *only* a reader:
/// malformed input returns `.notTLS` or `.incomplete`, never a crash and never
/// a guess — every field it reports is a field it found.
public enum TLSClientHello {

    /// A ClientHello is routinely 200–1500 bytes; this is the cap that stops a
    /// peer from making the relay buffer forever.
    public static let maxBytes = 16 * 1024

    /// Handshake message types.
    private static let handshakeTypeClientHello: UInt8 = 0x01
    /// Record content type for handshake messages.
    private static let recordTypeHandshake: UInt8 = 0x16

    private static let extensionServerName: UInt16 = 0x0000
    private static let extensionALPN: UInt16 = 0x0010
    private static let extensionSupportedVersions: UInt16 = 0x002b

    // MARK: Entry point

    public static func probe(_ bytes: [UInt8]) -> TLSClientHelloProbe {
        var cursor = Cursor(bytes)
        var handshake: [UInt8] = []

        while true {
            guard let type = cursor.u8() else { return .incomplete }
            if type != recordTypeHandshake { return .notTLS }
            guard cursor.skip(2) else { return .incomplete } // legacy record version
            guard let length = cursor.u16() else { return .incomplete }
            guard let payload = cursor.take(Int(length)) else {
                // The record is declared but not fully here yet.
                return bytes.count >= maxBytes ? .notTLS : .incomplete
            }
            handshake.append(contentsOf: payload)
            // A handshake message may be split across records; only parse once
            // the declared message length is satisfied.
            if handshake.count >= 4 {
                let declared = Int(handshake[1]) << 16 | Int(handshake[2]) << 8 | Int(handshake[3])
                if handshake[0] != handshakeTypeClientHello { return .notTLS }
                if handshake.count >= 4 + declared {
                    return .parsed(parseBody(Array(handshake[4..<(4 + declared)])))
                }
            }
            if cursor.remaining == 0 {
                return bytes.count >= maxBytes ? .notTLS : .incomplete
            }
        }
    }

    // MARK: Body

    private static func parseBody(_ body: [UInt8]) -> TLSClientHelloSummary {
        var summary = TLSClientHelloSummary()
        var cursor = Cursor(body)

        // legacy_version, random
        guard let legacyVersion = cursor.u16(), cursor.skip(32) else { return summary }
        summary.version = versionName(legacyVersion)

        // session_id
        guard let sessionIDLength = cursor.u8(), cursor.skip(Int(sessionIDLength)) else { return summary }
        // cipher_suites
        guard let cipherLength = cursor.u16(), cursor.skip(Int(cipherLength)) else { return summary }
        // compression_methods
        guard let compressionLength = cursor.u8(), cursor.skip(Int(compressionLength)) else { return summary }
        // extensions
        guard cursor.remaining >= 2 else { return summary }
        guard let extensionsLength = cursor.u16(),
              let extensions = cursor.take(Int(extensionsLength)) else { return summary }

        var extensionCursor = Cursor(extensions)
        while let type = extensionCursor.u16() {
            guard let length = extensionCursor.u16(),
                  let data = extensionCursor.take(Int(length)) else { break }
            switch type {
            case extensionServerName:
                summary.serverName = serverName(in: data)
            case extensionALPN:
                summary.alpn = alpn(in: data)
            case extensionSupportedVersions:
                if let highest = highestVersion(in: data) {
                    summary.version = highest
                }
            default:
                break
            }
        }
        return summary
    }

    /// `server_name` extension: a list of (type, name); type 0 is `host_name`.
    private static func serverName(in data: [UInt8]) -> String? {
        var cursor = Cursor(data)
        guard let listLength = cursor.u16() else { return nil }
        var list = Cursor(cursor.take(min(Int(listLength), cursor.remaining)) ?? [])
        while let type = list.u8() {
            guard let length = list.u16(), let name = list.take(Int(length)) else { return nil }
            if type == 0 {
                let text = String(decoding: name, as: UTF8.self)
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    /// `application_layer_protocol_negotiation`: a list of length-prefixed names.
    private static func alpn(in data: [UInt8]) -> [String] {
        var cursor = Cursor(data)
        guard let listLength = cursor.u16(),
              let list = cursor.take(min(Int(listLength), cursor.remaining)) else { return [] }
        var out: [String] = []
        var listCursor = Cursor(list)
        while let length = listCursor.u8() {
            guard let name = listCursor.take(Int(length)) else { break }
            let text = String(decoding: name, as: UTF8.self)
            if !text.isEmpty { out.append(text) }
        }
        return out
    }

    /// `supported_versions`: what actually decides the version in TLS 1.3.
    private static func highestVersion(in data: [UInt8]) -> String? {
        var cursor = Cursor(data)
        guard let listLength = cursor.u8(),
              let list = cursor.take(min(Int(listLength), cursor.remaining)) else { return nil }
        var listCursor = Cursor(list)
        var highest: UInt16?
        while let version = listCursor.u16() {
            guard !isGREASE(version) else { continue }
            if highest == nil || version > highest! { highest = version }
        }
        return highest.map(versionName)
    }

    /// GREASE values (`0x0a0a`, `0x1a1a`, …) are deliberately unassigned
    /// placeholders; reporting one as a version would be a lie.
    private static func isGREASE(_ version: UInt16) -> Bool {
        let high = UInt8(version >> 8)
        let low = UInt8(version & 0xff)
        return high == low && (low & 0x0f) == 0x0a
    }

    static func versionName(_ version: UInt16) -> String {
        switch version {
        case 0x0304: return "TLS 1.3"
        case 0x0303: return "TLS 1.2"
        case 0x0302: return "TLS 1.1"
        case 0x0301: return "TLS 1.0"
        case 0x0300: return "SSL 3.0"
        default: return String(format: "0x%04X", version)
        }
    }

    // MARK: Cursor

    /// Bounds-checked reader. Every out-of-range read is `nil`, which the
    /// parser treats as "this capture is over" — no index arithmetic can trap.
    private struct Cursor {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var remaining: Int { bytes.count - index }

        mutating func u8() -> UInt8? {
            guard index < bytes.count else { return nil }
            defer { index += 1 }
            return bytes[index]
        }

        mutating func u16() -> UInt16? {
            guard index + 2 <= bytes.count else { return nil }
            defer { index += 2 }
            return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        }

        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, index + count <= bytes.count else { return nil }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }

        mutating func skip(_ count: Int) -> Bool {
            take(count) != nil
        }
    }
}
