import XCTest
import Foundation
@testable import TurtleDiverAppGlue
import TurtleDiverCore
import TurtleDiverSystem

/// The app's half of "ask the agent to end the tunnel": the write, the answer,
/// and the bound on the wait.
///
/// These are the parts that need neither a tunnel nor root — what makes a request
/// a request, what a channel that has gone answers with, and that a wait always
/// ends. The end-to-end half (a real agent, a real child process, a real stop) is
/// pinned in `TunnelAgentProcessTests`; the wiring that uses this is pinned in
/// `TunnelAgentWiringTests`.
final class AgentStopTests: XCTestCase {

    // MARK: - Making the request

    /// No channel means no request, and nothing to say about it: a tunnel started
    /// the old way is ended the old way.
    func testAChannelThatDoesNotExistIsNotARequest() {
        XCTAssertEqual(AgentStopOutcome.request(to: nil, agentRunning: true), .noAgent)
        XCTAssertEqual(AgentStopOutcome.request(to: nil, agentRunning: false), .noAgent)
    }

    /// An agent that is not running is not written to.
    ///
    /// Its channel ended with it, and that end of input *is* the instruction to
    /// end the tunnel — so this is a report, not a failure to report.
    func testAnAgentThatIsNotRunningIsNotWrittenTo() {
        let pipe = Pipe()
        XCTAssertEqual(AgentStopOutcome.request(to: pipe, agentRunning: false), .agentGone)
    }

    func testTheRequestPutsExactlyTheVerbOnTheChannel() {
        let pipe = Pipe()
        XCTAssertEqual(AgentStopOutcome.request(to: pipe, agentRunning: true), .requested)

        // Read it back whole. Five bytes into an empty pipe buffer is all of it,
        // so this neither waits nor needs a readability handler.
        let written = pipe.fileHandleForReading.availableData
        XCTAssertEqual(written, TunnelAgentChannel.Launch.stopRequest())
        XCTAssertEqual(String(decoding: written, as: UTF8.self), "stop\n")
    }

    /// A channel that cannot be written to answers with a reason — and never by
    /// dying. This is the case the descriptor flag exists for: without it, the
    /// throw here would have been a `SIGPIPE`, and the test runner would have
    /// been killed instead of told.
    func testAChannelThatCannotBeWrittenToIsAnErrorNotASignal() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        guard case .writeFailed(let why) = AgentStopOutcome.request(to: pipe, agentRunning: true) else {
            return XCTFail("a closed channel did not report a write failure")
        }
        XCTAssertFalse(why.isEmpty, "a write failure with nothing to report")
    }

    // MARK: - Waiting for the answer

    /// The wait is a bound, not a hope: with nothing recorded it returns, and it
    /// says which bound it spent.
    func testTheWaitEndsEvenWhenNothingEverAnswers() {
        let box = AgentStopBox()
        let started = Date()
        XCTAssertEqual(box.wait(within: 0.2), .unanswered(0.2))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the wait ran on past its bound")
    }

    /// The answer is whatever the agent said, unchanged — including the answer
    /// that says the tunnel is still up. A wait that turned every outcome into
    /// "done" would be reporting something no one observed.
    func testTheWaitAnswersWithWhatTheAgentSaid() {
        let box = AgentStopBox()
        box.record(.stopped)
        XCTAssertEqual(box.wait(within: 5), .stopped)

        box.record(.stubborn)
        XCTAssertEqual(box.wait(within: 5), .stubborn)
    }

    /// A report outlives the wait. Clearing it is explicit, because the answer to
    /// one request must never be read as the answer to the next.
    func testAClearedBoxHasNothingToSay() {
        let box = AgentStopBox()
        box.record(.stopped)
        XCTAssertEqual(box.recorded(), .stopped)
        box.clear()
        XCTAssertNil(box.recorded())
        XCTAssertEqual(box.wait(within: 0.2), .unanswered(0.2))
    }

    // MARK: - What the log says

    /// The two cases that are not results say nothing. `.noAgent` has nothing to
    /// report, and `.requested` is the state between writing the verb and hearing
    /// back — printing it would put a line in the log for a request that may
    /// still be refused.
    func testTheLogOnlySpeaksWhenThereIsSomethingToSay() {
        XCTAssertEqual(AgentStopOutcome.noAgent.explanation, "")
        XCTAssertEqual(AgentStopOutcome.requested.explanation, "")

        for outcome: AgentStopOutcome in [
            .agentGone,
            .writeFailed("the channel is closed"),
            .stopped,
            .stubborn,
            .unanswered(5)
        ] {
            XCTAssertFalse(outcome.explanation.isEmpty, "\(outcome) had nothing to report")
            XCTAssertTrue(outcome.explanation.hasSuffix("\n"), "\(outcome) would run into the next line")
        }
    }

    /// The bound is quoted back, because "did not answer in 5s" and "did not
    /// answer in 1s" are two different stories about the same silence.
    func testTheUnansweredCaseQuotesItsOwnBound() {
        XCTAssertTrue(AgentStopOutcome.unanswered(5).explanation.contains("5s"))
        XCTAssertTrue(AgentStopOutcome.unanswered(1).explanation.contains("1s"))
        XCTAssertFalse(AgentStopOutcome.unanswered(1).explanation.contains("5s"))
    }
}
