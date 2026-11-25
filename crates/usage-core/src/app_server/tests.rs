use super::executable::windows_executable_in;
use super::*;

#[test]
fn selects_the_codex_weekly_window_and_merges_only_its_usage_readings() -> Result<()> {
    let mut limits: RateLimits = serde_json::from_value(json!({
        "rateLimits": {
            "limitId": "codex",
            "primary": {"usedPercent": 68, "windowDurationMins": 300, "resetsAt": 1700000000}
        },
        "rateLimitsByLimitId": {
            "alternative": {
                "limitId": "alternative",
                "primary": {"usedPercent": 98, "windowDurationMins": 10080, "resetsAt": 1700000010}
            },
            "codex": {
                "limitId": "codex",
                "primary": {"usedPercent": 24, "windowDurationMins": 300, "resetsAt": 1700000020},
                "secondary": {"usedPercent": 25, "windowDurationMins": 10090, "resetsAt": 1700000030}
            }
        }
    }))?;

    let quota = limits.select(1699999000.0, None).unwrap().0;
    assert_eq!(quota.limit_id, "codex");
    assert_eq!(quota.used_percent, 25.0);
    assert_eq!(quota.window_duration_minutes, 10090);
    assert_eq!(quota.starts_at, 1699394630.0);
    assert_eq!(quota.resets_at, 1700000030.0);

    for (value, used_percent, has_reading) in [
        (json!({"primary": {"usedPercent": 91}}), 25.0, false),
        (
            json!({"limitId": "alternative", "primary": {"usedPercent": 60}}),
            25.0,
            false,
        ),
        (json!({"secondary": {"usedPercent": 31}}), 31.0, true),
        (json!({"secondary": {"resetsAt": 1700000040}}), 31.0, false),
    ] {
        let patch = serde_json::from_value(value)?;
        let next = limits.applying(&patch);
        let (quota, has_usage_reading) =
            next.select(1699999500.0, Some((&limits, &patch))).unwrap();
        assert_eq!(quota.used_percent, used_percent);
        assert_eq!(quota.fetched_at, 1699999500.0);
        assert_eq!(has_usage_reading, has_reading);
        limits = next;
    }

    let clear = serde_json::from_value(json!({"secondary": null}))?;
    let cleared = limits.applying(&clear);
    let (quota, has_usage_reading) = cleared
        .select(1699999600.0, Some((&limits, &clear)))
        .unwrap();
    assert_eq!(quota.limit_id, "alternative");
    assert!(!has_usage_reading);
    Ok(())
}

#[test]
fn keeps_valid_official_days_when_other_buckets_are_invalid() -> Result<()> {
    let days = official_days(
        json!({
            "summary": {},
            "dailyUsageBuckets": [
                {"startDate": "2024-02-29", "tokens": 42},
                {"startDate": "2025-02-29", "tokens": 10},
                {"startDate": "2024-2-29", "tokens": 10},
                {"startDate": "0000-02-29", "tokens": 10},
                {"startDate": "2024-03-01", "tokens": -1},
                {"startDate": "2024-03-02", "tokens": "private response body"}
            ]
        }),
        10.0,
    )?;

    assert!(days.had_invalid_bucket);
    assert_eq!(days.days.len(), 1);
    assert_eq!(
        days.days[0].day,
        NaiveDate::from_ymd_opt(2024, 2, 29).unwrap()
    );
    assert_eq!(days.days[0].tokens, 42);
    assert_eq!(days.days[0].fetched_at, 10.0);
    assert!(official_days(json!({"summary": {}, "dailyUsageBuckets": null}), 10.0).is_err());
    Ok(())
}

#[test]
fn finds_npm_native_executable_without_using_windows_command_shims() -> Result<()> {
    let temp = tempfile::tempdir()?;
    std::fs::write(temp.path().join("codex.cmd"), "")?;
    let native = temp.path().join(
        "node_modules/@openai/codex/node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/bin/codex.exe",
    );
    assert_eq!(windows_executable_in(temp.path()), None);
    std::fs::create_dir_all(native.parent().unwrap())?;
    std::fs::write(&native, "")?;
    assert_eq!(windows_executable_in(temp.path()), Some(native));
    Ok(())
}

#[cfg(unix)]
#[test]
fn exchanges_read_only_requests_and_drains_sparse_quota_notifications() -> Result<()> {
    let fixture = r#"
        IFS= read -r line || exit 1
        case "$line" in *'"id":1'*'"method":"initialize"'*) ;; *) exit 2 ;; esac
        printf '%s\n' 'not JSON' '{"id":99,"result":{}}'
        printf '{"id":1,"result":{"codexHome":"%s"}}\n' "$CODEX_HOME"
        IFS= read -r line || exit 3
        case "$line" in *'"method":"initialized"'*) ;; *) exit 4 ;; esac
        IFS= read -r line || exit 5
        case "$line" in *'"id":2'*'"method":"account/rateLimits/read"'*) ;; *) exit 6 ;; esac
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1788753600}}}}'
        printf '%s\n' '{"method":"account/rateLimits/updated","params":false}'
        printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":31}}}}'
        IFS= read -r line || exit 7
        case "$line" in *'"id":3'*'"method":"account/usage/read"'*) ;; *) exit 8 ;; esac
        printf '%s\n' '{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":null}}}'
        printf '%s\n' '{"id":3,"result":{"summary":{},"dailyUsageBuckets":[{"startDate":"2026-08-30","tokens":400}]}}'
        IFS= read -r line || exit 9
        case "$line" in *'"id":4'*'"method":"account/rateLimits/read"'*) ;; *) exit 10 ;; esac
        printf '%s\n' '{"id":4,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1788753600}}}}'
        while IFS= read -r line; do exit 11; done
    "#;
    let mut command = Command::new("/bin/sh");
    command.args(["-c", fixture]);
    let home = Path::new("/tmp/selected codex home");
    let mut server = AppServer::start(command, Some(home), Duration::from_secs(2), None)?;
    assert_eq!(server.codex_home(), Some(home));
    assert_eq!(server.read_quota(10.0)?.unwrap().used_percent, 25.0);
    assert_eq!(server.read_official_days(11.0)?.days[0].tokens, 400);
    let notifications = server.quota_notifications();
    assert_eq!(notifications.len(), 2);
    assert_eq!(notifications[0].used_percent, 31.0);
    assert_eq!(notifications[1].used_percent, 47.0);
    assert!(notifications[0].fetched_at > 11.0);
    assert!(notifications[1].fetched_at >= notifications[0].fetched_at);
    assert!(server.quota_notifications().is_empty());
    Ok(())
}

#[cfg(unix)]
#[test]
fn returns_a_timeout_if_the_child_does_not_respond() {
    let mut command = Command::new("/bin/sh");
    command.args(["-c", "while IFS= read -r line; do :; done"]);
    let error = AppServer::start(command, None, Duration::from_millis(50), None)
        .err()
        .expect("expected initialize to time out");
    assert!(error.to_string().contains("timed out"), "{error}");
}

#[cfg(unix)]
#[test]
fn cancels_pending_read_and_allows_final_quota_capture() -> Result<()> {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    let fixture = r#"
        IFS= read -r line || exit 1
        printf '%s\n' '{"id":1,"result":{}}'
        IFS= read -r line || exit 2
        IFS= read -r line || exit 3
        case "$line" in *'"id":2'*'"method":"account/rateLimits/read"'*) ;; *) exit 4 ;; esac
        : > "$1"
        IFS= read -r line || exit 5
        case "$line" in *'"id":3'*'"method":"account/rateLimits/read"'*) ;; *) exit 6 ;; esac
        printf '%s\n' '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":98,"windowDurationMins":10080,"resetsAt":1788753600}}}}'
        printf '%s\n' '{"id":3,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":47,"windowDurationMins":10080,"resetsAt":1788753600}}}}'
        while IFS= read -r line; do exit 7; done
    "#;
    let directory = tempfile::tempdir()?;
    let read_started = directory.path().join("read-started");
    let cancellation = Arc::new(AtomicBool::new(false));
    let mut command = Command::new("/bin/sh");
    command.args(["-c", fixture, "fixture"]).arg(&read_started);
    let mut server = AppServer::start(
        command,
        None,
        Duration::from_secs(6),
        Some(cancellation.clone()),
    )?;
    thread::scope(|scope| {
        scope.spawn(|| {
            let deadline = Instant::now() + Duration::from_secs(2);
            while !read_started.is_file() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            assert!(read_started.is_file());
            cancellation.store(true, Ordering::Release);
        });
        let started = Instant::now();
        let error = server.read_quota(10.0).expect_err("expected cancellation");
        assert!(error.to_string().contains("cancelled"), "{error}");
        assert!(started.elapsed() < Duration::from_secs(3));
    });

    assert!(server.is_running());
    let quota = server.capture_quota(11.0, Duration::from_secs(2))?.unwrap();
    assert_eq!(quota.used_percent, 47.0);
    assert_eq!(quota.fetched_at, 11.0);
    Ok(())
}
