-- SQLite dump from a database populated by the Swift SQLiteUsageStore.
BEGIN TRANSACTION;
PRAGMA user_version = 3;
CREATE TABLE file_cursors (
  path_hash BLOB PRIMARY KEY NOT NULL,
  device_id INTEGER NOT NULL,
  inode INTEGER NOT NULL,
  committed_offset INTEGER NOT NULL,
  previous_input_tokens INTEGER,
  previous_cached_input_tokens INTEGER,
  previous_output_tokens INTEGER,
  model TEXT
);
INSERT INTO file_cursors VALUES (X'0042', 7, 8, 4294967296, 10, 4, 2, 'gpt-example');
CREATE TABLE usage_events (
  signature BLOB PRIMARY KEY NOT NULL,
  occurred_at REAL NOT NULL,
  local_day TEXT NOT NULL,
  input_tokens INTEGER NOT NULL CHECK(input_tokens >= 0),
  cached_input_tokens INTEGER NOT NULL CHECK(cached_input_tokens >= 0),
  output_tokens INTEGER NOT NULL CHECK(output_tokens >= 0),
  model TEXT
);
INSERT INTO usage_events VALUES (X'00ff', 100.25, '2024-02-29', 10, 4, 2, 'gpt-example');
CREATE TABLE official_usage_days (
  local_day TEXT PRIMARY KEY NOT NULL,
  tokens INTEGER NOT NULL CHECK(tokens >= 0),
  fetched_at REAL NOT NULL
);
INSERT INTO official_usage_days VALUES ('2024-02-29', 12, 100.25);
CREATE TABLE quota_snapshots (
  fetched_at REAL PRIMARY KEY NOT NULL,
  limit_id TEXT NOT NULL,
  used_percent REAL NOT NULL,
  window_duration_minutes INTEGER NOT NULL,
  starts_at REAL NOT NULL,
  resets_at REAL NOT NULL,
  is_from_session INTEGER NOT NULL DEFAULT 0
);
INSERT INTO quota_snapshots VALUES (90.25, 'codex', 10.0, 10080, 60.5, 604860.5, 0);
CREATE TABLE quota_cycles (
  starts_at REAL PRIMARY KEY NOT NULL,
  ends_at REAL NOT NULL,
  input_tokens INTEGER NOT NULL,
  cached_input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  displayed_tokens INTEGER NOT NULL,
  status TEXT NOT NULL,
  boundary_is_estimated INTEGER NOT NULL
);
INSERT INTO quota_cycles VALUES (60.5, 604860.5, 10, 4, 2, 14, 'partiallyCalibrated', 1);
CREATE TABLE refresh_state (
  singleton_id INTEGER PRIMARY KEY NOT NULL CHECK(singleton_id = 1),
  last_successful_quota_refresh_at REAL,
  last_successful_official_usage_refresh_at REAL,
  consecutive_failure_count INTEGER NOT NULL CHECK(consecutive_failure_count >= 0),
  account_initialization_failed INTEGER NOT NULL CHECK(account_initialization_failed IN (0, 1)),
  rate_limits_failed INTEGER NOT NULL CHECK(rate_limits_failed IN (0, 1)),
  official_usage_failed INTEGER NOT NULL CHECK(official_usage_failed IN (0, 1)),
  session_indexing_failed INTEGER NOT NULL CHECK(session_indexing_failed IN (0, 1))
);
INSERT INTO refresh_state VALUES (1, 101.5, NULL, 2, 0, 1, 0, 1);
CREATE INDEX usage_events_occurred_at ON usage_events(occurred_at);
CREATE INDEX usage_events_local_day ON usage_events(local_day);
COMMIT;
