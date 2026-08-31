import CryptoKit
import Foundation
import XCTest
@testable import UsageCore

final class SessionUsageIndexerTests: XCTestCase {
    func testResolverPrefersInitializedAbsoluteDirectoryThenEnvironment() throws {
        let root = try temporaryDirectory()
        let initialized = root.appendingPathComponent("initialized")
        let environment = root.appendingPathComponent("environment")
        try FileManager.default.createDirectory(
            at: initialized,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: environment,
            withIntermediateDirectories: true
        )

        let selected = CodexHomeResolver().resolve(
            initializedHome: initialized
                .appendingPathComponent("..")
                .appendingPathComponent("initialized")
                .path,
            environment: ["CODEX_HOME": environment.path],
            homeDirectory: root
        )

        XCTAssertEqual(selected, initialized.standardizedFileURL)
    }

    func testResolverFallsBackToEnvironmentWhenInitializedPathIsUnsafe() throws {
        let root = try temporaryDirectory()
        let environment = root.appendingPathComponent("environment")
        try FileManager.default.createDirectory(
            at: environment,
            withIntermediateDirectories: true
        )

        let selected = CodexHomeResolver().resolve(
            initializedHome: "relative/path",
            environment: ["CODEX_HOME": environment.path],
            homeDirectory: root
        )

        XCTAssertEqual(selected, environment.standardizedFileURL)
    }

    func testResolverRejectsRelativeMissingAndNonDirectoryCandidates() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)

        let selected = CodexHomeResolver().resolve(
            initializedHome: file.path,
            environment: ["CODEX_HOME": root.appendingPathComponent("missing").path],
            homeDirectory: root.appendingPathComponent("missing-home")
        )

        XCTAssertNil(selected)
    }

    func testResolverFallsBackToExistingHomeCodexDirectory() throws {
        let root = try temporaryDirectory()
        let fallback = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(
            at: fallback,
            withIntermediateDirectories: true
        )

        let selected = CodexHomeResolver().resolve(
            initializedHome: nil,
            environment: [:],
            homeDirectory: root
        )

        XCTAssertEqual(selected, fallback.standardizedFileURL)
    }

    func testScannerReturnsOnlySortedRecentRegularJSONLFilesWithoutFollowingSymlinks() throws {
        let root = try temporaryCodexHome()
        let sessions = root.appendingPathComponent("sessions")
        let archived = root.appendingPathComponent("archived_sessions")
        let nested = sessions.appendingPathComponent("nested")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        let active = nested.appendingPathComponent("active.jsonl")
        let archivedFile = archived.appendingPathComponent("archived.jsonl")
        let old = sessions.appendingPathComponent("old.jsonl")
        let wrongExtension = sessions.appendingPathComponent("session.txt")
        let outside = root.appendingPathComponent("outside.jsonl")
        for url in [active, archivedFile, old, wrongExtension, outside] {
            try Data("{}\n".utf8).write(to: url)
        }
        let cutoff = Date(timeIntervalSince1970: 1_788_148_800)
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff],
            ofItemAtPath: active.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(1)],
            ofItemAtPath: archivedFile.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: cutoff.addingTimeInterval(-1)],
            ofItemAtPath: old.path
        )
        let linkedFile = sessions.appendingPathComponent("linked.jsonl")
        try FileManager.default.createSymbolicLink(
            at: linkedFile,
            withDestinationURL: outside
        )
        let externalDirectory = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(
            to: externalDirectory.appendingPathComponent("linked-child.jsonl")
        )
        try FileManager.default.createSymbolicLink(
            at: sessions.appendingPathComponent("linked-directory"),
            withDestinationURL: externalDirectory
        )

        let files = try SessionFileScanner().files(
            in: root,
            modifiedSince: cutoff
        )

        XCTAssertEqual(
            files,
            [active, archivedFile]
                .map(\.standardizedFileURL)
                .sorted { $0.path < $1.path }
        )
    }

    func testScannerTreatsMissingRootsAsEmptyAndRejectsNonFiniteCutoff() throws {
        let root = try temporaryDirectory()

        XCTAssertEqual(
            try SessionFileScanner().files(
                in: root,
                modifiedSince: .distantPast
            ),
            []
        )
        XCTAssertThrowsError(
            try SessionFileScanner().files(
                in: root,
                modifiedSince: Date(timeIntervalSince1970: .nan)
            )
        )
    }

    func testIndexerCommitsOnlyCompleteLinesAndIsIdempotent() async throws {
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("rollout.jsonl")
        let complete = tokenLine(
            timestamp: "2026-08-31T18:00:00.000Z",
            input: 100,
            cached: 40,
            output: 20
        )
        let partial = tokenLine(
            timestamp: "2026-08-31T18:01:00.000Z",
            input: 30,
            cached: 10,
            output: 5
        )
        try Data((complete + "\n" + partial).utf8).write(to: session)
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let first = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let pathHash = Data(
            SHA256.hash(data: Data(session.standardizedFileURL.path.utf8))
        )
        let firstCursor = try await store.cursor(for: pathHash)
        let handle = try FileHandle(forWritingTo: session)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let second = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let third = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)

        XCTAssertEqual(first.insertedEventCount, 1)
        XCTAssertEqual(firstCursor?.committedOffset, Int64(complete.utf8.count + 1))
        XCTAssertEqual(second.insertedEventCount, 1)
        XCTAssertEqual(third.insertedEventCount, 0)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.localDay), [
            LocalDay(year: 2026, month: 9, day: 1),
            LocalDay(year: 2026, month: 9, day: 1)
        ])
    }

    func testTruncatedFileRestartsAtZeroWithoutLosingNewEvent() async throws {
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("truncated.jsonl")
        try Data(
            (
                tokenLine(
                    timestamp: "2026-08-31T01:00:00.000Z",
                    input: 1_000,
                    cached: 400,
                    output: 200
                ) + "\n"
            ).utf8
        ).write(to: session)
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        try Data(
            (
                tokenLine(
                    timestamp: "2026-08-31T01:01:00.000Z",
                    input: 5,
                    cached: 2,
                    output: 1
                ) + "\n"
            ).utf8
        ).write(to: session, options: .atomic)

        let result = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)

        XCTAssertEqual(result.insertedEventCount, 1)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.usage.inputTokens, 5)
    }

    func testSameIdentityShorterFileRestartsAtZero() async throws {
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("same-inode.jsonl")
        let longLine = tokenLine(
            timestamp: "2026-08-31T01:00:00.000Z",
            input: 100_000,
            cached: 40_000,
            output: 20_000
        ) + "\n"
        let shortLine = tokenLine(
            timestamp: "2026-08-31T01:01:00.000Z",
            input: 5,
            cached: 2,
            output: 1
        ) + "\n"
        try Data(longLine.utf8).write(to: session)
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let pathHash = Data(
            SHA256.hash(data: Data(session.standardizedFileURL.path.utf8))
        )
        let beforeCursor = try await store.cursor(for: pathHash)
        let before = try XCTUnwrap(beforeCursor)
        try Data(shortLine.utf8).write(to: session)

        let result = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let afterCursor = try await store.cursor(for: pathHash)
        let after = try XCTUnwrap(afterCursor)
        let events = try await store.events(from: .distantPast, to: .distantFuture)

        XCTAssertEqual(before.deviceID, after.deviceID)
        XCTAssertEqual(before.inode, after.inode)
        XCTAssertEqual(result.insertedEventCount, 1)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.usage.inputTokens, 5)
    }

    func testRewriteDuringSnapshotIsDiscardedThenRetriedFromZero() async throws {
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("rewritten-during-read.jsonl")
        let original = tokenLine(
            timestamp: "2026-08-31T01:00:00.000Z",
            input: 100,
            cached: 40,
            output: 20
        ) + "\n"
        let placeholder = tokenLine(
            timestamp: "2026-08-31T01:01:00.000Z",
            input: 200,
            cached: 80,
            output: 40
        ) + "\n"
        let secondPlaceholder = tokenLine(
            timestamp: "2026-08-31T01:02:00.000Z",
            input: 500,
            cached: 50,
            output: 90
        ) + "\n"
        let replacementPrefix = tokenLine(
            timestamp: "2026-08-31T02:00:00.000Z",
            input: 300,
            cached: 90,
            output: 60
        ) + "\n"
        let replacementTail = tokenLine(
            timestamp: "2026-08-31T02:01:00.000Z",
            input: 400,
            cached: 80,
            output: 80
        ) + "\n"
        XCTAssertEqual(original.utf8.count, replacementPrefix.utf8.count)
        XCTAssertEqual(placeholder.utf8.count, replacementTail.utf8.count)
        XCTAssertEqual(secondPlaceholder.utf8.count, original.utf8.count)
        try Data(original.utf8).write(to: session)
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let pathHash = Data(
            SHA256.hash(data: Data(session.standardizedFileURL.path.utf8))
        )
        let originalCursorValue = try await store.cursor(for: pathHash)
        let originalCursor = try XCTUnwrap(originalCursorValue)
        let initialContents = original + placeholder + secondPlaceholder
        try Data(initialContents.utf8).write(to: session)
        let replacementContents = replacementPrefix + replacementTail + original
        let mutation = OneShotSessionMutation { url in
            try Data(replacementContents.utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
                ofItemAtPath: url.path
            )
        }
        let indexer = SessionUsageIndexer(
            store: store,
            beforeSnapshotRead: mutation.run
        )

        let unstable = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let cursorAfterUnstable = try await store.cursor(for: pathHash)
        let restartedIndexer = SessionUsageIndexer(store: store)
        let retry = try await restartedIndexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let stableRepeat = try await restartedIndexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)

        XCTAssertEqual(unstable.insertedEventCount, 0)
        XCTAssertEqual(cursorAfterUnstable?.pathHash, originalCursor.pathHash)
        XCTAssertEqual(cursorAfterUnstable?.deviceID, originalCursor.deviceID)
        XCTAssertEqual(cursorAfterUnstable?.inode, originalCursor.inode)
        XCTAssertEqual(cursorAfterUnstable?.committedOffset, 0)
        XCTAssertNil(cursorAfterUnstable?.counterState.previousTotal)
        XCTAssertEqual(retry.insertedEventCount, 2)
        XCTAssertEqual(stableRepeat.insertedEventCount, 0)
        XCTAssertEqual(events.map(\.usage.inputTokens), [100, 300, 400])
    }

    func testRecoveryCursorFailureThrowsBeforeSnapshotRead() async throws {
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("recovery-failure.jsonl")
        let firstLine = tokenLine(
            timestamp: "2026-08-31T01:00:00.000Z",
            input: 100,
            cached: 40,
            output: 20
        ) + "\n"
        let secondLine = tokenLine(
            timestamp: "2026-08-31T01:01:00.000Z",
            input: 200,
            cached: 80,
            output: 40
        ) + "\n"
        try Data(firstLine.utf8).write(to: session)
        let databaseURL = try temporaryDatabaseURL()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = try await SessionUsageIndexer(store: store).index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let stableContents = firstLine + secondLine
        try Data(stableContents.utf8).write(to: session)
        do {
            let fixture = try SQLiteConnection(databaseURL: databaseURL)
            try fixture.execute(
                """
                CREATE TRIGGER reject_recovery_cursor
                BEFORE UPDATE ON file_cursors
                BEGIN
                  SELECT RAISE(ABORT, 'reject recovery cursor');
                END;
                """,
                operation: "test fixture"
            )
        }
        let indexer = SessionUsageIndexer(
            store: store,
            beforeSnapshotRead: { url in
                try Data("hook-ran".utf8).write(to: url)
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await indexer.index(
                codexHome: root,
                modifiedSince: .distantPast,
                calendar: calendar
            )
        ) { error in
            XCTAssertNotNil(error as? SQLiteStoreError)
        }
        let remainingContents = try Data(contentsOf: session)

        XCTAssertEqual(remainingContents, Data(stableContents.utf8))
    }

    func testArchivedReplayDoesNotIncreaseEventCount() async throws {
        let root = try temporaryCodexHome()
        let line = tokenLine(
            timestamp: "2026-08-31T01:00:00.000Z",
            input: 100,
            cached: 40,
            output: 20
        ) + "\n"
        try Data(line.utf8).write(
            to: root
                .appendingPathComponent("sessions")
                .appendingPathComponent("active.jsonl")
        )
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        _ = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        try Data(line.utf8).write(
            to: root
                .appendingPathComponent("archived_sessions")
                .appendingPathComponent("archived.jsonl")
        )

        let replay = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)

        XCTAssertEqual(replay.scannedFileCount, 2)
        XCTAssertEqual(replay.insertedEventCount, 0)
        XCTAssertEqual(events.count, 1)
    }

    func testInvalidTokenLineIsSkippedWithoutBlockingLaterValidEvent() async throws {
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("invalid.jsonl")
        let valid = tokenLine(
            timestamp: "2026-08-31T01:00:00.000Z",
            input: 100,
            cached: 40,
            output: 20
        )
        let invalid =
            #"{"timestamp":"bad","type":"event_msg","private_message":"do-not-store","payload":{"type":"token_count"}}"#
        let contents = invalid + "\n" + valid + "\n"
        try Data(contents.utf8).write(to: session)
        let databaseURL = try temporaryDatabaseURL()
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let pathHash = Data(
            SHA256.hash(data: Data(session.standardizedFileURL.path.utf8))
        )

        let first = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let second = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        let cursor = try await store.cursor(for: pathHash)

        XCTAssertEqual(first.insertedEventCount, 1)
        XCTAssertEqual(second.insertedEventCount, 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.usage.inputTokens, 100)
        XCTAssertEqual(cursor?.committedOffset, Int64(contents.utf8.count))
        var databaseBytes = try Data(contentsOf: databaseURL)
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        if FileManager.default.fileExists(atPath: walURL.path) {
            databaseBytes.append(try Data(contentsOf: walURL))
        }
        XCTAssertNil(databaseBytes.range(of: Data("do-not-store".utf8)))
    }

    func testInvalidAccumulatorLineDoesNotPolluteStateOrBlockLaterDelta() async throws {
        let root = try temporaryCodexHome()
        let session = root
            .appendingPathComponent("sessions")
            .appendingPathComponent("invalid-delta.jsonl")
        let lines = [
            totalTokenLine(
                timestamp: "2026-08-31T01:00:00.000Z",
                input: 100,
                cached: 90,
                output: 10
            ),
            totalTokenLine(
                timestamp: "2026-08-31T01:01:00.000Z",
                input: 110,
                cached: 105,
                output: 11
            ),
            totalTokenLine(
                timestamp: "2026-08-31T01:02:00.000Z",
                input: 120,
                cached: 100,
                output: 12
            )
        ]
        let contents = lines.joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: session)
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let pathHash = Data(
            SHA256.hash(data: Data(session.standardizedFileURL.path.utf8))
        )

        let first = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let second = try await indexer.index(
            codexHome: root,
            modifiedSince: .distantPast,
            calendar: calendar
        )
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        let cursor = try await store.cursor(for: pathHash)

        XCTAssertEqual(first.insertedEventCount, 2)
        XCTAssertEqual(second.insertedEventCount, 0)
        XCTAssertEqual(events.map(\.usage), [
            TokenBreakdown(inputTokens: 100, cachedInputTokens: 90, outputTokens: 10),
            TokenBreakdown(inputTokens: 20, cachedInputTokens: 10, outputTokens: 2)
        ])
        XCTAssertEqual(cursor?.committedOffset, Int64(contents.utf8.count))
    }
}

private func totalTokenLine(
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
                "total_token_usage": [
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

private final class OneShotSessionMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var hasRun = false
    private let action: @Sendable (URL) throws -> Void

    init(action: @escaping @Sendable (URL) throws -> Void) {
        self.action = action
    }

    func run(url: URL) throws {
        lock.lock()
        let shouldRun = !hasRun
        hasRun = true
        lock.unlock()
        if shouldRun {
            try action(url)
        }
    }
}
