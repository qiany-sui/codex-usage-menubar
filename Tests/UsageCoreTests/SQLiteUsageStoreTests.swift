import Foundation
import XCTest
@testable import UsageCore

final class SQLiteUsageStoreTests: XCTestCase {
    func testDuplicateSignatureIsInsertedOnlyOnce() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let event = StoredUsageEvent(
            signature: Data(repeating: 7, count: 32),
            occurredAt: Date(timeIntervalSince1970: 1_788_148_800),
            localDay: LocalDay(year: 2026, month: 8, day: 31),
            usage: TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 40,
                outputTokens: 20
            )
        )

        let firstCount = try await store.insert(events: [event])
        let secondCount = try await store.insert(events: [event])
        let saved = try await store.events(
            from: Date(timeIntervalSince1970: 1_788_140_000),
            to: Date(timeIntervalSince1970: 1_788_150_000)
        )

        XCTAssertEqual(firstCount, 1)
        XCTAssertEqual(secondCount, 0)
        XCTAssertEqual(saved, [event])
    }

    func testFileCursorSurvivesDatabaseReopen() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let cursor = FileCursor(
            pathHash: Data(repeating: 9, count: 32),
            deviceID: 12,
            inode: 34,
            committedOffset: 567,
            counterState: SessionCounterState(
                previousTotal: TokenBreakdown(
                    inputTokens: 10,
                    cachedInputTokens: 4,
                    outputTokens: 2
                )
            )
        )

        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
            try await store.save(cursor: cursor)
        }
        let reopened = try SQLiteUsageStore(databaseURL: databaseURL)
        try await reopened.migrate()
        let reopenedCursor = try await reopened.cursor(for: cursor.pathHash)

        XCTAssertEqual(reopenedCursor, cursor)
    }

    func testOfficialQuotaAndCyclesSurviveDatabaseReopen() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let fetchedAt = Date(timeIntervalSince1970: 1_788_148_800)
        let official = OfficialUsageDay(
            day: LocalDay(year: 2026, month: 8, day: 30),
            tokens: 400,
            fetchedAt: fetchedAt
        )
        let quota = QuotaSnapshot(
            limitID: "codex",
            usedPercent: 25,
            windowDurationMinutes: 10_080,
            startsAt: fetchedAt.addingTimeInterval(-300),
            resetsAt: fetchedAt.addingTimeInterval(10_080 * 60 - 300),
            fetchedAt: fetchedAt
        )
        let laterCycle = QuotaCycle(
            startsAt: quota.startsAt.addingTimeInterval(10_080 * 60),
            endsAt: quota.resetsAt.addingTimeInterval(10_080 * 60),
            usage: TokenBreakdown(inputTokens: 50, cachedInputTokens: 10, outputTokens: 5),
            displayedTokens: 55,
            status: .calibrated,
            boundaryIsEstimated: true
        )
        let cycle = QuotaCycle(
            startsAt: quota.startsAt,
            endsAt: quota.resetsAt,
            usage: TokenBreakdown(inputTokens: 100, cachedInputTokens: 40, outputTokens: 20),
            displayedTokens: 500,
            status: .partiallyCalibrated,
            boundaryIsEstimated: false
        )

        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
            try await store.upsert(officialDays: [official])
            try await store.save(quota: quota)
            try await store.replace(cycles: [laterCycle, cycle])
        }
        let reopened = try SQLiteUsageStore(databaseURL: databaseURL)
        try await reopened.migrate()
        let savedOfficialDays = try await reopened.officialDays()
        let savedQuota = try await reopened.latestQuota()
        let savedCycles = try await reopened.cycles()

        XCTAssertEqual(savedOfficialDays, [official])
        XCTAssertEqual(savedQuota, quota)
        XCTAssertEqual(savedCycles, [cycle, laterCycle])
    }

    func testTooManyCyclesDoesNotReplaceExistingCycles() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let existing = cycle(start: 100, input: 10)
        try await store.replace(cycles: [existing])

        await XCTAssertThrowsErrorAsync(
            try await store.replace(
                cycles: (0..<10).map { cycle(start: Double($0 + 1_000), input: Int64($0)) }
            )
        ) { error in
            XCTAssertEqual(error as? SQLiteStoreError, .tooManyCycles(10))
        }
        let savedCycles = try await store.cycles()
        XCTAssertEqual(savedCycles, [existing])
    }

    func testInvalidEventBatchIsRejectedWithoutPartialInsert() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let valid = storedEvent(at: Date(timeIntervalSince1970: 100), input: 10, cached: 4, output: 2)
        let invalid = storedEvent(at: Date(timeIntervalSince1970: 200), input: 5, cached: 6, output: 1)

        await XCTAssertThrowsErrorAsync(try await store.insert(events: [valid, invalid])) { error in
            guard case let SQLiteStoreError.operationFailed(operation, code) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "validate event")
            XCTAssertEqual(code, 275)
        }
        let savedEvents = try await store.events(
            from: .distantPast,
            to: .distantFuture
        )
        XCTAssertEqual(savedEvents, [])

        let negative = storedEvent(
            at: Date(timeIntervalSince1970: 300),
            input: -1,
            output: 0
        )
        await XCTAssertThrowsErrorAsync(try await store.insert(events: [negative])) { error in
            guard case let SQLiteStoreError.operationFailed(operation, code) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "validate event")
            XCTAssertEqual(code, 275)
        }
    }

    func testInvalidCursorCounterIsNotSaved() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let cursor = FileCursor(
            pathHash: Data(repeating: 6, count: 32),
            deviceID: 1,
            inode: 2,
            committedOffset: 3,
            counterState: SessionCounterState(
                previousTotal: TokenBreakdown(
                    inputTokens: 4,
                    cachedInputTokens: 5,
                    outputTokens: 1
                )
            )
        )

        await XCTAssertThrowsErrorAsync(try await store.save(cursor: cursor)) { error in
            guard case let SQLiteStoreError.operationFailed(operation, code) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "validate cursor")
            XCTAssertEqual(code, 275)
        }
        let savedCursor = try await store.cursor(for: cursor.pathHash)
        XCTAssertNil(savedCursor)
    }

    func testInvalidOfficialDayBatchIsRejectedWithoutPartialUpsert() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let fetchedAt = Date(timeIntervalSince1970: 300)
        let valid = OfficialUsageDay(
            day: LocalDay(year: 2026, month: 8, day: 1),
            tokens: 10,
            fetchedAt: fetchedAt
        )
        let invalid = OfficialUsageDay(
            day: LocalDay(year: 2026, month: 8, day: 2),
            tokens: -1,
            fetchedAt: fetchedAt
        )

        await XCTAssertThrowsErrorAsync(
            try await store.upsert(officialDays: [valid, invalid])
        ) { error in
            guard case let SQLiteStoreError.operationFailed(operation, code) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "validate official day")
            XCTAssertEqual(code, 275)
        }
        let savedDays = try await store.officialDays()
        XCTAssertEqual(savedDays, [])
    }

    func testInvalidCycleDoesNotReplaceExistingCycles() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let existing = cycle(start: 100, input: 10)
        try await store.replace(cycles: [existing])
        let invalid = QuotaCycle(
            startsAt: Date(timeIntervalSince1970: 200),
            endsAt: Date(timeIntervalSince1970: 300),
            usage: TokenBreakdown(inputTokens: 3, cachedInputTokens: 4, outputTokens: 1),
            displayedTokens: 4,
            status: .localLive,
            boundaryIsEstimated: false
        )

        await XCTAssertThrowsErrorAsync(try await store.replace(cycles: [invalid])) { error in
            guard case let SQLiteStoreError.operationFailed(operation, code) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(operation, "validate cycle")
            XCTAssertEqual(code, 275)
        }
        let savedCycles = try await store.cycles()
        XCTAssertEqual(savedCycles, [existing])
    }

    func testPruneRemovesOnlyOldUsageAndKeepsCursor() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let old = storedEvent(at: Date(timeIntervalSince1970: 100), input: 10, output: 2)
        let recent = storedEvent(at: Date(timeIntervalSince1970: 300), input: 20, output: 4)
        let cursor = FileCursor(
            pathHash: Data(repeating: 3, count: 32),
            deviceID: 1,
            inode: 2,
            committedOffset: 3,
            counterState: SessionCounterState(previousTotal: nil)
        )
        _ = try await store.insert(events: [old, recent])
        try await store.save(cursor: cursor)
        try await store.upsert(officialDays: [
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 7, day: 1),
                tokens: 100,
                fetchedAt: recent.occurredAt
            ),
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 1),
                tokens: 200,
                fetchedAt: recent.occurredAt
            )
        ])

        try await store.pruneUsage(
            eventsBefore: Date(timeIntervalSince1970: 200),
            officialDaysBefore: LocalDay(year: 2026, month: 8, day: 1)
        )
        let savedEvents = try await store.events(
            from: .distantPast,
            to: .distantFuture
        )
        let savedOfficialTokens = try await store.officialDays().map(\.tokens)
        let savedCursor = try await store.cursor(for: cursor.pathHash)

        XCTAssertEqual(savedEvents, [recent])
        XCTAssertEqual(savedOfficialTokens, [200])
        XCTAssertEqual(savedCursor, cursor)
    }

    func testMigrateIsIdempotent() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        try await store.migrate()
        let savedEvents = try await store.events(
            from: .distantPast,
            to: .distantFuture
        )
        XCTAssertEqual(savedEvents, [])
    }

    private func databaseURLWithCleanup() throws -> URL {
        let databaseURL = try temporaryDatabaseURL()
        let directory = databaseURL.deletingLastPathComponent()
        addTeardownBlock {
            try FileManager.default.removeItem(at: directory)
        }
        return databaseURL
    }

    private func cycle(start: Double, input: Int64) -> QuotaCycle {
        QuotaCycle(
            startsAt: Date(timeIntervalSince1970: start),
            endsAt: Date(timeIntervalSince1970: start + 60),
            usage: TokenBreakdown(inputTokens: input, cachedInputTokens: 0, outputTokens: 1),
            displayedTokens: input + 1,
            status: .localLive,
            boundaryIsEstimated: false
        )
    }
}
