use super::*;

fn database() -> (tempfile::TempDir, std::path::PathBuf) {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("usage.sqlite3");
    (directory, path)
}

fn day() -> NaiveDate {
    NaiveDate::from_ymd_opt(2024, 2, 29).unwrap()
}

fn tokens() -> TokenBreakdown {
    TokenBreakdown {
        input_tokens: 10,
        cached_input_tokens: 4,
        output_tokens: 2,
    }
}

fn event() -> StoredUsageEvent {
    StoredUsageEvent {
        signature: vec![0x00, 0xFF],
        occurred_at: 100.25,
        local_day: day(),
        usage: tokens(),
        model: Some("gpt-example".into()),
    }
}

fn cursor() -> FileCursor {
    FileCursor {
        path_hash: vec![0x00, 0x42],
        device_id: 7,
        inode: 8,
        committed_offset: 4_294_967_296,
        previous_total: Some(tokens()),
        model: Some("gpt-example".into()),
    }
}

fn quota(fetched_at: Timestamp, used_percent: f64) -> QuotaSnapshot {
    QuotaSnapshot {
        limit_id: "codex".into(),
        used_percent,
        window_duration_minutes: 10080,
        starts_at: 60.5,
        resets_at: 604860.5,
        fetched_at,
    }
}

#[test]
fn legacy_swift_schemas_replay_cursors_once_and_backfill_existing_events() -> Result<()> {
    for version in [0, 2] {
        let (_directory, path) = database();
        let legacy = Connection::open(&path)?;
        legacy.execute_batch(
            "CREATE TABLE file_cursors (
                path_hash BLOB PRIMARY KEY NOT NULL, device_id INTEGER NOT NULL,
                inode INTEGER NOT NULL, committed_offset INTEGER NOT NULL,
                previous_input_tokens INTEGER, previous_cached_input_tokens INTEGER,
                previous_output_tokens INTEGER
            );
            CREATE TABLE usage_events (
                signature BLOB PRIMARY KEY NOT NULL, occurred_at REAL NOT NULL,
                local_day TEXT NOT NULL, input_tokens INTEGER NOT NULL CHECK(input_tokens >= 0),
                cached_input_tokens INTEGER NOT NULL CHECK(cached_input_tokens >= 0),
                output_tokens INTEGER NOT NULL CHECK(output_tokens >= 0)
            );
            CREATE TABLE quota_snapshots (
                fetched_at REAL PRIMARY KEY NOT NULL, limit_id TEXT NOT NULL,
                used_percent REAL NOT NULL, window_duration_minutes INTEGER NOT NULL,
                starts_at REAL NOT NULL, resets_at REAL NOT NULL
            );
            INSERT INTO file_cursors VALUES (x'0042', 7, 8, 4294967296, 10, 4, 2);
            INSERT INTO usage_events VALUES (x'00FF', 100.25, '2024-02-29', 10, 4, 2);
            INSERT INTO quota_snapshots VALUES (90.25, 'codex', 10, 10080, 60.5, 604860.5);",
        )?;
        if version == 2 {
            legacy.execute_batch(
                "ALTER TABLE quota_snapshots ADD COLUMN is_from_session INTEGER NOT NULL DEFAULT 0;
                 INSERT INTO quota_snapshots VALUES (80.25, 'codex', 5, 10080, 60.5, 604860.5, 1);
                 PRAGMA user_version = 2;",
            )?;
        }
        drop(legacy);

        let mut store = Store::open(&path)?;
        let reset = store.cursor(&[0x00, 0x42])?.unwrap();
        assert_eq!(reset.committed_offset, 0);
        assert_eq!(reset.previous_total, None);
        assert_eq!(reset.model, None);
        assert_eq!(store.latest_quota()?, Some(quota(90.25, 10.0)));
        assert_eq!(
            store.quota_history(0.0, 100.0, "codex")?.len(),
            1 + version / 2
        );
        assert_eq!(
            store.ingest(
                &[StoredUsageEvent {
                    occurred_at: 101.75,
                    ..event()
                }],
                &[],
                &cursor(),
            )?,
            0
        );
        assert_eq!(store.events(100.25, 101.0)?, vec![event()]);
        store.checkpoint()?;
        drop(store);

        let reopened = Store::open(&path)?;
        assert_eq!(reopened.cursor(&[0x00, 0x42])?, Some(cursor()));
        let legacy_reader = Connection::open(&path)?;
        assert_eq!(
            legacy_reader.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))?,
            3
        );
        let persisted: (String, String, String, f64) = legacy_reader.query_row(
            "SELECT typeof(signature), typeof(occurred_at), model, occurred_at FROM usage_events",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )?;
        assert_eq!(
            persisted,
            ("blob".into(), "real".into(), "gpt-example".into(), 100.25)
        );
    }
    Ok(())
}

#[test]
fn future_schema_is_rejected_without_changes() -> Result<()> {
    let (_directory, path) = database();
    let db = Connection::open(&path)?;
    db.execute_batch("PRAGMA user_version = 4; CREATE TABLE future_data (value TEXT);")?;
    assert!(Store::open(&path).is_err());
    assert_eq!(
        db.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))?,
        4
    );
    assert_eq!(
        db.query_row(
            "SELECT name FROM sqlite_schema WHERE type = 'table'",
            [],
            |row| row.get::<_, String>(0)
        )?,
        "future_data"
    );
    Ok(())
}

#[test]
fn cursor_write_failure_rolls_back_events_and_session_quota() -> Result<()> {
    let (_directory, path) = database();
    let mut store = Store::open(&path)?;
    let previous = FileCursor {
        committed_offset: 4,
        model: None,
        previous_total: None,
        ..cursor()
    };
    store.save_cursor(&previous)?;
    store.save_quota(&quota(150.0, 20.0))?;
    let db = Connection::open(&path)?;
    db.execute_batch(
        "CREATE TRIGGER reject_cursor BEFORE UPDATE ON file_cursors
         BEGIN SELECT RAISE(ABORT, 'reject fixture cursor'); END;",
    )?;
    assert!(
        store
            .ingest(&[event()], &[quota(110.0, 10.0)], &cursor())
            .is_err()
    );
    assert_eq!(store.events(0.0, 200.0)?, vec![]);
    assert_eq!(
        store.quota_history(0.0, 200.0, "codex")?,
        vec![quota(150.0, 20.0)]
    );
    assert_eq!(store.cursor(&previous.path_hash)?, Some(previous));
    Ok(())
}

#[test]
fn quota_collisions_preserve_polled_readings_and_filter_stale_session_values() -> Result<()> {
    let mut store = Store::open(Path::new(":memory:"))?;
    let quotas = [
        quota(90.0, 10.0),
        quota(110.0, 5.0),
        quota(120.0, 10.0),
        quota(130.0, 35.0),
    ];
    store.ingest(&[], &quotas, &cursor())?;
    assert_eq!(store.latest_quota()?, None);
    assert!(store.quota_history(0.0, 200.0, "codex")?.is_empty());
    store.save_quota(&quota(90.0, 8.0))?;
    store.save_quota(&quota(140.0, 20.0))?;
    store.ingest(
        &[],
        &[quota(90.0, 12.0), quota(120.0, 12.0), quota(120.0, 9.0)],
        &cursor(),
    )?;
    assert_eq!(store.latest_quota()?, Some(quota(140.0, 20.0)));
    assert_eq!(
        store.quota_history(120.0, 140.0, "codex")?,
        vec![quota(90.0, 8.0), quota(120.0, 12.0), quota(140.0, 20.0)],
    );
    store.prune_usage(130.0, day())?;
    assert_eq!(
        store.quota_history(130.0, 150.0, "codex")?,
        vec![quota(120.0, 12.0), quota(140.0, 20.0)]
    );
    assert_eq!(store.quota_history(0.0, 150.0, "other")?, vec![]);
    let anchor: i64 = store.connection.query_row(
        "SELECT count(*) FROM quota_snapshots WHERE fetched_at = 90 AND is_from_session = 0",
        [],
        |row| row.get(0),
    )?;
    assert_eq!(anchor, 1);
    Ok(())
}

#[test]
fn swift_v3_rows_and_rust_updates_keep_the_same_storage_format() -> Result<()> {
    let (_directory, path) = database();
    let fixture = Connection::open(&path)?;
    fixture.execute_batch(include_str!("swift_v3.sql"))?;

    let mut store = Store::open(&path)?;
    assert_eq!(store.events(100.25, 101.0)?, vec![event()]);
    assert_eq!(store.cursor(&[0x00, 0x42])?, Some(cursor()));
    assert_eq!(store.latest_quota()?, Some(quota(90.25, 10.0)));
    let state = store.refresh_state()?;
    assert_eq!(state.last_successful_quota_refresh_at, Some(101.5));
    assert_eq!(state.last_successful_official_usage_refresh_at, None);
    assert_eq!(state.consecutive_failure_count, 2);
    assert_eq!(
        state.failed_sources,
        [FailureSource::RateLimits, FailureSource::SessionIndexing].into()
    );
    let mut days = store.official_days()?;
    assert_eq!(
        days[0],
        OfficialUsageDay {
            day: day(),
            tokens: 12,
            fetched_at: 100.25
        }
    );
    let mut cycles = store.cycles()?;
    assert_eq!(cycles[0].usage, tokens());
    assert_eq!(cycles[0].status, Status::PartiallyCalibrated);
    assert!(cycles[0].boundary_is_estimated);
    assert_eq!(cycles[0].last_recorded_quota, None);

    assert!(
        store
            .replace_cycles(&[cycles[0].clone(), cycles[0].clone()])
            .is_err()
    );
    assert_eq!(store.cycles()?, cycles);
    cycles[0].status = Status::LocalLive;
    days[0].tokens = 14;
    store.replace_cycles(&cycles)?;
    store.upsert_official_days(&days)?;
    store.save_refresh_state(&RefreshState {
        failed_sources: [FailureSource::OfficialUsage].into(),
        last_successful_official_usage_refresh_at: Some(130.25),
        ..state
    })?;
    assert_eq!(
        fixture.query_row("SELECT tokens FROM official_usage_days", [], |row| row
            .get::<_, i64>(0))?,
        14
    );
    assert_eq!(
        fixture.query_row("SELECT status FROM quota_cycles", [], |row| row
            .get::<_, String>(0))?,
        "localLive"
    );
    assert_eq!(
        fixture.query_row(
            "SELECT official_usage_failed FROM refresh_state",
            [],
            |row| row.get::<_, i64>(0)
        )?,
        1
    );
    store.prune_usage(100.25, day())?;
    assert_eq!(store.events(100.25, 101.0)?, vec![event()]);
    assert_eq!(store.official_days()?, days);
    store.prune_usage(100.5, day().succ_opt().unwrap())?;
    assert!(store.events(100.25, 101.0)?.is_empty());
    assert!(store.official_days()?.is_empty());
    assert_eq!(store.cursor(&[0x00, 0x42])?, Some(cursor()));
    assert_eq!(store.latest_quota()?, Some(quota(90.25, 10.0)));
    Ok(())
}

#[test]
fn validates_batches_and_rejects_noncanonical_stored_days() -> Result<()> {
    let mut store = Store::open(Path::new(":memory:"))?;
    let mut invalid = event();
    invalid.usage.cached_input_tokens = invalid.usage.input_tokens + 1;
    assert!(store.insert(&[event(), invalid]).is_err());
    assert_eq!(store.events(0.0, 200.0)?, vec![]);
    store.connection.execute_batch(
        "INSERT INTO usage_events VALUES (x'01', 100, '2024-2-29', 1, 0, 0, NULL);",
    )?;
    assert!(store.events(0.0, 200.0).is_err());
    Ok(())
}
