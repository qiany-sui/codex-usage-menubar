import XCTest
@testable import UsageCore

final class CycleTrackerTests: XCTestCase {
    func testPrependsEightEstimatedCyclesWithoutEstimatingObservedCurrentBoundary() {
        let start = Date(timeIntervalSince1970: 10_000_000)
        let duration = TimeInterval(10_080 * 60)

        let cycles = CycleTracker().update(
            existing: [],
            quota: quota(
                startsAt: start,
                endsAt: start.addingTimeInterval(duration)
            ),
            events: []
        )

        XCTAssertEqual(cycles.count, 9)
        XCTAssertEqual(cycles.first?.startsAt, start.addingTimeInterval(-8 * duration))
        XCTAssertTrue(cycles.dropLast().allSatisfy(\.boundaryIsEstimated))
        XCTAssertFalse(cycles.last?.boundaryIsEstimated ?? true)
        XCTAssertEqual(
            zip(cycles, cycles.dropFirst()).map { $0.endsAt == $1.startsAt },
            Array(repeating: true, count: 8)
        )
    }

    func testEstimatedDuplicateDoesNotOverwriteRealObservedBoundary() {
        let firstStart = Date(timeIntervalSince1970: 1_000)
        let duration = TimeInterval(10_080 * 60)
        let currentStart = firstStart.addingTimeInterval(duration)
        let existing = [
            cycle(
                startsAt: firstStart,
                endsAt: currentStart,
                boundaryIsEstimated: false
            ),
            cycle(
                startsAt: firstStart.addingTimeInterval(0.5),
                endsAt: currentStart,
                boundaryIsEstimated: true
            ),
            cycle(
                startsAt: currentStart,
                endsAt: currentStart.addingTimeInterval(duration),
                boundaryIsEstimated: false
            )
        ]

        let cycles = CycleTracker().update(
            existing: existing,
            quota: quota(
                startsAt: currentStart,
                endsAt: currentStart.addingTimeInterval(duration)
            ),
            events: []
        )

        XCTAssertFalse(cycles.first { $0.startsAt == firstStart }?.boundaryIsEstimated ?? true)
    }

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

        let observed = Array(cycles.suffix(2))
        XCTAssertEqual(cycles.count, 9)
        XCTAssertEqual(observed[0].endsAt, newStart)
        XCTAssertEqual(observed[1].startsAt, newStart)
        XCTAssertEqual(observed[1].usage, event.usage)
        XCTAssertEqual(observed[1].displayedTokens, 120)
        XCTAssertEqual(observed[1].status, .localLive)
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

        XCTAssertEqual(cycles.count, 9)
        XCTAssertEqual(cycles.last?.startsAt, start)
        XCTAssertEqual(cycles.last?.endsAt, start.addingTimeInterval(200))
        XCTAssertEqual(cycles.last?.usage, event.usage)
    }

    func testResetTimeDriftWithinOneMinuteDoesNotSplitCurrentCycle() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let end = start.addingTimeInterval(10_080 * 60)
        let event = storedEvent(
            at: start.addingTimeInterval(10),
            input: 7,
            output: 5
        )

        for drift: TimeInterval in [-36, 36, 60] {
            let cycles = CycleTracker().update(
                existing: [cycle(startsAt: start, endsAt: end)],
                quota: quota(
                    startsAt: start.addingTimeInterval(drift),
                    endsAt: end.addingTimeInterval(drift)
                ),
                events: [event]
            )

            let observed = cycles.filter { !$0.boundaryIsEstimated }
            XCTAssertEqual(observed.count, 1, "drift: \(drift)")
            XCTAssertEqual(observed.last?.startsAt, start)
            XCTAssertEqual(observed.last?.endsAt, end.addingTimeInterval(drift))
            XCTAssertEqual(observed.last?.displayedTokens, 12)
        }
    }

    func testRepairsStored36SecondCycleWithoutLosingUsageOrMergingRealReset() throws {
        let previousStart = try date("2026-09-07T10:29:40+08:00")
        let start = try date("2026-09-08T10:31:40+08:00")
        let correctedStart = try date("2026-09-08T10:32:16+08:00")
        let end = try date("2026-09-15T10:32:16+08:00")
        let existing = [
            cycle(startsAt: previousStart, endsAt: start),
            cycle(startsAt: start, endsAt: correctedStart),
            cycle(startsAt: correctedStart, endsAt: end)
        ]
        let events = [
            storedEvent(at: start.addingTimeInterval(-1), input: 100, output: 20),
            storedEvent(at: start.addingTimeInterval(10), input: 7, output: 5),
            storedEvent(at: correctedStart, input: 11, output: 3)
        ]
        let quota = quota(startsAt: correctedStart, endsAt: end)

        for stored in [existing, Array(existing.reversed())] {
            let cycles = CycleTracker().update(
                existing: stored,
                quota: quota,
                events: events
            )

            let observed = cycles.filter { !$0.boundaryIsEstimated }
            XCTAssertEqual(observed.map(\.startsAt), [previousStart, start])
            XCTAssertEqual(observed.map(\.endsAt), [start, end])
            XCTAssertEqual(observed.map(\.displayedTokens), [120, 26])
            XCTAssertEqual(cycles.count, 9)
            XCTAssertEqual(
                CycleTracker().update(existing: cycles, quota: quota, events: events),
                cycles,
                "refreshing the repaired history must not create another fragment"
            )
        }
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

        XCTAssertEqual(cycles.count, 9)
        XCTAssertEqual(cycles.last?.startsAt, start)
        XCTAssertEqual(cycles.last?.endsAt, current.endsAt)
        XCTAssertEqual(cycles.last?.usage, event.usage)
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

        XCTAssertEqual(cycles.last?.usage, inside.usage)
        XCTAssertEqual(cycles.last?.displayedTokens, 12)
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

        XCTAssertEqual(cycles.last?.usage.inputTokens, .max)
        XCTAssertEqual(cycles.last?.displayedTokens, .max)
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

        let observed = Array(cycles.suffix(3))
        XCTAssertEqual(cycles.count, 9)
        XCTAssertEqual(observed.map(\.startsAt), [
            firstStart,
            secondStart,
            thirdStart
        ])
        XCTAssertEqual(
            observed[0].endsAt,
            secondStart,
            "overlap must be truncated to the next start"
        )
        XCTAssertFalse(observed[0].boundaryIsEstimated)
        XCTAssertEqual(
            observed[1].endsAt,
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

        let observed = Array(cycles.suffix(2))
        XCTAssertEqual(cycles.count, 9)
        XCTAssertEqual(observed[0].endsAt, existingEnd)
        XCTAssertEqual(observed[1].startsAt, quotaStart)
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
