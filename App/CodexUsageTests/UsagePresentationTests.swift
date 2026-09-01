import Foundation
import UsageCore
import XCTest
@testable import CodexUsage

final class UsagePresentationTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

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

    func testOverviewMapsQuotaCycleAndStaleState() throws {
        let presentation = OverviewPresentation(
            snapshot: try sampleSnapshot(status: .stale),
            now: try fixedDate("2026-09-01T08:00:00Z"),
            timeZone: timeZone
        )

        XCTAssertEqual(presentation.remainingPercent, "62%")
        XCTAssertEqual(presentation.progress, 0.62, accuracy: 0.001)
        XCTAssertEqual(presentation.resetCountdown, "1 天后重置")
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
        XCTAssertEqual(presentation.currentCycleTokens, "--")
        XCTAssertEqual(presentation.currentCycleStatus, "暂无数据")
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
}
