#![cfg_attr(
    all(not(debug_assertions), target_os = "windows"),
    windows_subsystem = "windows"
)]

mod desktop;
#[cfg(target_os = "macos")]
mod macos;

fn main() {
    if let Err(error) = desktop::run() {
        eprintln!("Codex Usage failed: {error:#}");
        std::process::exit(1);
    }
}
