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

    func testRejectsTotalDeltaWhenCacheWouldExceedInputDelta() throws {
        var accumulator = SessionUsageAccumulator()
        let previous = totalRecord(input: 100, cached: 0, output: 0)
        let current = totalRecord(input: 110, cached: 110, output: 0)

        _ = try accumulator.ingest(previous)

        XCTAssertThrowsError(try accumulator.ingest(current)) { error in
            XCTAssertEqual(
                error as? SessionUsageAccumulatorError,
                .invalidTotalTransition
            )
        }
        XCTAssertEqual(accumulator.state.previousTotal, previous.totalUsage)
    }

    func testSingleTotalCounterRollbackStartsNewSegment() throws {
        var accumulator = SessionUsageAccumulator()
        let previous = totalRecord(input: 100, cached: 40, output: 20)
        let current = totalRecord(input: 120, cached: 30, output: 30)

        _ = try accumulator.ingest(previous)
        let event = try XCTUnwrap(accumulator.ingest(current))

        XCTAssertEqual(event.usage, current.totalUsage)
        XCTAssertEqual(accumulator.state.previousTotal, current.totalUsage)
    }

    func testAnonymousSignatureChangesForEveryAllowedInputField() throws {
        let baseline = SessionTokenRecord(
            occurredAt: Date(timeIntervalSince1970: 1_788_753_600),
            lastUsage: TokenBreakdown(
                inputTokens: 10,
                cachedInputTokens: 5,
                outputTokens: 3
            ),
            totalUsage: TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 50,
                outputTokens: 30
            ),
            schemaVariant: "last+total"
        )
        let changedRecords = [
            SessionTokenRecord(
                occurredAt: baseline.occurredAt.addingTimeInterval(0.001),
                lastUsage: baseline.lastUsage,
                totalUsage: baseline.totalUsage,
                schemaVariant: baseline.schemaVariant
            ),
            SessionTokenRecord(
                occurredAt: baseline.occurredAt,
                lastUsage: baseline.lastUsage,
                totalUsage: baseline.totalUsage,
                schemaVariant: "total"
            ),
            SessionTokenRecord(
                occurredAt: baseline.occurredAt,
                lastUsage: TokenBreakdown(inputTokens: 11, cachedInputTokens: 5, outputTokens: 3),
                totalUsage: baseline.totalUsage,
                schemaVariant: baseline.schemaVariant
            ),
            SessionTokenRecord(
                occurredAt: baseline.occurredAt,
                lastUsage: TokenBreakdown(inputTokens: 10, cachedInputTokens: 6, outputTokens: 3),
                totalUsage: baseline.totalUsage,
                schemaVariant: baseline.schemaVariant
            ),
            SessionTokenRecord(
                occurredAt: baseline.occurredAt,
                lastUsage: TokenBreakdown(inputTokens: 10, cachedInputTokens: 5, outputTokens: 4),
                totalUsage: baseline.totalUsage,
                schemaVariant: baseline.schemaVariant
            ),
            SessionTokenRecord(
                occurredAt: baseline.occurredAt,
                lastUsage: baseline.lastUsage,
                totalUsage: TokenBreakdown(inputTokens: 101, cachedInputTokens: 50, outputTokens: 30),
                schemaVariant: baseline.schemaVariant
            ),
            SessionTokenRecord(
                occurredAt: baseline.occurredAt,
                lastUsage: baseline.lastUsage,
                totalUsage: TokenBreakdown(inputTokens: 100, cachedInputTokens: 51, outputTokens: 30),
                schemaVariant: baseline.schemaVariant
            ),
            SessionTokenRecord(
                occurredAt: baseline.occurredAt,
                lastUsage: baseline.lastUsage,
                totalUsage: TokenBreakdown(inputTokens: 100, cachedInputTokens: 50, outputTokens: 31),
                schemaVariant: baseline.schemaVariant
            )
        ]
        let signature = try event(for: baseline)

        for record in changedRecords {
            let changed = try event(for: record)
            XCTAssertNotEqual(changed.signature, signature.signature)
        }
    }

    private func event(for record: SessionTokenRecord) throws -> SessionTokenEvent {
        var accumulator = SessionUsageAccumulator()
        return try XCTUnwrap(accumulator.ingest(record))
    }

    private func totalRecord(
        input: Int64,
        cached: Int64,
        output: Int64
    ) -> SessionTokenRecord {
        SessionTokenRecord(
            occurredAt: Date(timeIntervalSince1970: 1_788_753_600),
            lastUsage: nil,
            totalUsage: TokenBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output
            ),
            schemaVariant: "total"
        )
    }
}
