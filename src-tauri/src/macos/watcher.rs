use std::process::{self, Command};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use objc2::rc::autoreleasepool;
use objc2_app_kit::NSRunningApplication;
use objc2_foundation::{NSDate, NSRunLoop, NSString};

use super::bundle::{USAGE_BUNDLE_ID, app_bundle};
use crate::companion::{Action, CodexPresence};

const CODEX_BUNDLE_ID: &str = "com.openai.codex";
const POLL_INTERVAL: Duration = Duration::from_secs(1);

pub fn watch() -> Result<()> {
    let executable = std::env::current_exe()?.canonicalize()?;
    let bundle = app_bundle(&executable).context("locate Codex Usage app bundle")?;
    let codex_id = NSString::from_str(CODEX_BUNDLE_ID);
    let usage_id = NSString::from_str(USAGE_BUNDLE_ID);
    let run_loop = NSRunLoop::currentRunLoop();
    let own_pid = process::id() as i32;
    let mut presence = CodexPresence::default();

    loop {
        let next_poll = Instant::now() + POLL_INTERVAL;
        autoreleasepool(|_| {
            let codex = NSRunningApplication::runningApplicationsWithBundleIdentifier(&codex_id)
                .iter()
                .filter(|app| !app.isTerminated())
                .map(|app| app.processIdentifier())
                .collect();
            let Some(action) = presence.update(codex, Instant::now()) else {
                return;
            };
            let usage = NSRunningApplication::runningApplicationsWithBundleIdentifier(&usage_id);
            let mut usage = usage.iter().filter(|app| {
                app.processIdentifier() != own_pid
                    && !app.isTerminated()
                    && app
                        .bundleURL()
                        .and_then(|url| url.to_file_path())
                        .and_then(|path| path.canonicalize().ok())
                        .as_deref()
                        == Some(bundle)
            });
            match action {
                Action::Launch => {
                    if usage.next().is_none() {
                        match Command::new("/usr/bin/open")
                            .args(["-g", "-a"])
                            .arg(bundle)
                            .args(["--args", "--companion"])
                            .status()
                        {
                            Ok(status) if status.success() => (),
                            Ok(status) => eprintln!("Could not launch Codex Usage: {status}"),
                            Err(error) => eprintln!("Could not launch Codex Usage: {error}"),
                        }
                    }
                }
                Action::Terminate => {
                    for app in usage {
                        if !app.terminate() {
                            eprintln!("Codex Usage rejected the terminate request");
                        }
                    }
                }
            }
        });

        // AppKit refreshes its running-application state between main run-loop turns.
        autoreleasepool(|_| {
            let remaining = next_poll.saturating_duration_since(Instant::now());
            run_loop.runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(
                remaining.as_secs_f64(),
            ));
        });
        std::thread::sleep(next_poll.saturating_duration_since(Instant::now()));
    }
}
