import Foundation
import XCTest
@testable import UsageCore

final class RefreshPolicyTests: XCTestCase {
    func testMidnightSamplingUsesLocalDayAndOnlyItsTenMinuteEdges() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        for (timestamp, expected) in [
            ("2026-10-22T15:49:59Z", false),
            ("2026-10-22T15:50:00Z", true),
            ("2026-10-22T15:59:59Z", true),
            ("2026-10-22T16:00:00Z", true),
            ("2026-10-22T16:09:59Z", true),
            ("2026-10-22T16:10:00Z", false),
            ("2026-10-22T23:55:00Z", false)
        ] {
            let now = try date(timestamp)
            let decision = RefreshPolicy().decision(
                now: now, reason: .scheduled,
                lastQuotaRefresh: now.addingTimeInterval(-60),
                lastOfficialRefresh: now.addingTimeInterval(-60), consecutiveFailures: 0,
                calendar: calendar
            )
            XCTAssertEqual(decision.refreshQuota, expected, timestamp)
            XCTAssertFalse(decision.refreshOfficialUsage)
            XCTAssertFalse(decision.indexSessions)
        }
    }

    func testBoundarySamplingDoesNotPollMoreThanOncePerMinute() throws {
        let now = try date("2026-10-22T23:55:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let decision = RefreshPolicy().decision(
            now: now, reason: .scheduled, lastQuotaRefresh: now.addingTimeInterval(-59),
            lastOfficialRefresh: now, consecutiveFailures: 0, calendar: calendar,
            quotaResetsAt: now.addingTimeInterval(30)
        )
        XCTAssertFalse(decision.refreshQuota)
    }

    func testResetSamplingOnlyAcceleratesDuringLastTenMinutes() throws {
        let now = try date("2026-10-22T12:00:00Z")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for (seconds, expected) in [(601.0, false), (600.0, true), (1.0, true), (-1.0, false)] {
            let decision = RefreshPolicy().decision(
                now: now, reason: .scheduled, lastQuotaRefresh: now.addingTimeInterval(-60),
                lastOfficialRefresh: now, consecutiveFailures: 0, calendar: calendar,
                quotaResetsAt: now.addingTimeInterval(seconds)
            )
            XCTAssertEqual(decision.refreshQuota, expected)
        }
    }

    func testPopoverRefreshesMinuteOldQuotaButNotFreshOfficialUsage() {
        let now = Date(timeIntervalSince1970: 10_000)
        let decision = RefreshPolicy().decision(
            now: now,
            reason: .popoverOpened,
            lastQuotaRefresh: now.addingTimeInterval(-61),
            lastOfficialRefresh: now.addingTimeInterval(-120),
            consecutiveFailures: 0
        )

        XCTAssertTrue(decision.refreshQuota)
        XCTAssertFalse(decision.refreshOfficialUsage)
        XCTAssertTrue(decision.indexSessions)
    }

    func testScheduledRefreshUsesRemoteIntervalsWithoutPeriodicSessionScan() {
        let now = Date(timeIntervalSince1970: 10_000)
        let decision = RefreshPolicy().decision(
            now: now,
            reason: .scheduled,
            lastQuotaRefresh: now.addingTimeInterval(-301),
            lastOfficialRefresh: now.addingTimeInterval(-1_801),
            consecutiveFailures: 0
        )

        XCTAssertTrue(decision.refreshQuota)
        XCTAssertTrue(decision.refreshOfficialUsage)
        XCTAssertFalse(decision.indexSessions)
    }

    func testExactAgeBoundariesRefreshWithoutWaitingAnExtraSecond() {
        let now = Date(timeIntervalSince1970: 10_000)

        let popover = RefreshPolicy().decision(
            now: now,
            reason: .popoverOpened,
            lastQuotaRefresh: now.addingTimeInterval(-60),
            lastOfficialRefresh: now.addingTimeInterval(-1_800),
            consecutiveFailures: 0
        )
        let scheduled = RefreshPolicy().decision(
            now: now,
            reason: .scheduled,
            lastQuotaRefresh: now.addingTimeInterval(-300),
            lastOfficialRefresh: now.addingTimeInterval(-1_800),
            consecutiveFailures: 0
        )

        XCTAssertEqual(
            popover,
            RefreshDecision(
                refreshQuota: true,
                refreshOfficialUsage: true,
                indexSessions: true
            )
        )
        XCTAssertEqual(
            scheduled,
            RefreshDecision(
                refreshQuota: true,
                refreshOfficialUsage: true,
                indexSessions: false
            )
        )
    }

    func testFutureRefreshTimestampsAreFresh() {
        let now = Date(timeIntervalSince1970: 10_000)
        let decision = RefreshPolicy().decision(
            now: now,
            reason: .scheduled,
            lastQuotaRefresh: .distantFuture,
            lastOfficialRefresh: .distantFuture,
            consecutiveFailures: Int.max
        )

        XCTAssertFalse(decision.refreshQuota)
        XCTAssertFalse(decision.refreshOfficialUsage)
        XCTAssertFalse(decision.indexSessions)
    }

    func testNegativeRefreshTimestampsAreDueWithoutOverflow() {
        let decision = RefreshPolicy().decision(
            now: Date(timeIntervalSince1970: 10_000),
            reason: .scheduled,
            lastQuotaRefresh: Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude),
            lastOfficialRefresh: Date(timeIntervalSince1970: -Double.greatestFiniteMagnitude),
            consecutiveFailures: Int.min
        )

        XCTAssertTrue(decision.refreshQuota)
        XCTAssertTrue(decision.refreshOfficialUsage)
        XCTAssertFalse(decision.indexSessions)
    }

    func testImmediateReasonsRefreshEverythingAndFileChangesOnlyIndex() {
        let now = Date(timeIntervalSince1970: 10_000)
        for reason in [RefreshReason.startup, .wake, .manual] {
            XCTAssertEqual(
                RefreshPolicy().decision(
                    now: now,
                    reason: reason,
                    lastQuotaRefresh: .distantFuture,
                    lastOfficialRefresh: .distantFuture,
                    consecutiveFailures: Int.max
                ),
                RefreshDecision(
                    refreshQuota: true,
                    refreshOfficialUsage: true,
                    indexSessions: true
                )
            )
        }

        XCTAssertEqual(
            RefreshPolicy().decision(
                now: now,
                reason: .sessionFilesChanged,
                lastQuotaRefresh: nil,
                lastOfficialRefresh: nil,
                consecutiveFailures: 0
            ),
            RefreshDecision(
                refreshQuota: false,
                refreshOfficialUsage: false,
                indexSessions: true
            )
        )
    }

    func testBackoffClampsNegativeFailuresAndCapsAtFifteenMinutes() {
        let policy = RefreshPolicy()

        XCTAssertEqual(
            policy.retryDelay(consecutiveFailures: Int.min),
            .seconds(30)
        )
        XCTAssertEqual(
            policy.retryDelay(consecutiveFailures: 5),
            .seconds(900)
        )
        XCTAssertEqual(
            policy.retryDelay(consecutiveFailures: Int.max),
            .seconds(900)
        )
    }
}
