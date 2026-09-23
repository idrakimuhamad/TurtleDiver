import XCTest
@testable import TurtleDiverCLIKit
import TurtleDiverCore
import TurtleDiverSystem

/// The parts of the CLI that can be wrong without a process ever starting:
/// what the command line means, what argv the connect builds, and what the two
/// output shapes say.
final class CLIParsingTests: XCTestCase {

    // MARK: - Command line

    func testCommandAndPositionals() throws {
        let parsed = try ParsedCommandLine.parse(["rules", "explain", "github.com"])
        XCTAssertEqual(parsed.command, "rules")
        XCTAssertEqual(parsed.positional, ["explain", "github.com"])
    }

    func testSwitchAndValueOptions() throws {
        let parsed = try ParsedCommandLine.parse(["rules", "explain", "x.com", "--profile", "Work", "--port", "443", "--json"])
        XCTAssertEqual(parsed.options["profile"], "Work")
        XCTAssertEqual(try parsed.int("port"), 443)
        XCTAssertTrue(parsed.wantsJSON)
    }

    func testEqualsFormIsAccepted() throws {
        let parsed = try ParsedCommandLine.parse(["profile", "validate", "--profile=Home"])
        XCTAssertEqual(parsed.options["profile"], "Home")
    }

    func testUnknownOptionIsRefusedNotIgnored() {
        // The failure this prevents is `--jason`, which would otherwise produce
        // human output and exit 0 — a caller believing it had asked for JSON.
        XCTAssertThrowsError(try ParsedCommandLine.parse(["status", "--jason"])) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .usage)
        }
    }

    func testValueOptionWithoutValueIsUsageError() {
        XCTAssertThrowsError(try ParsedCommandLine.parse(["rules", "explain", "x", "--profile"])) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .usage)
        }
    }

    func testNonNumericPortIsUsageError() throws {
        let parsed = try ParsedCommandLine.parse(["rules", "explain", "x", "--port", "ssh"])
        XCTAssertThrowsError(try parsed.int("port")) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .usage)
        }
    }

    func testDoubleDashEndsOptions() throws {
        let parsed = try ParsedCommandLine.parse(["rules", "explain", "--", "--weird-host"])
        XCTAssertEqual(parsed.positional, ["explain", "--weird-host"])
    }

    func testShortForms() throws {
        XCTAssertTrue(try ParsedCommandLine.parse(["-h"]).wantsHelp)
        XCTAssertTrue(try ParsedCommandLine.parse(["-v"]).switches.contains("version"))
    }

    // MARK: - Output

    func testJSONIsSortedAndOneLine() {
        let encoded = Output.encode(["b": 2, "a": 1, "ok": true])
        XCTAssertEqual(encoded, "{\"a\":1,\"b\":2,\"ok\":true}\n")
    }

    func testJSONRefusesAValueItCannotEncode() {
        // A Date is not a JSON value. Printing `null` and exiting 0 would let a
        // caller believe the field was empty rather than that the tool is wrong.
        let encoded = Output.encode(["when": Date()])
        XCTAssertTrue(encoded.contains("\"ok\":false"))
    }

    func testReportSendsLinesToStderrInJSONMode() {
        let out = FileHandle(forWritingAtPath: "/dev/null")!
        let err = FileHandle(forWritingAtPath: "/dev/null")!
        let output = Output(json: true, quiet: false, out: out, err: err)
        // Nothing to assert about /dev/null; the point is it does not throw and
        // does not write the human line to the JSON stream.
        output.report(["ok": true], ["connected"])
        output.fail(.usage("bad"))
    }

    // MARK: - Exit codes

    func testExitCodesAreStable() {
        // These numbers are the interface. Changing one silently breaks every
        // caller that matches on it, so the test names them one by one.
        XCTAssertEqual(CLIExitCode.ok.rawValue, 0)
        XCTAssertEqual(CLIExitCode.failure.rawValue, 1)
        XCTAssertEqual(CLIExitCode.usage.rawValue, 2)
        XCTAssertEqual(CLIExitCode.notConfigured.rawValue, 3)
        XCTAssertEqual(CLIExitCode.alreadyConnected.rawValue, 4)
        XCTAssertEqual(CLIExitCode.noTunnel.rawValue, 5)
        XCTAssertEqual(CLIExitCode.needsApproval.rawValue, 6)
        XCTAssertEqual(CLIExitCode.missingTool.rawValue, 7)
        XCTAssertEqual(CLIExitCode.tunnelNotStopped.rawValue, 8)
        XCTAssertEqual(CLIExitCode.timedOut.rawValue, 9)
    }

    func testDispatchWithoutACommandIsUsage() {
        let output = Output(json: false, quiet: true, out: .nullDevice, err: .nullDevice)
        XCTAssertEqual(try? TurtleDiverCLI.dispatch(ParsedCommandLine(), output: output), .usage)
    }

    func testDispatchUnknownCommandThrowsUsage() {
        let output = Output(json: false, quiet: true, out: .nullDevice, err: .nullDevice)
        XCTAssertThrowsError(try TurtleDiverCLI.dispatch(ParsedCommandLine(command: "frobnicate"), output: output))
    }

    // MARK: - The openconnect command line

    private func settings(host: String = "vpn.example.com", id: String = "alice",
                          tunneling: Bool = false, urls: [String] = []) -> AppSettings {
        AppSettings(vpnHost: host, vpnID: id, useTunneling: tunneling, vpnSliceURLs: urls)
    }

    func testInvocationMatchesTheAppsArgumentOrder() throws {
        let invocation = try OpenConnectInvocation.build(
            settings: settings(),
            openconnectPath: "/opt/homebrew/bin/openconnect",
            slicePath: nil,
            pidFilePath: "/tmp/run/openconnect.pid"
        )
        XCTAssertEqual(invocation.arguments, [
            "--force-dpd=10",
            "--reconnect-timeout=604800",
            "--user=alice",
            "--pid-file", "/tmp/run/openconnect.pid",
            "vpn.example.com",
        ])
        // Two, not three: on the agent path the administrator password is not on
        // the pipe at all. A third line would be read as openconnect's password.
        XCTAssertEqual(invocation.credentialLineCount, 2)
        XCTAssertEqual(invocation.credentialLineCount, TunnelAgentChannel.Launch.credentialLineCount)
    }

    func testSplitTunnellingAddsOneSliceArgument() throws {
        let invocation = try OpenConnectInvocation.build(
            settings: settings(tunneling: true, urls: ["10.0.0.0/8", "*.corp.example.com"]),
            openconnectPath: "/usr/local/bin/openconnect",
            slicePath: "/usr/local/bin/vpn-slice",
            pidFilePath: "/tmp/oc.pid"
        )
        XCTAssertEqual(invocation.arguments, [
            "--force-dpd=10",
            "--reconnect-timeout=604800",
            "--user=alice",
            "--pid-file", "/tmp/oc.pid",
            "-s", "/usr/local/bin/vpn-slice 10.0.0.0/8 *.corp.example.com",
            "vpn.example.com",
        ])
    }

    func testSplitTunnellingWithoutSliceIsAMissingTool() {
        XCTAssertThrowsError(try OpenConnectInvocation.build(
            settings: settings(tunneling: true),
            openconnectPath: "/usr/local/bin/openconnect",
            slicePath: nil,
            pidFilePath: "/tmp/oc.pid"
        )) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .missingTool)
        }
    }

    func testMissingHostIsNotConfigured() {
        XCTAssertThrowsError(try OpenConnectInvocation.build(
            settings: settings(host: "  "),
            openconnectPath: "/usr/local/bin/openconnect",
            slicePath: nil,
            pidFilePath: "/tmp/oc.pid"
        )) { error in
            XCTAssertEqual((error as? CLIFailure)?.code, .notConfigured)
        }
    }

    func testHostAndAccountAreTrimmed() throws {
        let invocation = try OpenConnectInvocation.build(
            settings: settings(host: " vpn.example.com\n", id: " alice "),
            openconnectPath: "/usr/local/bin/openconnect",
            slicePath: nil,
            pidFilePath: "/tmp/oc.pid"
        )
        XCTAssertTrue(invocation.arguments.contains("--user=alice"))
        XCTAssertEqual(invocation.arguments.last, "vpn.example.com")
    }

    // MARK: - Token command

    func testTokenCommandWithTokenFile() {
        let command = TokenGenerator.command(for: .init(
            stokenPath: "/opt/homebrew/bin/stoken",
            tokenFilePath: "/Users/x/.stoken",
            rcPath: "/Users/x/.stokenrc",
            homeRCPath: "/Users/x/.stokenrc",
            passcode: "1234"
        ))
        XCTAssertEqual(command.executable, "/opt/homebrew/bin/stoken")
        XCTAssertEqual(command.arguments, ["tokencode", "--file", "/Users/x/.stoken", "-p", "1234"])
        // With a token file, STOKEN_RC must not be set: a stale rc would override
        // the file the user chose.
        XCTAssertNil(command.environment)
    }

    func testTokenCommandFallsBackToEnvAndRC() {
        let command = TokenGenerator.command(for: .init(
            stokenPath: nil,
            tokenFilePath: "",
            rcPath: "/Users/x/.stokenrc",
            homeRCPath: "/Users/x/.stokenrc",
            passcode: ""
        ))
        XCTAssertEqual(command.executable, "/usr/bin/env")
        XCTAssertEqual(command.arguments, ["stoken", "tokencode"])
        XCTAssertEqual(command.environment, ["STOKEN_RC": "/Users/x/.stokenrc"])
    }

    func testTokenCommandUsesHomeRCOnlyWhenNothingElseIsConfigured() {
        let command = TokenGenerator.command(for: .init(
            stokenPath: "/usr/local/bin/stoken",
            tokenFilePath: "",
            rcPath: "",
            homeRCPath: "/Users/x/.stokenrc",
            passcode: ""
        ))
        XCTAssertEqual(command.environment, ["STOKEN_RC": "/Users/x/.stokenrc"])
    }

    func testPinIsPasscodeThenCode() {
        XCTAssertEqual(TokenGenerator.combine(passcode: "9999", code: "123456"), "9999123456")
        XCTAssertEqual(TokenGenerator.combine(passcode: "", code: "123456"), "123456")
    }
}
