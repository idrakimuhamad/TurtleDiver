import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverEngine

// MARK: - ClientHello builder

/// Builds a real ClientHello for the parser tests: the shape a browser sends,
/// assembled by hand so the tests do not depend on a captured binary blob.
///
/// - Parameters:
///   - serverName: `nil` omits the extension entirely (what a client does when
///     it is already connecting to an IP address).
///   - versions: offered versions, in the client's order; GREASE may be included.
///   - splitAt: when set, the handshake message is cut into two TLS records at
///     that byte offset — the split that a real ClientHello with a large
///     extension list produces.
func makeClientHello(
    serverName: String?,
    alpn: [String] = [],
    versions: [UInt16] = [0x0304, 0x0303],
    cipherSuites: [UInt8] = [0x13, 0x01],
    extraExtensions: [(type: UInt16, data: [UInt8])] = [],
    splitAt: Int? = nil
) -> [UInt8] {
    var extensions: [UInt8] = []

    func appendExtension(_ type: UInt16, _ data: [UInt8]) {
        extensions.append(UInt8(type >> 8))
        extensions.append(UInt8(type & 0xff))
        extensions.append(UInt8(data.count >> 8))
        extensions.append(UInt8(data.count & 0xff))
        extensions.append(contentsOf: data)
    }

    if let serverName {
        let name = Array(serverName.utf8)
        // server_name_list length (2 bytes) = type + name length + name.
        var data: [UInt8] = [UInt8((name.count + 3) >> 8), UInt8((name.count + 3) & 0xff)]
        data.append(0x00) // host_name
        data.append(UInt8(name.count >> 8))
        data.append(UInt8(name.count & 0xff))
        data.append(contentsOf: name)
        appendExtension(0x0000, data)
    }
    if !alpn.isEmpty {
        var list: [UInt8] = []
        for proto in alpn {
            let bytes = Array(proto.utf8)
            list.append(UInt8(bytes.count))
            list.append(contentsOf: bytes)
        }
        appendExtension(0x0010, [UInt8(list.count >> 8), UInt8(list.count & 0xff)] + list)
    }
    if !versions.isEmpty {
        var list: [UInt8] = []
        for version in versions {
            list.append(UInt8(version >> 8))
            list.append(UInt8(version & 0xff))
        }
        appendExtension(0x002b, [UInt8(list.count)] + list)
    }
    for extra in extraExtensions {
        appendExtension(extra.type, extra.data)
    }

    var body: [UInt8] = [0x03, 0x03] // legacy_version (TLS 1.2)
    body.append(contentsOf: [UInt8](repeating: 0xAB, count: 32)) // random
    body.append(0x00) // session_id length
    body.append(UInt8(cipherSuites.count >> 8))
    body.append(UInt8(cipherSuites.count & 0xff))
    body.append(contentsOf: cipherSuites)
    body.append(0x01) // compression methods length
    body.append(0x00) // null
    body.append(UInt8(extensions.count >> 8))
    body.append(UInt8(extensions.count & 0xff))
    body.append(contentsOf: extensions)

    var handshake: [UInt8] = [0x01]
    handshake.append(UInt8((body.count >> 16) & 0xff))
    handshake.append(UInt8((body.count >> 8) & 0xff))
    handshake.append(UInt8(body.count & 0xff))
    handshake.append(contentsOf: body)

    func record(_ payload: ArraySlice<UInt8>) -> [UInt8] {
        let bytes = Array(payload)
        return [0x16, 0x03, 0x01, UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)] + bytes
    }

    if let splitAt, splitAt > 0, splitAt < handshake.count {
        return record(handshake[..<splitAt]) + record(handshake[splitAt...])
    }
    return record(handshake[...])
}

// MARK: - Tests

final class TLSClientHelloTests: XCTestCase {

    func testParsesServerNameALPNAndHighestVersion() {
        let bytes = makeClientHello(
            serverName: "login.example.com",
            alpn: ["h2", "http/1.1"],
            versions: [0x0304, 0x0303]
        )

        guard case .parsed(let summary) = TLSClientHello.probe(bytes) else {
            return XCTFail("expected a parsed summary")
        }
        XCTAssertEqual(summary.serverName, "login.example.com")
        XCTAssertEqual(summary.alpn, ["h2", "http/1.1"])
        XCTAssertEqual(summary.version, "TLS 1.3")
    }

    /// The whole point of the feature: a CONNECT target of "1.2.3.4:443" gains
    /// the name the client actually asked for.
    func testServerNameIsReadFromATunnelWhoseTargetWasAnAddress() {
        let bytes = makeClientHello(serverName: "vpn.rhbgroup.com")

        guard case .parsed(let summary) = TLSClientHello.probe(bytes) else {
            return XCTFail("expected a parsed summary")
        }
        XCTAssertEqual(summary.serverName, "vpn.rhbgroup.com")
    }

    func testAClientConnectingToAnIPHasNoServerNameButStillParses() {
        guard case .parsed(let summary) = TLSClientHello.probe(makeClientHello(serverName: nil)) else {
            return XCTFail("expected a parsed summary")
        }
        XCTAssertNil(summary.serverName)
        XCTAssertEqual(summary.version, "TLS 1.3")
    }

    /// GREASE values are deliberately unassigned placeholders. Reporting one as
    /// the negotiated version would be a lie.
    func testGreaseVersionsAreIgnored() {
        let bytes = makeClientHello(serverName: "example.com", versions: [0x0a0a, 0x0303, 0x1a1a])

        guard case .parsed(let summary) = TLSClientHello.probe(bytes) else {
            return XCTFail("expected a parsed summary")
        }
        XCTAssertEqual(summary.version, "TLS 1.2")
    }

    /// A ClientHello that is fragmented across records still has to be read.
    func testHandshakeSplitAcrossRecordsIsReassembled() {
        let bytes = makeClientHello(serverName: "split.example.com", alpn: ["h2"], splitAt: 20)

        guard case .parsed(let summary) = TLSClientHello.probe(bytes) else {
            return XCTFail("expected a parsed summary")
        }
        XCTAssertEqual(summary.serverName, "split.example.com")
        XCTAssertEqual(summary.alpn, ["h2"])
    }

    /// A large extension list is the realistic version of the split — the
    /// parser must not stop at the first record.
    func testABigExtensionListIsReadAcrossRecords() {
        let padding = (type: UInt16(0xff01), data: [UInt8](repeating: 0x00, count: 2000))
        let bytes = makeClientHello(serverName: "big.example.com", extraExtensions: [padding], splitAt: 700)

        guard case .parsed(let summary) = TLSClientHello.probe(bytes) else {
            return XCTFail("expected a parsed summary")
        }
        XCTAssertEqual(summary.serverName, "big.example.com")
    }

    func testATruncatedHelloAsksForMoreBytes() {
        let bytes = makeClientHello(serverName: "example.com", alpn: ["h2"])

        XCTAssertEqual(TLSClientHello.probe(Array(bytes.prefix(9))), .incomplete)
        XCTAssertEqual(TLSClientHello.probe(Array(bytes.prefix(bytes.count - 1))), .incomplete)
    }

    func testANonTLSStreamIsRejectedImmediately() {
        XCTAssertEqual(TLSClientHello.probe(Array("GET / HTTP/1.1\r\n\r\n".utf8)), .notTLS)
        XCTAssertEqual(TLSClientHello.probe([0x16, 0x03, 0x01, 0x00, 0x04, 0x02, 0x00, 0x00, 0x00]), .notTLS)
        XCTAssertEqual(TLSClientHello.probe([]), .incomplete)
    }

    /// A peer that declares a huge record must not make the relay buffer
    /// without bound: past the cap the probe gives up rather than growing.
    func testAnOversizedIncompleteRecordGivesUpAtTheCap() {
        var bytes: [UInt8] = [0x16, 0x03, 0x01, 0xff, 0xff] // declares 65535 bytes
        bytes.append(contentsOf: [UInt8](repeating: 0, count: TLSClientHello.maxBytes))
        XCTAssertEqual(TLSClientHello.probe(bytes), .notTLS)
    }

    func testVersionNames() {
        XCTAssertEqual(TLSClientHello.versionName(0x0304), "TLS 1.3")
        XCTAssertEqual(TLSClientHello.versionName(0x0303), "TLS 1.2")
        XCTAssertEqual(TLSClientHello.versionName(0x0301), "TLS 1.0")
        XCTAssertEqual(TLSClientHello.versionName(0x0a0a), "0x0A0A")
    }

    /// Every extension is optional; a malformed one must end the parse rather
    /// than read past the buffer or invent a value.
    func testMalformedExtensionsEndTheParseWithoutCrashing() {
        let bytes = makeClientHello(
            serverName: "example.com",
            extraExtensions: [(type: 0x1234, data: [0x00, 0x01])]
        )
        // Cut inside the last extension's length prefix.
        XCTAssertEqual(TLSClientHello.probe(Array(bytes.prefix(bytes.count - 3))), .incomplete)
    }
}
