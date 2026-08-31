import XCTest
@testable import UsageCore

final class CycleTrackerTests: XCTestCase {
    func testNewDerivedStartClosesPreviousCycleAndStartsAnother() {
        let oldStart = Date(timeIntervalSince1970: 1_000_000)
        let oldEnd = oldStart.addingTimeInterval(10_080 * 60)
        let old = cycle(startsAt: oldStart, endsAt: oldEnd)
        let newStart = oldStart.addingTimeInterval(3 * 24 * 60 * 60)
        let quota = quota(
            startsAt: newStart,
            endsAt: newStart.addingTimeInterval(10_080 * 60)
        )
        let event = storedEvent(
            at: newStart.addingTimeInterval(10),
            input: 100,
            output: 20
        )

        let cycles = CycleTracker().update(
            existing: [old],
            quota: quota,
            events: [event]
        )

        XCTAssertEqual(cycles.count, 2)
        XCTAssertEqual(cycles[0].endsAt, newStart)
        XCTAssertEqual(cycles[1].startsAt, newStart)
        XCTAssertEqual(cycles[1].usage, event.usage)
        XCTAssertEqual(cycles[1].displayedTokens, 120)
        XCTAssertEqual(cycles[1].status, .localLive)
    }

    func testStartWithinOneSecondUpdatesSameCycleEndAndUsage() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let old = cycle(
            startsAt: start,
            endsAt: start.addingTimeInterval(100)
        )
        let event = storedEvent(
            at: start.addingTimeInterval(150),
            input: 7,
            output: 5
        )

        let cycles = CycleTracker().update(
            existing: [old],
            quota: quota(
                startsAt: start.addingTimeInterval(1),
                endsAt: start.addingTimeInterval(200)
            ),
            events: [event]
        )

        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].startsAt, start)
        XCTAssertEqual(cycles[0].endsAt, start.addingTimeInterval(200))
        XCTAssertEqual(cycles[0].usage, event.usage)
    }

    func testOlderDerivedStartDoesNotMoveCurrentCycleBackward() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let current = cycle(
            startsAt: start,
            endsAt: start.addingTimeInterval(200)
        )
        let event = storedEvent(
            at: start.addingTimeInterval(50),
            input: 12,
            output: 3
        )

        let cycles = CycleTracker().update(
            existing: [current],
            quota: quota(
                startsAt: start.addingTimeInterval(-100),
                endsAt: start.addingTimeInterval(100)
            ),
            events: [event]
        )

        XCTAssertEqual(cycles.count, 1)
        XCTAssertEqual(cycles[0].startsAt, start)
        XCTAssertEqual(cycles[0].endsAt, current.endsAt)
        XCTAssertEqual(cycles[0].usage, event.usage)
    }

    func testCycleAggregationUsesHalfOpenInterval() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(100)
        let inside = storedEvent(
            at: end.addingTimeInterval(-1),
            input: 10,
            output: 2
        )
        let atEnd = storedEvent(
            at: end,
            input: 50,
            output: 8
        )

        let cycles = CycleTracker().update(
            existing: [],
            quota: quota(startsAt: start, endsAt: end),
            events: [inside, atEnd]
        )

        XCTAssertEqual(cycles.single?.usage, inside.usage)
        XCTAssertEqual(cycles.single?.displayedTokens, 12)
    }

    func testKeepsCurrentAndEightCompletedCycles() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let duration = TimeInterval(10_080 * 60)
        let cycles = (0..<12).map { index in
            let start = base.addingTimeInterval(
                TimeInterval(index) * duration
            )
            return cycle(
                startsAt: start,
                endsAt: start.addingTimeInterval(duration)
            )
        }
        let current = cycles[11]

        let retained = CycleTracker().update(
            existing: cycles,
            quota: quota(
                startsAt: current.startsAt,
                endsAt: current.endsAt
            ),
            events: []
        )

        XCTAssertEqual(retained.count, 9)
        XCTAssertEqual(retained.map(\.startsAt), cycles.suffix(9).map(\.startsAt))
        XCTAssertEqual(retained.last?.startsAt, current.startsAt)
    }

    func testAggregationClampsInsteadOfOverflowing() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(100)
        let events = [
            storedEvent(
                at: start.addingTimeInterval(1),
                input: .max,
                output: 0
            ),
            storedEvent(
                at: start.addingTimeInterval(2),
                input: 1,
                output: 0
            )
        ]

        let cycles = CycleTracker().update(
            existing: [],
            quota: quota(startsAt: start, endsAt: end),
            events: events
        )

        XCTAssertEqual(cycles.single?.usage.inputTokens, .max)
        XCTAssertEqual(cycles.single?.displayedTokens, .max)
    }

    func testNormalizesUnsortedDuplicateAndOverlappingCycles() {
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let secondStart = Date(timeIntervalSince1970: 2_100)
        let thirdStart = Date(timeIntervalSince1970: 4_000)
        let existing = [
            cycle(
                startsAt: thirdStart,
                endsAt: Date(timeIntervalSince1970: 5_000)
            ),
            cycle(
                startsAt: firstStart.addingTimeInterval(0.5),
                endsAt: Date(timeIntervalSince1970: 2_200),
                boundaryIsEstimated: true
            ),
            cycle(
                startsAt: secondStart,
                endsAt: Date(timeIntervalSince1970: 3_000)
            ),
            cycle(
                startsAt: firstStart,
                endsAt: Date(timeIntervalSince1970: 2_000)
            )
        ]

        let cycles = CycleTracker().update(
            existing: existing,
            quota: quota(
                startsAt: thirdStart,
                endsAt: Date(timeIntervalSince1970: 5_000)
            ),
            events: []
        )

        XCTAssertEqual(cycles.count, 3)
        XCTAssertEqual(cycles.map(\.startsAt), [
            firstStart,
            secondStart,
            thirdStart
        ])
        XCTAssertEqual(
            cycles[0].endsAt,
            secondStart,
            "overlap must be truncated to the next start"
        )
        XCTAssertTrue(cycles[0].boundaryIsEstimated)
        XCTAssertEqual(
            cycles[1].endsAt,
            Date(timeIntervalSince1970: 3_000),
            "an existing gap must not be expanded"
        )
    }

    func testNormalizationDoesNotDependOnExistingOrder() {
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let secondStart = Date(timeIntervalSince1970: 2_100)
        let thirdStart = Date(timeIntervalSince1970: 4_000)
        let existing = [
            cycle(
                startsAt: firstStart.addingTimeInterval(0.5),
                endsAt: Date(timeIntervalSince1970: 2_200),
                boundaryIsEstimated: true
            ),
            cycle(
                startsAt: thirdStart,
                endsAt: Date(timeIntervalSince1970: 5_000)
            ),
            cycle(
                startsAt: firstStart,
                endsAt: Date(timeIntervalSince1970: 2_000)
            ),
            cycle(
                startsAt: secondStart,
                endsAt: Date(timeIntervalSince1970: 3_000)
            )
        ]
        let quota = quota(
            startsAt: thirdStart,
            endsAt: Date(timeIntervalSince1970: 5_000)
        )

        let forward = CycleTracker().update(
            existing: existing,
            quota: quota,
            events: []
        )
        let reversed = CycleTracker().update(
            existing: Array(existing.reversed()),
            quota: quota,
            events: []
        )

        XCTAssertEqual(forward, reversed)
    }

    func testNewQuotaCycleDoesNotExpandExistingGap() {
        let start = Date(timeIntervalSince1970: 1_000)
        let existingEnd = Date(timeIntervalSince1970: 2_000)
        let quotaStart = Date(timeIntervalSince1970: 3_000)

        let cycles = CycleTracker().update(
            existing: [cycle(startsAt: start, endsAt: existingEnd)],
            quota: quota(
                startsAt: quotaStart,
                endsAt: Date(timeIntervalSince1970: 4_000)
            ),
            events: []
        )

        XCTAssertEqual(cycles.count, 2)
        XCTAssertEqual(cycles[0].endsAt, existingEnd)
        XCTAssertEqual(cycles[1].startsAt, quotaStart)
    }

    private func cycle(
        startsAt: Date,
        endsAt: Date,
        boundaryIsEstimated: Bool = false
    ) -> QuotaCycle {
        QuotaCycle(
            startsAt: startsAt,
            endsAt: endsAt,
            usage: .zero,
            displayedTokens: 0,
            status: .localLive,
            boundaryIsEstimated: boundaryIsEstimated
        )
    }

    private func quota(startsAt: Date, endsAt: Date) -> QuotaSnapshot {
        QuotaSnapshot(
            limitID: "codex",
            usedPercent: 20,
            windowDurationMinutes: 10_080,
            startsAt: startsAt,
            resetsAt: endsAt,
            fetchedAt: startsAt.addingTimeInterval(30)
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
