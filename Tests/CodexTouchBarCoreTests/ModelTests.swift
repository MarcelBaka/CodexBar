import XCTest
@testable import CodexTouchBarCore

final class ModelTests: XCTestCase {
    func testProgressCountsOnlyCompletedSteps() {
        var session = AgentSession(id: "test")
        XCTAssertNil(session.progressFraction)
        session.steps = [.init(title: "Analyze", status: .completed), .init(title: "Build", status: .inProgress), .init(title: "Verify")]
        XCTAssertEqual(session.progressFraction!, 1.0 / 3.0, accuracy: 0.0001)
        session.status = .completed
        XCTAssertEqual(session.completedSteps, 1, "A completed turn must not invent completed plan entries")
    }
    func testContextUsesLastUsageAndDurationFreezes() {
        var session = AgentSession(id: "test")
        session.totalTokens = 1000000
        XCTAssertNil(session.contextFraction)
        session.contextUsedTokens = 400; session.contextWindow = 1000
        XCTAssertEqual(session.contextFraction, 0.4)
        session.startedAt = Date(timeIntervalSince1970: 10)
        session.endedAt = Date(timeIntervalSince1970: 70)
        XCTAssertEqual(session.elapsed(at: Date(timeIntervalSince1970: 100)), 60)
        XCTAssertEqual(AgentSession.durationText(session.elapsed()), "01:00")
    }
    func testStalenessNeverClaimsCompletionOrWaiting() {
        var session = AgentSession(id: "test")
        session.status = .working; session.isStale = true
        XCTAssertEqual(session.displayStatus, .unknown)
        XCTAssertEqual(session.status, .working)
    }
}
