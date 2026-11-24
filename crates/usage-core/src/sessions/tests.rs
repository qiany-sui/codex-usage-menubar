use super::*;
use chrono::Utc;
use std::io::Write;

const SESSION: &[u8] =
    include_bytes!("../../../../Tests/UsageCoreTests/Fixtures/session-repeated-token-count.jsonl");

#[test]
fn compatible_digest_and_fractional_timestamp() {
    let first = SESSION.split(|&byte| byte == b'\n').next().unwrap();
    let Entry::Token(record) = parse(first).unwrap() else {
        panic!("missing token event");
    };
    let known = "timestampMs=1792630800000|schema=last+total|last=100,40,20|total=1000,400,200";
    assert_eq!(record.signature(), Sha256::digest(known).to_vec());

    let serialized = std::str::from_utf8(first).unwrap();
    let extra_precision = serialized.replace("09:00:00+08:00", "09:00:00.123999+08:00");
    let millis = serialized.replace("09:00:00+08:00", "09:00:00.123+08:00");
    let (Some(Entry::Token(left)), Some(Entry::Token(right))) =
        (parse(extra_precision.as_bytes()), parse(millis.as_bytes()))
    else {
        panic!("missing token event");
    };
    assert_eq!(left.signature(), right.signature());
}

#[test]
fn cursor_can_resume_after_restart_and_replayed_archive_is_deduplicated() -> Result<()> {
    let root = tempfile::tempdir()?;
    let session_dir = root.path().join("sessions");
    let archived = root.path().join("archived_sessions");
    fs::create_dir(&session_dir)?;
    fs::create_dir(&archived)?;
    let path = session_dir.join("active.jsonl");
    let lines: Vec<_> = SESSION.split_inclusive(|&byte| byte == b'\n').collect();
    let mut file = File::create(&path)?;
    writeln!(
        file,
        r#"{{"type":"turn_context","payload":{{"model":"gpt-6.2-sol"}}}}"#
    )?;
    file.write_all(lines[0])?;
    file.write_all(&lines[1][..lines[1].len() - 1])?;
    drop(file);

    let database = root.path().join("usage.sqlite");
    let quitting = AtomicBool::new(false);
    {
        let mut store = Store::open(&database)?;
        assert_eq!(
            SessionIndexer::default().index(root.path(), 0.0, &Utc, &mut store, &quitting)?,
            1
        );
    }
    let mut file = OpenOptions::new().append(true).open(&path)?;
    file.write_all(b"\n")?;
    file.write_all(lines[2])?;
    drop(file);
    fs::copy(&path, archived.join("replayed.jsonl"))?;
    let mut store = Store::open(&database)?;
    assert_eq!(
        SessionIndexer::default().index(root.path(), 0.0, &Utc, &mut store, &quitting)?,
        1
    );
    let events = store.events(0.0, 2_000_000_000.0)?;
    assert_eq!(events.len(), 2);
    assert_eq!(
        events.iter().map(|event| event.usage.total()).sum::<i64>(),
        240
    );
    assert!(
        events
            .iter()
            .all(|event| event.model.as_deref() == Some("gpt-6.2-sol"))
    );
    Ok(())
}
