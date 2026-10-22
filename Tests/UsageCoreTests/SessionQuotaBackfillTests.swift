import Foundation
import CryptoKit
import XCTest
@testable import UsageCore

final class SessionQuotaBackfillTests: XCTestCase {
    func testLaterOfficialDecreaseDoesNotRemovePreviouslyConfirmedHistory() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        for poll in try [quota(36, "2026-10-21T20:52:00+08:00"),
                         quota(37, "2026-10-22T09:41:00+08:00"),
                         quota(0, "2026-10-22T10:00:00+08:00"),
                         quota(5, "2026-10-22T10:13:00+08:00")] {
            try await store.save(quota: poll)
        }
        try write([line(37, "2026-10-21T21:05:00+08:00")], to: root)
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(history.map(\.usedPercent), [36, 37, 37, 0, 5])
        try await store.close()
    }

    func testSessionClockCorrectionCannotMoveConfirmedCycleOrTokenBoundary() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let poll = try quota(1, "2026-10-20T14:45:00+08:00")
        try await store.save(quota: poll)
        try write([line(0, "2026-10-20T14:42:00+08:00", reset: "2026-10-27T14:41:04+08:00")], to: root)
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        let events = [storedEvent(at: poll.startsAt.addingTimeInterval(-10), input: 100, output: 0),
                      storedEvent(at: poll.startsAt.addingTimeInterval(10), input: 20, output: 0)]
        let cycles = CycleTracker().update(existing: [], quota: poll, events: events, quotaHistory: history)
        XCTAssertEqual(cycles.last?.startsAt, poll.startsAt)
        XCTAssertEqual(cycles.last?.usage.totalTokens, 20)
        try await store.close()
    }

    func testResetCollisionKeepsNewCycleRegardlessOfFileOrder() async throws {
        for oldFirst in [true, false] {
            let root = try temporaryCodexHome()
            let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
            try await store.migrate()
            let reset = "2026-10-29T09:00:00+08:00"
            for poll in try [quota(37, "2026-10-21T21:00:00+08:00"),
                             quota(0, "2026-10-22T09:00:00+08:00", reset: reset),
                             quota(2, "2026-10-22T10:13:00+08:00", reset: reset)] {
                try await store.save(quota: poll)
            }
            let old = try line(37, "2026-10-22T09:02:00+08:00")
            let new = try line(1, "2026-10-22T09:02:00+08:00", reset: reset)
            try Data(((oldFirst ? old : new) + "\n").utf8).write(to: root.appendingPathComponent("sessions/a.jsonl"))
            try Data(((oldFirst ? new : old) + "\n").utf8).write(to: root.appendingPathComponent("sessions/b.jsonl"))
            _ = try await SessionUsageIndexer(store: store).index(
                codexHome: root, modifiedSince: .distantPast, calendar: calendar
            )
            let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
            XCTAssertEqual(history.map(\.usedPercent), [37, 0, 1, 2])
            try await store.close()
        }
    }

    func testCloseResetCollisionKeepsZeroFromNewerCycleInEitherOrder() async throws {
        for oldFirst in [true, false] {
            let root = try temporaryCodexHome()
            let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
            try await store.migrate()
            let reset = "2026-10-27T14:42:04+08:00"
            for poll in try [quota(37, "2026-10-20T14:41:40+08:00"),
                             quota(0, "2026-10-20T14:42:04+08:00", reset: reset),
                             quota(2, "2026-10-20T14:45:00+08:00", reset: reset)] {
                try await store.save(quota: poll)
            }
            let old = try line(37, "2026-10-20T14:42:30+08:00")
            let new = try line(0, "2026-10-20T14:42:30+08:00", reset: reset)
            // 显式分两次导入，覆盖两个方向的同时间戳冲突。
            let indexer = SessionUsageIndexer(store: store)
            try write([oldFirst ? old : new], to: root)
            _ = try await indexer.index(codexHome: root, modifiedSince: .distantPast, calendar: calendar)
            try Data(((oldFirst ? new : old) + "\n").utf8).write(to: root.appendingPathComponent("sessions/second.jsonl"))
            _ = try await indexer.index(codexHome: root, modifiedSince: .distantPast, calendar: calendar)
            let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
            XCTAssertEqual(history.map(\.usedPercent), [37, 0, 0, 2])
            try await store.close()
        }
    }

    func testQueryAndRetentionKeepValidPredecessorInsteadOfLaterCachedReading() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        for poll in try [quota(36, "2026-10-21T20:52:00+08:00"),
                         quota(37, "2026-10-22T09:41:00+08:00"),
                         quota(38, "2026-10-22T10:13:00+08:00")] {
            try await store.save(quota: poll)
        }
        try write([line(37, "2026-10-21T21:05:00+08:00"), line(36, "2026-10-21T23:00:00+08:00")], to: root)
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let cutoff = try date("2026-10-22T00:00:00+08:00")
        let before = try await store.quotaHistory(from: cutoff, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(before.map(\.usedPercent), [37, 37, 38])
        try await store.pruneUsage(eventsBefore: cutoff, officialDaysBefore: LocalDay(year: 2026, month: 10, day: 22))
        let after = try await store.quotaHistory(from: cutoff, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(after, before)
        try await store.close()
    }

    func testConcurrentSnapshotCollisionDoesNotDependOnImportOrder() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        for poll in try [quota(36, "2026-10-21T20:52:00+08:00"), quota(38, "2026-10-22T10:13:00+08:00")] {
            try await store.save(quota: poll)
        }
        let indexer = SessionUsageIndexer(store: store)
        try write([line(37, "2026-10-21T21:05:00+08:00")], to: root)
        _ = try await indexer.index(codexHome: root, modifiedSince: .distantPast, calendar: calendar)
        try Data((line(36, "2026-10-21T21:05:00+08:00") + "\n").utf8)
            .write(to: root.appendingPathComponent("sessions/old.jsonl"))
        _ = try await indexer.index(codexHome: root, modifiedSince: .distantPast, calendar: calendar)
        let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(history.map(\.usedPercent), [36, 37, 38])
        try await store.save(quota: quota(36, "2026-10-21T21:05:00+08:00"))
        let corrected = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(corrected.map(\.usedPercent), [36, 36, 38])
        try await store.close()
    }

    func testLegacyCursorIsReplayedOnceAndExistingTokensAreDeduplicated() async throws {
        let root = try temporaryCodexHome()
        let database = try temporaryDatabaseURL()
        let content = try line(37, "2026-10-21T21:05:00+08:00", input: 10)
        try write([content], to: root)
        let session = root.appendingPathComponent("sessions/usage.jsonl")
        do {
            let legacy = try SQLiteConnection(databaseURL: database)
            try legacy.execute("""
                CREATE TABLE file_cursors (path_hash BLOB PRIMARY KEY NOT NULL,
                  device_id INTEGER NOT NULL, inode INTEGER NOT NULL, committed_offset INTEGER NOT NULL,
                  previous_input_tokens INTEGER, previous_cached_input_tokens INTEGER, previous_output_tokens INTEGER);
                CREATE TABLE quota_snapshots (fetched_at REAL PRIMARY KEY NOT NULL, limit_id TEXT NOT NULL,
                  used_percent REAL NOT NULL, window_duration_minutes INTEGER NOT NULL,
                  starts_at REAL NOT NULL, resets_at REAL NOT NULL);
                CREATE TABLE usage_events (signature BLOB PRIMARY KEY NOT NULL, occurred_at REAL NOT NULL,
                  local_day TEXT NOT NULL, input_tokens INTEGER NOT NULL, cached_input_tokens INTEGER NOT NULL,
                  output_tokens INTEGER NOT NULL);
                PRAGMA user_version = 1;
                """, operation: "create legacy fixture")
        }
        let metadata = try FileManager.default.attributesOfItem(atPath: session.path)
        let hash = Data(SHA256.hash(data: Data(session.path.utf8)))
        let cursor = FileCursor(pathHash: hash,
            deviceID: try XCTUnwrap(metadata[.systemNumber] as? NSNumber).int64Value,
            inode: try XCTUnwrap(metadata[.systemFileNumber] as? NSNumber).int64Value,
            committedOffset: Int64(content.utf8.count + 1), counterState: SessionCounterState(previousTotal: nil))
        let legacyStore = try SQLiteUsageStore(databaseURL: database)
        var accumulator = SessionUsageAccumulator()
        let record = try XCTUnwrap(SessionLineParser().parse(line: Data(content.utf8)))
        let event = try XCTUnwrap(accumulator.ingest(record))
        _ = try await legacyStore.insert(events: [StoredUsageEvent(signature: event.signature,
            occurredAt: event.occurredAt, localDay: LocalDay(year: 2026, month: 10, day: 21), usage: event.usage)])
        try await legacyStore.save(cursor: cursor)
        try await legacyStore.close()

        let store = try SQLiteUsageStore(databaseURL: database)
        try await store.migrate()
        try await store.migrate()
        for poll in try [quota(36, "2026-10-21T20:52:00+08:00"), quota(38, "2026-10-22T10:13:00+08:00")] {
            try await store.save(quota: poll)
        }
        let indexer = SessionUsageIndexer(store: store)
        _ = try await indexer.index(codexHome: root, modifiedSince: .distantPast, calendar: calendar)
        let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(history.map(\.usedPercent), [36, 37, 38])
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.usage.inputTokens, 10)
        try await store.migrate()
        let after = try await store.cursor(for: hash)
        XCTAssertEqual(after?.committedOffset, cursor.committedOffset)
        try await store.close()
    }

    func testFailedCursorCommitRollsBackSessionQuotaAndTokens() async throws {
        let root = try temporaryCodexHome()
        let database = try temporaryDatabaseURL()
        let store = try SQLiteUsageStore(databaseURL: database)
        try await store.migrate()
        for poll in try [quota(36, "2026-10-21T20:52:00+08:00"), quota(38, "2026-10-22T10:13:00+08:00")] {
            try await store.save(quota: poll)
        }
        try write([line(37, "2026-10-21T21:05:00+08:00", input: 10)], to: root)
        let fixture = try SQLiteConnection(databaseURL: database)
        try fixture.execute("""
            CREATE TRIGGER reject_cursor BEFORE INSERT ON file_cursors
            BEGIN SELECT RAISE(ABORT, 'reject cursor'); END;
            """, operation: "reject cursor fixture")
        let indexer = SessionUsageIndexer(store: store)
        await XCTAssertThrowsErrorAsync(try await indexer.index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )) { XCTAssertNotNil($0 as? SQLiteStoreError) }
        let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(history.map(\.usedPercent), [36, 38])
        XCTAssertTrue(events.isEmpty)
        try fixture.execute("DROP TRIGGER reject_cursor;", operation: "allow retry")
        _ = try await indexer.index(codexHome: root, modifiedSince: .distantPast, calendar: calendar)
        let retried = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(retried.map(\.usedPercent), [36, 37, 38])
        try await store.close()
    }

    func testSessionSnapshotsCompleteBothSidesOfOvernightGapWithoutChangingTokens() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let polls = try [
            quota(14, "2026-10-20T20:41:00+08:00"),
            quota(14, "2026-10-21T10:17:00+08:00"),
            quota(36, "2026-10-21T20:52:00+08:00"),
            quota(37, "2026-10-22T09:41:00+08:00"),
            quota(38, "2026-10-22T10:13:00+08:00")
        ]
        for poll in polls { try await store.save(quota: poll) }
        try write([
            line(37, "2026-10-21T20:56:18+08:00", input: 10),
            line(37, "2026-10-21T21:05:03+08:00"),
            line(38, "2026-10-22T09:46:34+08:00"),
            line(37, "2026-10-22T09:47:48+08:00"),
            line(38, "2026-10-22T09:48:04+08:00")
        ], to: root)
        let indexer = SessionUsageIndexer(store: store)
        _ = try await indexer.index(codexHome: root, modifiedSince: .distantPast, calendar: calendar)
        let first = try await snapshot(store)
        XCTAssertEqual(first.recentDays.first { $0.day.day == 21 }?.quotaConsumedPercent, 23)
        XCTAssertEqual(first.today.quotaConsumedPercent, 1)
        XCTAssertNil(first.today.recordedQuotaConsumedPercent)

        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.usage.inputTokens, 10)
        let second = try await snapshot(store)
        XCTAssertEqual(second, first)
        let latest = try await store.latestQuota()
        XCTAssertEqual(latest, polls.last)
        try await store.close()
    }

    func testSessionOnlyRecordDoesNotReplaceLiveQuotaOrHideAnOfficialDecrease() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        for poll in try [quota(14, "2026-10-21T23:58:00+08:00"),
                         quota(38, "2026-10-22T09:41:00+08:00"),
                         quota(37, "2026-10-22T10:13:00+08:00")] {
            try await store.save(quota: poll)
        }
        try write([line(40, "2026-10-22T10:14:00+08:00")], to: root)
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let latest = try await store.latestQuota()
        XCTAssertEqual(latest?.usedPercent, 37)
        let value = try await snapshot(store)
        XCTAssertNil(value.today.quotaConsumedPercent)
        XCTAssertNil(value.today.recordedQuotaConsumedPercent)
        try await store.close()
    }

    func testMalformedQuotaDoesNotDiscardValidTokenEvent() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(
            tokenLine(timestamp: "2026-10-22T01:00:00Z", input: 12, cached: 3, output: 2).utf8
        )) as? [String: Any])
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        payload["rate_limits"] = ["primary": ["used_percent": "bad"]]
        object["payload"] = payload
        try write([String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)], to: root)
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        XCTAssertEqual(events.first?.usage.totalTokens, 14)
        try await store.close()
    }

    func testSessionQuotaValidationAndSecondaryWindowSelection() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        for poll in try [quota(36, "2026-10-21T20:52:00+08:00"),
                         quota(38, "2026-10-22T10:13:00+08:00")] {
            try await store.save(quota: poll)
        }
        try write([
            line(-1, "2026-10-21T20:55:00+08:00"),
            line(37, "2026-10-21T21:05:00+08:00", secondary: true),
            line(99, "2026-10-22T09:00:00+08:00", limitID: "other"),
            line(39, "2026-10-22T09:30:00+08:00")
        ], to: root)
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(history.map(\.usedPercent), [36, 37, 38])
        try await store.close()
    }

    func testCachedPreviousCycleDoesNotHideRealReset() async throws {
        let root = try temporaryCodexHome()
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let reset = "2026-10-29T09:00:00+08:00"
        for poll in try [quota(36, "2026-10-21T20:52:00+08:00"),
                         quota(0, "2026-10-22T09:00:00+08:00", reset: reset),
                         quota(2, "2026-10-22T10:13:00+08:00", reset: reset)] {
            try await store.save(quota: poll)
        }
        try write([
            line(37, "2026-10-21T21:05:00+08:00"),
            line(37, "2026-10-22T09:01:00+08:00"),
            line(1, "2026-10-22T09:02:00+08:00", reset: reset)
        ], to: root)
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root, modifiedSince: .distantPast, calendar: calendar
        )
        let history = try await store.quotaHistory(from: .distantPast, to: .distantFuture, limitID: "codex")
        XCTAssertEqual(history.map(\.usedPercent), [36, 37, 0, 1, 2])
        try await store.close()
    }

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    private func quota(_ percent: Double, _ at: String, reset: String = "2026-10-27T14:41:34+08:00") throws -> QuotaSnapshot {
        let end = try date(reset)
        return QuotaSnapshot(limitID: "codex", usedPercent: percent, windowDurationMinutes: 10080,
                             startsAt: end.addingTimeInterval(-604800), resetsAt: end, fetchedAt: try date(at))
    }

    private func line(_ percent: Double, _ at: String, input: Int64? = nil,
                      secondary: Bool = false, limitID: String = "codex",
                      reset: String = "2026-10-27T14:41:34+08:00") throws -> String {
        let window: [String: Any] = ["used_percent": percent, "window_minutes": 10080,
                                     "resets_at": Int64(try date(reset).timeIntervalSince1970)]
        var payload: [String: Any] = ["type": "token_count", "info": NSNull(),
                                     "rate_limits": ["limit_id": limitID,
                                                     secondary ? "secondary" : "primary": window]]
        if let input {
            payload["info"] = ["last_token_usage": ["input_tokens": input, "cached_input_tokens": 0, "output_tokens": 0]]
        }
        let object: [String: Any] = ["timestamp": at, "type": "event_msg", "payload": payload]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func write(_ lines: [String], to root: URL) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent("sessions/usage.jsonl"))
    }

    private func snapshot(_ store: SQLiteUsageStore) async throws -> UsageSnapshot {
        let now = try date("2026-10-22T10:13:00+08:00")
        let latest = try await store.latestQuota()
        let history = try await store.quotaHistory(from: .distantPast, to: now, limitID: "codex")
        return UsageReconciler().snapshot(now: now, calendar: calendar, quota: latest,
            events: try await store.events(from: .distantPast, to: now), officialDays: [], cycles: [],
            lastUpdatedAt: now, quotaHistory: history)
    }
}
