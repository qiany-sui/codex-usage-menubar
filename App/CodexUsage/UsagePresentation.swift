import Foundation
import UsageCore

struct UsageSegment: Equatable, Identifiable {
    let id: String
    let label: String
    let value: Int64
    let formattedValue: String
}

struct OverviewPresentation: Equatable {
    let remainingPercent: String
    let progress: Double
    let resetCountdown: String
    let todayTotal: String
    let inputTokens: String
    let cachedInputTokens: String
    let outputTokens: String
    let additiveSegments: [UsageSegment]
    let currentCycleTokens: String
    let currentCycleStatus: String
    let staleMessage: String?
    let lastUpdated: String

    init(snapshot: UsageSnapshot, now: Date, timeZone: TimeZone) {
        let today = snapshot.today.localUsage
        remainingPercent = UsageFormatters.remainingPercent(
            snapshot.quota?.remainingPercent
        )
        if let quota = snapshot.quota {
            progress = min(max(quota.remainingPercent / 100, 0), 1)
            resetCountdown = UsageFormatters.resetCountdown(
                resetsAt: quota.resetsAt,
                now: now
            )
        } else {
            progress = 0
            resetCountdown = "暂无数据"
        }

        todayTotal = UsageFormatters.tokens(today.totalTokens)
        inputTokens = UsageFormatters.tokens(today.inputTokens)
        cachedInputTokens = UsageFormatters.tokens(today.cachedInputTokens)
        outputTokens = UsageFormatters.tokens(today.outputTokens)
        additiveSegments = [
            UsageSegment(
                id: "input",
                label: "输入",
                value: today.inputTokens,
                formattedValue: inputTokens
            ),
            UsageSegment(
                id: "output",
                label: "输出",
                value: today.outputTokens,
                formattedValue: outputTokens
            )
        ]

        if let cycle = snapshot.currentCycle {
            currentCycleTokens = UsageFormatters.tokens(
                cycle.displayedTokens
            )
            currentCycleStatus = UsageFormatters.calibration(cycle.status)
        } else {
            currentCycleTokens = "--"
            currentCycleStatus = "暂无数据"
        }

        staleMessage = snapshot.status == .stale
            ? UsageFormatters.calibration(.stale)
            : nil
        lastUpdated = Self.lastUpdated(
            snapshot.lastUpdatedAt,
            now: now,
            timeZone: timeZone
        )
    }

    private static func lastUpdated(
        _ date: Date,
        now: Date,
        timeZone: TimeZone
    ) -> String {
        let elapsedSeconds = max(now.timeIntervalSince(date), 0)
        guard elapsedSeconds >= 60 * 60 else {
            return UsageFormatters.lastUpdated(date, now: now)
        }
        return UsageFormatters.dateTime(date, timeZone: timeZone) + " 更新"
    }
}

struct TrendDayPresentation: Equatable, Identifiable {
    var id: LocalDay { day }

    let day: LocalDay
    let label: String
    let tokens: Int64
    let formattedTokens: String
    let status: UsageCalibrationStatus
    let statusLabel: String
}

struct TrendPresentation: Equatable {
    let totalTokens: Int64
    let averageTokens: Int64
    let days: [TrendDayPresentation]

    init(snapshot: UsageSnapshot) {
        days = snapshot.recentDays.suffix(7).map { day in
            TrendDayPresentation(
                day: day.day,
                label: UsageFormatters.day(day.day),
                tokens: day.displayedTokens,
                formattedTokens: UsageFormatters.tokens(day.displayedTokens),
                status: day.status,
                statusLabel: UsageFormatters.calibration(day.status)
            )
        }
        totalTokens = days.reduce(0) { $0 + $1.tokens }
        averageTokens = days.isEmpty
            ? 0
            : totalTokens / Int64(days.count)
    }
}

struct CycleEntryPresentation: Equatable, Identifiable {
    let id: Date
    let range: String
    let formattedTokens: String
    let statusLabel: String
    let isCurrent: Bool
    let boundaryIsEstimated: Bool
}

struct CycleHistoryPresentation: Equatable {
    let entries: [CycleEntryPresentation]

    init(snapshot: UsageSnapshot, timeZone: TimeZone) {
        var cycles: [(cycle: QuotaCycle, isCurrent: Bool)] = []
        var seenStartsAt = Set<Date>()

        if let current = snapshot.currentCycle {
            cycles.append((current, true))
            seenStartsAt.insert(current.startsAt)
        }

        for cycle in snapshot.cycleHistory.sorted(by: {
            $0.endsAt > $1.endsAt
        }) {
            guard cycles.count < (snapshot.currentCycle == nil ? 8 : 9) else {
                break
            }
            guard seenStartsAt.insert(cycle.startsAt).inserted else {
                continue
            }
            cycles.append((cycle, false))
        }

        entries = cycles.map { item in
            CycleEntryPresentation(
                id: item.cycle.startsAt,
                range: UsageFormatters.cycleRange(
                    startsAt: item.cycle.startsAt,
                    endsAt: item.cycle.endsAt,
                    timeZone: timeZone
                ),
                formattedTokens: UsageFormatters.tokens(
                    item.cycle.displayedTokens
                ),
                statusLabel: UsageFormatters.calibration(
                    item.cycle.status
                ),
                isCurrent: item.isCurrent,
                boundaryIsEstimated: item.cycle.boundaryIsEstimated
            )
        }
    }
}

#if DEBUG
enum UsagePreviewData {
    static let now = Date(timeIntervalSince1970: 1_788_249_600)
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static let fullSnapshot = makeSnapshot(status: .partiallyCalibrated)
    static let staleSnapshot = makeSnapshot(status: .stale)
    static let snapshotWithoutQuota = makeSnapshot(
        status: .localLive,
        includesQuota: false
    )

    private static func makeSnapshot(
        status: UsageCalibrationStatus,
        includesQuota: Bool = true
    ) -> UsageSnapshot {
        let todayUsage = TokenBreakdown(
            inputTokens: 7_800_000,
            cachedInputTokens: 5_100_000,
            outputTokens: 620_000
        )
        let totals: [Int64] = [
            4_300_000,
            7_900_000,
            5_200_000,
            9_600_000,
            6_800_000,
            3_900_000,
            todayUsage.totalTokens
        ]
        let days = [
            LocalDay(year: 2026, month: 8, day: 26),
            LocalDay(year: 2026, month: 8, day: 27),
            LocalDay(year: 2026, month: 8, day: 28),
            LocalDay(year: 2026, month: 8, day: 29),
            LocalDay(year: 2026, month: 8, day: 30),
            LocalDay(year: 2026, month: 8, day: 31),
            LocalDay(year: 2026, month: 9, day: 1)
        ]
        let recentDays = totals.enumerated().map { index, total in
            UsageDay(
                day: days[index],
                localUsage: TokenBreakdown(
                    inputTokens: total,
                    cachedInputTokens: total / 2,
                    outputTokens: 0
                ),
                officialTokens: index < totals.count - 1 ? total : nil,
                displayedTokens: total,
                status: index < totals.count - 1 ? .calibrated : .localLive
            )
        }
        let cycleUsage = TokenBreakdown(
            inputTokens: 31_400_000,
            cachedInputTokens: 18_200_000,
            outputTokens: 3_300_000
        )
        let currentCycle = QuotaCycle(
            startsAt: now.addingTimeInterval(-5 * 24 * 60 * 60),
            endsAt: now.addingTimeInterval(2 * 24 * 60 * 60),
            usage: cycleUsage,
            displayedTokens: 34_700_000,
            status: status,
            boundaryIsEstimated: false
        )
        let cycleHistory = (0 ..< 8).map { index in
            let end = currentCycle.startsAt.addingTimeInterval(
                -Double(index) * 7 * 24 * 60 * 60
            )
            let start = end.addingTimeInterval(-7 * 24 * 60 * 60)
            let tokens = Int64(28_600_000 - index * 1_350_000)
            return QuotaCycle(
                startsAt: start,
                endsAt: end,
                usage: TokenBreakdown(
                    inputTokens: tokens - 2_400_000,
                    cachedInputTokens: tokens / 2,
                    outputTokens: 2_400_000
                ),
                displayedTokens: tokens,
                status: index < 5 ? .calibrated : .partiallyCalibrated,
                boundaryIsEstimated: index >= 6
            )
        }
        let quota = includesQuota
            ? QuotaSnapshot(
                limitID: "weekly",
                usedPercent: 38,
                windowDurationMinutes: 10_080,
                startsAt: currentCycle.startsAt,
                resetsAt: currentCycle.endsAt,
                fetchedAt: now
            )
            : nil

        return UsageSnapshot(
            quota: quota,
            today: UsageDay(
                day: LocalDay(year: 2026, month: 9, day: 1),
                localUsage: todayUsage,
                officialTokens: nil,
                displayedTokens: todayUsage.totalTokens,
                status: .localLive
            ),
            currentCycle: currentCycle,
            recentDays: recentDays,
            cycleHistory: cycleHistory,
            lastUpdatedAt: now.addingTimeInterval(-7 * 60),
            status: status
        )
    }
}
#endif
