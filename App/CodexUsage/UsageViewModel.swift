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

    static let live = UsageViewModelEnvironment(
        now: Date.init,
        sleep: { try await Task.sleep(for: $0) }
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
    @Published private(set) var fatalErrorMessage: String?
    @Published private(set) var page: UsagePage = .overview

    var isStale: Bool {
        snapshot?.status == .stale
    }

    var menuBarTitle: String {
        UsageFormatters.menuBarTitle(
            remainingPercent: snapshot?.quota?.remainingPercent,
            isFatal: fatalErrorMessage != nil
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
    private var activeRefreshCount = 0

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

        do {
            runtime = try await runtimeBuilder.makeRuntime(
                codexHome: restoredHome
            )
            await refresh(reason: .startup)
            if let runtime {
                currentCodexHome = await runtime.service.resolvedCodexHome()
                    ?? restoredHome
            }
        } catch {
            applyRuntimeFailure(error)
        }

        isInitialLoading = false
        isRefreshing = activeRefreshCount > 0

        guard currentCodexHome == nil, snapshot == nil else {
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
        guard let selectedURL = await chooseCodexHomeAction() else {
            needsCodexHomeSelection = true
            return
        }
        let codexHome = selectedURL.standardizedFileURL
        guard CodexHomeBookmarkStore.isValidCodexHome(codexHome) else {
            needsCodexHomeSelection = true
            return
        }

        do {
            try bookmarkStore.save(codexHome)
        } catch {
            needsCodexHomeSelection = true
            return
        }

        let oldRuntime = runtime
        runtime = nil
        await oldRuntime?.stop()
        currentCodexHome = codexHome
        page = .overview
        fatalErrorMessage = nil

        do {
            runtime = try await runtimeBuilder.makeRuntime(
                codexHome: codexHome
            )
            needsCodexHomeSelection = false
            await refresh(reason: .startup)
            if let runtime {
                currentCodexHome = await runtime.service.resolvedCodexHome()
                    ?? codexHome
            }
        } catch {
            applyRuntimeFailure(error)
        }
    }

    func retryFatalError() async {
        guard didStart, !didStop else {
            return
        }
        fatalErrorMessage = nil
        if runtime != nil {
            await refresh(reason: .manual)
            return
        }

        do {
            runtime = try await runtimeBuilder.makeRuntime(
                codexHome: currentCodexHome
            )
            await refresh(reason: .startup)
        } catch {
            applyRuntimeFailure(error)
        }
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
        let oldRuntime = runtime
        runtime = nil
        await oldRuntime?.stop()
        bookmarkStore.releaseAccess()
    }

    private func refresh(reason: RefreshReason) async {
        guard let runtime else {
            return
        }

        let requestID = nextRefreshID
        nextRefreshID += 1
        activeRefreshCount += 1
        isRefreshing = !isInitialLoading
        defer {
            activeRefreshCount -= 1
            isRefreshing = activeRefreshCount > 0 && !isInitialLoading
        }

        do {
            let value = try await runtime.service.refresh(
                reason: reason,
                now: environment.now()
            )
            guard requestID >= lastAppliedRefreshID else {
                return
            }
            lastAppliedRefreshID = requestID
            snapshot = value
            fatalErrorMessage = nil
        } catch is CancellationError {
            return
        } catch is SQLiteStoreError {
            guard requestID >= lastAppliedRefreshID else {
                return
            }
            lastAppliedRefreshID = requestID
            fatalErrorMessage = Self.databaseFailureMessage
        } catch {
            guard requestID >= lastAppliedRefreshID else {
                return
            }
            lastAppliedRefreshID = requestID
            fatalErrorMessage = nil
        }
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
