import Foundation
import UsageCore
import XCTest
@testable import CodexUsage

final class UsageFormattersTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    func testRemainingPercentClampsRoundsAndHandlesMissingValue() {
        XCTAssertEqual(UsageFormatters.remainingPercent(nil), "--")
        XCTAssertEqual(UsageFormatters.remainingPercent(-2), "0%")
        XCTAssertEqual(UsageFormatters.remainingPercent(62.4), "62%")
        XCTAssertEqual(UsageFormatters.remainingPercent(99.6), "100%")
        XCTAssertEqual(UsageFormatters.remainingPercent(120), "100%")
    }

    func testMenuBarTitleUsesDataEmptyAndFatalStates() {
        XCTAssertEqual(
            UsageFormatters.menuBarTitle(
                remainingPercent: 62.4,
                isFatal: false
            ),
            "◔ 62%"
        )
        XCTAssertEqual(
            UsageFormatters.menuBarTitle(
                remainingPercent: nil,
                isFatal: false
            ),
            "◔ --"
        )
        XCTAssertEqual(
            UsageFormatters.menuBarTitle(
                remainingPercent: 62,
                isFatal: true
            ),
            "◔ !"
        )
    }

    func testTokensUseCompactStableUnits() {
        XCTAssertEqual(UsageFormatters.tokens(999), "999")
        XCTAssertEqual(UsageFormatters.tokens(1_200), "1.2K")
        XCTAssertEqual(UsageFormatters.tokens(12_000), "12K")
        XCTAssertEqual(UsageFormatters.tokens(1_250_000), "1.3M")
    }

    func testResetCountdownUsesChineseBoundaries() throws {
        let now = try fixedDate("2026-09-01T08:00:00Z")
        XCTAssertEqual(
            UsageFormatters.resetCountdown(
                resetsAt: now.addingTimeInterval(42 * 60),
                now: now
            ),
            "42 分钟后重置"
        )
        XCTAssertEqual(
            UsageFormatters.resetCountdown(
                resetsAt: now.addingTimeInterval(27 * 60 * 60),
                now: now
            ),
            "1 天 3 小时后重置"
        )
        XCTAssertEqual(
            UsageFormatters.resetCountdown(resetsAt: now, now: now),
            "即将重置"
        )
    }

    func testDateFormattingUsesInjectedTimeZoneAndLocale() throws {
        let value = try fixedDate("2026-09-01T08:05:00Z")

        XCTAssertEqual(
            UsageFormatters.dateTime(
                value,
                timeZone: timeZone,
                locale: Locale(identifier: "zh_CN")
            ),
            "9/1 16:05"
        )
        XCTAssertEqual(
            UsageFormatters.cycleRange(
                startsAt: try fixedDate("2026-08-25T08:00:00Z"),
                endsAt: value,
                timeZone: timeZone,
                locale: Locale(identifier: "zh_CN")
            ),
            "8/25 – 9/1"
        )
        XCTAssertEqual(
            UsageFormatters.day(LocalDay(year: 2026, month: 9, day: 1)),
            "9/1"
        )
    }

    func testLastUpdatedUsesRecentMinuteAndDateBoundaries() throws {
        let now = try fixedDate("2026-09-01T08:00:00Z")

        XCTAssertEqual(
            UsageFormatters.lastUpdated(
                now.addingTimeInterval(-30),
                now: now
            ),
            "刚刚更新"
        )
        XCTAssertEqual(
            UsageFormatters.lastUpdated(
                now.addingTimeInterval(-7 * 60),
                now: now
            ),
            "7 分钟前更新"
        )
        XCTAssertEqual(
            UsageFormatters.lastUpdated(
                now.addingTimeInterval(-2 * 60 * 60),
                now: now
            ),
            "9/1 14:00 更新"
        )
    }

    func testCalibrationLabelsAreExhaustive() {
        XCTAssertEqual(UsageFormatters.calibration(.localLive), "本机实时")
        XCTAssertEqual(UsageFormatters.calibration(.calibrated), "已校准")
        XCTAssertEqual(
            UsageFormatters.calibration(.partiallyCalibrated),
            "部分校准"
        )
        XCTAssertEqual(UsageFormatters.calibration(.stale), "数据可能已过期")
        XCTAssertEqual(UsageFormatters.calibration(.unavailable), "暂无数据")
    }

    private func fixedDate(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = formatter.date(from: text) {
            return value
        }

        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: text))
    }
}
