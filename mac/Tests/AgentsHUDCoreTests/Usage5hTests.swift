import XCTest
@testable import AgentsHUDCore

final class Usage5hTests: XCTestCase {
    private func cfg(basis: Config.PercentBasis = .budget, budget: Int = 2_000_000) -> Config {
        Config(claudeDir: "/tmp/nonexistent", tokenBudget: budget, percentBasis: basis)
    }

    private let hour: Double = 60 * 60_000

    func testEmptyEvents() {
        let u = Usage5hCalculator.compute(events: [], cfg: cfg(), now: 0)
        XCTAssertEqual(u.percent, 0)
        XCTAssertNil(u.blockStart)
        XCTAssertEqual(u.source, "estimate")
    }

    func testSingleActiveBlock() {
        // Event at 10:30 UTC -> block start floors to 10:00, end 15:00.
        let base = 1_700_000_000_000.0 // 2023-11-14T22:13:20Z
        let evTs = Usage5hCalculator.floorToHour(base) + 30 * 60_000
        let now = evTs + hour
        let u = Usage5hCalculator.compute(
            events: [UsageEvent(ts: evTs, tokens: 500_000)],
            cfg: cfg(),
            now: now
        )
        XCTAssertEqual(u.tokensUsed, 500_000)
        XCTAssertEqual(u.percent, 25)
        XCTAssertEqual(u.blockStart, ISO8601Millis.string(fromEpochMs: Usage5hCalculator.floorToHour(evTs)))
        // Reset: block start + 5h - now = 4h - 30min = 210 min
        XCTAssertEqual(u.resetInMinutes, 210)
    }

    func testGapClosesBlock() {
        // Two events >5h apart form two blocks; only the second is active.
        let start = Usage5hCalculator.floorToHour(1_700_000_000_000.0)
        let ev1 = UsageEvent(ts: start + 10 * 60_000, tokens: 100)
        let ev2 = UsageEvent(ts: start + 6 * hour, tokens: 200)
        let now = start + 6 * hour + 60_000
        let u = Usage5hCalculator.compute(events: [ev1, ev2], cfg: cfg(), now: now)
        XCTAssertEqual(u.tokensUsed, 200)
    }

    func testExpiredBlockReturnsEmptyWithMaxBlockBudget() {
        let start = Usage5hCalculator.floorToHour(1_700_000_000_000.0)
        let ev = UsageEvent(ts: start, tokens: 3_000_000)
        let now = start + 6 * hour
        let u = Usage5hCalculator.compute(events: [ev], cfg: cfg(basis: .maxBlock), now: now)
        XCTAssertEqual(u.tokensUsed, 0)
        XCTAssertEqual(u.tokenBudget, 3_000_000) // max(budget, maxBlock)
        XCTAssertNil(u.blockStart)
    }

    func testWithinWindowButAfterGapStartsNewBlock() {
        // Event within 5h of block start but >5h after the previous event
        // must start a new block (dual-condition close).
        let start = Usage5hCalculator.floorToHour(1_700_000_000_000.0)
        // First event right at block start; second 4.9h later — within the
        // block window but the inter-event gap is < 5h so same block.
        let ev1 = UsageEvent(ts: start, tokens: 100)
        let ev2 = UsageEvent(ts: start + 4.9 * hour, tokens: 50)
        let now = start + 4.95 * hour
        let u = Usage5hCalculator.compute(events: [ev1, ev2], cfg: cfg(), now: now)
        XCTAssertEqual(u.tokensUsed, 150)
    }
}
