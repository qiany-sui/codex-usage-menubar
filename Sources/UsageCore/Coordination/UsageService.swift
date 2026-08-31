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
    private var lastQuotaRefresh: Date?
    private var lastOfficialRefresh: Date?
    private var consecutiveFailures = 0

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
        try await migrateIfNeeded()

        var degraded = false
        if !didInitialize {
            do {
                let result = try await accountClient.initialize()
                initializedHome = result.codexHome
                didInitialize = true
            } catch {
                degraded = true
            }
        }

        let decision = policy.decision(
            now: now,
            reason: reason,
            lastQuotaRefresh: lastQuotaRefresh,
            lastOfficialRefresh: lastOfficialRefresh,
            consecutiveFailures: consecutiveFailures
        )

        if decision.refreshQuota, didInitialize {
            do {
                let response = try await accountClient.readRateLimits()
                lastFullRateLimits = response
                if let quota = quotaSelector.select(
                    from: response,
                    fetchedAt: now
                ) {
                    try await store.save(quota: quota)
                    lastQuotaRefresh = now
                } else {
                    degraded = true
                }
            } catch let error as SQLiteStoreError {
                throw error
            } catch {
                degraded = true
            }
        } else if decision.refreshQuota {
            degraded = true
        }

        if decision.refreshOfficialUsage, didInitialize {
            do {
                let response = try await accountClient.readAccountUsage()
                guard let buckets = response.dailyUsageBuckets else {
                    degraded = true
                    throw RemoteDataUnavailable()
                }
                let conversion = officialDays(from: buckets, fetchedAt: now)
                if !conversion.days.isEmpty {
                    try await store.upsert(officialDays: conversion.days)
                }
                if conversion.hadInvalidBucket {
                    degraded = true
                } else {
                    lastOfficialRefresh = now
                }
            } catch let error as SQLiteStoreError {
                throw error
            } catch is RemoteDataUnavailable {
                // 旧版服务可能缺少可选字段，保留本地已有数据。
            } catch {
                degraded = true
            }
        } else if decision.refreshOfficialUsage {
            degraded = true
        }

        if decision.indexSessions {
            if let codexHome = homeResolver.resolve(
                initializedHome: initializedHome,
                environment: environment,
                homeDirectory: homeDirectory
            ) {
                do {
                    _ = try await indexer.index(
                        codexHome: codexHome,
                        modifiedSince: historyStart(now: now),
                        calendar: calendar
                    )
                } catch let error as SQLiteStoreError {
                    throw error
                } catch {
                    degraded = true
                }
            } else {
                degraded = true
            }
        }

        if degraded {
            consecutiveFailures = incremented(consecutiveFailures)
        } else {
            consecutiveFailures = 0
        }

        var snapshot = try await buildSnapshot(now: now, updateCycles: true)
        if degraded {
            snapshot = snapshot.markedStale()
        }
        return snapshot
    }

    public func processNextAccountNotification(
        now: Date
    ) async throws -> UsageSnapshot? {
        try await migrateIfNeeded()
        guard let notification = await accountClient.nextNotification() else {
            return nil
        }
        guard case let .rateLimitsUpdated(update) = notification else {
            return nil
        }

        var degraded = false
        var response = lastFullRateLimits?.applying(update)
        var quota = response.flatMap {
            quotaSelector.select(from: $0, fetchedAt: now)
        }
        if quota == nil {
            do {
                let full = try await accountClient.readRateLimits()
                response = full
                quota = quotaSelector.select(from: full, fetchedAt: now)
            } catch {
                degraded = true
            }
        }

        if let response {
            lastFullRateLimits = response
        }
        if let quota {
            try await store.save(quota: quota)
            lastQuotaRefresh = now
        } else {
            degraded = true
        }

        if degraded {
            consecutiveFailures = incremented(consecutiveFailures)
        } else {
            consecutiveFailures = 0
        }
        var snapshot = try await buildSnapshot(now: now, updateCycles: false)
        if degraded {
            snapshot = snapshot.markedStale()
        }
        return snapshot
    }

    public func currentSnapshot(now: Date) async throws -> UsageSnapshot {
        try await migrateIfNeeded()
        return try await buildSnapshot(now: now, updateCycles: false)
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
        let events = try await store.events(
            from: historyStart(now: now),
            to: Date(
                timeIntervalSince1970: now.timeIntervalSince1970.nextUp
            )
        )
        let officialDays = try await store.officialDays()
        let quota = try await store.latestQuota()
        var cycles = try await store.cycles()

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

        return reconciler.snapshot(
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
    }

    private func historyStart(now: Date) -> Date {
        calendar.date(byAdding: .day, value: -56, to: now)
            ?? now.addingTimeInterval(-56 * 24 * 60 * 60)
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
}

private struct RemoteDataUnavailable: Error {}

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
