import Foundation
import SQLite3

public actor SQLiteUsageStore: UsageStore {
    private let connection: SQLiteConnection

    public init(databaseURL: URL) throws {
        connection = try SQLiteConnection(databaseURL: databaseURL)
    }

    public func migrate() throws {
        try connection.transaction {
            try connection.execute(
                """
                CREATE TABLE IF NOT EXISTS file_cursors (
                  path_hash BLOB PRIMARY KEY NOT NULL,
                  device_id INTEGER NOT NULL,
                  inode INTEGER NOT NULL,
                  committed_offset INTEGER NOT NULL,
                  previous_input_tokens INTEGER,
                  previous_cached_input_tokens INTEGER,
                  previous_output_tokens INTEGER
                );

                CREATE TABLE IF NOT EXISTS usage_events (
                  signature BLOB PRIMARY KEY NOT NULL,
                  occurred_at REAL NOT NULL,
                  local_day TEXT NOT NULL,
                  input_tokens INTEGER NOT NULL CHECK(input_tokens >= 0),
                  cached_input_tokens INTEGER NOT NULL CHECK(cached_input_tokens >= 0),
                  output_tokens INTEGER NOT NULL CHECK(output_tokens >= 0)
                );

                CREATE INDEX IF NOT EXISTS usage_events_occurred_at
                ON usage_events(occurred_at);

                CREATE INDEX IF NOT EXISTS usage_events_local_day
                ON usage_events(local_day);

                CREATE TABLE IF NOT EXISTS official_usage_days (
                  local_day TEXT PRIMARY KEY NOT NULL,
                  tokens INTEGER NOT NULL CHECK(tokens >= 0),
                  fetched_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS quota_snapshots (
                  fetched_at REAL PRIMARY KEY NOT NULL,
                  limit_id TEXT NOT NULL,
                  used_percent REAL NOT NULL,
                  window_duration_minutes INTEGER NOT NULL,
                  starts_at REAL NOT NULL,
                  resets_at REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS quota_cycles (
                  starts_at REAL PRIMARY KEY NOT NULL,
                  ends_at REAL NOT NULL,
                  input_tokens INTEGER NOT NULL,
                  cached_input_tokens INTEGER NOT NULL,
                  output_tokens INTEGER NOT NULL,
                  displayed_tokens INTEGER NOT NULL,
                  status TEXT NOT NULL,
                  boundary_is_estimated INTEGER NOT NULL
                );
                """,
                operation: "migrate schema"
            )
            try connection.execute(
                "PRAGMA user_version = 1;",
                operation: "set schema version"
            )
        }
    }

    public func insert(events: [StoredUsageEvent]) throws -> Int {
        guard events.allSatisfy(isValidEvent) else {
            throw validationFailure(operation: "validate event")
        }
        return try connection.transaction {
            let statement = try connection.prepare(
                """
                INSERT OR IGNORE INTO usage_events (
                  signature, occurred_at, local_day, input_tokens,
                  cached_input_tokens, output_tokens
                ) VALUES (?, ?, ?, ?, ?, ?);
                """,
                operation: "insert event"
            )
            var inserted = 0
            for event in events {
                try statement.bind(event.signature, at: 1)
                try statement.bind(event.occurredAt.timeIntervalSince1970, at: 2)
                try statement.bind(event.localDay.iso8601, at: 3)
                try statement.bind(event.usage.inputTokens, at: 4)
                try statement.bind(event.usage.cachedInputTokens, at: 5)
                try statement.bind(event.usage.outputTokens, at: 6)
                guard try statement.step() == .done else {
                    throw corruption(operation: "insert event")
                }
                inserted += try connection.changes()
                try statement.reset()
            }
            return inserted
        }
    }

    public func events(from: Date, to: Date) throws -> [StoredUsageEvent] {
        guard isFinite(from), isFinite(to) else {
            throw validationFailure(operation: "validate event query")
        }
        let statement = try connection.prepare(
            """
            SELECT signature, occurred_at, local_day, input_tokens,
                   cached_input_tokens, output_tokens
            FROM usage_events
            WHERE occurred_at >= ? AND occurred_at < ?
            ORDER BY occurred_at ASC, signature ASC;
            """,
            operation: "read events"
        )
        try statement.bind(from.timeIntervalSince1970, at: 1)
        try statement.bind(to.timeIntervalSince1970, at: 2)
        var events: [StoredUsageEvent] = []
        while try statement.step() == .row {
            let event = StoredUsageEvent(
                signature: try statement.data(at: 0),
                occurredAt: Date(timeIntervalSince1970: try statement.double(at: 1)),
                localDay: try localDay(
                    from: statement.string(at: 2),
                    operation: "read events"
                ),
                usage: TokenBreakdown(
                    inputTokens: try statement.int64(at: 3),
                    cachedInputTokens: try statement.int64(at: 4),
                    outputTokens: try statement.int64(at: 5)
                )
            )
            guard isValidEvent(event) else {
                throw corruption(operation: "read events")
            }
            events.append(event)
        }
        return events
    }

    public func cursor(for pathHash: Data) throws -> FileCursor? {
        let statement = try connection.prepare(
            """
            SELECT device_id, inode, committed_offset, previous_input_tokens,
                   previous_cached_input_tokens, previous_output_tokens
            FROM file_cursors WHERE path_hash = ?;
            """,
            operation: "read cursor"
        )
        try statement.bind(pathHash, at: 1)
        guard try statement.step() == .row else {
            return nil
        }
        let previousInput = try statement.optionalInt64(at: 3)
        let previousCached = try statement.optionalInt64(at: 4)
        let previousOutput = try statement.optionalInt64(at: 5)
        let previousTotal: TokenBreakdown?
        switch (previousInput, previousCached, previousOutput) {
        case (nil, nil, nil):
            previousTotal = nil
        case let (.some(input), .some(cached), .some(output)):
            previousTotal = TokenBreakdown(
                inputTokens: input,
                cachedInputTokens: cached,
                outputTokens: output
            )
        default:
            throw corruption(operation: "read cursor")
        }
        let cursor = FileCursor(
            pathHash: pathHash,
            deviceID: try statement.int64(at: 0),
            inode: try statement.int64(at: 1),
            committedOffset: try statement.int64(at: 2),
            counterState: SessionCounterState(previousTotal: previousTotal)
        )
        guard isValidCursor(cursor) else {
            throw corruption(operation: "read cursor")
        }
        return cursor
    }

    public func save(cursor: FileCursor) throws {
        guard isValidCursor(cursor) else {
            throw validationFailure(operation: "validate cursor")
        }
        let statement = try connection.prepare(
            """
            INSERT INTO file_cursors (
              path_hash, device_id, inode, committed_offset,
              previous_input_tokens, previous_cached_input_tokens,
              previous_output_tokens
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path_hash) DO UPDATE SET
              device_id = excluded.device_id,
              inode = excluded.inode,
              committed_offset = excluded.committed_offset,
              previous_input_tokens = excluded.previous_input_tokens,
              previous_cached_input_tokens = excluded.previous_cached_input_tokens,
              previous_output_tokens = excluded.previous_output_tokens;
            """,
            operation: "save cursor"
        )
        try statement.bind(cursor.pathHash, at: 1)
        try statement.bind(cursor.deviceID, at: 2)
        try statement.bind(cursor.inode, at: 3)
        try statement.bind(cursor.committedOffset, at: 4)
        if let total = cursor.counterState.previousTotal {
            try statement.bind(total.inputTokens, at: 5)
            try statement.bind(total.cachedInputTokens, at: 6)
            try statement.bind(total.outputTokens, at: 7)
        } else {
            try statement.bindNull(at: 5)
            try statement.bindNull(at: 6)
            try statement.bindNull(at: 7)
        }
        guard try statement.step() == .done else {
            throw corruption(operation: "save cursor")
        }
    }

    public func upsert(officialDays: [OfficialUsageDay]) throws {
        guard officialDays.allSatisfy(isValidOfficialDay) else {
            throw validationFailure(operation: "validate official day")
        }
        try connection.transaction {
            let statement = try connection.prepare(
                """
                INSERT INTO official_usage_days (local_day, tokens, fetched_at)
                VALUES (?, ?, ?)
                ON CONFLICT(local_day) DO UPDATE SET
                  tokens = excluded.tokens,
                  fetched_at = excluded.fetched_at;
                """,
                operation: "upsert official day"
            )
            for day in officialDays {
                try statement.bind(day.day.iso8601, at: 1)
                try statement.bind(day.tokens, at: 2)
                try statement.bind(day.fetchedAt.timeIntervalSince1970, at: 3)
                guard try statement.step() == .done else {
                    throw corruption(operation: "upsert official day")
                }
                try statement.reset()
            }
        }
    }

    public func officialDays() throws -> [OfficialUsageDay] {
        let statement = try connection.prepare(
            """
            SELECT local_day, tokens, fetched_at
            FROM official_usage_days ORDER BY local_day ASC;
            """,
            operation: "read official days"
        )
        var days: [OfficialUsageDay] = []
        while try statement.step() == .row {
            let day = OfficialUsageDay(
                day: try localDay(
                    from: statement.string(at: 0),
                    operation: "read official days"
                ),
                tokens: try statement.int64(at: 1),
                fetchedAt: Date(timeIntervalSince1970: try statement.double(at: 2))
            )
            guard isValidOfficialDay(day) else {
                throw corruption(operation: "read official days")
            }
            days.append(day)
        }
        return days
    }

    public func save(quota: QuotaSnapshot) throws {
        guard isValidQuota(quota) else {
            throw validationFailure(operation: "validate quota")
        }
        let statement = try connection.prepare(
            """
            INSERT INTO quota_snapshots (
              fetched_at, limit_id, used_percent, window_duration_minutes,
              starts_at, resets_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(fetched_at) DO UPDATE SET
              limit_id = excluded.limit_id,
              used_percent = excluded.used_percent,
              window_duration_minutes = excluded.window_duration_minutes,
              starts_at = excluded.starts_at,
              resets_at = excluded.resets_at;
            """,
            operation: "save quota"
        )
        try statement.bind(quota.fetchedAt.timeIntervalSince1970, at: 1)
        try statement.bind(quota.limitID, at: 2)
        try statement.bind(quota.usedPercent, at: 3)
        try statement.bind(Int64(quota.windowDurationMinutes), at: 4)
        try statement.bind(quota.startsAt.timeIntervalSince1970, at: 5)
        try statement.bind(quota.resetsAt.timeIntervalSince1970, at: 6)
        guard try statement.step() == .done else {
            throw corruption(operation: "save quota")
        }
    }

    public func latestQuota() throws -> QuotaSnapshot? {
        let statement = try connection.prepare(
            """
            SELECT limit_id, used_percent, window_duration_minutes,
                   starts_at, resets_at, fetched_at
            FROM quota_snapshots ORDER BY fetched_at DESC LIMIT 1;
            """,
            operation: "read quota"
        )
        guard try statement.step() == .row else {
            return nil
        }
        guard let duration = Int(exactly: try statement.int64(at: 2)) else {
            throw corruption(operation: "read quota")
        }
        let quota = QuotaSnapshot(
            limitID: try statement.string(at: 0),
            usedPercent: try statement.double(at: 1),
            windowDurationMinutes: duration,
            startsAt: Date(timeIntervalSince1970: try statement.double(at: 3)),
            resetsAt: Date(timeIntervalSince1970: try statement.double(at: 4)),
            fetchedAt: Date(timeIntervalSince1970: try statement.double(at: 5))
        )
        guard isValidQuota(quota) else {
            throw corruption(operation: "read quota")
        }
        return quota
    }

    public func replace(cycles: [QuotaCycle]) throws {
        guard cycles.count <= 9 else {
            throw SQLiteStoreError.tooManyCycles(cycles.count)
        }
        guard cycles.allSatisfy(isValidCycle) else {
            throw validationFailure(operation: "validate cycle")
        }
        try connection.transaction {
            try connection.execute(
                "DELETE FROM quota_cycles;",
                operation: "clear cycles"
            )
            let statement = try connection.prepare(
                """
                INSERT INTO quota_cycles (
                  starts_at, ends_at, input_tokens, cached_input_tokens,
                  output_tokens, displayed_tokens, status, boundary_is_estimated
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                operation: "insert cycle"
            )
            for cycle in cycles.sorted(by: { $0.startsAt < $1.startsAt }) {
                try statement.bind(cycle.startsAt.timeIntervalSince1970, at: 1)
                try statement.bind(cycle.endsAt.timeIntervalSince1970, at: 2)
                try statement.bind(cycle.usage.inputTokens, at: 3)
                try statement.bind(cycle.usage.cachedInputTokens, at: 4)
                try statement.bind(cycle.usage.outputTokens, at: 5)
                try statement.bind(cycle.displayedTokens, at: 6)
                try statement.bind(cycle.status.rawValue, at: 7)
                try statement.bind(
                    cycle.boundaryIsEstimated ? Int64(1) : Int64(0),
                    at: 8
                )
                guard try statement.step() == .done else {
                    throw corruption(operation: "insert cycle")
                }
                try statement.reset()
            }
        }
    }

    public func cycles() throws -> [QuotaCycle] {
        let statement = try connection.prepare(
            """
            SELECT starts_at, ends_at, input_tokens, cached_input_tokens,
                   output_tokens, displayed_tokens, status, boundary_is_estimated
            FROM quota_cycles ORDER BY starts_at ASC;
            """,
            operation: "read cycles"
        )
        var cycles: [QuotaCycle] = []
        while try statement.step() == .row {
            guard let status = UsageCalibrationStatus(
                rawValue: try statement.string(at: 6)
            ) else {
                throw corruption(operation: "read cycles")
            }
            let cycle = QuotaCycle(
                startsAt: Date(timeIntervalSince1970: try statement.double(at: 0)),
                endsAt: Date(timeIntervalSince1970: try statement.double(at: 1)),
                usage: TokenBreakdown(
                    inputTokens: try statement.int64(at: 2),
                    cachedInputTokens: try statement.int64(at: 3),
                    outputTokens: try statement.int64(at: 4)
                ),
                displayedTokens: try statement.int64(at: 5),
                status: status,
                boundaryIsEstimated: try statement.int64(at: 7) != 0
            )
            guard isValidCycle(cycle) else {
                throw corruption(operation: "read cycles")
            }
            cycles.append(cycle)
        }
        return cycles
    }

    public func pruneUsage(
        eventsBefore: Date,
        officialDaysBefore: LocalDay
    ) throws {
        guard isFinite(eventsBefore), isCanonical(officialDaysBefore) else {
            throw validationFailure(operation: "validate prune cutoff")
        }
        try connection.transaction {
            let events = try connection.prepare(
                "DELETE FROM usage_events WHERE occurred_at < ?;",
                operation: "prune events"
            )
            try events.bind(eventsBefore.timeIntervalSince1970, at: 1)
            guard try events.step() == .done else {
                throw corruption(operation: "prune events")
            }

            let officialDays = try connection.prepare(
                "DELETE FROM official_usage_days WHERE local_day < ?;",
                operation: "prune official days"
            )
            try officialDays.bind(officialDaysBefore.iso8601, at: 1)
            guard try officialDays.step() == .done else {
                throw corruption(operation: "prune official days")
            }
        }
    }

    private func isValidEvent(_ event: StoredUsageEvent) -> Bool {
        isFinite(event.occurredAt)
            && isCanonical(event.localDay)
            && isValid(event.usage)
    }

    private func isValidCursor(_ cursor: FileCursor) -> Bool {
        guard cursor.committedOffset >= 0 else {
            return false
        }
        return cursor.counterState.previousTotal.map(isValid) ?? true
    }

    private func isValidOfficialDay(_ day: OfficialUsageDay) -> Bool {
        day.tokens >= 0
            && isFinite(day.fetchedAt)
            && isCanonical(day.day)
    }

    private func isValidQuota(_ quota: QuotaSnapshot) -> Bool {
        quota.usedPercent.isFinite
            && quota.usedPercent >= 0
            && quota.windowDurationMinutes > 0
            && isFinite(quota.startsAt)
            && isFinite(quota.resetsAt)
            && isFinite(quota.fetchedAt)
    }

    private func isValidCycle(_ cycle: QuotaCycle) -> Bool {
        isFinite(cycle.startsAt)
            && isFinite(cycle.endsAt)
            && isValid(cycle.usage)
            && cycle.displayedTokens >= 0
            && cycle.endsAt >= cycle.startsAt
    }

    private func isValid(_ usage: TokenBreakdown) -> Bool {
        usage.inputTokens >= 0
            && usage.cachedInputTokens >= 0
            && usage.outputTokens >= 0
            && usage.cachedInputTokens <= usage.inputTokens
    }

    private func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSince1970.isFinite
    }

    private func isCanonical(_ day: LocalDay) -> Bool {
        guard (1...9_999).contains(day.year) else {
            return false
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = day.year
        components.month = day.month
        components.day = day.day
        guard let date = calendar.date(from: components) else {
            return false
        }
        let normalized = calendar.dateComponents(
            [.year, .month, .day],
            from: date
        )
        return normalized.year == day.year
            && normalized.month == day.month
            && normalized.day == day.day
            && day.iso8601.utf8.count == 10
    }

    private func localDay(from text: String, operation: String) throws -> LocalDay {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            throw corruption(operation: operation)
        }
        let value = LocalDay(year: year, month: month, day: day)
        guard isCanonical(value), value.iso8601 == text else {
            throw corruption(operation: operation)
        }
        return value
    }

    private func validationFailure(operation: String) -> SQLiteStoreError {
        SQLiteStoreError.operationFailed(
            operation: operation,
            code: SQLITE_CONSTRAINT | (1 << 8)
        )
    }

    private func corruption(operation: String) -> SQLiteStoreError {
        SQLiteStoreError.operationFailed(operation: operation, code: SQLITE_CORRUPT)
    }
}
