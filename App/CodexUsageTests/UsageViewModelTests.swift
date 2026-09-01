import Foundation
import UsageCore
import XCTest
@testable import CodexUsage

enum RecordedRefreshReason: Equatable, Hashable, Sendable {
    case startup
    case scheduled
    case popoverOpened
    case wake
    case sessionFilesChanged
    case manual

    init(_ reason: RefreshReason) {
        switch reason {
        case .startup:
            self = .startup
        case .scheduled:
            self = .scheduled
        case .popoverOpened:
            self = .popoverOpened
        case .wake:
            self = .wake
        case .sessionFilesChanged:
            self = .sessionFilesChanged
        case .manual:
            self = .manual
        }
    }
}

@MainActor
final class UsageViewModelTests: XCTestCase {
    func testStartPublishesSnapshotAndResolvedHome() async throws {
        let snapshot = try sampleSnapshot(status: .calibrated)
        let fixture = ViewModelFixture(snapshot: snapshot)

        await fixture.viewModel.start()

        XCTAssertEqual(fixture.viewModel.snapshot, snapshot)
        XCTAssertFalse(fixture.viewModel.isInitialLoading)
        XCTAssertFalse(fixture.viewModel.needsCodexHomeSelection)
        XCTAssertNil(fixture.viewModel.fatalErrorMessage)
        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ 62%")
        let reasons = await fixture.service.reasons()
        XCTAssertEqual(reasons, [.startup])
        await fixture.viewModel.stop()
    }

    func testStaleSnapshotKeepsContentAndShowsCompactWarning() async throws {
        let snapshot = try sampleSnapshot(status: .stale)
        let fixture = ViewModelFixture(snapshot: snapshot)

        await fixture.viewModel.start()

        XCTAssertEqual(fixture.viewModel.snapshot, snapshot)
        XCTAssertTrue(fixture.viewModel.isStale)
        XCTAssertNil(fixture.viewModel.fatalErrorMessage)
        await fixture.viewModel.stop()
    }

    func testSQLiteFailureShowsFatalStateWithoutDeletingDatabase() async throws {
        let fixture = ViewModelFixture(
            refreshError: SQLiteStoreError.operationFailed(
                operation: "migrate",
                code: 11
            )
        )

        await fixture.viewModel.start()

        XCTAssertNil(fixture.viewModel.snapshot)
        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ !")
        XCTAssertEqual(
            fixture.viewModel.fatalErrorMessage,
            "本地用量数据库无法使用。请重试；应用不会自动删除现有数据。"
        )
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
        await fixture.viewModel.stop()
    }

    func testMissingHomeAutomaticallyAsksOnlyOnceThenKeepsGuide() async throws {
        let fixture = ViewModelFixture(resolvedHome: nil, chosenHome: nil)

        await fixture.viewModel.start()
        await fixture.viewModel.openPopover()

        XCTAssertTrue(fixture.viewModel.needsCodexHomeSelection)
        XCTAssertEqual(fixture.chooser.callCount, 1)
        await fixture.viewModel.stop()
    }

    func testExplicitActionsMapToRefreshReasonsAndNavigation() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()

        await fixture.viewModel.openPopover()
        await fixture.viewModel.handleWake()
        await fixture.viewModel.refreshManually()
        fixture.viewModel.showTrend()
        XCTAssertEqual(fixture.viewModel.page, .trend)
        fixture.viewModel.showHistory()
        XCTAssertEqual(fixture.viewModel.page, .history)
        fixture.viewModel.showOverview()

        let reasons = await fixture.service.reasons()
        XCTAssertEqual(
            reasons,
            [.startup, .popoverOpened, .wake, .manual]
        )
        XCTAssertEqual(fixture.viewModel.page, .overview)
        await fixture.viewModel.stop()
    }

    func testNonSQLiteFailureKeepsExistingSnapshot() async throws {
        let snapshot = try sampleSnapshot()
        let fixture = ViewModelFixture(snapshot: snapshot)
        await fixture.viewModel.start()
        await fixture.service.suspendNext(.manual)
        let refreshTask = Task {
            await fixture.viewModel.refreshManually()
        }
        await fixture.service.waitForReason(.manual)

        await fixture.service.resumeNext(
            .manual,
            with: .failure(FakeViewModelError.unavailable)
        )
        await refreshTask.value

        XCTAssertEqual(fixture.viewModel.snapshot, snapshot)
        XCTAssertNil(fixture.viewModel.fatalErrorMessage)
        await fixture.viewModel.stop()
    }

    func testNonSQLiteFailureWithoutSnapshotShowsNonfatalEmptyState() async {
        let fixture = ViewModelFixture(
            refreshError: FakeViewModelError.unavailable
        )

        await fixture.viewModel.start()

        XCTAssertNil(fixture.viewModel.snapshot)
        XCTAssertNil(fixture.viewModel.fatalErrorMessage)
        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ --")
        XCTAssertFalse(fixture.viewModel.isInitialLoading)
        await fixture.viewModel.stop()
    }

    func testManualRefreshPublishesRefreshingStateWhileRequestIsPending() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()
        await fixture.service.suspendNext(.manual)
        let refreshTask = Task {
            await fixture.viewModel.refreshManually()
        }
        await fixture.service.waitForReason(.manual)

        XCTAssertTrue(fixture.viewModel.isRefreshing)

        await fixture.service.resumeNext(
            .manual,
            with: .success(try sampleSnapshot(remainingPercent: 55))
        )
        await refreshTask.value
        XCTAssertFalse(fixture.viewModel.isRefreshing)
        await fixture.viewModel.stop()
    }

    func testOlderRefreshCompletingLastCannotOverwriteNewerResult() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        let older = try sampleSnapshot(remainingPercent: 70)
        let newer = try sampleSnapshot(remainingPercent: 45)
        await fixture.viewModel.start()
        await fixture.service.suspendNext(.manual)
        await fixture.service.suspendNext(.wake)

        let olderTask = Task {
            await fixture.viewModel.refreshManually()
        }
        await fixture.service.waitForReason(.manual)
        let newerTask = Task {
            await fixture.viewModel.handleWake()
        }
        await fixture.service.waitForReason(.wake)

        await fixture.service.resumeNext(.wake, with: .success(newer))
        await newerTask.value
        await fixture.service.resumeNext(.manual, with: .success(older))
        await olderTask.value

        XCTAssertEqual(fixture.viewModel.snapshot, newer)
        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ 45%")
        await fixture.viewModel.stop()
    }
}

private enum FakeViewModelError: Error, Sendable {
    case unavailable
}

private enum FakeRefreshOutcome: Sendable {
    case success(UsageSnapshot)
    case failure(any Error)

    func get() throws -> UsageSnapshot {
        switch self {
        case let .success(snapshot):
            snapshot
        case let .failure(error):
            throw error
        }
    }
}

private actor FakeUsageService: UsageServicing {
    private let defaultOutcome: FakeRefreshOutcome
    private let home: URL?
    private var recordedReasons: [RecordedRefreshReason] = []
    private var suspendedCounts: [RecordedRefreshReason: Int] = [:]
    private var pending: [RecordedRefreshReason: [CheckedContinuation<UsageSnapshot, Error>]] = [:]
    private var reasonWaiters: [RecordedRefreshReason: [CheckedContinuation<Void, Never>]] = [:]

    init(defaultOutcome: FakeRefreshOutcome, home: URL?) {
        self.defaultOutcome = defaultOutcome
        self.home = home
    }

    func refresh(reason: RefreshReason, now: Date) async throws -> UsageSnapshot {
        _ = now
        let recorded = RecordedRefreshReason(reason)
        recordedReasons.append(recorded)
        let waiters = reasonWaiters.removeValue(forKey: recorded) ?? []
        waiters.forEach { $0.resume() }

        let suspendedCount = suspendedCounts[recorded, default: 0]
        guard suspendedCount > 0 else {
            return try defaultOutcome.get()
        }
        suspendedCounts[recorded] = suspendedCount - 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[recorded, default: []].append(continuation)
        }
    }

    func processNextAccountNotification(now: Date) async throws -> UsageSnapshot? {
        _ = now
        return nil
    }

    func currentSnapshot(now: Date) async throws -> UsageSnapshot {
        _ = now
        return try defaultOutcome.get()
    }

    func resolvedCodexHome() async -> URL? {
        home
    }

    func reasons() -> [RecordedRefreshReason] {
        recordedReasons
    }

    func waitForReason(_ value: RecordedRefreshReason) async {
        if recordedReasons.contains(value) {
            return
        }
        await withCheckedContinuation { continuation in
            reasonWaiters[value, default: []].append(continuation)
        }
    }

    func suspendNext(_ reason: RecordedRefreshReason) {
        suspendedCounts[reason, default: 0] += 1
    }

    func resumeNext(
        _ reason: RecordedRefreshReason,
        with outcome: FakeRefreshOutcome
    ) {
        guard var continuations = pending[reason], !continuations.isEmpty else {
            return
        }
        let continuation = continuations.removeFirst()
        pending[reason] = continuations
        do {
            continuation.resume(returning: try outcome.get())
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

private actor FakeSessionWatcher: SessionChangeWatching {
    private var continuation: AsyncStream<Void>.Continuation?

    func changes(for directories: [URL]) async -> AsyncStream<Void> {
        _ = directories
        let pair = AsyncStream<Void>.makeStream()
        continuation = pair.continuation
        return pair.stream
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
    }
}

@MainActor
private final class FakeRuntimeBuilder: UsageRuntimeBuilding {
    let service: FakeUsageService
    let watcher: FakeSessionWatcher
    private(set) var buildCount = 0
    private(set) var stopCount = 0

    init(service: FakeUsageService, watcher: FakeSessionWatcher) {
        self.service = service
        self.watcher = watcher
    }

    func makeRuntime(codexHome: URL?) async throws -> UsageRuntime {
        _ = codexHome
        buildCount += 1
        return UsageRuntime(
            service: service,
            watcher: watcher,
            stop: { [weak self] in
                await MainActor.run {
                    self?.stopCount += 1
                }
            }
        )
    }
}

@MainActor
private final class FakeBookmarkStore: CodexHomeBookmarkStoring {
    var restoreResult: CodexHomeBookmarkRestoreResult = .needsSelection
    private(set) var savedURLs: [URL] = []
    private(set) var releaseCount = 0

    func restore() throws -> CodexHomeBookmarkRestoreResult {
        restoreResult
    }

    func save(_ url: URL) throws {
        savedURLs.append(url)
        restoreResult = .available(url.standardizedFileURL)
    }

    func clear() {
        restoreResult = .needsSelection
        releaseAccess()
    }

    func releaseAccess() {
        releaseCount += 1
    }
}

@MainActor
private final class FakeCodexHomeChooser {
    let result: URL?
    private(set) var callCount = 0

    init(result: URL?) {
        self.result = result
    }

    func choose() async -> URL? {
        callCount += 1
        return result
    }
}

@MainActor
private final class ViewModelFixture {
    let service: FakeUsageService
    let watcher: FakeSessionWatcher
    let runtimeBuilder: FakeRuntimeBuilder
    let bookmarkStore: FakeBookmarkStore
    let chooser: FakeCodexHomeChooser
    let viewModel: UsageViewModel

    init(
        snapshot: UsageSnapshot? = nil,
        refreshError: (any Error)? = nil,
        resolvedHome: URL? = URL(
            fileURLWithPath: "/tmp/fake-codex-home",
            isDirectory: true
        ),
        chosenHome: URL? = nil
    ) {
        let outcome: FakeRefreshOutcome
        if let refreshError {
            outcome = .failure(refreshError)
        } else if let snapshot {
            outcome = .success(snapshot)
        } else {
            outcome = .failure(FakeViewModelError.unavailable)
        }
        service = FakeUsageService(
            defaultOutcome: outcome,
            home: resolvedHome
        )
        watcher = FakeSessionWatcher()
        runtimeBuilder = FakeRuntimeBuilder(
            service: service,
            watcher: watcher
        )
        bookmarkStore = FakeBookmarkStore()
        chooser = FakeCodexHomeChooser(result: chosenHome)
        viewModel = UsageViewModel(
            runtimeBuilder: runtimeBuilder,
            bookmarkStore: bookmarkStore,
            chooseCodexHome: { [chooser] in
                await chooser.choose()
            },
            environment: UsageViewModelEnvironment(
                now: {
                    ISO8601DateFormatter().date(
                        from: "2026-09-01T08:00:00Z"
                    )!
                },
                sleep: { _ in }
            )
        )
    }
}
