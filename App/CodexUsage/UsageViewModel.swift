import AppKit
import Combine
import Foundation
import UsageCore

enum UsagePage: Hashable {
    case overview
    case trend
    case history
}

struct UsageViewModelEnvironment: Sendable {
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void
    let schedulerInterval: Duration

    static let live = UsageViewModelEnvironment(
        now: Date.init,
        sleep: { try await Task.sleep(for: $0) },
        schedulerInterval: .seconds(60)
    )
}

@MainActor
final class UsageViewModel: ObservableObject {
    static let databaseFailureMessage =
        "本地用量数据库无法使用。请重试；应用不会自动删除现有数据。"

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isInitialLoading = true
    @Published private(set) var isRefreshing = false
    @Published private(set) var needsCodexHomeSelection = false
    @Published private(set) var codexHomeSelectionMessage: String?
    @Published private(set) var fatalErrorMessage: String?
    @Published private(set) var page: UsagePage = .overview

    var isStale: Bool {
        snapshot?.status == .stale
    }

    var menuBarTitle: String {
        menuBarPresentation.title
    }

    var menuBarPresentation: MenuBarPresentation {
        MenuBarPresentation(
            remainingPercent: snapshot?.quota?.remainingPercent,
            isFatal: fatalErrorMessage != nil,
            isStale: isStale,
            lastUpdatedAt: snapshot?.quota?.fetchedAt
        )
    }

    private let runtimeBuilder: any UsageRuntimeBuilding
    private let bookmarkStore: any CodexHomeBookmarkStoring
    private let chooseCodexHomeAction: @MainActor () async -> URL?
    private let environment: UsageViewModelEnvironment
    private let refreshPolicy: RefreshPolicy

    private var runtime: UsageRuntime?
    private var currentCodexHome: URL?
    private var didStart = false
    private var didStop = false
    private var didAutomaticallyRequestSelection = false
    private var nextRefreshID = 0
    private var lastAppliedRefreshID = -1
    private var activeRefreshes: [Int: RefreshReason] = [:]
    private var runtimeID = 0
    private var lifecycleGeneration = 0
    private var notificationFailureCount = 0
    private var schedulerTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var lifecycleTransitionIsActive = false
    private var lifecycleTransitionWaiters: [
        CheckedContinuation<Void, Never>
    ] = []

    init(
        runtimeBuilder: any UsageRuntimeBuilding,
        bookmarkStore: any CodexHomeBookmarkStoring,
        chooseCodexHome: @escaping @MainActor () async -> URL?,
        environment: UsageViewModelEnvironment = .live,
        refreshPolicy: RefreshPolicy = RefreshPolicy()
    ) {
        self.runtimeBuilder = runtimeBuilder
        self.bookmarkStore = bookmarkStore
        chooseCodexHomeAction = chooseCodexHome
        self.environment = environment
        self.refreshPolicy = refreshPolicy
    }

    func start() async {
        guard !didStart, !didStop else {
            return
        }
        didStart = true

        let restoredHome: URL?
        do {
            switch try bookmarkStore.restore() {
            case let .available(url):
                restoredHome = url
            case .needsSelection:
                restoredHome = nil
            }
        } catch {
            restoredHome = nil
        }
        currentCodexHome = restoredHome

        let startGeneration = lifecycleGeneration
        await installRuntime(
            codexHome: restoredHome,
            lifecycleGeneration: startGeneration
        )

        isInitialLoading = false
        isRefreshing = !activeRefreshes.isEmpty
        guard !didStop else {
            return
        }

        var isDirectory = ObjCBool(false)
        let hasAvailableHome = currentCodexHome.map {
            FileManager.default.fileExists(
                atPath: $0.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
        } ?? false
        guard !hasAvailableHome else {
            needsCodexHomeSelection = false
            return
        }
        needsCodexHomeSelection = true
        await requestCodexHomeAutomaticallyOnce()
    }

    func openPopover() async {
        guard !didStop else {
            return
        }
        if !didStart {
            await start()
            return
        }
        // 正在进行的交互刷新会持续发布结果，重复打开无需再排一轮。
        guard !activeRefreshes.values.contains(where: {
            $0 != .scheduled && $0 != .sessionFilesChanged
        }) else { return }
        await refresh(reason: .popoverOpened)
    }

    func handleWake() async {
        guard didStart, !didStop else {
            return
        }
        await refresh(reason: .wake)
    }

    func refreshManually() async {
        guard didStart, !didStop else {
            return
        }
        await refresh(reason: .manual)
    }

    func chooseCodexHome() async {
        guard !didStop else {
            return
        }
        let chooserGeneration = lifecycleGeneration
        codexHomeSelectionMessage = nil
        guard let selectedURL = await chooseCodexHomeAction() else {
            guard
                !didStop,
                lifecycleGeneration == chooserGeneration
            else {
                return
            }
            needsCodexHomeSelection = true
            return
        }
        guard
            !didStop,
            lifecycleGeneration == chooserGeneration
        else {
            return
        }
        let codexHome = selectedURL.standardizedFileURL
        guard CodexHomeBookmarkStore.isValidCodexHome(codexHome) else {
            needsCodexHomeSelection = true
            codexHomeSelectionMessage =
                "所选文件夹不包含 sessions 或 archived_sessions，请选择 Codex Home 文件夹。"
            return
        }

        do {
            try bookmarkStore.save(codexHome)
        } catch {
            needsCodexHomeSelection = true
            codexHomeSelectionMessage =
                "无法保存所选文件夹的访问授权，请重新选择或重试。"
            return
        }

        let replacementGeneration = await stopBackgroundTasks()
        guard
            !didStop,
            lifecycleGeneration == replacementGeneration
        else {
            return
        }
        currentCodexHome = codexHome
        page = .overview
        fatalErrorMessage = nil
        notificationFailureCount = 0

        await installRuntime(
            codexHome: codexHome,
            lifecycleGeneration: replacementGeneration
        )
        if runtime != nil {
            needsCodexHomeSelection = false
        }
    }

    func retryFatalError() async {
        guard didStart, !didStop else {
            return
        }
        fatalErrorMessage = nil
        notificationFailureCount = 0
        let codexHome = currentCodexHome
        let retryGeneration = await stopBackgroundTasks()
        guard
            !didStop,
            lifecycleGeneration == retryGeneration
        else {
            return
        }
        await installRuntime(
            codexHome: codexHome,
            lifecycleGeneration: retryGeneration
        )
    }

    func showOverview() {
        page = .overview
    }

    func showTrend() {
        page = .trend
    }

    func showHistory() {
        page = .history
    }

    func stop() async {
        guard !didStop else {
            return
        }
        didStop = true
        await stopBackgroundTasks()
        bookmarkStore.releaseAccess()
    }

    private func installRuntime(
        codexHome: URL?,
        lifecycleGeneration expectedGeneration: Int
    ) async {
        await acquireLifecycleTransition()
        defer { releaseLifecycleTransition() }
        guard
            !didStop,
            lifecycleGeneration == expectedGeneration,
            runtime == nil
        else {
            return
        }
        do {
            let installedRuntime = try await runtimeBuilder.makeRuntime(
                codexHome: codexHome
            )
            guard
                !didStop,
                lifecycleGeneration == expectedGeneration,
                runtime == nil
            else {
                await installedRuntime.stop()
                return
            }
            runtimeID += 1
            let installedRuntimeID = runtimeID
            runtime = installedRuntime

            await refresh(
                reason: .startup,
                expectedRuntimeID: installedRuntimeID
            )
            guard
                !didStop,
                lifecycleGeneration == expectedGeneration,
                runtimeID == installedRuntimeID,
                runtime != nil
            else {
                return
            }

            let resolvedCodexHome = await installedRuntime.service
                .resolvedCodexHome()
            guard
                !didStop,
                lifecycleGeneration == expectedGeneration,
                runtimeID == installedRuntimeID,
                runtime != nil
            else {
                return
            }
            currentCodexHome = resolvedCodexHome ?? codexHome
            startBackgroundTasks(
                runtime: installedRuntime,
                runtimeID: installedRuntimeID,
                codexHome: currentCodexHome
            )
        } catch {
            guard
                !didStop,
                lifecycleGeneration == expectedGeneration
            else {
                return
            }
            applyRuntimeFailure(error)
        }
    }

    private func refresh(
        reason: RefreshReason,
        expectedRuntimeID: Int? = nil
    ) async {
        guard let runtime else {
            return
        }
        let requestedRuntimeID = runtimeID
        if let expectedRuntimeID,
           expectedRuntimeID != requestedRuntimeID {
            return
        }

        let requestID = takeRefreshID()
        activeRefreshes[requestID] = reason
        isRefreshing = !isInitialLoading
        defer {
            activeRefreshes[requestID] = nil
            isRefreshing = !activeRefreshes.isEmpty && !isInitialLoading
        }

        do {
            let value = try await runtime.service.refresh(
                reason: reason,
                now: environment.now(),
                onUpdate: { [weak self] value in
                    await self?.applyRefreshSnapshot(
                        value,
                        requestID: requestID,
                        runtimeID: requestedRuntimeID
                    )
                }
            )
            guard applyRefreshSnapshot(
                value,
                requestID: requestID,
                runtimeID: requestedRuntimeID
            ) else {
                return
            }
            if reason != .startup, value.status != .stale {
                notificationFailureCount = 0
            }
        } catch is CancellationError {
            return
        } catch is SQLiteStoreError {
            guard
                runtimeID == requestedRuntimeID,
                requestID >= lastAppliedRefreshID
            else {
                return
            }
            lastAppliedRefreshID = requestID
            fatalErrorMessage = Self.databaseFailureMessage
        } catch {
            guard
                runtimeID == requestedRuntimeID,
                requestID >= lastAppliedRefreshID
            else {
                return
            }
            lastAppliedRefreshID = requestID
            fatalErrorMessage = nil
        }
    }

    @discardableResult
    private func applyRefreshSnapshot(
        _ value: UsageSnapshot,
        requestID: Int,
        runtimeID expectedRuntimeID: Int
    ) -> Bool {
        guard !didStop, runtimeID == expectedRuntimeID,
              requestID >= lastAppliedRefreshID else {
            return false
        }
        lastAppliedRefreshID = requestID
        snapshot = value
        fatalErrorMessage = nil
        isInitialLoading = false
        isRefreshing = !activeRefreshes.isEmpty
        return true
    }

    private func startBackgroundTasks(
        runtime: UsageRuntime,
        runtimeID: Int,
        codexHome: URL?
    ) {
        notificationTask = Task { [weak self] in
            await self?.consumeAccountNotifications(
                runtime: runtime,
                runtimeID: runtimeID
            )
        }

        let sleep = environment.sleep
        let schedulerInterval = environment.schedulerInterval
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(schedulerInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh(
                    reason: .scheduled,
                    expectedRuntimeID: runtimeID
                )
            }
        }

        guard let codexHome else {
            return
        }
        let directories = watchedDirectories(for: codexHome)
        guard !directories.isEmpty else {
            return
        }
        watcherTask = Task { [weak self] in
            let changes = await runtime.watcher.changes(
                for: directories
            )
            for await _ in changes {
                guard !Task.isCancelled else {
                    return
                }
                await self?.refresh(
                    reason: .sessionFilesChanged,
                    expectedRuntimeID: runtimeID
                )
            }
        }
    }

    private func consumeAccountNotifications(
        runtime: UsageRuntime,
        runtimeID: Int
    ) async {
        while !Task.isCancelled {
            do {
                let value = try await runtime.service
                    .processNextAccountNotification(now: environment.now)
                guard !Task.isCancelled, self.runtimeID == runtimeID else {
                    return
                }
                guard let value else {
                    scheduleNotificationReconnect(runtimeID: runtimeID)
                    return
                }

                let requestID = takeRefreshID()
                if requestID >= lastAppliedRefreshID {
                    lastAppliedRefreshID = requestID
                    snapshot = value
                    fatalErrorMessage = nil
                }
                notificationFailureCount = 0
            } catch is CancellationError {
                return
            } catch is SQLiteStoreError {
                guard self.runtimeID == runtimeID else {
                    return
                }
                let requestID = takeRefreshID()
                if requestID >= lastAppliedRefreshID {
                    lastAppliedRefreshID = requestID
                    fatalErrorMessage = Self.databaseFailureMessage
                }
                return
            } catch {
                guard self.runtimeID == runtimeID else {
                    return
                }
                scheduleNotificationReconnect(runtimeID: runtimeID)
                return
            }
        }
    }

    private func scheduleNotificationReconnect(runtimeID: Int) {
        guard
            !didStop,
            self.runtimeID == runtimeID,
            retryTask == nil
        else {
            return
        }

        let delay = refreshPolicy.retryDelay(
            consecutiveFailures: notificationFailureCount
        )
        notificationFailureCount += 1
        let sleep = environment.sleep
        retryTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.rebuildRuntimeAfterNotificationFailure(
                runtimeID: runtimeID
            )
        }
    }

    private func rebuildRuntimeAfterNotificationFailure(
        runtimeID: Int
    ) async {
        guard !didStop, self.runtimeID == runtimeID else {
            return
        }
        retryTask = nil
        let codexHome = currentCodexHome
        let replacementGeneration = await stopBackgroundTasks()
        guard
            !didStop,
            lifecycleGeneration == replacementGeneration
        else {
            return
        }
        await installRuntime(
            codexHome: codexHome,
            lifecycleGeneration: replacementGeneration
        )
    }

    @discardableResult
    private func stopBackgroundTasks() async -> Int {
        await acquireLifecycleTransition()
        defer { releaseLifecycleTransition() }
        lifecycleGeneration += 1
        let stoppingGeneration = lifecycleGeneration
        let tasks = [
            schedulerTask,
            watcherTask,
            notificationTask,
            retryTask
        ].compactMap { $0 }
        schedulerTask = nil
        watcherTask = nil
        notificationTask = nil
        retryTask = nil
        tasks.forEach { $0.cancel() }

        let oldRuntime = runtime
        runtime = nil
        runtimeID += 1
        activeRefreshes.removeAll()
        isRefreshing = false
        await oldRuntime?.stop()
        for task in tasks {
            await task.value
        }
        return stoppingGeneration
    }

    private func acquireLifecycleTransition() async {
        guard lifecycleTransitionIsActive else {
            lifecycleTransitionIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            lifecycleTransitionWaiters.append(continuation)
        }
    }

    private func releaseLifecycleTransition() {
        guard !lifecycleTransitionWaiters.isEmpty else {
            lifecycleTransitionIsActive = false
            return
        }
        lifecycleTransitionWaiters.removeFirst().resume()
    }

    private func watchedDirectories(for codexHome: URL) -> [URL] {
        ["sessions", "archived_sessions"]
            .map {
                codexHome.appendingPathComponent(
                    $0,
                    isDirectory: true
                )
            }
            .filter { url in
                var isDirectory = ObjCBool(false)
                return FileManager.default.fileExists(
                    atPath: url.path,
                    isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }
    }

    private func takeRefreshID() -> Int {
        defer { nextRefreshID += 1 }
        return nextRefreshID
    }

    private func requestCodexHomeAutomaticallyOnce() async {
        guard !didAutomaticallyRequestSelection else {
            return
        }
        didAutomaticallyRequestSelection = true
        await chooseCodexHome()
    }

    private func applyRuntimeFailure(_ error: any Error) {
        if error is SQLiteStoreError {
            fatalErrorMessage = Self.databaseFailureMessage
        }
    }
}
