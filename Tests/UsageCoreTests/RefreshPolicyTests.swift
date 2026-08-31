import Foundation
import XCTest
@testable import UsageCore

final class RefreshPolicyTests: XCTestCase {
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

    func testScheduledRefreshUsesFiveAndThirtyMinuteIntervals() {
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
        XCTAssertTrue(decision.indexSessions)
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
                indexSessions: true
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
        XCTAssertTrue(decision.indexSessions)
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
        XCTAssertTrue(decision.indexSessions)
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
