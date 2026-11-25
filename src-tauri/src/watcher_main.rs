#[cfg(target_os = "macos")]
#[path = "macos/bundle.rs"]
mod bundle;
#[cfg(target_os = "macos")]
mod companion;
#[cfg(target_os = "macos")]
#[path = "macos/watcher.rs"]
mod watcher;

fn main() {
    #[cfg(not(target_os = "macos"))]
    compile_error!("CodexUsageWatcher is only supported on macOS");

    #[cfg(target_os = "macos")]
    if let Err(error) = watcher::watch() {
        eprintln!("Codex Usage watcher failed: {error:#}");
        std::process::exit(1);
    }
}
