import Foundation
import XCTest
@testable import CodexUsage

@MainActor
final class CodexHomeBookmarkStoreTests: XCTestCase {
    func testSaveRejectsDirectoryWithoutSessionRoots() throws {
        let root = try trackedTemporaryAppDirectory()
        let store = makeBookmarkStore()

        XCTAssertThrowsError(try store.save(root)) { error in
            XCTAssertEqual(
                error as? CodexHomeBookmarkError,
                .invalidCodexHome
            )
        }
    }

    func testDirectoryWithEitherSupportedSessionRootIsValid() throws {
        let sessionsHome = try trackedTemporaryAppDirectory()
        try FileManager.default.createDirectory(
            at: sessionsHome.appendingPathComponent("sessions"),
            withIntermediateDirectories: true
        )
        let archivedHome = try trackedTemporaryAppDirectory()
        try FileManager.default.createDirectory(
            at: archivedHome.appendingPathComponent("archived_sessions"),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(CodexHomeBookmarkStore.isValidCodexHome(sessionsHome))
        XCTAssertTrue(CodexHomeBookmarkStore.isValidCodexHome(archivedHome))
    }

    func testRestoreReturnsSavedURLAndStartsScopedAccess() throws {
        let root = try trackedValidCodexHome()
        var startedURL: URL?
        let store = makeBookmarkStore(
            encode: { _ in Data("bookmark".utf8) },
            resolve: { _ in (root, false) },
            startAccess: { url in
                startedURL = url
                return true
            }
        )
        try store.save(root)

        XCTAssertEqual(
            try store.restore(),
            .available(root.standardizedFileURL)
        )
        XCTAssertEqual(startedURL, root.standardizedFileURL)
    }

    func testStaleBookmarkIsRemovedAndRequestsSelectionAgain() throws {
        let root = try trackedValidCodexHome()
        let defaults = isolatedDefaults()
        defaults.set(Data("stale".utf8), forKey: "codexHomeBookmark")
        let store = makeBookmarkStore(
            defaults: defaults,
            resolve: { _ in (root, true) }
        )

        XCTAssertEqual(try store.restore(), .needsSelection)
        XCTAssertNil(defaults.data(forKey: "codexHomeBookmark"))
    }

    func testReleaseStopsOnlyAccessStartedByStore() throws {
        let root = try trackedValidCodexHome()
        var stoppedURL: URL?
        let store = makeBookmarkStore(
            resolve: { _ in (root, false) },
            startAccess: { _ in true },
            stopAccess: { stoppedURL = $0 }
        )
        try store.save(root)
        _ = try store.restore()

        store.releaseAccess()

        XCTAssertEqual(stoppedURL, root.standardizedFileURL)
    }

    func testDamagedBookmarkIsRemovedAndRequestsSelectionAgain() throws {
        enum DamagedBookmark: Error { case unreadable }

        let defaults = isolatedDefaults()
        defaults.set(Data("damaged".utf8), forKey: "codexHomeBookmark")
        let store = makeBookmarkStore(
            defaults: defaults,
            resolve: { _ in throw DamagedBookmark.unreadable }
        )

        XCTAssertEqual(try store.restore(), .needsSelection)
        XCTAssertNil(defaults.data(forKey: "codexHomeBookmark"))
    }

    func testResolvedDirectoryWithoutSessionRootsIsRemoved() throws {
        let root = try trackedTemporaryAppDirectory()
        let defaults = isolatedDefaults()
        defaults.set(Data("bookmark".utf8), forKey: "codexHomeBookmark")
        var didStartAccess = false
        let store = makeBookmarkStore(
            defaults: defaults,
            resolve: { _ in (root, false) },
            startAccess: { _ in
                didStartAccess = true
                return true
            }
        )

        XCTAssertEqual(try store.restore(), .needsSelection)
        XCTAssertFalse(didStartAccess)
        XCTAssertNil(defaults.data(forKey: "codexHomeBookmark"))
    }

    func testRepeatedReleaseDoesNotStopAccessTwice() throws {
        let root = try trackedValidCodexHome()
        var stopCount = 0
        let store = makeBookmarkStore(
            resolve: { _ in (root, false) },
            startAccess: { _ in true },
            stopAccess: { _ in stopCount += 1 }
        )
        try store.save(root)
        _ = try store.restore()

        store.releaseAccess()
        store.releaseAccess()

        XCTAssertEqual(stopCount, 1)
    }

    private func makeBookmarkStore(
        defaults: UserDefaults? = nil,
        encode: @escaping (URL) throws -> Data = {
            Data($0.path.utf8)
        },
        resolve: @escaping (Data) throws -> (url: URL, isStale: Bool) = {
            (
                URL(
                    fileURLWithPath: String(decoding: $0, as: UTF8.self),
                    isDirectory: true
                ),
                false
            )
        },
        startAccess: @escaping (URL) -> Bool = { _ in false },
        stopAccess: @escaping (URL) -> Void = { _ in }
    ) -> CodexHomeBookmarkStore {
        CodexHomeBookmarkStore(
            defaults: defaults ?? isolatedDefaults(),
            key: "codexHomeBookmark",
            encode: encode,
            resolve: resolve,
            startAccess: startAccess,
            stopAccess: stopAccess
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CodexHomeBookmarkStoreTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func trackedTemporaryAppDirectory() throws -> URL {
        let url = try temporaryAppDirectory()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func trackedValidCodexHome() throws -> URL {
        let root = try validCodexHome()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
