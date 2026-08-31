import XCTest
@testable import UsageCore

final class SessionUsageAccumulatorTests: XCTestCase {
    func testUsesNonNegativeTotalDeltasAndStartsNewSegmentAfterReset() throws {
        let records = try fixtureLines(named: "session-total-usage")
            .compactMap { try SessionLineParser().parse(line: $0) }
        var accumulator = SessionUsageAccumulator()

        let events = try records.compactMap {
            try accumulator.ingest($0)
        }

        XCTAssertEqual(
            events.map(\.usage),
            [
                TokenBreakdown(
                    inputTokens: 100,
                    cachedInputTokens: 60,
                    outputTokens: 20
                ),
                TokenBreakdown(
                    inputTokens: 50,
                    cachedInputTokens: 30,
                    outputTokens: 10
                ),
                TokenBreakdown(
                    inputTokens: 40,
                    cachedInputTokens: 10,
                    outputTokens: 10
                )
            ]
        )
    }

    func testReplayedRecordProducesSameAnonymousSignature() throws {
        let lines = try fixtureLines(named: "session-replayed-prefix")
        let records = try lines.compactMap {
            try SessionLineParser().parse(line: $0)
        }
        var first = SessionUsageAccumulator()
        var second = SessionUsageAccumulator()

        let left = try XCTUnwrap(first.ingest(records[0]))
        let right = try XCTUnwrap(second.ingest(records[1]))

        XCTAssertEqual(left.signature, right.signature)
    }

    func testLastUsageTakesPrecedenceWhileTotalStateStillAdvances() throws {
        let record = try XCTUnwrap(
            SessionLineParser().parse(
                line: try fixtureLine(named: "session-last-usage")
            )
        )
        var accumulator = SessionUsageAccumulator()

        let event = try XCTUnwrap(accumulator.ingest(record))

        XCTAssertEqual(event.usage, record.lastUsage)
        XCTAssertEqual(accumulator.state.previousTotal, record.totalUsage)
    }
}
