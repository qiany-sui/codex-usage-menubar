import Foundation
import UsageCore

enum MenuBarIconPresentation: Equatable {
    case quota(progress: Double?)
    case fatal
}

struct MenuBarPresentation: Equatable {
    let icon: MenuBarIconPresentation
    let title: String
    let accessibilityLabel: String

    init(remainingPercent: Double?, isFatal: Bool) {
        if isFatal {
            icon = .fatal
        } else {
            icon = .quota(
                progress: remainingPercent.map {
                    min(max($0 / 100, 0), 1)
                }
            )
        }
        title = UsageFormatters.menuBarTitle(
            remainingPercent: remainingPercent,
            isFatal: isFatal
        )
        accessibilityLabel = "Codex 周额度 \(title)"
    }
}

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
    let resetTime: String?
    let todayTotal: String
    let todayQuota: DayQuotaPresentation
    let inputTokens: String
    let cachedInputTokens: String
    let outputTokens: String
    let additiveSegments: [UsageSegment]
    let currentCycleTokens: String
    let currentCycleStatus: String
    let currentCycleQuota: String
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
            resetTime = UsageFormatters.resetTime(
                quota.resetsAt,
                timeZone: timeZone
            )
        } else {
            progress = 0
            resetCountdown = "暂无数据"
            resetTime = nil
        }

        todayQuota = DayQuotaPresentation(day: snapshot.today, timeZone: timeZone)
        currentCycleQuota = UsageFormatters.cycleQuotaUsage(snapshot.currentCycle?.quotaUsedPercent)
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

struct TrendQuotaSegmentPresentation: Equatable, Identifiable {
    let id: Date
    let label: String
    let percent: String
}

struct DayQuotaPresentation: Equatable {
    let percent: String
    let segments: [TrendQuotaSegmentPresentation]
    let resetLabel: String?
    let help: String

    var summary: String {
        if segments.isEmpty {
            return percent == "--" ? "额度记录不足" : "额度消耗 " + percent
        }
        if segments.count > 2 {
            return "分\(segments.count)段：" + segments.map(\.percent).joined(separator: " / ")
        }
        return segments.map { $0.label + " " + $0.percent }.joined(separator: " · ")
    }

    init(day: UsageDay, timeZone: TimeZone) {
        let time = DateFormatter()
        time.calendar = Calendar(identifier: .gregorian)
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = timeZone
        time.dateFormat = "HH:mm"
        let preciseTime = DateFormatter()
        preciseTime.calendar = time.calendar
        preciseTime.locale = time.locale
        preciseTime.timeZone = timeZone
        preciseTime.dateFormat = "M/d HH:mm:ss"
        let rawSegments = day.quotaSegments ?? []
        let resets = rawSegments.filter(\.startsWithReset)
        let parts = rawSegments.enumerated().map { index, segment in
            let label: String
            if rawSegments.count == 1 {
                label = "重置后"
            } else if rawSegments.count == 2, !rawSegments[0].startsWithReset {
                label = index == 0 ? "重置前" : "重置后"
            } else {
                label = "第\(index + 1)段"
            }
            return TrendQuotaSegmentPresentation(
                id: segment.startsAt,
                label: label,
                percent: segment.consumedPercent.map { UsageFormatters.quotaConsumedPercent($0) }
                    ?? "记录不足"
            )
        }
        resetLabel = resets.count == 1
            ? time.string(from: resets[0].startsAt) + " 重置"
            : resets.isEmpty ? nil : "重置 \(resets.count) 次"
        help = parts.isEmpty
            ? "当天官方已用额度的增量；-- 表示边界记录不足。Token 校准状态不代表额度记录完整。"
            : zip(rawSegments, parts).map { segment, part in
                "\(preciseTime.string(from: segment.startsAt))–\(preciseTime.string(from: segment.endsAt)) \(part.label)：\(part.percent)"
            }.joined(separator: "\n") + "\n每段按各自周期额度计算；Token 为全天总量。"
        segments = parts
        percent = parts.isEmpty ? UsageFormatters.quotaConsumedPercent(day.quotaConsumedPercent) : "已分段"
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
    let quotaPercent: String
    let quotaSegments: [TrendQuotaSegmentPresentation]
    let resetLabel: String?
    let quotaHelp: String
}

struct TrendPresentation: Equatable {
    let totalTokens: Int64
    let averageTokens: Int64
    let days: [TrendDayPresentation]
    let today: LocalDay

    init(snapshot: UsageSnapshot, timeZone: TimeZone = .autoupdatingCurrent) {
        today = snapshot.today.day
        days = snapshot.recentDays.suffix(7).map { day in
            let quota = DayQuotaPresentation(day: day, timeZone: timeZone)
            return TrendDayPresentation(
                day: day.day,
                label: UsageFormatters.day(day.day),
                tokens: day.displayedTokens,
                formattedTokens: UsageFormatters.tokens(day.displayedTokens),
                status: day.status,
                statusLabel: UsageFormatters.calibration(day.status),
                quotaPercent: quota.percent,
                quotaSegments: quota.segments,
                resetLabel: quota.resetLabel,
                quotaHelp: quota.help
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
    let quotaUsage: String
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
                boundaryIsEstimated: item.cycle.boundaryIsEstimated,
                quotaUsage: UsageFormatters.cycleQuotaUsage(item.cycle.quotaUsedPercent)
            )
        }
    }
}

#if DEBUG
enum UsagePreviewData {
    static let now = Date(timeIntervalSince1970: 1788935520)
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
            LocalDay(year: 2026, month: 9, day: 3),
            LocalDay(year: 2026, month: 9, day: 4),
            LocalDay(year: 2026, month: 9, day: 5),
            LocalDay(year: 2026, month: 9, day: 6),
            LocalDay(year: 2026, month: 9, day: 7),
            LocalDay(year: 2026, month: 9, day: 8),
            LocalDay(year: 2026, month: 9, day: 9)
        ]
        let quotaConsumption: [Double?] = [nil, 8, 0, 6, nil, 9, 7]
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
                status: index < totals.count - 1 ? .calibrated : .localLive,
                quotaConsumedPercent: includesQuota ? quotaConsumption[index] : nil
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
                day: LocalDay(year: 2026, month: 9, day: 9),
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
