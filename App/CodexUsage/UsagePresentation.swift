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
            cycleHistory: [],
            lastUpdatedAt: now.addingTimeInterval(-7 * 60),
            status: status
        )
    }
}
#endif
