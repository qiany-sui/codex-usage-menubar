use std::env;
use std::path::{Path, PathBuf};

pub(super) fn absolute_path(value: impl AsRef<Path>) -> Option<PathBuf> {
    let path = value.as_ref();
    path.is_absolute().then(|| path.to_path_buf())
}

fn path_directories() -> Vec<PathBuf> {
    env::var_os("PATH")
        .iter()
        .flat_map(env::split_paths)
        .filter(|path| path.is_absolute())
        .collect()
}

#[cfg(unix)]
pub(super) fn find_executable() -> Option<PathBuf> {
    use std::os::unix::fs::PermissionsExt;

    let explicit = env::var_os("CODEX_CLI_PATH").and_then(absolute_path);
    let path = path_directories()
        .into_iter()
        .map(|directory| directory.join("codex"));
    let standalone = env::var_os("HOME")
        .and_then(absolute_path)
        .map(|home| home.join(".local/bin/codex"));
    let well_known = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]
    .into_iter()
    .map(PathBuf::from);
    explicit
        .into_iter()
        .chain(path)
        .chain(standalone)
        .chain(well_known)
        .find(|path| {
            path.metadata().is_ok_and(|metadata| {
                metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
            })
        })
}

#[cfg(windows)]
pub(super) fn find_executable() -> Option<PathBuf> {
    let explicit = env::var_os("CODEX_CLI_PATH").and_then(absolute_path);
    if let Some(executable) = explicit.filter(|path| is_windows_executable(path)) {
        return Some(executable);
    }
    let (architecture, triple) = if cfg!(target_arch = "aarch64") {
        ("arm64", "aarch64-pc-windows-msvc")
    } else {
        ("x64", "x86_64-pc-windows-msvc")
    };
    let npm = env::var_os("APPDATA")
        .and_then(absolute_path)
        .map(|path| path.join("npm"));
    path_directories()
        .into_iter()
        .chain(npm)
        .find_map(|directory| windows_executable_in(&directory, architecture, triple))
        .or_else(|| {
            env::var_os("LOCALAPPDATA")
                .and_then(absolute_path)
                .map(|path| path.join("Programs/OpenAI/Codex/bin/codex.exe"))
                .filter(|path| is_windows_executable(path))
        })
}

#[cfg(any(windows, test))]
pub(super) fn windows_executable_in(
    directory: &Path,
    architecture: &str,
    triple: &str,
) -> Option<PathBuf> {
    let package = directory.join("node_modules/@openai/codex");
    let alias = format!("node_modules/@openai/codex-win32-{architecture}");
    let vendor_roots = [package.join(&alias), directory.join(alias), package];
    let native = vendor_roots.into_iter().flat_map(|root| {
        let vendor = root.join("vendor").join(triple);
        [vendor.join("bin/codex.exe"), vendor.join("codex/codex.exe")]
    });
    std::iter::once(directory.join("codex.exe"))
        .chain(native)
        .find(|path| is_windows_executable(path))
}

#[cfg(any(windows, test))]
fn is_windows_executable(path: &Path) -> bool {
    path.extension()
        .is_some_and(|extension| extension.eq_ignore_ascii_case("exe"))
        && path.is_file()
}
