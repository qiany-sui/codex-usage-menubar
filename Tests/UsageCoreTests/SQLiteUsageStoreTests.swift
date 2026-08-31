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

    func testDuplicateSignaturesInOneBatchReturnOneAndSurviveReopen() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let event = storedEvent(
            at: Date(timeIntervalSince1970: 100),
            input: 10,
            cached: 4,
            output: 2
        )
        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
            let inserted = try await store.insert(events: [event, event])
            XCTAssertEqual(inserted, 1)
        }
        let reopened = try SQLiteUsageStore(databaseURL: databaseURL)
        try await reopened.migrate()
        let saved = try await reopened.events(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 200)
        )

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

    func testCycleInsertConflictRollsBackReplacementAfterReopen() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let existing = cycle(start: 100, input: 10)
        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
            try await store.replace(cycles: [existing])
            let first = cycle(start: 1_000, input: 20)
            let conflicting = cycle(start: 1_000, input: 30)

            await assertSQLiteError(
                try await store.replace(cycles: [first, conflicting]),
                operation: "insert cycle: step",
                code: 1_555
            )
        }
        let reopened = try SQLiteUsageStore(databaseURL: databaseURL)
        try await reopened.migrate()
        let saved = try await reopened.cycles()

        XCTAssertEqual(saved, [existing])
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

    func testNonFiniteEventBatchIsRejectedBeforeAnyInsert() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let valid = storedEvent(
            at: Date(timeIntervalSince1970: 100),
            input: 10,
            output: 2
        )

        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let invalid = StoredUsageEvent(
                signature: Data(repeating: 8, count: 32),
                occurredAt: Date(timeIntervalSince1970: interval),
                localDay: LocalDay(year: 2026, month: 8, day: 31),
                usage: TokenBreakdown(
                    inputTokens: 10,
                    cachedInputTokens: 4,
                    outputTokens: 2
                )
            )
            await assertSQLiteError(
                try await store.insert(events: [valid, invalid]),
                operation: "validate event",
                code: 275
            )
        }

        let saved = try await store.events(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(saved, [])
    }

    func testNonFiniteEventQueryBoundsAreRejectedBeforeSQL() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let finite = Date(timeIntervalSince1970: 100)

        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let invalid = Date(timeIntervalSince1970: interval)
            await assertSQLiteError(
                try await store.events(from: invalid, to: finite),
                operation: "validate event query",
                code: 275
            )
            await assertSQLiteError(
                try await store.events(from: finite, to: invalid),
                operation: "validate event query",
                code: 275
            )
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

    func testNegativeCursorOffsetIsRejectedBeforeSQL() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let cursor = FileCursor(
            pathHash: Data(repeating: 10, count: 32),
            deviceID: 1,
            inode: 2,
            committedOffset: -1,
            counterState: SessionCounterState(previousTotal: nil)
        )

        await assertSQLiteError(
            try await store.save(cursor: cursor),
            operation: "validate cursor",
            code: 275
        )
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

    func testNonFiniteOfficialFetchDateIsRejectedWithoutPartialUpsert() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let valid = OfficialUsageDay(
            day: LocalDay(year: 2026, month: 8, day: 1),
            tokens: 10,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let invalid = OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 2),
                tokens: 20,
                fetchedAt: Date(timeIntervalSince1970: interval)
            )
            await assertSQLiteError(
                try await store.upsert(officialDays: [valid, invalid]),
                operation: "validate official day",
                code: 275
            )
        }

        let savedDays = try await store.officialDays()
        XCTAssertEqual(savedDays, [])
    }

    func testInvalidQuotaNumbersAreRejectedBeforeSQL() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let finite = Date(timeIntervalSince1970: 100)
        let valid = QuotaSnapshot(
            limitID: "codex",
            usedPercent: 25,
            windowDurationMinutes: 10_080,
            startsAt: finite,
            resetsAt: finite.addingTimeInterval(60),
            fetchedAt: finite
        )
        var invalid: [QuotaSnapshot] = [
            quota(from: valid, usedPercent: .nan),
            quota(from: valid, usedPercent: .infinity),
            quota(from: valid, usedPercent: -.infinity),
            quota(from: valid, usedPercent: -1),
            quota(from: valid, duration: 0),
            quota(from: valid, duration: -1)
        ]
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let date = Date(timeIntervalSince1970: interval)
            invalid.append(quota(from: valid, startsAt: date))
            invalid.append(quota(from: valid, resetsAt: date))
            invalid.append(quota(from: valid, fetchedAt: date))
        }

        for quota in invalid {
            await assertSQLiteError(
                try await store.save(quota: quota),
                operation: "validate quota",
                code: 275
            )
        }
        let savedQuota = try await store.latestQuota()
        XCTAssertNil(savedQuota)
    }

    func testQuotaLimitIDWithEmbeddedNULRoundTripsCompletely() async throws {
        let databaseURL = try databaseURLWithCleanup()
        let fetchedAt = Date(timeIntervalSince1970: 100)
        let quota = QuotaSnapshot(
            limitID: "codex\0secondary",
            usedPercent: 25,
            windowDurationMinutes: 10_080,
            startsAt: Date(timeIntervalSince1970: 0),
            resetsAt: Date(timeIntervalSince1970: 200),
            fetchedAt: fetchedAt
        )
        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
            try await store.save(quota: quota)
        }
        let reopened = try SQLiteUsageStore(databaseURL: databaseURL)
        let saved = try await reopened.latestQuota()

        XCTAssertEqual(saved, quota)
    }

    func testInvalidUTF8DatabaseTextThrowsFixedCorruptionError() async throws {
        let databaseURL = try databaseURLWithCleanup()
        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
        }
        do {
            let connection = try SQLiteConnection(databaseURL: databaseURL)
            try connection.execute(
                """
                INSERT INTO quota_snapshots
                VALUES (100, CAST(x'80' AS TEXT), 25, 10080, 0, 200);
                """,
                operation: "test fixture"
            )
        }
        let store = try SQLiteUsageStore(databaseURL: databaseURL)

        await assertSQLiteError(
            try await store.latestQuota(),
            operation: "read quota: read text",
            code: 11
        )
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

    func testInvalidCycleNumbersDoNotReplaceExistingCycles() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let existing = cycle(start: 100, input: 10)
        try await store.replace(cycles: [existing])
        let finite = Date(timeIntervalSince1970: 200)
        let valid = QuotaCycle(
            startsAt: finite,
            endsAt: finite.addingTimeInterval(60),
            usage: TokenBreakdown(inputTokens: 10, cachedInputTokens: 4, outputTokens: 2),
            displayedTokens: 12,
            status: .localLive,
            boundaryIsEstimated: false
        )
        var invalid = [
            cycle(from: valid, usage: TokenBreakdown(inputTokens: -1, cachedInputTokens: 0, outputTokens: 0)),
            cycle(from: valid, usage: TokenBreakdown(inputTokens: 1, cachedInputTokens: -1, outputTokens: 0)),
            cycle(from: valid, usage: TokenBreakdown(inputTokens: 1, cachedInputTokens: 0, outputTokens: -1)),
            cycle(from: valid, displayedTokens: -1)
        ]
        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            let date = Date(timeIntervalSince1970: interval)
            invalid.append(cycle(from: valid, startsAt: date))
            invalid.append(cycle(from: valid, endsAt: date))
        }

        for value in invalid {
            await assertSQLiteError(
                try await store.replace(cycles: [value]),
                operation: "validate cycle",
                code: 275
            )
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

    func testNonFinitePruneDateIsRejectedWithoutDeletingUsage() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let event = storedEvent(
            at: Date(timeIntervalSince1970: 100),
            input: 10,
            output: 2
        )
        _ = try await store.insert(events: [event])

        for interval in [Double.nan, Double.infinity, -Double.infinity] {
            await assertSQLiteError(
                try await store.pruneUsage(
                    eventsBefore: Date(timeIntervalSince1970: interval),
                    officialDaysBefore: LocalDay(year: 2026, month: 8, day: 1)
                ),
                operation: "validate prune cutoff",
                code: 275
            )
        }

        let saved = try await store.events(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(saved, [event])
    }

    func testCorruptStoredValuesAreRejectedWithFixedReadErrors() async throws {
        let databaseURL = try databaseURLWithCleanup()
        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
        }
        do {
            let connection = try SQLiteConnection(databaseURL: databaseURL)
            try connection.execute(
                """
                INSERT INTO usage_events VALUES (x'01', 100, '2026-08-31', 1, 2, 0);
                INSERT INTO file_cursors VALUES (x'02', 1, 2, -1, NULL, NULL, NULL);
                INSERT INTO official_usage_days VALUES ('2026-08-31', 1, 1e999);
                INSERT INTO quota_snapshots VALUES (100, 'codex', 25, 10080, 1e999, 200);
                INSERT INTO quota_cycles VALUES (100, 200, 1, 0, 0, -1, 'localLive', 0);
                """,
                operation: "test fixture"
            )
        }
        let store = try SQLiteUsageStore(databaseURL: databaseURL)

        await assertSQLiteError(
            try await store.events(
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 200)
            ),
            operation: "read events",
            code: 11
        )
        await assertSQLiteError(
            try await store.cursor(for: Data([2])),
            operation: "read cursor",
            code: 11
        )
        await assertSQLiteError(
            try await store.officialDays(),
            operation: "read official days",
            code: 11
        )
        await assertSQLiteError(
            try await store.latestQuota(),
            operation: "read quota",
            code: 11
        )
        await assertSQLiteError(
            try await store.cycles(),
            operation: "read cycles",
            code: 11
        )
    }

    func testNonCanonicalLocalDaysAreRejectedBeforeSQL() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let invalidDays = [
            LocalDay(year: 0, month: 1, day: 1),
            LocalDay(year: 10_000, month: 1, day: 1),
            LocalDay(year: 2026, month: 0, day: 1),
            LocalDay(year: 2026, month: 13, day: 1),
            LocalDay(year: 2026, month: 2, day: 29),
            LocalDay(year: 2026, month: 2, day: 31)
        ]

        for (index, day) in invalidDays.enumerated() {
            let event = StoredUsageEvent(
                signature: Data([UInt8(index + 1)]),
                occurredAt: Date(timeIntervalSince1970: 100),
                localDay: day,
                usage: TokenBreakdown(inputTokens: 1, cachedInputTokens: 0, outputTokens: 0)
            )
            await assertSQLiteError(
                try await store.insert(events: [event]),
                operation: "validate event",
                code: 275
            )
            await assertSQLiteError(
                try await store.upsert(
                    officialDays: [
                        OfficialUsageDay(
                            day: day,
                            tokens: 1,
                            fetchedAt: Date(timeIntervalSince1970: 100)
                        )
                    ]
                ),
                operation: "validate official day",
                code: 275
            )
            await assertSQLiteError(
                try await store.pruneUsage(
                    eventsBefore: Date(timeIntervalSince1970: 100),
                    officialDaysBefore: day
                ),
                operation: "validate prune cutoff",
                code: 275
            )
        }

        let savedEvents = try await store.events(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(savedEvents, [])
        let savedDays = try await store.officialDays()
        XCTAssertEqual(savedDays, [])
    }

    func testCanonicalLeapDayRoundTripsAndIsAcceptedAsPruneCutoff() async throws {
        let store = try SQLiteUsageStore(databaseURL: try databaseURLWithCleanup())
        try await store.migrate()
        let leapDay = LocalDay(year: 2024, month: 2, day: 29)
        let event = StoredUsageEvent(
            signature: Data([1]),
            occurredAt: Date(timeIntervalSince1970: 100),
            localDay: leapDay,
            usage: TokenBreakdown(inputTokens: 1, cachedInputTokens: 0, outputTokens: 1)
        )
        let official = OfficialUsageDay(
            day: leapDay,
            tokens: 2,
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        _ = try await store.insert(events: [event])
        try await store.upsert(officialDays: [official])
        try await store.pruneUsage(
            eventsBefore: Date(timeIntervalSince1970: 0),
            officialDaysBefore: leapDay
        )

        let savedEvents = try await store.events(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(savedEvents, [event])
        let savedDays = try await store.officialDays()
        XCTAssertEqual(savedDays, [official])
    }

    func testCorruptLocalDaysAreRejectedOnRead() async throws {
        let databaseURL = try databaseURLWithCleanup()
        do {
            let store = try SQLiteUsageStore(databaseURL: databaseURL)
            try await store.migrate()
        }
        do {
            let connection = try SQLiteConnection(databaseURL: databaseURL)
            try connection.execute(
                """
                INSERT INTO usage_events VALUES (x'01', 100, '2026-02-31', 1, 0, 0);
                INSERT INTO official_usage_days VALUES ('0000-01-01', 1, 100);
                """,
                operation: "test fixture"
            )
        }
        let store = try SQLiteUsageStore(databaseURL: databaseURL)

        await assertSQLiteError(
            try await store.events(
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 200)
            ),
            operation: "read events",
            code: 11
        )
        await assertSQLiteError(
            try await store.officialDays(),
            operation: "read official days",
            code: 11
        )
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

    private func quota(
        from quota: QuotaSnapshot,
        usedPercent: Double? = nil,
        duration: Int? = nil,
        startsAt: Date? = nil,
        resetsAt: Date? = nil,
        fetchedAt: Date? = nil
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            limitID: quota.limitID,
            usedPercent: usedPercent ?? quota.usedPercent,
            windowDurationMinutes: duration ?? quota.windowDurationMinutes,
            startsAt: startsAt ?? quota.startsAt,
            resetsAt: resetsAt ?? quota.resetsAt,
            fetchedAt: fetchedAt ?? quota.fetchedAt
        )
    }

    private func cycle(
        from cycle: QuotaCycle,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        usage: TokenBreakdown? = nil,
        displayedTokens: Int64? = nil
    ) -> QuotaCycle {
        QuotaCycle(
            startsAt: startsAt ?? cycle.startsAt,
            endsAt: endsAt ?? cycle.endsAt,
            usage: usage ?? cycle.usage,
            displayedTokens: displayedTokens ?? cycle.displayedTokens,
            status: cycle.status,
            boundaryIsEstimated: cycle.boundaryIsEstimated
        )
    }

    private func assertSQLiteError<T>(
        _ expression: @autoclosure () async throws -> T,
        operation: String,
        code: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await XCTAssertThrowsErrorAsync(
            try await expression(),
            file: file,
            line: line
        ) { error in
            guard case let SQLiteStoreError.operationFailed(actualOperation, actualCode) = error else {
                return XCTFail("unexpected error type", file: file, line: line)
            }
            XCTAssertEqual(actualOperation, operation, file: file, line: line)
            XCTAssertEqual(actualCode, code, file: file, line: line)
        }
    }
}
