import XCTest
@testable import UsageCore

final class UsageReconcilerTests: XCTestCase {
    func testOfficialBucketReplacesOnlyCompletedNaturalDay() throws {
        let calendar = shanghaiCalendar()
        let now = try date("2026-08-31T12:00:00+08:00")
        let events = [
            event(
                at: try date("2026-08-30T10:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 30),
                input: 100,
                output: 20
            ),
            event(
                at: try date("2026-08-31T10:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 31),
                input: 200,
                output: 30
            )
        ]
        let official = [
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 30),
                tokens: 500,
                fetchedAt: now
            ),
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 31),
                tokens: 900,
                fetchedAt: now
            )
        ]

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: nil,
            events: events,
            officialDays: official,
            cycles: [],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.today.displayedTokens, 230)
        XCTAssertEqual(snapshot.today.status, .localLive)
        XCTAssertEqual(
            snapshot.recentDays.last { $0.day.day == 30 }?.displayedTokens,
            500
        )
        XCTAssertEqual(
            snapshot.recentDays.last { $0.day.day == 30 }?.status,
            .calibrated
        )
        XCTAssertEqual(snapshot.status, .unavailable)
    }

    func testDailyAggregationUsesStoredLocalDayInsteadOfTimestampDay() throws {
        let calendar = shanghaiCalendar()
        let now = try date("2026-08-31T12:00:00+08:00")
        let recordedDay = LocalDay(year: 2026, month: 8, day: 30)
        let event = event(
            at: try date("2026-08-31T10:00:00+08:00"),
            day: recordedDay,
            input: 40,
            output: 2
        )

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: nil,
            events: [event],
            officialDays: [],
            cycles: [],
            lastUpdatedAt: now
        )

        XCTAssertEqual(
            snapshot.recentDays.first { $0.day == recordedDay }?.localUsage,
            event.usage
        )
        XCTAssertEqual(snapshot.today.localUsage, .zero)
    }

    func testRecentDaysDoNotSkipDateAcrossDaylightSavingTransition() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(
            identifier: "America/Los_Angeles"
        )!
        let now = try date("2026-03-09T00:30:00-07:00")

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: nil,
            events: [],
            officialDays: [],
            cycles: [],
            lastUpdatedAt: now
        )

        XCTAssertEqual(
            snapshot.recentDays.map(\.day.iso8601),
            [
                "2026-03-03",
                "2026-03-04",
                "2026-03-05",
                "2026-03-06",
                "2026-03-07",
                "2026-03-08",
                "2026-03-09"
            ]
        )
    }

    func testMiddayCycleBoundaryUsesLocalEventsNotWholeOfficialDay() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T12:00:00+08:00")
        let endsAt = try date("2026-09-04T12:00:00+08:00")
        let now = try date("2026-08-31T12:00:00+08:00")
        let event = event(
            at: try date("2026-08-28T13:00:00+08:00"),
            day: LocalDay(year: 2026, month: 8, day: 28),
            input: 100,
            cached: 40,
            output: 20
        )
        let cycle = quotaCycle(
            startsAt: startsAt,
            endsAt: endsAt,
            usage: event.usage
        )
        let quota = quotaSnapshot(
            startsAt: startsAt,
            endsAt: endsAt,
            fetchedAt: now
        )
        let official = OfficialUsageDay(
            day: LocalDay(year: 2026, month: 8, day: 28),
            tokens: 1_000,
            fetchedAt: now
        )

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quota,
            events: [event],
            officialDays: [official],
            cycles: [cycle],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 120)
        XCTAssertEqual(snapshot.currentCycle?.usage, event.usage)
        XCTAssertEqual(
            snapshot.currentCycle?.status,
            .partiallyCalibrated
        )
        XCTAssertEqual(snapshot.status, .partiallyCalibrated)
    }

    func testCycleUsesOfficialTokensForEveryCoveredCompletedDay() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T00:00:00+08:00")
        let endsAt = try date("2026-09-04T00:00:00+08:00")
        let now = try date("2026-08-31T12:00:00+08:00")
        let events = [
            event(
                at: try date("2026-08-28T13:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 28),
                input: 100,
                output: 20
            ),
            event(
                at: try date("2026-08-29T13:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 29),
                input: 50,
                output: 10
            ),
            event(
                at: try date("2026-08-31T10:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 31),
                input: 18,
                output: 2
            )
        ]
        let localUsage = events.reduce(.zero) {
            addingForFixture($0, $1.usage)
        }
        let official = [
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 28),
                tokens: 500,
                fetchedAt: now
            ),
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 29),
                tokens: 300,
                fetchedAt: now
            ),
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: 30),
                tokens: 0,
                fetchedAt: now
            )
        ]

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            events: events,
            officialDays: official,
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: localUsage
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.currentCycle?.usage, localUsage)
        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 820)
        XCTAssertEqual(snapshot.currentCycle?.status, .calibrated)
    }

    func testCycleWithMissingOfficialCoverageIsPartiallyCalibrated() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T00:00:00+08:00")
        let endsAt = try date("2026-09-04T00:00:00+08:00")
        let now = try date("2026-08-31T12:00:00+08:00")
        let event = event(
            at: try date("2026-08-28T13:00:00+08:00"),
            day: LocalDay(year: 2026, month: 8, day: 28),
            input: 100,
            output: 20
        )

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            events: [event],
            officialDays: [
                OfficialUsageDay(
                    day: LocalDay(year: 2026, month: 8, day: 28),
                    tokens: 500,
                    fetchedAt: now
                )
            ],
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: event.usage
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 500)
        XCTAssertEqual(
            snapshot.currentCycle?.status,
            .partiallyCalibrated
        )
    }

    func testCycleSkipsOfficialReplacementWhenEventsExceedStoredUsage() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T00:00:00+08:00")
        let endsAt = try date("2026-09-04T00:00:00+08:00")
        let now = try date("2026-08-29T12:00:00+08:00")
        let day = LocalDay(year: 2026, month: 8, day: 28)
        let event = event(
            at: try date("2026-08-28T13:00:00+08:00"),
            day: day,
            input: 100,
            output: 0
        )

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            events: [event],
            officialDays: [
                OfficialUsageDay(day: day, tokens: 50, fetchedAt: now)
            ],
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: .zero
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 0)
        XCTAssertEqual(
            snapshot.currentCycle?.status,
            .partiallyCalibrated
        )
    }

    func testCycleSkipsOfficialReplacementWhenStoredUsageHasNoEvents() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T00:00:00+08:00")
        let endsAt = try date("2026-09-04T00:00:00+08:00")
        let now = try date("2026-08-29T12:00:00+08:00")
        let day = LocalDay(year: 2026, month: 8, day: 28)
        let usage = TokenBreakdown(
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0
        )

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            events: [],
            officialDays: [
                OfficialUsageDay(day: day, tokens: 50, fetchedAt: now)
            ],
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: usage
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 100)
        XCTAssertEqual(
            snapshot.currentCycle?.status,
            .partiallyCalibrated
        )
    }

    func testCycleReplacementAccumulatesExtremeValuesWithoutGoingNegative() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T00:00:00+08:00")
        let endsAt = try date("2026-09-04T00:00:00+08:00")
        let now = try date("2026-08-30T12:00:00+08:00")
        let firstDay = LocalDay(year: 2026, month: 8, day: 28)
        let secondDay = LocalDay(year: 2026, month: 8, day: 29)
        let events = [
            event(
                at: try date("2026-08-28T13:00:00+08:00"),
                day: firstDay,
                input: .max,
                output: 0
            ),
            event(
                at: try date("2026-08-29T13:00:00+08:00"),
                day: secondDay,
                input: 1,
                output: 0
            )
        ]
        let usage = TokenBreakdown(
            inputTokens: .max,
            cachedInputTokens: 0,
            outputTokens: 0
        )

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            events: events,
            officialDays: [firstDay, secondDay].map {
                OfficialUsageDay(day: $0, tokens: 0, fetchedAt: now)
            },
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: usage
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 0)
        XCTAssertEqual(snapshot.currentCycle?.status, .calibrated)
    }

    func testOfficialFullDayCanReplaceZeroLocalUsage() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T00:00:00+08:00")
        let endsAt = try date("2026-09-04T00:00:00+08:00")
        let now = try date("2026-08-29T12:00:00+08:00")
        let today = LocalDay(year: 2026, month: 8, day: 29)
        let event = event(
            at: try date("2026-08-29T10:00:00+08:00"),
            day: today,
            input: 10,
            output: 0
        )

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            events: [event],
            officialDays: [
                OfficialUsageDay(
                    day: LocalDay(year: 2026, month: 8, day: 28),
                    tokens: 50,
                    fetchedAt: now
                )
            ],
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: event.usage
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 60)
        XCTAssertEqual(snapshot.currentCycle?.status, .calibrated)
    }

    func testOnlyFullIntermediateDayUsesOfficialTokens() throws {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T12:00:00+08:00")
        let endsAt = try date("2026-08-30T12:00:00+08:00")
        let now = try date("2026-08-31T12:00:00+08:00")
        let events = [
            event(
                at: try date("2026-08-28T13:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 28),
                input: 100,
                output: 20
            ),
            event(
                at: try date("2026-08-29T13:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 29),
                input: 40,
                output: 10
            ),
            event(
                at: try date("2026-08-30T10:00:00+08:00"),
                day: LocalDay(year: 2026, month: 8, day: 30),
                input: 25,
                output: 5
            )
        ]
        let localUsage = events.reduce(.zero) {
            addingForFixture($0, $1.usage)
        }
        let official = [28, 29, 30].map { day in
            OfficialUsageDay(
                day: LocalDay(year: 2026, month: 8, day: day),
                tokens: day == 29 ? 500 : 1_000,
                fetchedAt: now
            )
        }

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            events: events,
            officialDays: official,
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: localUsage
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertNil(snapshot.currentCycle)
        XCTAssertEqual(snapshot.cycleHistory.single?.displayedTokens, 650)
        XCTAssertEqual(
            snapshot.cycleHistory.single?.status,
            .partiallyCalibrated
        )
    }

    func testCurrentCycleUsesHalfOpenInterval() throws {
        let calendar = shanghaiCalendar()
        let start = try date("2026-08-24T00:00:00+08:00")
        let end = try date("2026-08-31T00:00:00+08:00")
        let cycle = quotaCycle(
            startsAt: start,
            endsAt: end,
            usage: .zero
        )

        let atStart = UsageReconciler().snapshot(
            now: start,
            calendar: calendar,
            quota: nil,
            events: [],
            officialDays: [],
            cycles: [cycle],
            lastUpdatedAt: start
        )
        let atEnd = UsageReconciler().snapshot(
            now: end,
            calendar: calendar,
            quota: nil,
            events: [],
            officialDays: [],
            cycles: [cycle],
            lastUpdatedAt: end
        )

        XCTAssertEqual(atStart.currentCycle?.startsAt, start)
        XCTAssertNil(atEnd.currentCycle)
    }

    func testCycleHistoryKeepsEightMostRecentEndedCyclesDescending() throws {
        let calendar = shanghaiCalendar()
        let now = try date("2026-08-31T12:00:00+08:00")
        let base = try date("2026-06-01T00:00:00+08:00")
        let cycles = (0..<10).map { index -> QuotaCycle in
            let start = calendar.date(
                byAdding: .day,
                value: index * 7,
                to: base
            )!
            let end = calendar.date(byAdding: .day, value: 7, to: start)!
            return quotaCycle(
                startsAt: start,
                endsAt: end,
                usage: .zero
            )
        }

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: nil,
            events: [],
            officialDays: [],
            cycles: cycles,
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.cycleHistory.count, 8)
        XCTAssertEqual(
            snapshot.cycleHistory.map(\.startsAt),
            cycles.suffix(8).reversed().map(\.startsAt)
        )
    }

    func testFreshQuotaUsesWeakestCalibrationStatusAtTenMinuteBoundary() throws {
        let calendar = shanghaiCalendar()
        let now = try date("2026-08-31T12:00:00+08:00")
        let startsAt = try date("2026-08-28T12:00:00+08:00")
        let endsAt = try date("2026-09-04T12:00:00+08:00")

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now.addingTimeInterval(-600)
            ),
            events: [],
            officialDays: [],
            cycles: [
                quotaCycle(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    usage: .zero
                )
            ],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.status, .partiallyCalibrated)
    }

    func testQuotaOlderThanTenMinutesMakesSnapshotStale() throws {
        let calendar = shanghaiCalendar()
        let now = try date("2026-08-31T12:00:00+08:00")

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: now.addingTimeInterval(-100),
                endsAt: now.addingTimeInterval(100),
                fetchedAt: now.addingTimeInterval(-601)
            ),
            events: [],
            officialDays: [],
            cycles: [],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.status, .stale)
    }

    func testQuotaFreshnessUsesAbsoluteTenMinuteBoundary() throws {
        let calendar = shanghaiCalendar()
        let now = try date("2026-08-31T12:00:00+08:00")
        let startsAt = try date("2026-08-28T12:00:00+08:00")
        let endsAt = try date("2026-09-04T12:00:00+08:00")
        let cycle = quotaCycle(
            startsAt: startsAt,
            endsAt: endsAt,
            usage: .zero
        )
        let fixtures: [(offset: TimeInterval, expected: UsageCalibrationStatus)] = [
            (-600, .partiallyCalibrated),
            (600, .partiallyCalibrated),
            (-601, .stale),
            (601, .stale)
        ]

        for fixture in fixtures {
            let snapshot = UsageReconciler().snapshot(
                now: now,
                calendar: calendar,
                quota: quotaSnapshot(
                    startsAt: startsAt,
                    endsAt: endsAt,
                    fetchedAt: now.addingTimeInterval(fixture.offset)
                ),
                events: [],
                officialDays: [],
                cycles: [cycle],
                lastUpdatedAt: now
            )

            XCTAssertEqual(
                snapshot.status,
                fixture.expected,
                "offset: \(fixture.offset)"
            )
        }
    }

    func testNonFiniteQuotaFetchDateIsStale() throws {
        let calendar = shanghaiCalendar()
        let now = try date("2026-08-31T12:00:00+08:00")

        let snapshot = UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quotaSnapshot(
                startsAt: now.addingTimeInterval(-100),
                endsAt: now.addingTimeInterval(100),
                fetchedAt: Date(timeIntervalSince1970: .nan)
            ),
            events: [],
            officialDays: [],
            cycles: [],
            lastUpdatedAt: now
        )

        XCTAssertEqual(snapshot.status, .stale)
    }

    func testLatestOfficialDayIsOrderIndependentForDayAndCycle() throws {
        let fixture = try officialDuplicateFixture()
        let older = OfficialUsageDay(
            day: fixture.day,
            tokens: 40,
            fetchedAt: fixture.now.addingTimeInterval(-10)
        )
        let latest = OfficialUsageDay(
            day: fixture.day,
            tokens: 50,
            fetchedAt: fixture.now
        )

        let forward = fixture.snapshot(officialDays: [older, latest])
        let reversed = fixture.snapshot(officialDays: [latest, older])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            forward.recentDays.first { $0.day == fixture.day }?.displayedTokens,
            50
        )
        XCTAssertEqual(forward.currentCycle?.displayedTokens, 50)
        XCTAssertEqual(forward.currentCycle?.status, .calibrated)
    }

    func testConflictingLatestOfficialDayIsRejectedIndependentOfOrder() throws {
        let fixture = try officialDuplicateFixture()
        let first = OfficialUsageDay(
            day: fixture.day,
            tokens: 50,
            fetchedAt: fixture.now
        )
        let conflicting = OfficialUsageDay(
            day: fixture.day,
            tokens: 60,
            fetchedAt: fixture.now
        )

        let forward = fixture.snapshot(officialDays: [first, conflicting])
        let reversed = fixture.snapshot(officialDays: [conflicting, first])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(
            forward.recentDays.first { $0.day == fixture.day }?.displayedTokens,
            20
        )
        XCTAssertEqual(
            forward.recentDays.first { $0.day == fixture.day }?.status,
            .localLive
        )
        XCTAssertEqual(forward.currentCycle?.displayedTokens, 20)
        XCTAssertEqual(forward.currentCycle?.status, .localLive)
    }

    func testEqualLatestOfficialDuplicatesStillCalibrate() throws {
        let fixture = try officialDuplicateFixture()
        let duplicate = OfficialUsageDay(
            day: fixture.day,
            tokens: 50,
            fetchedAt: fixture.now
        )

        let snapshot = fixture.snapshot(officialDays: [duplicate, duplicate])

        XCTAssertEqual(
            snapshot.recentDays.first { $0.day == fixture.day }?.displayedTokens,
            50
        )
        XCTAssertEqual(snapshot.currentCycle?.displayedTokens, 50)
        XCTAssertEqual(snapshot.currentCycle?.status, .calibrated)
    }

    private func shanghaiCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func event(
        at occurredAt: Date,
        day: LocalDay,
        input: Int64,
        cached: Int64 = 0,
        output: Int64
    ) -> StoredUsageEvent {
        StoredUsageEvent(
            signature: Data(
                "\(occurredAt.timeIntervalSince1970)|\(input)|\(output)".utf8
            ),
            occurredAt: occurredAt,
            localDay: day,
            usage: TokenBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output
            )
        )
    }

    private func quotaCycle(
        startsAt: Date,
        endsAt: Date,
        usage: TokenBreakdown
    ) -> QuotaCycle {
        QuotaCycle(
            startsAt: startsAt,
            endsAt: endsAt,
            usage: usage,
            displayedTokens: usage.totalTokens,
            status: .localLive,
            boundaryIsEstimated: false
        )
    }

    private func quotaSnapshot(
        startsAt: Date,
        endsAt: Date,
        fetchedAt: Date
    ) -> QuotaSnapshot {
        QuotaSnapshot(
            limitID: "codex",
            usedPercent: 30,
            windowDurationMinutes: 10_080,
            startsAt: startsAt,
            resetsAt: endsAt,
            fetchedAt: fetchedAt
        )
    }

    private func officialDuplicateFixture() throws -> OfficialDuplicateFixture {
        let calendar = shanghaiCalendar()
        let startsAt = try date("2026-08-28T00:00:00+08:00")
        let endsAt = try date("2026-09-04T00:00:00+08:00")
        let now = try date("2026-08-29T12:00:00+08:00")
        let day = LocalDay(year: 2026, month: 8, day: 28)
        let event = event(
            at: try date("2026-08-28T13:00:00+08:00"),
            day: day,
            input: 20,
            output: 0
        )
        return OfficialDuplicateFixture(
            calendar: calendar,
            now: now,
            day: day,
            event: event,
            quota: quotaSnapshot(
                startsAt: startsAt,
                endsAt: endsAt,
                fetchedAt: now
            ),
            cycle: quotaCycle(
                startsAt: startsAt,
                endsAt: endsAt,
                usage: event.usage
            )
        )
    }

    private func addingForFixture(
        _ lhs: TokenBreakdown,
        _ rhs: TokenBreakdown
    ) -> TokenBreakdown {
        TokenBreakdown(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens
        )
    }
}

private struct OfficialDuplicateFixture {
    let calendar: Calendar
    let now: Date
    let day: LocalDay
    let event: StoredUsageEvent
    let quota: QuotaSnapshot
    let cycle: QuotaCycle

    func snapshot(officialDays: [OfficialUsageDay]) -> UsageSnapshot {
        UsageReconciler().snapshot(
            now: now,
            calendar: calendar,
            quota: quota,
            events: [event],
            officialDays: officialDays,
            cycles: [cycle],
            lastUpdatedAt: now
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
