import XCTest
@testable import UsageCore

final class SessionLineParserTests: XCTestCase {
    func testParsesLastUsageWithoutDoubleCountingReasoningOutput() throws {
        let data = try fixtureLine(named: "session-last-usage")

        let record = try XCTUnwrap(SessionLineParser().parse(line: data))

        XCTAssertEqual(
            record.lastUsage,
            TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 80,
                outputTokens: 20
            )
        )
        XCTAssertEqual(
            record.occurredAt,
            try date("2026-08-31T01:02:03.000Z")
        )
    }

    func testIgnoresNonTokenEventWithoutRetainingPayload() throws {
        let line = Data(
            #"{"timestamp":"2026-08-31T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"SECRET_BODY"}}"#.utf8
        )

        XCTAssertNil(try SessionLineParser().parse(line: line))
    }

    func testRejectsNegativeTokenCountsAndInvalidTimestamps() {
        let parser = SessionLineParser()

        XCTAssertThrowsError(
            try parser.parse(
                line: Data(
                    tokenLine(
                        timestamp: "2026-08-31T01:00:00Z",
                        input: -1,
                        cached: 0,
                        output: 0
                    ).utf8
                )
            )
        ) { error in
            XCTAssertEqual(error as? SessionParseError, .invalidTokenEvent)
        }
        XCTAssertThrowsError(
            try parser.parse(
                line: Data(
                    tokenLine(
                        timestamp: "not-a-date",
                        input: 1,
                        cached: 0,
                        output: 0
                    ).utf8
                )
            )
        ) { error in
            XCTAssertEqual(error as? SessionParseError, .invalidTokenEvent)
        }
    }

    func testRejectsCachedInputExceedingInput() {
        XCTAssertThrowsError(
            try SessionLineParser().parse(
                line: Data(
                    tokenLine(
                        timestamp: "2026-08-31T01:00:00Z",
                        input: 1,
                        cached: 2,
                        output: 0
                    ).utf8
                )
            )
        ) { error in
            XCTAssertEqual(error as? SessionParseError, .invalidTokenEvent)
        }
    }
}
