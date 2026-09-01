import Foundation

public protocol AccountUsageReading: Actor {
    func initialize() async throws -> InitializeResult
    func readRateLimits() async throws -> RateLimitsResponse
    func readAccountUsage() async throws -> AccountUsageResponse
    func nextNotification() async -> AppServerNotification?
}

public protocol SessionUsageIndexing: Actor {
    func index(
        codexHome: URL,
        modifiedSince: Date,
        calendar: Calendar
    ) async throws -> SessionIndexResult
}

extension CodexAppServerClient: AccountUsageReading {}
extension SessionUsageIndexer: SessionUsageIndexing {}

public actor UsageService {
    private let accountClient: any AccountUsageReading
    private let indexer: any SessionUsageIndexing
    private let store: any UsageStore
    private let environment: [String: String]
    private let homeDirectory: URL
    private let calendar: Calendar
    private let policy: RefreshPolicy
    private let homeResolver = CodexHomeResolver()
    private let quotaSelector = WeeklyQuotaSelector()
    private let cycleTracker = CycleTracker()
    private let reconciler = UsageReconciler()

    private var didMigrate = false
    private var didInitialize = false
    private var initializedHome: String?
    private var lastFullRateLimits: RateLimitsResponse?
    private var lastBuiltSnapshot: UsageSnapshot?
    private var lastSessionIndexAttemptAt: Date?
    private var operationIsLocked = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var notificationConsumerIsLocked = false
    private var notificationConsumerWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        accountClient: any AccountUsageReading,
        indexer: any SessionUsageIndexing,
        store: any UsageStore,
        environment: [String: String],
        homeDirectory: URL,
        calendar: Calendar,
        policy: RefreshPolicy = RefreshPolicy()
    ) {
        self.accountClient = accountClient
        self.indexer = indexer
        self.store = store
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.calendar = calendar
        self.policy = policy
    }

    public func refresh(
        reason: RefreshReason,
        now: Date
    ) async throws -> UsageSnapshot {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await refreshLocked(reason: reason, now: now)
    }

    private func refreshLocked(
        reason: RefreshReason,
        now: Date
    ) async throws -> UsageSnapshot {
        try await migrateIfNeeded()
        let wasInitialized = didInitialize
        var refreshState = try await store.refreshState()
        let previousFailureCount = refreshState.consecutiveFailureCount
        var operationHadFailure = false

        if !didInitialize {
            do {
                let result = try await accountClient.initialize()
                initializedHome = result.codexHome
                didInitialize = true
                refreshState = recordingSuccess(
                    .accountInitialization,
                    in: refreshState
                )
            } catch {
                operationHadFailure = true
                refreshState = recordingFailure(
                    .accountInitialization,
                    in: refreshState
                )
            }
        }

        let decision = policy.decision(
            now: now,
            reason: reason,
            lastQuotaRefresh: refreshState.lastSuccessfulQuotaRefreshAt,
            lastOfficialRefresh: refreshState.lastSuccessfulOfficialUsageRefreshAt,
            consecutiveFailures: refreshState.consecutiveFailureCount
        )
        let cachedQuotaHasReset = lastBuiltSnapshot?.quota.map {
            now >= $0.resetsAt
        } ?? false
        let shouldRefreshQuota = decision.refreshQuota || cachedQuotaHasReset
        let shouldIndexSessions = decision.indexSessions
            || shouldRunScheduledSessionFallback(reason: reason, now: now)
        if wasInitialized,
           !shouldRefreshQuota,
           !decision.refreshOfficialUsage,
           !shouldIndexSessions,
           let lastBuiltSnapshot,
           canReuse(lastBuiltSnapshot, now: now) {
            return lastBuiltSnapshot
        }

        if shouldRefreshQuota, didInitialize {
            let response: RateLimitsResponse?
            do {
                response = try await accountClient.readRateLimits()
            } catch {
                response = nil
                operationHadFailure = true
                refreshState = recordingFailure(.rateLimits, in: refreshState)
            }
            if let response {
                lastFullRateLimits = response
                if let quota = quotaSelector.select(
                    from: response,
                    fetchedAt: now
                ) {
                    try await store.save(quota: quota)
                    refreshState = recordingSuccess(
                        .rateLimits,
                        in: refreshState,
                        at: now
                    )
                } else {
                    operationHadFailure = true
                    refreshState = recordingFailure(.rateLimits, in: refreshState)
                }
            }
        }

        if decision.refreshOfficialUsage, didInitialize {
            let response: AccountUsageResponse?
            do {
                response = try await accountClient.readAccountUsage()
            } catch {
                response = nil
                operationHadFailure = true
                refreshState = recordingFailure(.officialUsage, in: refreshState)
            }
            if let response {
                if let buckets = response.dailyUsageBuckets {
                    let conversion = officialDays(from: buckets, fetchedAt: now)
                    if !conversion.days.isEmpty {
                        try await store.upsert(officialDays: conversion.days)
                    }
                    if conversion.hadInvalidBucket {
                        operationHadFailure = true
                        refreshState = recordingFailure(
                            .officialUsage,
                            in: refreshState
                        )
                    } else {
                        refreshState = recordingSuccess(
                            .officialUsage,
                            in: refreshState,
                            at: now
                        )
                    }
                } else {
                    operationHadFailure = true
                    refreshState = recordingFailure(.officialUsage, in: refreshState)
                }
            }
        }

        if shouldIndexSessions {
            lastSessionIndexAttemptAt = now
            if let codexHome = homeResolver.resolve(
                initializedHome: initializedHome,
                environment: environment,
                homeDirectory: homeDirectory
            ) {
                do {
                    _ = try await indexer.index(
                        codexHome: codexHome,
                        modifiedSince: try await indexHistoryStart(now: now),
                        calendar: calendar
                    )
                    refreshState = recordingSuccess(
                        .sessionIndexing,
                        in: refreshState
                    )
                } catch let error as SQLiteStoreError {
                    throw error
                } catch {
                    operationHadFailure = true
                    refreshState = recordingFailure(
                        .sessionIndexing,
                        in: refreshState
                    )
                }
            } else {
                operationHadFailure = true
                refreshState = recordingFailure(.sessionIndexing, in: refreshState)
            }
        }

        refreshState = finalizingFailureCount(
            in: refreshState,
            previousCount: previousFailureCount,
            operationHadFailure: operationHadFailure
        )
        try await store.save(refreshState: refreshState)
        return try await buildSnapshot(now: now, updateCycles: true)
    }

    public func processNextAccountNotification(
        now: Date
    ) async throws -> UsageSnapshot? {
        await acquireNotificationConsumer()
        defer { releaseNotificationConsumer() }
        try Task.checkCancellation()

        await acquireOperation()
        do {
            try await migrateIfNeeded()
            var refreshState = try await store.refreshState()
            let storedRefreshState = refreshState
            let previousFailureCount = refreshState.consecutiveFailureCount
            if !didInitialize {
                do {
                    let result = try await accountClient.initialize()
                    initializedHome = result.codexHome
                    didInitialize = true
                    refreshState = recordingSuccess(
                        .accountInitialization,
                        in: refreshState
                    )
                } catch {
                    refreshState = recordingFailure(
                        .accountInitialization,
                        in: refreshState
                    )
                    refreshState = finalizingFailureCount(
                        in: refreshState,
                        previousCount: refreshState.consecutiveFailureCount,
                        operationHadFailure: true
                    )
                    try await store.save(refreshState: refreshState)
                    if refreshState != storedRefreshState {
                        lastBuiltSnapshot = nil
                    }
                    releaseOperation()
                    return nil
                }
            }
            refreshState = finalizingFailureCount(
                in: refreshState,
                previousCount: previousFailureCount,
                operationHadFailure: false
            )
            try await store.save(refreshState: refreshState)
            if refreshState != storedRefreshState {
                lastBuiltSnapshot = nil
            }
            releaseOperation()
        } catch {
            releaseOperation()
            throw error
        }

        guard let notification = await accountClient.nextNotification() else {
            return nil
        }

        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await processAccountNotificationLocked(
            notification,
            now: now
        )
    }

    private func processAccountNotificationLocked(
        _ notification: AppServerNotification,
        now: Date
    ) async throws -> UsageSnapshot? {
        guard case let .rateLimitsUpdated(update) = notification else {
            return nil
        }

        var refreshState = try await store.refreshState()
        let previousFailureCount = refreshState.consecutiveFailureCount
        var operationHadFailure = false
        var response = lastFullRateLimits?.applying(update)
        var quota = response.flatMap {
            quotaSelector.select(from: $0, fetchedAt: now)
        }
        if quota == nil {
            do {
                let full = try await accountClient.readRateLimits()
                response = full
                quota = quotaSelector.select(from: full, fetchedAt: now)
            } catch {}
        }

        if let response {
            lastFullRateLimits = response
        }
        if let quota {
            try await store.save(quota: quota)
            refreshState = recordingSuccess(
                .rateLimits,
                in: refreshState,
                at: now
            )
        } else {
            operationHadFailure = true
            refreshState = recordingFailure(.rateLimits, in: refreshState)
        }

        refreshState = finalizingFailureCount(
            in: refreshState,
            previousCount: previousFailureCount,
            operationHadFailure: operationHadFailure
        )
        try await store.save(refreshState: refreshState)
        return try await buildSnapshot(now: now, updateCycles: false)
    }

    public func resolvedCodexHome() -> URL? {
        homeResolver.resolve(
            initializedHome: initializedHome,
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    public func currentSnapshot(now: Date) async throws -> UsageSnapshot {
        await acquireOperation()
        defer { releaseOperation() }
        try Task.checkCancellation()
        return try await currentSnapshotLocked(now: now)
    }

    private func currentSnapshotLocked(now: Date) async throws -> UsageSnapshot {
        return try await buildSnapshot(now: now, updateCycles: false)
    }

    private func acquireOperation() async {
        if !operationIsLocked {
            operationIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            operationWaiters.append(continuation)
        }
    }

    private func releaseOperation() {
        guard !operationWaiters.isEmpty else {
            operationIsLocked = false
            return
        }
        operationWaiters.removeFirst().resume()
    }

    func operationQueueDepth() -> Int {
        operationWaiters.count
    }

    private func acquireNotificationConsumer() async {
        if !notificationConsumerIsLocked {
            notificationConsumerIsLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            notificationConsumerWaiters.append(continuation)
        }
    }

    private func releaseNotificationConsumer() {
        guard !notificationConsumerWaiters.isEmpty else {
            notificationConsumerIsLocked = false
            return
        }
        notificationConsumerWaiters.removeFirst().resume()
    }

    private func migrateIfNeeded() async throws {
        guard !didMigrate else { return }
        try await store.migrate()
        didMigrate = true
    }

    private func buildSnapshot(
        now: Date,
        updateCycles: Bool
    ) async throws -> UsageSnapshot {
        var cycles = try await store.cycles()
        let quota = try await store.latestQuota()
        var eventStart = historyStart(now: now)
        if let earliestCycle = cycles.first?.startsAt {
            eventStart = min(eventStart, earliestCycle)
        }
        if let quotaStart = oldestEstimatedBoundary(for: quota) {
            eventStart = min(eventStart, quotaStart)
        }
        let events = try await store.events(
            from: eventStart,
            to: Date(
                timeIntervalSince1970: now.timeIntervalSince1970.nextUp
            )
        )
        let officialDays = try await store.officialDays()

        if updateCycles, let quota {
            cycles = cycleTracker.update(
                existing: cycles,
                quota: quota,
                events: events
            )
            try await store.replace(cycles: cycles)
            if cycles.count == 9, let earliest = cycles.first {
                try await store.pruneUsage(
                    eventsBefore: earliest.startsAt,
                    officialDaysBefore: localDay(for: earliest.startsAt)
                )
            }
        }

        let snapshot = reconciler.snapshot(
            now: now,
            calendar: calendar,
            quota: quota,
            events: events,
            officialDays: officialDays,
            cycles: cycles,
            lastUpdatedAt: latestUpdate(
                now: now,
                quota: quota,
                events: events,
                officialDays: officialDays
            )
        )
        let refreshState = try await store.refreshState()
        let finalSnapshot = refreshState.failedSources.isEmpty
            ? snapshot
            : snapshot.markedStale()
        lastBuiltSnapshot = finalSnapshot
        return finalSnapshot
    }

    private func historyStart(now: Date) -> Date {
        calendar.date(byAdding: .day, value: -56, to: now)
            ?? now.addingTimeInterval(-56 * 24 * 60 * 60)
    }

    private func shouldRunScheduledSessionFallback(
        reason: RefreshReason,
        now: Date
    ) -> Bool {
        guard case .scheduled = reason else { return false }
        guard let lastSessionIndexAttemptAt else { return true }
        let age = now.timeIntervalSince(lastSessionIndexAttemptAt)
        return age.isFinite && age >= 300
    }

    private func canReuse(_ snapshot: UsageSnapshot, now: Date) -> Bool {
        guard snapshot.today.day == localDay(for: now) else { return false }
        if let cycle = snapshot.currentCycle {
            guard cycle.startsAt <= now, now < cycle.endsAt else { return false }
        }
        if let quota = snapshot.quota, now >= quota.resetsAt {
            return false
        }
        return true
    }

    private func indexHistoryStart(now: Date) async throws -> Date {
        var start = historyStart(now: now)
        if let quotaStart = oldestEstimatedBoundary(
            for: try await store.latestQuota()
        ) {
            start = min(start, quotaStart)
        }
        if let storedStart = try await store.cycles().first?.startsAt {
            start = min(start, storedStart)
        }
        return start
    }

    private func oldestEstimatedBoundary(
        for quota: QuotaSnapshot?
    ) -> Date? {
        guard let quota,
              (9_000...11_000).contains(quota.windowDurationMinutes) else {
            return nil
        }
        let duration = TimeInterval(quota.windowDurationMinutes) * 60
        let boundary = quota.startsAt.addingTimeInterval(-8 * duration)
        return boundary.timeIntervalSince1970.isFinite ? boundary : nil
    }

    private func officialDays(
        from buckets: [AccountTokenUsageDailyBucket],
        fetchedAt: Date
    ) -> (days: [OfficialUsageDay], hadInvalidBucket: Bool) {
        var days: [OfficialUsageDay] = []
        var hadInvalidBucket = false
        for bucket in buckets {
            guard bucket.tokens >= 0,
                  let day = strictLocalDay(bucket.startDate) else {
                hadInvalidBucket = true
                continue
            }
            days.append(
                OfficialUsageDay(
                    day: day,
                    tokens: bucket.tokens,
                    fetchedAt: fetchedAt
                )
            )
        }
        return (days, hadInvalidBucket)
    }

    private func strictLocalDay(_ value: String) -> LocalDay? {
        guard value.utf8.count == 10 else { return nil }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ part in
                  part.utf8.allSatisfy { (48...57).contains($0) }
              }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...9_999).contains(year) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let canonical = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        guard canonical.year == year,
              canonical.month == month,
              canonical.day == day else {
            return nil
        }
        return LocalDay(year: year, month: month, day: day)
    }

    private func localDay(for date: Date) -> LocalDay {
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return LocalDay(
            year: components.year ?? 1,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    private func latestUpdate(
        now: Date,
        quota: QuotaSnapshot?,
        events: [StoredUsageEvent],
        officialDays: [OfficialUsageDay]
    ) -> Date {
        let candidates = [quota?.fetchedAt]
            + events.map { Optional($0.occurredAt) }
            + officialDays.map { Optional($0.fetchedAt) }
        return candidates.compactMap { $0 }.max() ?? now
    }

    private func incremented(_ value: Int) -> Int {
        let (next, overflow) = value.addingReportingOverflow(1)
        return overflow ? .max : next
    }

    private func recordingFailure(
        _ source: UsageRefreshFailureSource,
        in state: UsageRefreshState
    ) -> UsageRefreshState {
        var failedSources = state.failedSources
        failedSources.insert(source)
        return UsageRefreshState(
            lastSuccessfulQuotaRefreshAt: state.lastSuccessfulQuotaRefreshAt,
            lastSuccessfulOfficialUsageRefreshAt:
                state.lastSuccessfulOfficialUsageRefreshAt,
            consecutiveFailureCount: state.consecutiveFailureCount,
            failedSources: failedSources
        )
    }

    private func recordingSuccess(
        _ source: UsageRefreshFailureSource,
        in state: UsageRefreshState,
        at date: Date? = nil
    ) -> UsageRefreshState {
        var failedSources = state.failedSources
        failedSources.remove(source)
        let quotaRefresh = source == .rateLimits
            ? date ?? state.lastSuccessfulQuotaRefreshAt
            : state.lastSuccessfulQuotaRefreshAt
        let officialRefresh = source == .officialUsage
            ? date ?? state.lastSuccessfulOfficialUsageRefreshAt
            : state.lastSuccessfulOfficialUsageRefreshAt
        return UsageRefreshState(
            lastSuccessfulQuotaRefreshAt: quotaRefresh,
            lastSuccessfulOfficialUsageRefreshAt: officialRefresh,
            consecutiveFailureCount: state.consecutiveFailureCount,
            failedSources: failedSources
        )
    }

    private func finalizingFailureCount(
        in state: UsageRefreshState,
        previousCount: Int,
        operationHadFailure: Bool
    ) -> UsageRefreshState {
        UsageRefreshState(
            lastSuccessfulQuotaRefreshAt: state.lastSuccessfulQuotaRefreshAt,
            lastSuccessfulOfficialUsageRefreshAt:
                state.lastSuccessfulOfficialUsageRefreshAt,
            consecutiveFailureCount: operationHadFailure
                ? incremented(previousCount)
                : state.failedSources.isEmpty ? 0 : previousCount,
            failedSources: state.failedSources
        )
    }
}

private extension UsageSnapshot {
    func markedStale() -> UsageSnapshot {
        UsageSnapshot(
            quota: quota,
            today: today,
            currentCycle: currentCycle,
            recentDays: recentDays,
            cycleHistory: cycleHistory,
            lastUpdatedAt: lastUpdatedAt,
            status: .stale
        )
    }
}
