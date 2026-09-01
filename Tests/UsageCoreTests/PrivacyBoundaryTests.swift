import Darwin
import Foundation
import XCTest
@testable import UsageCore

final class PrivacyBoundaryTests: XCTestCase {
    func testMessageBodyNeverReachesStoredArtifacts() async throws {
        let secret = "PRIVATE_PROMPT_7E9D4A"
        let secretBytes = Data(secret.utf8)
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("privacy.jsonl")
        let content = [
            #"{"timestamp":"2026-08-31T01:00:00Z","type":"event_msg","payload":{"type":"user_message","message":"\#(secret)"}}"#,
            tokenLine(
                timestamp: "2026-08-31T01:01:00.000Z",
                input: 100,
                cached: 40,
                output: 20
            )
        ].joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: session)

        let databaseURL = try temporaryDatabaseURL()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        let result = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: Calendar(identifier: .gregorian)
        )
        let events = try await store.events(
            from: .distantPast,
            to: .distantFuture
        )
        let snapshot = UsageReconciler().snapshot(
            now: try date("2026-08-31T12:00:00.000Z"),
            calendar: Calendar(identifier: .gregorian),
            quota: nil,
            events: events,
            officialDays: [],
            cycles: [],
            lastUpdatedAt: try date("2026-08-31T12:00:00.000Z")
        )

        XCTAssertEqual(result.scannedFileCount, 1)
        XCTAssertEqual(result.insertedEventCount, 1)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(
            events.first?.usage,
            TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 40,
                outputTokens: 20
            )
        )
        XCTAssertEqual(
            snapshot.today.localUsage,
            TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 40,
                outputTokens: 20
            )
        )
        XCTAssertEqual(snapshot.today.displayedTokens, 120)

        XCTAssertNil(try JSONEncoder().encode(events).range(of: secretBytes))
        XCTAssertNil(try JSONEncoder().encode(snapshot).range(of: secretBytes))
        for artifactURL in databaseArtifactURLs(for: databaseURL)
        where FileManager.default.fileExists(atPath: artifactURL.path) {
            XCTAssertNil(
                try Data(contentsOf: artifactURL).range(of: secretBytes)
            )
        }

        try await store.close()

        XCTAssertNil(
            try Data(contentsOf: databaseURL).range(of: secretBytes)
        )
    }

    func testResolverAndIndexerNeverOpenAuthJSON() async throws {
        let root = try temporaryDirectory()
        let auth = root.appendingPathComponent("auth.json")
        try Data("PRIVATE_TOKEN".utf8).write(to: auth)
        XCTAssertEqual(chmod(auth.path, 0), 0)
        defer {
            chmod(auth.path, S_IRUSR | S_IWUSR)
        }

        let resolved = CodexHomeResolver().resolve(
            initializedHome: root.path,
            environment: [:],
            homeDirectory: root.deletingLastPathComponent()
        )
        let store = try SQLiteUsageStore(
            databaseURL: try temporaryDatabaseURL()
        )
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)

        let result = try await indexer.index(
            codexHome: try XCTUnwrap(resolved),
            modifiedSince: .distantPast,
            calendar: Calendar(identifier: .gregorian)
        )

        XCTAssertEqual(result.scannedFileCount, 0)
        XCTAssertEqual(result.insertedEventCount, 0)
        try await store.close()
    }

    func testCloseIsIdempotentAndAllDatabaseOperationsReportClosed() async throws {
        let store = try SQLiteUsageStore(
            databaseURL: try temporaryDatabaseURL()
        )
        try await store.migrate()

        try await store.close()
        try await store.close()

        let eventDate = try date("2026-08-31T01:00:00.000Z")
        let day = LocalDay(year: 2026, month: 8, day: 31)
        let cursor = FileCursor(
            pathHash: Data([0x01]),
            deviceID: 1,
            inode: 1,
            committedOffset: 0,
            counterState: SessionCounterState(previousTotal: nil)
        )
        let event = StoredUsageEvent(
            signature: Data([0x02]),
            occurredAt: eventDate,
            localDay: day,
            usage: TokenBreakdown(
                inputTokens: 1,
                cachedInputTokens: 0,
                outputTokens: 1
            )
        )
        let officialDay = OfficialUsageDay(
            day: day,
            tokens: 2,
            fetchedAt: eventDate
        )
        let quota = QuotaSnapshot(
            limitID: "codex",
            usedPercent: 25,
            windowDurationMinutes: 10_080,
            startsAt: eventDate,
            resetsAt: eventDate.addingTimeInterval(10_080 * 60),
            fetchedAt: eventDate
        )
        let cycle = QuotaCycle(
            startsAt: eventDate,
            endsAt: eventDate.addingTimeInterval(10_080 * 60),
            usage: event.usage,
            displayedTokens: event.usage.totalTokens,
            status: .localLive,
            boundaryIsEstimated: false
        )

        await assertClosed(try await store.migrate())
        await assertClosed(try await store.insert(events: [event]))
        await assertClosed(try await store.ingest(events: [event], cursor: cursor))
        await assertClosed(
            try await store.events(from: eventDate, to: eventDate.addingTimeInterval(1))
        )
        await assertClosed(try await store.cursor(for: cursor.pathHash))
        await assertClosed(try await store.save(cursor: cursor))
        await assertClosed(try await store.upsert(officialDays: [officialDay]))
        await assertClosed(try await store.officialDays())
        await assertClosed(try await store.save(quota: quota))
        await assertClosed(try await store.latestQuota())
        await assertClosed(try await store.replace(cycles: [cycle]))
        await assertClosed(try await store.cycles())
        await assertClosed(
            try await store.pruneUsage(eventsBefore: eventDate, officialDaysBefore: day)
        )

        let invalidEvent = StoredUsageEvent(
            signature: Data([0x03]),
            occurredAt: eventDate,
            localDay: day,
            usage: TokenBreakdown(
                inputTokens: 0,
                cachedInputTokens: 1,
                outputTokens: 0
            )
        )
        let invalidCursor = FileCursor(
            pathHash: Data([0x04]),
            deviceID: 1,
            inode: 1,
            committedOffset: -1,
            counterState: SessionCounterState(previousTotal: nil)
        )
        let invalidOfficialDay = OfficialUsageDay(
            day: day,
            tokens: -1,
            fetchedAt: eventDate
        )
        let invalidQuota = QuotaSnapshot(
            limitID: "codex",
            usedPercent: -1,
            windowDurationMinutes: 0,
            startsAt: eventDate,
            resetsAt: eventDate,
            fetchedAt: eventDate
        )

        await assertClosed(try await store.insert(events: [invalidEvent]))
        await assertClosed(
            try await store.ingest(events: [invalidEvent], cursor: invalidCursor)
        )
        await assertClosed(try await store.save(cursor: invalidCursor))
        await assertClosed(
            try await store.upsert(officialDays: [invalidOfficialDay])
        )
        await assertClosed(try await store.save(quota: invalidQuota))
        await assertClosed(try await store.replace(cycles: Array(repeating: cycle, count: 10)))
        await assertClosed(
            try await store.pruneUsage(
                eventsBefore: Date(timeIntervalSince1970: .nan),
                officialDaysBefore: day
            )
        )
    }

    private func databaseArtifactURLs(for databaseURL: URL) -> [URL] {
        [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm")
        ]
    }

    private func assertClosed<T>(
        _ expression: @autoclosure () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await XCTAssertThrowsErrorAsync(
            try await expression(),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SQLiteStoreError,
                .closed,
                file: file,
                line: line
            )
        }
    }
}
