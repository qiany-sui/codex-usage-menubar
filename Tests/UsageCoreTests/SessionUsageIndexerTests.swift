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

    func testInvalidTokenEventDoesNotAdvanceCursorOrPartiallyInsert() async throws {
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
            #"{"timestamp":"bad","type":"event_msg","payload":{"type":"token_count"}}"#
        try Data((valid + "\n" + invalid + "\n").utf8).write(to: session)
        let store = try SQLiteUsageStore(databaseURL: try temporaryDatabaseURL())
        try await store.migrate()
        let indexer = SessionUsageIndexer(store: store)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let pathHash = Data(
            SHA256.hash(data: Data(session.standardizedFileURL.path.utf8))
        )

        await XCTAssertThrowsErrorAsync(
            try await indexer.index(
                codexHome: root,
                modifiedSince: .distantPast,
                calendar: calendar
            )
        ) { error in
            XCTAssertEqual(error as? SessionParseError, .invalidTokenEvent)
        }
        let events = try await store.events(from: .distantPast, to: .distantFuture)
        let cursor = try await store.cursor(for: pathHash)

        XCTAssertEqual(events, [])
        XCTAssertNil(cursor)
    }
}
