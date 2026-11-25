#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

#[cfg(target_os = "windows")]
mod companion;
mod desktop;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "windows")]
mod windows;

fn main() {
    if let Err(error) = run() {
        eprintln!("Codex Usage failed: {error:#}");
        std::process::exit(1);
    }
}

fn run() -> anyhow::Result<()> {
    #[cfg(target_os = "windows")]
    match std::env::args().nth(1).as_deref() {
        Some("--watch-codex") => return windows::companion::watch(),
        Some("--stop-companion") => return windows::companion::stop(),
        _ => (),
    }
    desktop::run()
}
