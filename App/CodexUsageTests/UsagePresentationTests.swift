import AppKit
import Foundation
import UsageCore
import XCTest
@testable import CodexUsage

final class UsagePresentationTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testStaleMenuBarPreservesQuotaAndExplainsItsTimestamp() throws {
        let presentation = MenuBarPresentation(
            remainingPercent: 62, isFatal: false, isStale: true,
            lastUpdatedAt: try fixedDate("2026-10-04T01:30:00Z"),
            timeZone: timeZone
        )
        XCTAssertEqual(presentation.title, "62%")
        XCTAssertTrue(presentation.isStale)
        XCTAssertTrue(presentation.accessibilityLabel.contains("已过期"))
        XCTAssertTrue(presentation.help.contains("10/4 09:30"))

        let fatal = MenuBarPresentation(remainingPercent: 62, isFatal: true, isStale: true)
        XCTAssertEqual(fatal.icon, .fatal)
        XCTAssertFalse(fatal.isStale)
    }

    func testMenuBarPresentationUsesBrandedQuotaIconStateAndSeparateText() {
        let normal = MenuBarPresentation(
            remainingPercent: 62,
            isFatal: false
        )
        let fatal = MenuBarPresentation(
            remainingPercent: 62,
            isFatal: true
        )

        XCTAssertEqual(normal.icon, .quota(progress: 0.62))
        XCTAssertEqual(normal.title, "62%")
        XCTAssertEqual(normal.accessibilityLabel, "Codex 周额度 62%")
        XCTAssertEqual(fatal.icon, .fatal)
        XCTAssertEqual(fatal.title, "!")
        XCTAssertEqual(fatal.accessibilityLabel, "Codex 周额度 !")
    }

    func testMenuBarPresentationNormalizesQuotaIconProgress() {
        let over = MenuBarPresentation(
            remainingPercent: 140,
            isFatal: false
        )
        let under = MenuBarPresentation(
            remainingPercent: -20,
            isFatal: false
        )
        let missing = MenuBarPresentation(
            remainingPercent: nil,
            isFatal: false
        )

        XCTAssertEqual(over.icon, .quota(progress: 1))
        XCTAssertEqual(under.icon, .quota(progress: 0))
        XCTAssertEqual(missing.icon, .quota(progress: nil))
    }

    func testMenuBarQuotaImageProvidesCompactVisibleTemplatePixels() throws {
        let image = MenuBarQuotaImageRenderer.image(progress: 0.56)

        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 13, height: 13))

        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let containsVisiblePixel = (0..<bitmap.pixelsWide).contains { x in
            (0..<bitmap.pixelsHigh).contains { y in
                (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0
            }
        }

        XCTAssertTrue(containsVisiblePixel)
    }

    func testOverviewKeepsTodayTotalPrimaryAndCacheAsInputSubset() throws {
        let snapshot = try sampleSnapshot(
            today: TokenBreakdown(
                inputTokens: 100,
                cachedInputTokens: 80,
                outputTokens: 20
            )
        )

        let presentation = OverviewPresentation(
            snapshot: snapshot,
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.todayTotal, "120")
        XCTAssertEqual(presentation.inputTokens, "100")
        XCTAssertEqual(presentation.cachedInputTokens, "80")
        XCTAssertEqual(presentation.outputTokens, "20")
        XCTAssertEqual(presentation.additiveSegments.map(\.value), [100, 20])
    }

    func testOverviewUsesChineseCompactTokenUnits() throws {
        let presentation = OverviewPresentation(
            snapshot: try sampleSnapshot(
                today: TokenBreakdown(
                    inputTokens: 115_000_000,
                    cachedInputTokens: 110_000_000,
                    outputTokens: 377_000
                )
            ),
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.todayTotal, "1.2亿")
        XCTAssertEqual(presentation.inputTokens, "1.2亿")
        XCTAssertEqual(presentation.cachedInputTokens, "1.1亿")
        XCTAssertEqual(presentation.outputTokens, "37.7万")
    }

    func testOverviewAndHistoryDisplayEachCyclesOwnQuotaPercentage() throws {
        let base = try sampleSnapshot()
        let current = try XCTUnwrap(base.currentCycle)
        let old = try XCTUnwrap(base.cycleHistory.first)
        func withPercent(_ cycle: QuotaCycle, _ value: Double?) -> QuotaCycle {
            QuotaCycle(
                startsAt: cycle.startsAt, endsAt: cycle.endsAt, usage: cycle.usage,
                displayedTokens: cycle.displayedTokens, status: cycle.status,
                boundaryIsEstimated: cycle.boundaryIsEstimated, quotaUsedPercent: value
            )
        }
        for historicalValue: Double? in [98, 0, nil] {
            let snapshot = UsageSnapshot(
                quota: base.quota, today: base.today,
                currentCycle: withPercent(current, 32), recentDays: base.recentDays,
                cycleHistory: [withPercent(old, historicalValue)],
                lastUpdatedAt: base.lastUpdatedAt, status: base.status
            )
            let overview = OverviewPresentation(snapshot: snapshot, now: base.lastUpdatedAt, timeZone: timeZone)
            let history = CycleHistoryPresentation(snapshot: snapshot, timeZone: timeZone)
            XCTAssertEqual(overview.currentCycleQuota, "额度已用 32%")
            XCTAssertEqual(history.entries.first?.quotaUsage, "额度已用 32%")
            let expected = historicalValue == 98 ? "额度已用 98%"
                : historicalValue == 0 ? "额度已用 0%" : "额度记录不足"
            XCTAssertEqual(history.entries.last?.quotaUsage, expected)
            XCTAssertEqual(history.entries.last?.formattedTokens, UsageFormatters.tokens(old.displayedTokens))
        }
    }

    func testPartialDailyConsumptionIsLabeledInTrendAndOverview() throws {
        let base = try sampleSnapshot()
        let day = UsageDay(
            day: base.today.day, localUsage: base.today.localUsage,
            officialTokens: nil, displayedTokens: 210_000_000, status: .calibrated,
            recordedQuotaConsumedPercent: 18
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: day, currentCycle: base.currentCycle,
            recentDays: [day], cycleHistory: [], lastUpdatedAt: base.lastUpdatedAt, status: base.status
        )
        let trend = TrendPresentation(snapshot: snapshot, timeZone: timeZone)
        XCTAssertEqual(trend.days.first?.quotaPercent, "18%")
        XCTAssertTrue(trend.days.first?.quotaHelp.contains("记录不完整") == true)
        XCTAssertEqual(trend.days.first?.statusLabel, "已校准")
        let overview = OverviewPresentation(snapshot: snapshot, now: base.lastUpdatedAt, timeZone: timeZone)
        XCTAssertEqual(overview.todayQuota.summary, "已记录消耗 18%（记录不完整）")
    }

    func testPartialResetSegmentRetainsItsLabelAndKnownValue() throws {
        let base = try sampleSnapshot()
        let start = base.lastUpdatedAt.addingTimeInterval(-3600)
        let reset = start.addingTimeInterval(1800)
        let day = UsageDay(
            day: base.today.day, localUsage: .zero, officialTokens: nil,
            displayedTokens: 0, status: .localLive,
            quotaSegments: [
                QuotaConsumptionSegment(startsAt: start, endsAt: reset, consumedPercent: nil,
                    startsWithReset: false, recordedConsumedPercent: 15),
                QuotaConsumptionSegment(startsAt: reset, endsAt: base.lastUpdatedAt,
                    consumedPercent: 20, startsWithReset: true)
            ]
        )
        let quota = DayQuotaPresentation(day: day, timeZone: timeZone)
        XCTAssertEqual(quota.segments.map(\.percent), ["15%", "20%"])
        XCTAssertTrue(quota.summary.contains("重置前 已记录 15%"))
        XCTAssertTrue(quota.help.contains("记录不完整"))
    }

    func testTrendQuotaDetailsKeepPreciseSegmentRecordsWithoutGeneralExplanation() throws {
        let base = try sampleSnapshot()
        let start = try fixedDate("2026-10-13T00:10:11Z")
        let firstReset = try fixedDate("2026-10-13T00:30:22Z")
        let secondReset = try fixedDate("2026-10-13T01:40:33Z")
        let end = try fixedDate("2026-10-13T02:50:44Z")
        let day = UsageDay(
            day: LocalDay(year: 2026, month: 10, day: 13), localUsage: .zero,
            officialTokens: nil, displayedTokens: 0, status: .localLive,
            quotaSegments: [
                QuotaConsumptionSegment(
                    startsAt: start, endsAt: firstReset, consumedPercent: nil,
                    startsWithReset: false
                ),
                QuotaConsumptionSegment(
                    startsAt: firstReset, endsAt: secondReset, consumedPercent: nil,
                    startsWithReset: true, recordedConsumedPercent: 30
                ),
                QuotaConsumptionSegment(
                    startsAt: secondReset, endsAt: end, consumedPercent: 1,
                    startsWithReset: true
                )
            ]
        )
        let quota = DayQuotaPresentation(day: day, timeZone: timeZone)
        let expected = """
        10/13 08:10:11–10/13 08:30:22 第1段：记录不足
        10/13 08:30:22–10/13 09:40:33 第2段：已记录 30%
        10/13 09:40:33–10/13 10:50:44 第3段：1%
        """
        XCTAssertEqual(quota.details, expected)
        XCTAssertTrue(quota.help.contains("每段按各自周期额度计算；Token 为全天总量。"))
        XCTAssertTrue(quota.help.contains("不代表整个时间段的最终消耗"))

        let snapshot = UsageSnapshot(
            quota: base.quota, today: day, currentCycle: base.currentCycle,
            recentDays: [day], cycleHistory: [], lastUpdatedAt: end, status: .localLive
        )
        let row = try XCTUnwrap(TrendPresentation(snapshot: snapshot, timeZone: timeZone).days.first)
        XCTAssertEqual(row.quotaDetails, expected)
        XCTAssertEqual(row.quotaHelp, quota.help)
        XCTAssertTrue(row.quotaIsPartial)
    }

    func testDailyQuotaDetailsPreserveCompletePartialAndMissingUnsegmentedStates() throws {
        let cases: [(Double?, Double?, String)] = [
            (12, nil, "额度消耗 12%"),
            (0, nil, "额度消耗 0%"),
            (nil, 30, "已记录消耗 30%（记录不完整）"),
            (nil, nil, "额度记录不足")
        ]
        let base = try sampleSnapshot()
        for (complete, recorded, expected) in cases {
            let day = UsageDay(
                day: base.today.day, localUsage: .zero, officialTokens: nil,
                displayedTokens: 0, status: .localLive,
                quotaConsumedPercent: complete, recordedQuotaConsumedPercent: recorded
            )
            XCTAssertEqual(DayQuotaPresentation(day: day, timeZone: timeZone).details, expected)
            let snapshot = UsageSnapshot(
                quota: base.quota, today: day, currentCycle: base.currentCycle,
                recentDays: [day], cycleHistory: [], lastUpdatedAt: base.lastUpdatedAt, status: .localLive
            )
            let row = try XCTUnwrap(TrendPresentation(snapshot: snapshot, timeZone: timeZone).days.first)
            XCTAssertEqual(row.quotaDetails, expected)
        }
    }

    func testHistoricalPartialQuotaShowsLastRecordedValueAndTimestamp() throws {
        let base = try sampleSnapshot()
        let old = try XCTUnwrap(base.cycleHistory.first)
        let recordedAt = try fixedDate("2026-09-11T15:09:56Z")
        let record = QuotaSnapshot(
            limitID: "codex", usedPercent: 76, windowDurationMinutes: 10_080,
            startsAt: old.startsAt, resetsAt: old.endsAt, fetchedAt: recordedAt
        )
        let partial = QuotaCycle(
            startsAt: old.startsAt, endsAt: old.endsAt, usage: old.usage,
            displayedTokens: old.displayedTokens, status: old.status,
            boundaryIsEstimated: false, lastRecordedQuota: record
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: base.today, currentCycle: base.currentCycle,
            recentDays: base.recentDays, cycleHistory: [partial],
            lastUpdatedAt: base.lastUpdatedAt, status: base.status
        )
        let entry = try XCTUnwrap(CycleHistoryPresentation(snapshot: snapshot, timeZone: timeZone).entries.last)
        XCTAssertEqual(entry.quotaPercent, "76%")
        XCTAssertEqual(entry.quotaUsage, "最后记录 76%（记录不完整）")
        XCTAssertTrue(entry.quotaIsPartial)
        XCTAssertEqual(entry.quotaHelp, "最后记录于 2026/9/11 23:09：76%。记录不完整，周期结束时的最终已用额度未知。")
    }

    func testCurrentCycleDetailsIncludeItsOfficialQuotaReadTime() throws {
        let base = try sampleSnapshot()
        let current = try XCTUnwrap(base.currentCycle)
        let quota = try XCTUnwrap(base.quota)
        let cycle = QuotaCycle(
            startsAt: current.startsAt, endsAt: current.endsAt, usage: current.usage,
            displayedTokens: current.displayedTokens, status: current.status,
            boundaryIsEstimated: false, quotaUsedPercent: quota.usedPercent
        )
        let snapshot = UsageSnapshot(
            quota: quota, today: base.today, currentCycle: cycle,
            recentDays: base.recentDays, cycleHistory: base.cycleHistory,
            lastUpdatedAt: base.lastUpdatedAt, status: base.status
        )
        let entry = try XCTUnwrap(CycleHistoryPresentation(snapshot: snapshot, timeZone: timeZone).entries.first)

        XCTAssertEqual(entry.quotaHelp, "当前周期累计已用额度，来自最近一次官方额度记录。采集于 2026/9/1 16:00。")
        XCTAssertFalse(entry.quotaIsPartial)
    }

    func testHistoricalCycleWithOnlyLocalTokensUsesLocalStatisticsLabel() throws {
        let base = try sampleSnapshot()
        let old = try XCTUnwrap(base.cycleHistory.first)
        let cycle = QuotaCycle(
            startsAt: old.startsAt, endsAt: old.endsAt, usage: old.usage,
            displayedTokens: old.displayedTokens, status: .localLive,
            boundaryIsEstimated: false
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: base.today, currentCycle: nil,
            recentDays: base.recentDays, cycleHistory: [cycle],
            lastUpdatedAt: base.lastUpdatedAt, status: base.status
        )

        XCTAssertEqual(CycleHistoryPresentation(snapshot: snapshot, timeZone: timeZone)
            .entries.first?.statusLabel, "本地统计")
    }

    func testCycleDailyDetailsUseItsOwnHistoryAndExplainTokenSources() throws {
        let base = try sampleSnapshot()
        let start = try fixedDate("2026-08-01T04:30:01Z")
        let midnight = try fixedDate("2026-08-01T16:00:00Z")
        let nextMidnight = try fixedDate("2026-08-02T16:00:00Z")
        let end = try fixedDate("2026-08-03T04:10:02Z")
        let cycle = QuotaCycle(
            startsAt: start, endsAt: end, usage: .zero,
            displayedTokens: 1_234_568_000, status: .partiallyCalibrated,
            boundaryIsEstimated: false, dailyUsage: [
                CycleUsageDay(day: LocalDay(year: 2026, month: 8, day: 1),
                    startsAt: start, endsAt: midnight, displayedTokens: 100,
                    status: .localLive, quotaConsumedPercent: 0),
                CycleUsageDay(day: LocalDay(year: 2026, month: 8, day: 2),
                    startsAt: midnight, endsAt: nextMidnight, displayedTokens: 1_234_567_890,
                    status: .calibrated, recordedQuotaConsumedPercent: 12),
                CycleUsageDay(day: LocalDay(year: 2026, month: 8, day: 3),
                    startsAt: nextMidnight, endsAt: end, displayedTokens: 10,
                    status: .localLive)
            ]
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: base.today, currentCycle: nil,
            recentDays: base.recentDays, cycleHistory: [cycle],
            lastUpdatedAt: base.lastUpdatedAt, status: base.status
        )
        let entry = try XCTUnwrap(CycleHistoryPresentation(snapshot: snapshot, timeZone: timeZone).entries.first)
        let days = try XCTUnwrap(entry.dailyUsage)

        XCTAssertEqual(days.map(\.dateLabel), ["8/3", "8/2", "8/1"])
        XCTAssertEqual(days.map(\.tokens), [10, 1_234_567_890, 100])
        XCTAssertEqual(days.reduce(0) { $0 + $1.tokens }, entry.tokens)
        XCTAssertEqual(days.map(\.sourceLabel), ["本地统计", "官方校准", "本地统计"])
        XCTAssertEqual(days.map(\.quotaLabel), ["—", "已记录 12%", "0%"])
        XCTAssertEqual(days.map(\.quotaIsPartial), [false, true, false])
        XCTAssertEqual(days.first?.timeRange, "00:00–12:10")
        XCTAssertEqual(days.last?.timeRange, "12:30–24:00")
        XCTAssertTrue(entry.calibrationHelp.contains("1 天采用官方 Token"))
        XCTAssertTrue(entry.calibrationHelp.contains("2 个日内时段使用本地记录"))
    }

    func testCycleWithoutDailyRecordsDoesNotInventZeroRows() throws {
        let entry = try XCTUnwrap(CycleHistoryPresentation(
            snapshot: sampleSnapshot(), timeZone: timeZone
        ).entries.first)

        XCTAssertNil(entry.dailyUsage)
        XCTAssertTrue(entry.calibrationHelp.contains("原始逐日记录不足"))
    }

    func testCycleDetailsKeepCalibratedTotalAndShowBoundariesToTheMinute() throws {
        let base = try sampleSnapshot()
        let cycle = QuotaCycle(
            startsAt: try fixedDate("2026-12-31T16:00:01Z"),
            endsAt: try fixedDate("2026-12-31T16:15:59Z"),
            usage: TokenBreakdown(inputTokens: 700, cachedInputTokens: 280, outputTokens: 140),
            displayedTokens: 1_234_567_890, status: .partiallyCalibrated,
            boundaryIsEstimated: true
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: base.today, currentCycle: nil,
            recentDays: base.recentDays, cycleHistory: [cycle],
            lastUpdatedAt: base.lastUpdatedAt, status: base.status
        )
        let entry = try XCTUnwrap(CycleHistoryPresentation(snapshot: snapshot, timeZone: timeZone).entries.first)

        XCTAssertEqual(entry.startTime, "2027/1/1 00:00")
        XCTAssertEqual(entry.endTime, "2027/1/1 00:15")
        XCTAssertEqual(entry.tokens, 1_234_567_890)
        XCTAssertEqual(entry.statusLabel, "部分校准")
        XCTAssertTrue(entry.boundaryIsEstimated)
        XCTAssertFalse(entry.isCurrent)
        XCTAssertEqual(entry.quotaUsage, "额度记录不足")
        XCTAssertFalse(entry.quotaHelp.contains("2026/9/1"))
    }

    func testOverviewMapsQuotaCycleAndStaleState() throws {
        let presentation = OverviewPresentation(
            snapshot: try sampleSnapshot(status: .stale),
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.remainingPercent, "62%")
        XCTAssertEqual(presentation.progress, 0.62, accuracy: 0.001)
        XCTAssertEqual(presentation.resetCountdown, "1 天后重置")
        XCTAssertEqual(presentation.resetTime, "09/02 · 16:00")
        XCTAssertEqual(presentation.staleMessage, "数据可能已过期")
        XCTAssertFalse(presentation.currentCycleTokens.isEmpty)
        XCTAssertEqual(presentation.currentCycleStatus, "数据可能已过期")
    }

    func testOverviewUsesPlaceholdersWhenQuotaAndCycleAreMissing() throws {
        let base = try sampleSnapshot()
        let snapshot = UsageSnapshot(
            quota: nil,
            today: base.today,
            currentCycle: nil,
            recentDays: base.recentDays,
            cycleHistory: base.cycleHistory,
            lastUpdatedAt: base.lastUpdatedAt,
            status: base.status
        )

        let presentation = OverviewPresentation(
            snapshot: snapshot,
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.remainingPercent, "--")
        XCTAssertEqual(presentation.progress, 0)
        XCTAssertEqual(presentation.resetCountdown, "暂无数据")
        XCTAssertNil(presentation.resetTime)
        XCTAssertEqual(presentation.currentCycleTokens, "--")
        XCTAssertEqual(presentation.currentCycleStatus, "暂无数据")
        XCTAssertEqual(presentation.currentCycleQuota, "额度记录不足")
        XCTAssertEqual(presentation.todayQuota.summary, "额度记录不足")
    }

    func testOverviewClampsProgressToValidRange() throws {
        let over = OverviewPresentation(
            snapshot: try sampleSnapshot(remainingPercent: 140),
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: timeZone
        )
        let under = OverviewPresentation(
            snapshot: try sampleSnapshot(remainingPercent: -20),
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(over.progress, 1)
        XCTAssertEqual(under.progress, 0)
    }

    func testOverviewFormatsLastUpdatedRelativeToNow() throws {
        let base = try sampleSnapshot()
        let now = try fixedDate("2026-09-01T08:00:00Z")
        let snapshot = UsageSnapshot(
            quota: base.quota,
            today: base.today,
            currentCycle: base.currentCycle,
            recentDays: base.recentDays,
            cycleHistory: base.cycleHistory,
            lastUpdatedAt: now.addingTimeInterval(-7 * 60),
            status: base.status
        )

        let presentation = OverviewPresentation(
            snapshot: snapshot,
            now: now,
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.lastUpdated, "7 分钟前更新")
        XCTAssertNil(presentation.staleMessage)
    }

    func testTrendUsesSevenMostRecentDaysAndComputesAverage() throws {
        let snapshot = try sampleSnapshot(
            recentDayTotals: [100, 200, 300, 400, 500, 600, 700, 800]
        )

        let trend = TrendPresentation(snapshot: snapshot)

        XCTAssertEqual(
            trend.days.map(\.tokens),
            [200, 300, 400, 500, 600, 700, 800]
        )
        XCTAssertEqual(trend.totalTokens, 3_500)
        XCTAssertEqual(trend.averageTokens, 500)
    }

    func testTrendUsesSharedChineseCompactTokenUnits() throws {
        let snapshot = try sampleSnapshot(
            recentDayTotals: [
                321_941_660,
                684_928_819,
                685_907_642,
                82_000_000,
                0
            ]
        )

        XCTAssertEqual(
            TrendPresentation(snapshot: snapshot)
                .days.map(\.formattedTokens),
            ["3.2亿", "6.8亿", "6.9亿", "8200.0万", "0"]
        )
    }

    func testTrendDisplaysObservedQuotaConsumptionAlongsideDailyTokens() throws {
        let base = try sampleSnapshot()
        let today = UsageDay(
            day: base.today.day,
            localUsage: base.today.localUsage,
            officialTokens: nil,
            displayedTokens: 120,
            status: .localLive,
            quotaConsumedPercent: 12.34
        )
        let snapshot = UsageSnapshot(
            quota: base.quota,
            today: today,
            currentCycle: base.currentCycle,
            recentDays: [base.recentDays[0], today],
            cycleHistory: base.cycleHistory,
            lastUpdatedAt: base.lastUpdatedAt,
            status: base.status
        )

        let trend = TrendPresentation(snapshot: snapshot)

        XCTAssertEqual(trend.days.map(\.quotaPercent), ["--", "12.3%"])
        XCTAssertEqual(trend.days.last?.formattedTokens, "120")
        XCTAssertEqual(trend.days.last?.status, .localLive)
        XCTAssertTrue(trend.days.allSatisfy { $0.quotaSegments.isEmpty && $0.resetLabel == nil })
    }

    func testTrendDoesNotPresentCrossResetSumAsSingleCyclePercentage() throws {
        let base = try sampleSnapshot()
        let start = Date(timeIntervalSince1970: 1788883200)
        let reset = start.addingTimeInterval(16 * 3600 + 28 * 60 + 52)
        let end = start.addingTimeInterval(17 * 3600)
        let today = UsageDay(
            day: base.today.day, localUsage: base.today.localUsage,
            officialTokens: nil, displayedTokens: 380_000_000, status: .localLive,
            quotaConsumedPercent: 58,
            quotaSegments: [
                QuotaConsumptionSegment(startsAt: start, endsAt: reset, consumedPercent: 52, startsWithReset: false),
                QuotaConsumptionSegment(startsAt: reset, endsAt: end, consumedPercent: 6, startsWithReset: true)
            ]
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: today, currentCycle: base.currentCycle,
            recentDays: [today], cycleHistory: [], lastUpdatedAt: end, status: .localLive
        )
        let trend = TrendPresentation(snapshot: snapshot, timeZone: timeZone)
        XCTAssertEqual(trend.days.first?.quotaSegments.map(\.label), ["重置前", "重置后"])
        XCTAssertEqual(trend.days.first?.quotaSegments.map(\.percent), ["52%", "6%"])
        XCTAssertEqual(trend.days.first?.resetLabel, "16:28 重置")
        XCTAssertTrue(trend.days.first?.quotaHelp.contains("16:28:52") == true)
        XCTAssertEqual(
            TrendPresentation(snapshot: snapshot, timeZone: TimeZone(secondsFromGMT: 0)!).days.first?.resetLabel,
            "08:28 重置"
        )
        XCTAssertEqual(trend.days.first?.quotaPercent, "已分段")
        XCTAssertEqual(trend.days.first?.formattedTokens, "3.8亿")
        XCTAssertEqual(trend.totalTokens, 380_000_000)
        let overview = OverviewPresentation(snapshot: snapshot, now: end, timeZone: timeZone)
        XCTAssertEqual(overview.todayQuota.summary, "重置前 52% · 重置后 6%")
        XCTAssertEqual(overview.todayQuota.segments.map(\.percent), ["52%", "6%"])
        XCTAssertEqual(overview.todayQuota.help, trend.days.first?.quotaHelp)
    }

    func testTrendLabelsMultipleResetsChronologicallyAndPreservesUnknownSegments() throws {
        let base = try sampleSnapshot()
        let start = Date(timeIntervalSince1970: 1788883200)
        let firstReset = start.addingTimeInterval(10 * 3600)
        let secondReset = start.addingTimeInterval(16 * 3600)
        let end = start.addingTimeInterval(17 * 3600)
        let day = UsageDay(
            day: base.today.day, localUsage: base.today.localUsage,
            officialTokens: nil, displayedTokens: 100, status: .localLive,
            quotaSegments: [
                QuotaConsumptionSegment(startsAt: start, endsAt: firstReset, consumedPercent: nil, startsWithReset: false),
                QuotaConsumptionSegment(startsAt: firstReset, endsAt: secondReset, consumedPercent: 5, startsWithReset: true),
                QuotaConsumptionSegment(startsAt: secondReset, endsAt: end, consumedPercent: 6, startsWithReset: true)
            ]
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: day, currentCycle: base.currentCycle,
            recentDays: [day], cycleHistory: [], lastUpdatedAt: end, status: .localLive
        )
        let row = try XCTUnwrap(TrendPresentation(snapshot: snapshot, timeZone: timeZone).days.first)
        XCTAssertEqual(row.quotaSegments.map(\.label), ["第1段", "第2段", "第3段"])
        XCTAssertEqual(row.quotaSegments.map(\.percent), ["记录不足", "5%", "6%"])
        XCTAssertEqual(row.resetLabel, "重置 2 次")
        XCTAssertTrue(row.quotaHelp.contains("9/9 10:00:00–9/9 16:00:00"))
        let overview = OverviewPresentation(snapshot: snapshot, now: end, timeZone: timeZone)
        XCTAssertEqual(overview.todayQuota.summary, "分3段：记录不足 / 5% / 6%")
    }

    func testTrendShowsBothDatesForAMidnightToMidnightSegment() throws {
        let base = try sampleSnapshot()
        let start = Date(timeIntervalSince1970: 1788796800)
        let end = start.addingTimeInterval(24 * 3600)
        let day = UsageDay(
            day: LocalDay(year: 2026, month: 9, day: 8), localUsage: .zero,
            officialTokens: 100, displayedTokens: 100, status: .calibrated,
            quotaSegments: [
                QuotaConsumptionSegment(startsAt: start, endsAt: end, consumedPercent: 46, startsWithReset: true)
            ]
        )
        let snapshot = UsageSnapshot(
            quota: base.quota, today: base.today, currentCycle: base.currentCycle,
            recentDays: [day], cycleHistory: [], lastUpdatedAt: end, status: .localLive
        )
        let row = try XCTUnwrap(TrendPresentation(snapshot: snapshot, timeZone: timeZone).days.first)
        XCTAssertTrue(row.quotaHelp.contains("9/8 00:00:00–9/9 00:00:00"))
        XCTAssertEqual(row.quotaSegments.map(\.label), ["重置后"])
    }

    func testTrendRetainsPerDayCalibrationStatus() throws {
        let snapshot = try sampleSnapshot(
            recentStatuses: [
                .calibrated,
                .partiallyCalibrated,
                .localLive
            ]
        )

        XCTAssertEqual(
            TrendPresentation(snapshot: snapshot)
                .days.suffix(3).map(\.status),
            [.calibrated, .partiallyCalibrated, .localLive]
        )
    }

    func testTrendDoesNotPadMissingDaysAndHandlesEmptyAverage() throws {
        let short = TrendPresentation(
            snapshot: try sampleSnapshot(recentDayTotals: [100, 300, 500])
        )
        let empty = TrendPresentation(
            snapshot: try sampleSnapshot(recentDayTotals: [])
        )

        XCTAssertEqual(short.days.map(\.tokens), [100, 300, 500])
        XCTAssertEqual(short.averageTokens, 300)
        XCTAssertTrue(empty.days.isEmpty)
        XCTAssertEqual(empty.totalTokens, 0)
        XCTAssertEqual(empty.averageTokens, 0)
    }

    func testCycleHistoryContainsCurrentThenEightCompletedCycles() throws {
        let snapshot = try sampleSnapshot(completedCycleCount: 10)

        let history = CycleHistoryPresentation(
            snapshot: snapshot,
            timeZone: timeZone
        )

        XCTAssertEqual(history.entries.count, 9)
        XCTAssertTrue(history.entries[0].isCurrent)
        XCTAssertTrue(
            history.entries.dropFirst().allSatisfy { !$0.isCurrent }
        )
    }

    func testCycleHistoryUsesChineseCompactTokenUnits() throws {
        let base = try sampleSnapshot()
        let current = try XCTUnwrap(base.currentCycle)
        let largeCurrent = QuotaCycle(
            startsAt: current.startsAt,
            endsAt: current.endsAt,
            usage: current.usage,
            displayedTokens: 1_455_000_000,
            status: current.status,
            boundaryIsEstimated: current.boundaryIsEstimated
        )
        let snapshot = UsageSnapshot(
            quota: base.quota,
            today: base.today,
            currentCycle: largeCurrent,
            recentDays: base.recentDays,
            cycleHistory: base.cycleHistory,
            lastUpdatedAt: base.lastUpdatedAt,
            status: base.status
        )

        let history = CycleHistoryPresentation(
            snapshot: snapshot,
            timeZone: timeZone
        )

        XCTAssertEqual(history.entries.first?.formattedTokens, "14.6亿")
    }

    func testCycleHistorySortsNewestFirstAndRemovesCurrentDuplicate() throws {
        let base = try sampleSnapshot(completedCycleCount: 4)
        let current = try XCTUnwrap(base.currentCycle)
        let snapshot = UsageSnapshot(
            quota: base.quota,
            today: base.today,
            currentCycle: current,
            recentDays: base.recentDays,
            cycleHistory: [
                base.cycleHistory[2],
                current,
                base.cycleHistory[3],
                base.cycleHistory[0],
                base.cycleHistory[1],
                base.cycleHistory[0]
            ],
            lastUpdatedAt: base.lastUpdatedAt,
            status: base.status
        )

        let entries = CycleHistoryPresentation(
            snapshot: snapshot,
            timeZone: timeZone
        ).entries

        XCTAssertEqual(entries.count, 5)
        XCTAssertEqual(entries[0].id, current.startsAt)
        XCTAssertEqual(
            Array(entries.dropFirst().map(\.id)),
            base.cycleHistory.map(\.startsAt)
        )
    }
}
