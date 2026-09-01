import Foundation
import UsageCore
import XCTest
@testable import CodexUsage

func temporaryAppDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "CodexUsageAppTests-" + UUID().uuidString,
            isDirectory: true
        )
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

func validCodexHome() throws -> URL {
    let root = try temporaryAppDirectory()
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("sessions", isDirectory: true),
        withIntermediateDirectories: true
    )
    return root
}

func fixedDate(_ text: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = formatter.date(from: text) {
        return value
    }

    formatter.formatOptions = [.withInternetDateTime]
    return try XCTUnwrap(formatter.date(from: text))
}

func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

func tokenJSONLine(
    timestamp: String = "2026-09-01T08:00:00.000Z",
    input: Int64,
    cached: Int64,
    output: Int64
) throws -> String {
    let value: [String: Any] = [
        "timestamp": timestamp,
        "type": "event_msg",
        "payload": [
            "type": "token_count",
            "info": [
                "last_token_usage": [
                    "input_tokens": input,
                    "cached_input_tokens": cached,
                    "output_tokens": output,
                    "reasoning_output_tokens": 0
                ]
            ]
        ]
    ]
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.sortedKeys]
    )
    return String(decoding: data, as: UTF8.self)
}

func sampleSnapshot(
    status: UsageCalibrationStatus = .calibrated,
    remainingPercent: Double = 62,
    today: TokenBreakdown = TokenBreakdown(
        inputTokens: 100,
        cachedInputTokens: 40,
        outputTokens: 20
    ),
    recentDayTotals: [Int64] = [60, 70, 80, 90, 100, 110, 120],
    recentStatuses: [UsageCalibrationStatus] = [],
    completedCycleCount: Int = 8
) throws -> UsageSnapshot {
    let now = try fixedDate("2026-09-01T08:00:00Z")
    let calendar = utcCalendar()
    let recentStart = try XCTUnwrap(
        calendar.date(byAdding: .day, value: 1 - recentDayTotals.count, to: now)
    )
    let statusOffset = max(recentDayTotals.count - recentStatuses.count, 0)
    let recentDays = try recentDayTotals.enumerated().map { index, total in
        let date = try XCTUnwrap(
            calendar.date(byAdding: .day, value: index, to: recentStart)
        )
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        let day = LocalDay(
            year: try XCTUnwrap(components.year),
            month: try XCTUnwrap(components.month),
            day: try XCTUnwrap(components.day)
        )
        let dayStatus = index >= statusOffset
            ? recentStatuses[index - statusOffset]
            : status
        let usage = TokenBreakdown(
            inputTokens: total,
            cachedInputTokens: 0,
            outputTokens: 0
        )
        return UsageDay(
            day: day,
            localUsage: usage,
            officialTokens: total,
            displayedTokens: total,
            status: dayStatus
        )
    }
    let cycleStart = try XCTUnwrap(
        calendar.date(byAdding: .day, value: -6, to: now)
    )
    let cycleEnd = try XCTUnwrap(
        calendar.date(byAdding: .day, value: 1, to: now)
    )
    let cycleUsage = TokenBreakdown(
        inputTokens: 700,
        cachedInputTokens: 280,
        outputTokens: 140
    )
    let currentCycle = QuotaCycle(
        startsAt: cycleStart,
        endsAt: cycleEnd,
        usage: cycleUsage,
        displayedTokens: cycleUsage.totalTokens,
        status: status,
        boundaryIsEstimated: false
    )
    let history = try (0 ..< completedCycleCount).map { index in
        let end = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -7 * index, to: cycleStart)
        )
        let start = try XCTUnwrap(
            calendar.date(byAdding: .day, value: -7, to: end)
        )
        let usage = TokenBreakdown(
            inputTokens: Int64(600 - min(index, 5) * 40),
            cachedInputTokens: Int64(200 - min(index, 5) * 20),
            outputTokens: Int64(120 - min(index, 5) * 10)
        )
        return QuotaCycle(
            startsAt: start,
            endsAt: end,
            usage: usage,
            displayedTokens: usage.totalTokens,
            status: status,
            boundaryIsEstimated: false
        )
    }
    let todayUsage = UsageDay(
        day: LocalDay(year: 2026, month: 9, day: 1),
        localUsage: today,
        officialTokens: today.totalTokens,
        displayedTokens: today.totalTokens,
        status: status
    )
    let quota = QuotaSnapshot(
        limitID: "weekly",
        usedPercent: 100 - remainingPercent,
        windowDurationMinutes: 10_080,
        startsAt: cycleStart,
        resetsAt: cycleEnd,
        fetchedAt: now
    )

    return UsageSnapshot(
        quota: quota,
        today: todayUsage,
        currentCycle: currentCycle,
        recentDays: recentDays,
        cycleHistory: history,
        lastUpdatedAt: now,
        status: status
    )
}
