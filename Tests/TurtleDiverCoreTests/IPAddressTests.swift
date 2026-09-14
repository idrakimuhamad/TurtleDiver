import XCTest
@testable import TurtleDiverCore
@testable import TurtleDiverRules

final class IPAddressTests: XCTestCase {

    // MARK: - IPv4 parsing

    func testIPv4ParseRoundTrip() {
        let ip = IPAddress.parse("192.168.1.100")
        XCTAssertNotNil(ip)
        XCTAssertTrue(ip!.isIPv4)
        XCTAssertEqual(ip!.bytes, [192, 168, 1, 100])
        XCTAssertEqual(ip!.text, "192.168.1.100")
    }

    func testIPv4RejectsMalformed() {
        let bad = ["256.1.1.1", "1.2.3", "1.2.3.4.5", "1.2.3.", ".1.2.3",
                   "1.2.3.04", "01.2.3.4", "0x1.2.3.4", "1.2.3.4 ", "1..2.3"]
        for text in bad {
            XCTAssertNil(IPAddress.parseIPv4(text), "expected \(text) to be rejected")
        }
    }

    func testIPv4AcceptsZeroAddress() {
        XCTAssertEqual(IPAddress.parseIPv4("0.0.0.0")?.bytes, [0, 0, 0, 0])
    }

    // MARK: - IPv6 parsing

    func testIPv6Loopback() {
        let ip = IPAddress.parse("::1")
        XCTAssertNotNil(ip)
        XCTAssertFalse(ip!.isIPv4)
        XCTAssertEqual(ip!.text, "::1")
    }

    func testIPv6FullForm() {
        let ip = IPAddress.parse("2001:0db8:0000:0000:0000:0000:0000:0001")
        XCTAssertNotNil(ip)
        XCTAssertEqual(ip!.text, "2001:db8::1")
    }

    func testIPv6CompressedMiddle() {
        let ip = IPAddress.parse("2001:db8::8a2e:370:7334")
        XCTAssertNotNil(ip)
        XCTAssertEqual(ip!.bytes[0], 0x20)
        XCTAssertEqual(ip!.bytes[1], 0x01)
        XCTAssertEqual(ip!.bytes[2], 0x0d)
        XCTAssertEqual(ip!.bytes[3], 0xb8)
    }

    func testIPv6MappedNormalizesToIPv4() {
        let ip = IPAddress.parse("::ffff:192.168.1.1")
        XCTAssertNotNil(ip)
        XCTAssertTrue(ip!.isIPv4, "mapped addresses should normalize to IPv4")
        XCTAssertEqual(ip!.bytes, [192, 168, 1, 1])
    }

    func testIPv6MappedHexForm() {
        let ip = IPAddress.parse("::ffff:c0a8:101") // 192.168.1.1
        XCTAssertNotNil(ip)
        XCTAssertTrue(ip!.isIPv4)
        XCTAssertEqual(ip!.bytes, [192, 168, 1, 1])
    }

    func testIPv6ZoneStripped() {
        let ip = IPAddress.parse("fe80::1%en0")
        XCTAssertNotNil(ip)
        XCTAssertEqual(ip!.text, "fe80::1")
    }

    func testIPv6UnspecifiedAddressAccepted() {
        // Bare `::` is the valid unspecified address (RFC 4291; inet_pton
        // accepts it too), so it must parse to all-zero bytes.
        let ip = IPAddress.parse("::")
        XCTAssertEqual(ip?.bytes, [UInt8](repeating: 0, count: 16))
    }

    func testIPv6RejectsMalformed() {
        let bad = ["::1::2", "1:2:3:4:5:6:7:8:9", "g::1", "12345::", ":1:2", "1:2:"]
        for text in bad {
            XCTAssertNil(IPAddress.parseIPv6(text), "expected \(text) to be rejected")
        }
    }

    func testIPv6LoopbackOnlyCompressionRejected() {
        // `::` standing for zero groups is invalid per RFC 4291.
        XCTAssertNil(IPAddress.parseIPv6("1:2:3:4:5:6:7:8::"))
        XCTAssertNil(IPAddress.parseIPv6("::1:2:3:4:5:6:7:8"))
    }

    // MARK: - CIDR

    func testCIDRParse() {
        let cidr = CIDRBlock(text: "10.0.0.0/8")
        XCTAssertEqual(cidr?.address.text, "10.0.0.0")
        XCTAssertEqual(cidr?.prefixLength, 8)
    }

    func testCIDRRejectsBadPrefix() {
        XCTAssertNil(CIDRBlock(text: "10.0.0.0/33"))
        XCTAssertNil(CIDRBlock(text: "10.0.0.0/-1"))
        XCTAssertNil(CIDRBlock(text: "10.0.0.0/"))
        XCTAssertNil(CIDRBlock(text: "10.0.0.0"))
        XCTAssertNil(CIDRBlock(text: "10.0.0.0/x"))
    }

    func testCIDRv6PrefixBounds() {
        XCTAssertNil(CIDRBlock(text: "::/129"))
        XCTAssertNotNil(CIDRBlock(text: "::/128"))
        XCTAssertNotNil(CIDRBlock(text: "fe80::/10"))
    }

    func testCIDRContainsIPv4() {
        let block = CIDRBlock(text: "192.168.0.0/16")!
        XCTAssertTrue(block.contains(IPAddress.parse("192.168.0.1")!))
        XCTAssertTrue(block.contains(IPAddress.parse("192.168.255.254")!))
        XCTAssertFalse(block.contains(IPAddress.parse("192.169.0.1")!))
        XCTAssertFalse(block.contains(IPAddress.parse("10.0.0.1")!))
    }

    func testCIDRZeroPrefixMatchesEverything() {
        let block = CIDRBlock(text: "0.0.0.0/0")!
        XCTAssertTrue(block.contains(IPAddress.parse("1.2.3.4")!))
        XCTAssertTrue(block.contains(IPAddress.parse("255.255.255.255")!))
    }

    func testCIDRHostPrefixMatchesExactlyOneHost() {
        let block = CIDRBlock(text: "10.1.2.3/32")!
        XCTAssertTrue(block.contains(IPAddress.parse("10.1.2.3")!))
        XCTAssertFalse(block.contains(IPAddress.parse("10.1.2.4")!))
    }

    func testCIDRPartialBytePrefix() {
        // /20 cuts in the middle of the third byte.
        let block = CIDRBlock(text: "10.64.0.0/20")!
        XCTAssertTrue(block.contains(IPAddress.parse("10.64.0.1")!))
        XCTAssertTrue(block.contains(IPAddress.parse("10.64.15.255")!))
        XCTAssertFalse(block.contains(IPAddress.parse("10.64.16.0")!))
        XCTAssertFalse(block.contains(IPAddress.parse("10.65.0.0")!))
    }

    func testCIDRIPv6Containment() {
        let block = CIDRBlock(text: "fe80::/10")!
        XCTAssertTrue(block.contains(IPAddress.parse("fe80::1")!))
        XCTAssertTrue(block.contains(IPAddress.parse("febf::ffff")!))
        XCTAssertFalse(block.contains(IPAddress.parse("fec0::1")!))
        XCTAssertFalse(block.contains(IPAddress.parse("2001:db8::1")!))
    }

    func testCIDRIPv6FullLength() {
        let block = CIDRBlock(text: "2001:db8::1/128")!
        XCTAssertTrue(block.contains(IPAddress.parse("2001:db8::1")!))
        XCTAssertFalse(block.contains(IPAddress.parse("2001:db8::2")!))
    }

    func testMappedIPv6MatchesIPv4Block() {
        let block = CIDRBlock(text: "10.0.0.0/8")!
        let mapped = IPAddress.parse("::ffff:10.1.2.3")!
        XCTAssertTrue(block.contains(mapped), "mapped v6 should normalize into the v4 block")
    }

    func testAddressFamilyMismatchDoesNotContain() {
        let block = CIDRBlock(text: "10.0.0.0/8")!
        XCTAssertFalse(block.contains(IPAddress.parse("2001:db8::1")!))
        let v6 = CIDRBlock(text: "fe80::/10")!
        XCTAssertFalse(v6.contains(IPAddress.parse("192.168.1.1")!))
    }

    func testParseAddressOrBlock() {
        XCTAssertEqual(IPAddress.parseAddressOrBlock("10.0.0.5")?.prefix, 32)
        XCTAssertEqual(IPAddress.parseAddressOrBlock("10.0.0.0/8")?.prefix, 8)
        XCTAssertEqual(IPAddress.parseAddressOrBlock("::1")?.prefix, 128)
        XCTAssertNil(IPAddress.parseAddressOrBlock("not-an-ip"))
    }
}
