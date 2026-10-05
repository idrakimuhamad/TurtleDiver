import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import TurtleDiverCore
@testable import TurtleDiverRules
@testable import TurtleDiverEngine

/// Regression tests for the retain cycles that used to keep every finished
/// relay — and the `RelayStreamObserver` it carried — alive for the life of
/// the process.
///
/// The servers installed their teardown closure on the very object that
/// closure had to release:
///
///     relay.onFinished = { [weak self] _, _ in
///         ...
///         self?.relayRegistry.release(relay)   // `relay` captured strongly
///     }
///     observer.onClientPrefix = { ... observer.peerAddress ... }
///
/// `relay → onFinished → relay` and `observer → onClientPrefix → observer` are
/// cycles. `RelayRegistry.release` did remove the relay from its table, but the
/// self-reference kept the object resident anyway — and the observer's up-to-
/// 16 KB stream prefix with it. Measured on a live 2.1.3 build after six days of
/// normal browsing: 114,685 leaked `RelayConnection`s, 115,505 leaked
/// observers, ~1.4 GB of physical footprint (`leaks` reported the root cycles).
///
/// Two guards: a structural one pinning the weak captures (the exact fix) and a
/// behavioural one that drives real tunnels and checks the leak is gone.
final class RelayRetainCycleTests: XCTestCase {

    // MARK: - Harness

    private var profile: Profile!

    override func setUpWithError() throws {
        try super.setUpWithError()
        profile = Profile(name: "retain-cycle-test")
        profile.general.testInterval = 3600
    }

    private func makeEngine(rules: [ProfileRule]) throws -> (engine: ProxyEngine, httpPort: Int) {
        var profile = profile!
        profile.general.socks5Listen = ""
        profile.rules = rules
        let httpPort = try freePort()
        profile.general.httpListen = "127.0.0.1:\(httpPort)"
        let engine = ProxyEngine(profile: profile, requestLog: RequestLog())
        try engine.start(profile: profile)
        return (engine, httpPort)
    }

    private func freePort() throws -> Int {
        let (fd, port) = TestSockets.listenOnEphemeralLoopback()
        TestSockets.closeFD(fd)
        return port
    }

    /// A TLS handshake record whose declared payload length is far past the
    /// 16 KB observer cap. `TLSClientHello.probe` never finishes parsing it, so
    /// the observer buffers up to its full limit — the worst-case payload a
    /// leaked observer pins per finished tunnel.
    private static let partialClientHello: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: TLSClientHello.maxBytes + 64)
        bytes[0] = 0x16   // handshake
        bytes[1] = 0x03   // legacy record version
        bytes[2] = 0x01
        bytes[3] = 0xFF   // declared record length, never satisfied
        bytes[4] = 0xFF
        return bytes
    }()

    private func tunnelOneConnection(httpPort: Int, originPort: Int) throws {
        let fd = try TCPClient.connect(host: "127.0.0.1", port: httpPort, timeoutSeconds: 5)
        defer { TCPClient.closeSocket(fd) }
        try TCPClient.sendAll(
            fd: fd,
            Array("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n".utf8),
            timeoutSeconds: 5
        )
        let reply = try readSome(fd, minBytes: 12)
        let text = String(decoding: reply, as: UTF8.self)
        guard text.contains("200") else {
            throw NSError(domain: "RelayRetainCycleTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "tunnel not established: \(text.prefix(80))"])
        }
        try TCPClient.sendAll(fd: fd, Self.partialClientHello, timeoutSeconds: 5)
    }

    private func readSome(_ fd: Int32, minBytes: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        let deadline = Date().addingTimeInterval(5)
        while out.count < minBytes && Date() < deadline {
            guard TCPClient.waitForReadable(fd: fd, timeoutSeconds: max(deadline.timeIntervalSinceNow, 0.1)) else { break }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, 4096, 0) }
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                break
            } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                break
            }
        }
        return out
    }

    private static func memoryFootprintMB() -> Double {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / (1024 * 1024)
        #else
        return -1
        #endif
    }

    private static func waitUntil(timeoutSeconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return condition()
    }

    // MARK: - Behavioural guard

    /// Runs real CONNECT tunnels whose client prefix is large enough that a
    /// leaked observer keeps its whole 16 KB buffer. With the cycles present
    /// the footprint grows by ~`rounds × 16 KB`; with them broken it settles
    /// back near the baseline.
    func testFinishedTunnelsDoNotRetainTheirObserverPrefixes() throws {
        let origin = DiscardingOrigin()
        defer { origin.stop() }
        let (engine, httpPort) = try makeEngine(rules: [
            ProfileRule(type: .final, value: "", policy: "DIRECT")
        ])

        // Warm up: the first connections pay for lazily created dispatch
        // sources, thread-pool growth and malloc zone expansion.
        for _ in 0..<8 { try tunnelOneConnection(httpPort: httpPort, originPort: origin.port) }
        XCTAssertTrue(
            Self.waitUntil(timeoutSeconds: 10) { engine.relayRegistry.activeCount == 0 },
            "warm-up relays did not retire"
        )
        Thread.sleep(forTimeInterval: 0.5)
        let baseline = Self.memoryFootprintMB()

        let rounds = 512
        for _ in 0..<rounds { try tunnelOneConnection(httpPort: httpPort, originPort: origin.port) }

        XCTAssertTrue(
            Self.waitUntil(timeoutSeconds: 20) { engine.relayRegistry.activeCount == 0 },
            "relay registry still holds \(engine.relayRegistry.activeCount) relays"
        )
        Thread.sleep(forTimeInterval: 1.0)
        let after = Self.memoryFootprintMB()
        guard baseline >= 0, after >= 0 else { throw XCTSkip("physical footprint unavailable") }

        let growth = after - baseline
        // Leaky: 512 observers × 16 KB ≈ 8 MB stay resident. Fixed: only runtime
        // noise remains, so a 4 MB ceiling separates the two with headroom.
        XCTAssertLessThanOrEqual(
            growth, 4,
            "memory grew \(String(format: "%.1f", growth)) MB over \(rounds) finished tunnels "
                + "(baseline \(String(format: "%.1f", baseline)) MB → \(String(format: "%.1f", after)) MB); "
                + "a finished relay is still retaining its observer"
        )
    }

    // MARK: - Structural guard

    /// The exact shape of the fix: neither teardown closure may capture the
    /// object it is stored on. This pins the capture lists even if the
    /// footprint test is skipped on a platform without `task_vm_info`.
    func testServerTeardownClosuresCaptureTheirOwnerWeakly() throws {
        let expected: [(file: String, closure: String, owner: String, count: Int)] = [
            ("HTTPProxyServer.swift", "onFinished = {", "weak relay", 2),
            ("HTTPProxyServer.swift", ".onClientPrefix = {", "weak observer", 1),
            ("HTTPProxyServer.swift", ".onServerPrefix = {", "weak observer", 1),
            ("SOCKS5Server.swift", "onFinished = {", "weak relay", 1),
            ("SOCKS5Server.swift", ".onClientPrefix = {", "weak observer", 1),
        ]

        for spec in expected {
            let text = try String(contentsOf: engineSourceURL(spec.file), encoding: .utf8)
            var matches: [String] = []
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                guard line.contains(spec.closure) else { continue }
                matches.append(line.trimmingCharacters(in: .whitespaces))
                XCTAssertTrue(
                    line.contains(spec.owner),
                    "\(spec.file) installs `\(spec.closure)` without capturing the owner weakly "
                        + "(`\(spec.owner)`): a strong capture is a retain cycle that keeps every "
                        + "finished relay/observer alive. Line: \(line.trimmingCharacters(in: .whitespaces))"
                )
            }
            XCTAssertEqual(
                matches.count, spec.count,
                "\(spec.file) has \(matches.count) `\(spec.closure)` site(s), expected \(spec.count); "
                    + "update this guard if the teardown moved"
            )
        }
    }

    private func engineSourceURL(_ relativePath: String) -> URL {
        // …/Tests/TurtleDiverCoreTests/RelayRetainCycleTests.swift -> VPNConnect/Engine/<file>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VPNConnect")
            .appendingPathComponent("Engine")
            .appendingPathComponent(relativePath)
    }
}

/// A loopback origin that accepts connections forever and drains them until
/// EOF. `FakeEchoServer`'s accept loop exits after a 0.5s idle gap (its
/// `acceptOne` returns nil), which strands later connections in the kernel
/// backlog; this origin keeps accepting for the whole run.
private final class DiscardingOrigin: @unchecked Sendable {
    let port: Int
    private let listenerFD: Int32
    private let lock = NSLock()
    private var stopped = false

    init() {
        let (fd, port) = TestSockets.listenOnEphemeralLoopback()
        listen(fd, 256)
        self.listenerFD = fd
        self.port = port
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "discarding-origin"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func acceptLoop() {
        while !lock.withLock({ stopped }) {
            let client = accept(listenerFD, nil, nil)
            guard client >= 0 else {
                switch errno {
                case EINTR, ECONNABORTED, EPROTO:
                    continue
                default:
                    return // listener closed by stop()
                }
            }
            let thread = Thread { [weak self] in self?.drain(client) }
            thread.name = "discarding-origin-conn"
            thread.start()
        }
    }

    private func drain(_ fd: Int32) {
        defer { TestSockets.closeFD(fd) }
        while true {
            guard let data = TestSockets.readSome(fd: fd, max: 64 * 1024) else { return }
            if data.isEmpty { return } // EOF
        }
    }

    func stop() {
        lock.withLock { stopped = true }
        TestSockets.closeFD(listenerFD)
    }
}
