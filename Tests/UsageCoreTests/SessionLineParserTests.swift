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

    func testIgnoresNonTokenEventBeforeDecodingIncompleteTokenLikeInfo() throws {
        let line = Data(
            #"{"type":"event_msg","payload":{"type":"user_message","info":{"last_token_usage":{"input_tokens":1}}}}"#.utf8
        )

        XCTAssertNil(try SessionLineParser().parse(line: line))
    }

    func testRejectsMissingTimestampForTokenEvent() {
        let line = Data(
            #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}}}"#.utf8
        )

        XCTAssertThrowsError(try SessionLineParser().parse(line: line)) { error in
            XCTAssertEqual(error as? SessionParseError, .invalidTokenEvent)
        }
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

    func testRejectsEachNegativeLastUsageCounter() {
        let fields = [
            "input_tokens",
            "cached_input_tokens",
            "output_tokens",
            "reasoning_output_tokens"
        ]

        for field in fields {
            let line = tokenEventLine(
                usageKey: "last_token_usage",
                overriding: field,
                with: -1
            )

            XCTAssertThrowsError(try SessionLineParser().parse(line: line)) {
                error in
                XCTAssertEqual(error as? SessionParseError, .invalidTokenEvent)
            }
        }
    }

    func testRejectsNegativeReasoningTotalUsageCounter() {
        let line = tokenEventLine(
            usageKey: "total_token_usage",
            overriding: "reasoning_output_tokens",
            with: -1
        )

        XCTAssertThrowsError(try SessionLineParser().parse(line: line)) { error in
            XCTAssertEqual(error as? SessionParseError, .invalidTokenEvent)
        }
    }

    private func tokenEventLine(
        usageKey: String,
        overriding field: String,
        with value: Int64
    ) -> Data {
        var usage: [String: Int64] = [
            "input_tokens": 10,
            "cached_input_tokens": 5,
            "output_tokens": 3,
            "reasoning_output_tokens": 0
        ]
        usage[field] = value
        let object: [String: Any] = [
            "timestamp": "2026-08-31T01:00:00Z",
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [usageKey: usage]
            ]
        ]
        return try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }
}
