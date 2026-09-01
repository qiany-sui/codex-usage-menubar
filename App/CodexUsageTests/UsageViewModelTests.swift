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

    func testScheduledLoopRefreshesEverySixtySeconds() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()

        try await fixture.sleeper.resumeNext(expected: .seconds(60))
        await fixture.service.waitForReason(.scheduled)

        let reasons = await fixture.service.reasons()
        XCTAssertTrue(reasons.contains(.scheduled))
        await fixture.viewModel.stop()
    }

    func testSessionChangeMapsToLocalOnlyReason() async throws {
        let codexHome = try trackedValidCodexHome()
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            resolvedHome: codexHome
        )
        await fixture.viewModel.start()

        await fixture.watcher.sendChange()
        await fixture.service.waitForReason(.sessionFilesChanged)

        let reasons = await fixture.service.reasons()
        XCTAssertEqual(reasons.last, .sessionFilesChanged)
        await fixture.viewModel.stop()
    }

    func testNotificationSnapshotPublishesWithoutFullRefresh() async throws {
        let updated = try sampleSnapshot(remainingPercent: 48)
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.service.enqueueNotification(updated)

        await fixture.viewModel.start()
        await fixture.waitUntilSnapshotEquals(updated)

        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ 48%")
        await fixture.viewModel.stop()
    }

    func testParkedNotificationPublishesAfterNewerManualRefresh() async throws {
        let manual = try sampleSnapshot(remainingPercent: 40)
        let notification = try sampleSnapshot(remainingPercent: 48)
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()
        await fixture.waitUntilNotificationCallCount(1)
        await fixture.service.suspendNext(.manual)

        let manualTask = Task {
            await fixture.viewModel.refreshManually()
        }
        await fixture.service.waitForReason(.manual)
        await fixture.service.resumeNext(.manual, with: .success(manual))
        await manualTask.value
        await fixture.service.enqueueNotification(notification)
        await fixture.waitUntilSnapshotEquals(notification)

        XCTAssertEqual(fixture.viewModel.menuBarTitle, "◔ 48%")
        await fixture.viewModel.stop()
    }

    func testStaleNotificationKeepsConsumingWithoutReconnect() async throws {
        let stale = try sampleSnapshot(
            status: .stale,
            remainingPercent: 51
        )
        let next = try sampleSnapshot(remainingPercent: 49)
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()
        await fixture.waitUntilNotificationCallCount(1)

        await fixture.service.enqueueNotification(stale)
        await fixture.waitUntilSnapshotEquals(stale)
        await fixture.waitUntilNotificationCallCount(2)

        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
        let retries = await fixture.sleeper.pendingRequestCount(
            for: .seconds(30)
        )
        XCTAssertEqual(retries, 0)

        await fixture.service.enqueueNotification(next)
        await fixture.waitUntilSnapshotEquals(next)
        await fixture.viewModel.stop()
    }

    func testNotificationEOFBacksOffThenBuildsFreshRuntime() async throws {
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            notificationResults: [nil]
        )
        await fixture.viewModel.start()
        try await fixture.sleeper.waitForRequest(.seconds(30))

        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
        try await fixture.sleeper.resumeNext(expected: .seconds(30))
        await fixture.runtimeBuilder.waitForBuildCount(2)

        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 2)
        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
        await fixture.viewModel.stop()
    }

    func testRepeatedNotificationEOFUsesCappedRefreshPolicyBackoff() async throws {
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            everyNotificationEnds: true,
            schedulerInterval: .seconds(61)
        )
        await fixture.viewModel.start()

        let expectedSeconds = [30, 60, 120, 240, 480, 900, 900]
        for (index, seconds) in expectedSeconds.enumerated() {
            try await fixture.sleeper.resumeNext(
                expected: .seconds(seconds)
            )
            await fixture.runtimeBuilder.waitForBuildCount(index + 2)
        }

        let resumed = await fixture.sleeper.resumedDurations()
        XCTAssertEqual(
            Array(resumed.suffix(expectedSeconds.count)),
            expectedSeconds.map { .seconds($0) }
        )
        await fixture.viewModel.stop()
    }

    func testStopCancelsLoopsStopsWatcherRuntimeAndBookmarkAccess() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()

        await fixture.viewModel.stop()
        await fixture.watcher.sendChange()

        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
        XCTAssertEqual(fixture.bookmarkStore.releaseCount, 1)
        let reasons = await fixture.service.reasons()
        XCTAssertEqual(reasons, [.startup])
    }

    func testWatcherConsumesEveryOutputWithoutAddingItsOwnDebounce() async throws {
        let codexHome = try trackedValidCodexHome()
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            resolvedHome: codexHome
        )
        await fixture.viewModel.start()

        await fixture.watcher.sendChange()
        await fixture.watcher.sendChange()
        await fixture.watcher.sendChange()
        await fixture.service.waitForReasonCount(
            .sessionFilesChanged,
            count: 3
        )

        let reasons = await fixture.service.reasons()
        XCTAssertEqual(
            reasons.filter { $0 == .sessionFilesChanged }.count,
            3
        )
        await fixture.viewModel.stop()
    }

    func testChoosingNewDirectoryStopsOldRuntimeBeforeStartingNewLoops() async throws {
        let oldHome = try trackedValidCodexHome()
        let newHome = try trackedValidCodexHome()
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            resolvedHome: oldHome,
            chosenHome: newHome
        )
        await fixture.viewModel.start()

        await fixture.viewModel.chooseCodexHome()

        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 2)
        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
        XCTAssertEqual(
            fixture.bookmarkStore.savedURLs,
            [newHome.standardizedFileURL]
        )
        try await fixture.sleeper.waitForRequest(.seconds(60))
        let schedulerCount = await fixture.sleeper.pendingRequestCount(
            for: .seconds(60)
        )
        XCTAssertEqual(schedulerCount, 1)
        await fixture.viewModel.stop()
    }

    func testManualRefreshRunsImmediatelyDuringNotificationBackoff() async throws {
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            notificationResults: [nil]
        )
        await fixture.viewModel.start()
        try await fixture.sleeper.waitForRequest(.seconds(30))

        await fixture.viewModel.refreshManually()

        let reasons = await fixture.service.reasons()
        XCTAssertEqual(reasons, [.startup, .manual])
        await fixture.viewModel.stop()
    }

    func testSuccessfulNotificationResetsEOFBackoff() async throws {
        let updated = try sampleSnapshot(remainingPercent: 51)
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            notificationResults: [nil]
        )
        await fixture.viewModel.start()
        try await fixture.sleeper.resumeNext(expected: .seconds(30))
        await fixture.runtimeBuilder.waitForBuildCount(2)

        await fixture.service.enqueueNotification(updated)
        await fixture.waitUntilSnapshotEquals(updated)
        await fixture.service.enqueueNotificationEOF()
        try await fixture.sleeper.resumeNext(expected: .seconds(30))

        let resumed = await fixture.sleeper.resumedDurations()
        XCTAssertEqual(Array(resumed.suffix(2)), [.seconds(30), .seconds(30)])
        await fixture.viewModel.stop()
    }

    func testNotificationSQLiteFailureWaitsForManualRuntimeRetry() async throws {
        let updated = try sampleSnapshot(remainingPercent: 47)
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()
        await fixture.waitUntilNotificationCallCount(1)

        await fixture.service.enqueueNotificationSQLiteFailure()
        await fixture.waitUntilFatalError()

        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
        let automaticRetries = await fixture.sleeper.pendingRequestCount(
            for: .seconds(30)
        )
        XCTAssertEqual(automaticRetries, 0)

        await fixture.viewModel.retryFatalError()
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 2)
        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
        await fixture.waitUntilNotificationCallCount(2)
        await fixture.service.enqueueNotification(updated)
        await fixture.waitUntilSnapshotEquals(updated)

        XCTAssertNil(fixture.viewModel.fatalErrorMessage)
        await fixture.viewModel.stop()
    }

    func testNonSQLiteNotificationFailureUsesReconnectBackoff() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        await fixture.viewModel.start()
        await fixture.waitUntilNotificationCallCount(1)

        await fixture.service.enqueueNotificationFailure()
        try await fixture.sleeper.waitForRequest(.seconds(30))
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)

        try await fixture.sleeper.resumeNext(expected: .seconds(30))
        await fixture.runtimeBuilder.waitForBuildCount(2)
        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
        await fixture.viewModel.stop()
    }

    func testStartingTwiceDoesNotDuplicateRuntimeOrScheduler() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())

        await fixture.viewModel.start()
        await fixture.viewModel.start()

        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
        try await fixture.sleeper.waitForRequest(.seconds(60))
        let schedulerCount = await fixture.sleeper.pendingRequestCount(
            for: .seconds(60)
        )
        XCTAssertEqual(schedulerCount, 1)
        await fixture.viewModel.stop()
    }

    func testStopDuringRuntimeBuildStopsLateRuntime() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        fixture.runtimeBuilder.suspendNextBuild()
        let startTask = Task {
            await fixture.viewModel.start()
        }
        await fixture.runtimeBuilder.waitForBuildCount(1)

        let stopTask = Task {
            await fixture.viewModel.stop()
        }
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        fixture.runtimeBuilder.resumeNextBuild()
        await startTask.value
        await stopTask.value

        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
        XCTAssertEqual(fixture.bookmarkStore.releaseCount, 1)
    }

    func testStopWhileChooserIsOpenDoesNotSaveOrBuild() async throws {
        let chosenHome = try trackedValidCodexHome()
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            chosenHome: chosenHome
        )
        await fixture.viewModel.start()
        fixture.chooser.suspendNextCall()
        let chooseTask = Task {
            await fixture.viewModel.chooseCodexHome()
        }
        await fixture.chooser.waitForCallCount(1)

        await fixture.viewModel.stop()
        fixture.chooser.resumeNextCall()
        await chooseTask.value

        XCTAssertTrue(fixture.bookmarkStore.savedURLs.isEmpty)
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
    }

    func testDirectoryChoiceWinsAgainstSuspendedReconnectBuild() async throws {
        let oldHome = try trackedValidCodexHome()
        let newHome = try trackedValidCodexHome()
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            resolvedHome: oldHome,
            chosenHome: newHome,
            notificationResults: [nil]
        )
        await fixture.viewModel.start()
        try await fixture.sleeper.waitForRequest(.seconds(30))
        fixture.runtimeBuilder.suspendNextBuild()
        try await fixture.sleeper.resumeNext(expected: .seconds(30))
        await fixture.runtimeBuilder.waitForBuildCount(2)

        let chooseTask = Task {
            await fixture.viewModel.chooseCodexHome()
        }
        await fixture.waitUntilSavedURLCount(1)
        for _ in 0 ..< 100 {
            await Task.yield()
        }
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 2)
        fixture.runtimeBuilder.resumeNextBuild()
        await chooseTask.value
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 3)
        await fixture.waitUntilStopCount(2)

        XCTAssertEqual(
            fixture.bookmarkStore.savedURLs,
            [newHome.standardizedFileURL]
        )
        await fixture.viewModel.stop()
        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 3)
    }

    func testDirectoryChoiceWaitsForInFlightRuntimeStop() async throws {
        let oldHome = try trackedValidCodexHome()
        let newHome = try trackedValidCodexHome()
        let fixture = ViewModelFixture(
            snapshot: try sampleSnapshot(),
            resolvedHome: oldHome,
            chosenHome: newHome,
            notificationResults: [nil]
        )
        await fixture.viewModel.start()
        try await fixture.sleeper.waitForRequest(.seconds(30))
        fixture.runtimeBuilder.suspendNextStop()
        try await fixture.sleeper.resumeNext(expected: .seconds(30))
        await fixture.runtimeBuilder.waitForStopAttemptCount(1)

        let chooseTask = Task {
            await fixture.viewModel.chooseCodexHome()
        }
        await fixture.waitUntilSavedURLCount(1)
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 1)
        fixture.runtimeBuilder.resumeNextStop()
        await chooseTask.value
        XCTAssertEqual(fixture.runtimeBuilder.buildCount, 2)
        await fixture.viewModel.stop()
    }

    func testStopWaitsForLateRuntimeBuildCleanup() async throws {
        let fixture = ViewModelFixture(snapshot: try sampleSnapshot())
        let probe = LifecycleCompletionProbe()
        fixture.runtimeBuilder.suspendNextBuild()
        let startTask = Task {
            await fixture.viewModel.start()
        }
        await fixture.runtimeBuilder.waitForBuildCount(1)
        let stopTask = Task {
            await probe.markStarted()
            await fixture.viewModel.stop()
            await probe.markCompleted()
        }
        await probe.waitUntilStarted()
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        let completedBeforeBuild = await probe.isCompleted()
        XCTAssertFalse(completedBeforeBuild)
        fixture.runtimeBuilder.resumeNextBuild()
        await startTask.value
        await stopTask.value

        let completedAfterBuild = await probe.isCompleted()
        XCTAssertTrue(completedAfterBuild)
        XCTAssertEqual(fixture.runtimeBuilder.stopCount, 1)
    }

    private func trackedValidCodexHome() throws -> URL {
        let root = try validCodexHome()
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
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

private enum FakeNotificationEvent: Sendable {
    case snapshot(UsageSnapshot)
    case end
    case sqliteFailure
    case unavailable
}

private actor FakeUsageService: UsageServicing {
    private let defaultOutcome: FakeRefreshOutcome
    private let notificationStream: AsyncStream<FakeNotificationEvent>
    private let notificationContinuation:
        AsyncStream<FakeNotificationEvent>.Continuation
    private let everyNotificationEnds: Bool
    private var home: URL?
    private var recordedReasons: [RecordedRefreshReason] = []
    private var suspendedCounts: [RecordedRefreshReason: Int] = [:]
    private var pending: [RecordedRefreshReason: [CheckedContinuation<UsageSnapshot, Error>]] = [:]
    private var reasonWaiters: [ReasonWaiter] = []
    private var notificationCallCount = 0

    init(
        defaultOutcome: FakeRefreshOutcome,
        home: URL?,
        notificationResults: [UsageSnapshot?],
        everyNotificationEnds: Bool
    ) {
        self.defaultOutcome = defaultOutcome
        self.home = home
        self.everyNotificationEnds = everyNotificationEnds
        let pair = AsyncStream<FakeNotificationEvent>.makeStream()
        notificationStream = pair.stream
        notificationContinuation = pair.continuation
        for result in notificationResults {
            if let result {
                pair.continuation.yield(.snapshot(result))
            } else {
                pair.continuation.yield(.end)
            }
        }
    }

    func refresh(reason: RefreshReason, now: Date) async throws -> UsageSnapshot {
        _ = now
        let recorded = RecordedRefreshReason(reason)
        recordedReasons.append(recorded)
        resumeSatisfiedReasonWaiters()

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
        notificationCallCount += 1
        if everyNotificationEnds {
            return nil
        }
        for await event in notificationStream {
            guard !Task.isCancelled else {
                return nil
            }
            switch event {
            case let .snapshot(snapshot):
                return snapshot
            case .end:
                return nil
            case .sqliteFailure:
                throw SQLiteStoreError.operationFailed(
                    operation: "notification",
                    code: 11
                )
            case .unavailable:
                throw FakeViewModelError.unavailable
            }
        }
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

    func notificationCalls() -> Int {
        notificationCallCount
    }

    func waitForReason(_ value: RecordedRefreshReason) async {
        await waitForReasonCount(value, count: 1)
    }

    func waitForReasonCount(
        _ value: RecordedRefreshReason,
        count: Int
    ) async {
        if recordedReasons.count(where: { $0 == value }) >= count {
            return
        }
        await withCheckedContinuation { continuation in
            reasonWaiters.append(
                ReasonWaiter(
                    reason: value,
                    count: count,
                    continuation: continuation
                )
            )
        }
    }

    func enqueueNotification(_ snapshot: UsageSnapshot) {
        notificationContinuation.yield(.snapshot(snapshot))
    }

    func enqueueNotificationEOF() {
        notificationContinuation.yield(.end)
    }

    func enqueueNotificationSQLiteFailure() {
        notificationContinuation.yield(.sqliteFailure)
    }

    func enqueueNotificationFailure() {
        notificationContinuation.yield(.unavailable)
    }

    func setResolvedCodexHome(_ url: URL?) {
        home = url
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

    private func resumeSatisfiedReasonWaiters() {
        var remaining: [ReasonWaiter] = []
        for waiter in reasonWaiters {
            let count = recordedReasons.count(where: {
                $0 == waiter.reason
            })
            if count >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        reasonWaiters = remaining
    }

    private struct ReasonWaiter {
        let reason: RecordedRefreshReason
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }
}

private actor FakeSessionWatcher: SessionChangeWatching {
    private var continuation: AsyncStream<Void>.Continuation?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var isStopped = false

    func changes(for directories: [URL]) async -> AsyncStream<Void> {
        _ = directories
        let pair = AsyncStream<Void>.makeStream()
        continuation = pair.continuation
        isStopped = false
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return pair.stream
    }

    func stop() async {
        isStopped = true
        continuation?.finish()
        continuation = nil
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func sendChange() async {
        if isStopped {
            return
        }
        if continuation == nil {
            await withCheckedContinuation { value in
                startWaiters.append(value)
            }
        }
        guard !isStopped else {
            return
        }
        continuation?.yield()
    }
}

@MainActor
private final class FakeRuntimeBuilder: UsageRuntimeBuilding {
    let service: FakeUsageService
    let watcher: FakeSessionWatcher
    private(set) var buildCount = 0
    private(set) var stopCount = 0
    private var buildWaiters: [BuildWaiter] = []
    private var suspendedBuildCount = 0
    private var pendingBuilds: [CheckedContinuation<Void, Never>] = []
    private var suspendedStopCount = 0
    private var pendingStops: [CheckedContinuation<Void, Never>] = []
    private var stopAttemptCount = 0
    private var stopAttemptWaiters: [BuildWaiter] = []

    init(service: FakeUsageService, watcher: FakeSessionWatcher) {
        self.service = service
        self.watcher = watcher
    }

    func makeRuntime(codexHome: URL?) async throws -> UsageRuntime {
        buildCount += 1
        resumeSatisfiedBuildWaiters()
        if suspendedBuildCount > 0 {
            suspendedBuildCount -= 1
            await withCheckedContinuation { continuation in
                pendingBuilds.append(continuation)
            }
        }
        if let codexHome {
            await service.setResolvedCodexHome(codexHome)
        }
        let runtimeWatcher = watcher
        return UsageRuntime(
            service: service,
            watcher: runtimeWatcher,
            stop: { [weak self] in
                await runtimeWatcher.stop()
                await self?.finishRuntimeStop()
            }
        )
    }

    func suspendNextBuild() {
        suspendedBuildCount += 1
    }

    func resumeNextBuild() {
        guard !pendingBuilds.isEmpty else {
            return
        }
        pendingBuilds.removeFirst().resume()
    }

    func suspendNextStop() {
        suspendedStopCount += 1
    }

    func resumeNextStop() {
        guard !pendingStops.isEmpty else {
            return
        }
        pendingStops.removeFirst().resume()
    }

    func waitForBuildCount(_ value: Int) async {
        if buildCount >= value {
            return
        }
        await withCheckedContinuation { continuation in
            buildWaiters.append(
                BuildWaiter(count: value, continuation: continuation)
            )
        }
    }

    func waitForStopAttemptCount(_ value: Int) async {
        if stopAttemptCount >= value {
            return
        }
        await withCheckedContinuation { continuation in
            stopAttemptWaiters.append(
                BuildWaiter(count: value, continuation: continuation)
            )
        }
    }

    private func finishRuntimeStop() async {
        stopAttemptCount += 1
        resumeSatisfiedStopAttemptWaiters()
        if suspendedStopCount > 0 {
            suspendedStopCount -= 1
            await withCheckedContinuation { continuation in
                pendingStops.append(continuation)
            }
        }
        stopCount += 1
    }

    private func resumeSatisfiedBuildWaiters() {
        var remaining: [BuildWaiter] = []
        for waiter in buildWaiters {
            if buildCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        buildWaiters = remaining
    }

    private func resumeSatisfiedStopAttemptWaiters() {
        var remaining: [BuildWaiter] = []
        for waiter in stopAttemptWaiters {
            if stopAttemptCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        stopAttemptWaiters = remaining
    }

    private struct BuildWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
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
    private var shouldSuspendNextCall = false
    private var pendingCall: CheckedContinuation<URL?, Never>?

    init(result: URL?) {
        self.result = result
    }

    func choose() async -> URL? {
        callCount += 1
        guard shouldSuspendNextCall else {
            return result
        }
        shouldSuspendNextCall = false
        return await withCheckedContinuation { continuation in
            pendingCall = continuation
        }
    }

    func suspendNextCall() {
        shouldSuspendNextCall = true
    }

    func resumeNextCall() {
        let continuation = pendingCall
        pendingCall = nil
        continuation?.resume(returning: result)
    }

    func waitForCallCount(_ expected: Int) async {
        for _ in 0 ..< 2_000 {
            if callCount >= expected, pendingCall != nil {
                return
            }
            await Task.yield()
        }
        XCTFail("等待目录选择器打开超时")
    }
}

@MainActor
private final class ViewModelFixture {
    let service: FakeUsageService
    let watcher: FakeSessionWatcher
    let runtimeBuilder: FakeRuntimeBuilder
    let bookmarkStore: FakeBookmarkStore
    let chooser: FakeCodexHomeChooser
    let sleeper: ControlledSleeper
    let viewModel: UsageViewModel

    init(
        snapshot: UsageSnapshot? = nil,
        refreshError: (any Error)? = nil,
        resolvedHome: URL? = URL(
            fileURLWithPath: "/tmp/fake-codex-home",
            isDirectory: true
        ),
        chosenHome: URL? = nil,
        notificationResults: [UsageSnapshot?] = [],
        everyNotificationEnds: Bool = false,
        schedulerInterval: Duration = .seconds(60)
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
            home: resolvedHome,
            notificationResults: notificationResults,
            everyNotificationEnds: everyNotificationEnds
        )
        watcher = FakeSessionWatcher()
        runtimeBuilder = FakeRuntimeBuilder(
            service: service,
            watcher: watcher
        )
        bookmarkStore = FakeBookmarkStore()
        chooser = FakeCodexHomeChooser(result: chosenHome)
        sleeper = ControlledSleeper()
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
                sleep: { [sleeper] duration in
                    try await sleeper.sleep(for: duration)
                },
                schedulerInterval: schedulerInterval
            )
        )
    }

    func waitUntilSnapshotEquals(_ expected: UsageSnapshot) async {
        for _ in 0 ..< 2_000 {
            if viewModel.snapshot == expected {
                return
            }
            await Task.yield()
        }
        XCTFail("等待快照发布超时")
    }

    func waitUntilNotificationCallCount(_ expected: Int) async {
        for _ in 0 ..< 2_000 {
            if await service.notificationCalls() >= expected {
                return
            }
            await Task.yield()
        }
        XCTFail("等待通知消费启动超时")
    }

    func waitUntilStopCount(_ expected: Int) async {
        for _ in 0 ..< 2_000 {
            if runtimeBuilder.stopCount >= expected {
                return
            }
            await Task.yield()
        }
        XCTFail("等待 runtime 停止超时")
    }

    func waitUntilFatalError() async {
        for _ in 0 ..< 2_000 {
            if viewModel.fatalErrorMessage != nil {
                return
            }
            await Task.yield()
        }
        XCTFail("等待数据库致命错误超时")
    }

    func waitUntilSavedURLCount(_ expected: Int) async {
        for _ in 0 ..< 2_000 {
            if bookmarkStore.savedURLs.count >= expected {
                return
            }
            await Task.yield()
        }
        XCTFail("等待目录授权保存超时")
    }
}

private actor LifecycleCompletionProbe {
    private var started = false
    private var completed = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func markCompleted() {
        completed = true
    }

    func waitUntilStarted() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func isCompleted() -> Bool {
        completed
    }
}
