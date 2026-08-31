import Foundation
import CryptoKit
import XCTest
@testable import UsageCore
enum TestSupportError: Error { case missingFixture(String); case invalidDate(String) }
func temporaryDirectory() throws -> URL { let url=FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsageTests-"+UUID().uuidString,isDirectory:true); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url }
func temporaryDatabaseURL() throws -> URL { try temporaryDirectory().appendingPathComponent("usage.sqlite3") }
func temporaryCodexHome() throws -> URL { let root=try temporaryDirectory(); for name in ["sessions","archived_sessions"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true) }; return root }
func storedEvent(
    at occurredAt: Date,
    input: Int64,
    cached: Int64 = 0,
    output: Int64
) -> StoredUsageEvent {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = calendar.dateComponents(
        [.year, .month, .day],
        from: occurredAt
    )
    let signatureText = [
        String(occurredAt.timeIntervalSince1970),
        String(input),
        String(cached),
        String(output)
    ].joined(separator: "|")
    return StoredUsageEvent(
        signature: Data(
            SHA256.hash(data: Data(signatureText.utf8))
        ),
        occurredAt: occurredAt,
        localDay: LocalDay(
            year: components.year!,
            month: components.month!,
            day: components.day!
        ),
        usage: TokenBreakdown(
            inputTokens: input,
            cachedInputTokens: cached,
            outputTokens: output
        )
    )
}
func fixtureLines(named name:String) throws -> [Data] { guard let url=Bundle.module.url(forResource:name,withExtension:"jsonl",subdirectory:"Fixtures") else { throw TestSupportError.missingFixture(name) }; let bytes = Array(try Data(contentsOf:url)); let lines: [ArraySlice<UInt8>] = bytes.split(separator:0x0A, maxSplits: Int.max, omittingEmptySubsequences: true); return lines.map { Data(bytes: Array($0), count: $0.count) } }
func fixtureLine(named name:String) throws -> Data { guard let first=try fixtureLines(named:name).first else { throw TestSupportError.missingFixture(name) }; return first }
func date(_ text:String) throws -> Date { let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; if let value=formatter.date(from:text){return value}; formatter.formatOptions=[.withInternetDateTime]; guard let value=formatter.date(from:text) else { throw TestSupportError.invalidDate(text) }; return value }

func tokenLine(
    timestamp: String,
    input: Int64,
    cached: Int64,
    output: Int64
) -> String {
    let object: [String: Any] = [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": input,
                    "cached_input_tokens": cached,
                    "output_tokens": output,
                    "reasoning_output_tokens": 0
                ]
            ]
        ]
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail(
            "expected expression to throw",
            file: file,
            line: line
        )
    } catch {
        errorHandler(error)
    }
}
