use std::collections::HashSet;
use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};
use windows_sys::Win32::Foundation::{
    ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_NO_MORE_FILES, ERROR_SUCCESS, FILETIME,
    GetLastError, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0, WAIT_TIMEOUT,
};
use windows_sys::Win32::Storage::Packaging::Appx::GetPackageFamilyName;
use windows_sys::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows_sys::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_SZ, RegGetValueW};
use windows_sys::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CreateEventW, CreateMutexW, EVENT_MODIFY_STATE, GetProcessTimes, OpenEventW,
    OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW,
    SYNCHRONIZATION_SYNCHRONIZE, SetEvent, WaitForSingleObject,
};

use crate::companion::{Action, CodexPresence};

const CODEX_FAMILY: &str = "OpenAI.Codex_2p2nqsd0c76g0";
const POLL_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
struct ProcessId {
    pid: u32,
    birth: u64,
}

#[derive(Clone)]
struct Process {
    id: ProcessId,
    parent: u32,
    path: PathBuf,
    parent_is_other_app: bool,
}

#[derive(Default)]
struct DesktopRoots {
    children: HashSet<ProcessId>,
    previous: Vec<Process>,
    roots: HashSet<ProcessId>,
}

impl DesktopRoots {
    fn update(&mut self, processes: &[Process]) -> Vec<ProcessId> {
        self.children
            .retain(|id| processes.iter().any(|process| process.id == *id));
        for process in processes {
            if processes.iter().chain(&self.previous).any(|parent| {
                parent.id.pid == process.parent
                    && parent.path == process.path
                    && parent.id.birth <= process.id.birth
            }) {
                self.children.insert(process.id);
            }
        }
        // 没有父进程信息的新叶子可能是孤儿 renderer，不能单凭相同包名启动用量采集。
        // 浏览器主进程若由已退出的启动器打开，等它创建自己的子进程后再确认。
        let roots = processes
            .iter()
            .filter(|process| {
                !self.children.contains(&process.id)
                    && (process.parent_is_other_app
                        || self.roots.contains(&process.id)
                        || processes.iter().any(|child| {
                            child.parent == process.id.pid && child.id.birth >= process.id.birth
                        }))
            })
            .map(|process| process.id)
            .collect::<Vec<_>>();
        self.roots = roots.iter().copied().collect();
        self.previous = processes.to_vec();
        roots
    }
}

fn wide(value: impl AsRef<OsStr>) -> Vec<u16> {
    value.as_ref().encode_wide().chain(Some(0)).collect()
}

fn owned(handle: HANDLE) -> Result<OwnedHandle> {
    ensure!(
        !handle.is_null() && handle != INVALID_HANDLE_VALUE,
        std::io::Error::last_os_error()
    );
    Ok(unsafe { OwnedHandle::from_raw_handle(handle) })
}

fn entries() -> Result<Vec<PROCESSENTRY32W>> {
    let snapshot = owned(unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) })?;
    let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
    entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
    let mut found = unsafe { Process32FirstW(snapshot.as_raw_handle(), &mut entry) };
    let mut result = Vec::new();
    while found != 0 {
        result.push(entry);
        found = unsafe { Process32NextW(snapshot.as_raw_handle(), &mut entry) };
    }
    ensure!(
        unsafe { GetLastError() } == ERROR_NO_MORE_FILES,
        std::io::Error::last_os_error()
    );
    Ok(result)
}

fn session(pid: u32) -> Option<u32> {
    let mut value = 0;
    (unsafe { ProcessIdToSessionId(pid, &mut value) } != 0).then_some(value)
}

fn process_path(handle: HANDLE) -> Option<PathBuf> {
    let mut buffer = vec![0; 32768];
    let mut length = buffer.len() as u32;
    (unsafe { QueryFullProcessImageNameW(handle, 0, buffer.as_mut_ptr(), &mut length) } != 0)
        .then(|| PathBuf::from(String::from_utf16_lossy(&buffer[..length as usize])))
}

fn process_birth(handle: HANDLE) -> Option<u64> {
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    (unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) } != 0)
        .then_some((u64::from(creation.dwHighDateTime) << 32) | u64::from(creation.dwLowDateTime))
}

fn is_codex_desktop(family: &str, path: &Path) -> bool {
    family.eq_ignore_ascii_case(CODEX_FAMILY)
        && path
            .parent()
            .and_then(Path::file_name)
            .is_some_and(|name| name.eq_ignore_ascii_case("app"))
        && path.file_name().is_some_and(|name| {
            name.eq_ignore_ascii_case("ChatGPT.exe") || name.eq_ignore_ascii_case("Codex.exe")
        })
}

fn codex_processes() -> Result<Vec<Process>> {
    let own_session = session(std::process::id()).context("read current Windows session")?;
    let mut result = Vec::new();
    let entries = entries()?;
    for entry in &entries {
        let name = String::from_utf16_lossy(
            &entry.szExeFile[..entry
                .szExeFile
                .iter()
                .position(|c| *c == 0)
                .unwrap_or(entry.szExeFile.len())],
        );
        if !(name.eq_ignore_ascii_case("ChatGPT.exe") || name.eq_ignore_ascii_case("Codex.exe"))
            || session(entry.th32ProcessID) != Some(own_session)
        {
            continue;
        }
        let Ok(handle) = owned(unsafe {
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID)
        }) else {
            continue;
        };
        let mut family = [0; 256];
        let mut length = family.len() as u32;
        if unsafe { GetPackageFamilyName(handle.as_raw_handle(), &mut length, family.as_mut_ptr()) }
            != ERROR_SUCCESS
        {
            continue;
        }
        let Some(path) = process_path(handle.as_raw_handle()) else {
            continue;
        };
        if !is_codex_desktop(
            &String::from_utf16_lossy(&family[..length.saturating_sub(1) as usize]),
            &path,
        ) {
            continue;
        }
        if let Some(birth) = process_birth(handle.as_raw_handle()) {
            result.push(Process {
                id: ProcessId {
                    pid: entry.th32ProcessID,
                    birth,
                },
                parent: entry.th32ParentProcessID,
                path,
                parent_is_other_app: entries
                    .iter()
                    .find(|parent| parent.th32ProcessID == entry.th32ParentProcessID)
                    .is_some_and(|parent| {
                        let name = String::from_utf16_lossy(
                            &parent.szExeFile[..parent
                                .szExeFile
                                .iter()
                                .position(|c| *c == 0)
                                .unwrap_or(parent.szExeFile.len())],
                        );
                        let different_app = !name.eq_ignore_ascii_case("ChatGPT.exe")
                            && !name.eq_ignore_ascii_case("Codex.exe");
                        different_app
                            && owned(unsafe {
                                OpenProcess(
                                    PROCESS_QUERY_LIMITED_INFORMATION,
                                    0,
                                    parent.th32ProcessID,
                                )
                            })
                            .ok()
                            .and_then(|parent| process_birth(parent.as_raw_handle()))
                            .is_some_and(|parent_birth| parent_birth <= birth)
                    }),
            });
        }
    }
    Ok(result)
}

fn object_name(kind: &str) -> Result<Vec<u16>> {
    // 同一登录会话、同一安装路径共享信号；开发构建和备份副本不会关闭已安装的应用。
    let path = std::env::current_exe()?.to_string_lossy().to_lowercase();
    let hash = path
        .as_bytes()
        .iter()
        .fold(0xcbf29ce484222325u64, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
        });
    Ok(wide(format!(r"Local\CodexUsage.{hash:016x}.{kind}")))
}

pub struct QuitEvent(OwnedHandle);

impl QuitEvent {
    fn create(kind: &str) -> Result<Self> {
        let name = object_name(kind)?;
        Ok(Self(owned(unsafe {
            CreateEventW(std::ptr::null(), 1, 0, name.as_ptr())
        })?))
    }

    pub fn for_app() -> Result<Self> {
        Self::create("quit")
    }

    pub fn wait(&self, timeout: Duration) -> Result<bool> {
        match unsafe { WaitForSingleObject(self.0.as_raw_handle(), timeout.as_millis() as u32) } {
            WAIT_OBJECT_0 => Ok(true),
            WAIT_TIMEOUT => Ok(false),
            _ => Err(std::io::Error::last_os_error().into()),
        }
    }
}

fn open_event(kind: &str, access: u32) -> Result<Option<OwnedHandle>> {
    let name = object_name(kind)?;
    let handle = unsafe { OpenEventW(access, 0, name.as_ptr()) };
    if handle.is_null() && unsafe { GetLastError() } == ERROR_FILE_NOT_FOUND {
        return Ok(None);
    }
    Ok(Some(owned(handle)?))
}

fn signal(kind: &str) -> Result<bool> {
    if let Some(event) = open_event(kind, EVENT_MODIFY_STATE)? {
        ensure!(
            unsafe { SetEvent(event.as_raw_handle()) } != 0,
            std::io::Error::last_os_error()
        );
        return Ok(true);
    }
    Ok(false)
}

fn app_is_quitting() -> Result<bool> {
    match open_event("quit", SYNCHRONIZATION_SYNCHRONIZE)? {
        Some(event) => QuitEvent(event).wait(Duration::ZERO),
        None => Ok(false),
    }
}

pub fn mark_quitting() -> Result<()> {
    signal("quit").map(|_| ())
}

fn spawn(argument: &str) -> Result<Child> {
    Ok(Command::new(std::env::current_exe()?)
        .arg(argument)
        .creation_flags(CREATE_NO_WINDOW)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?)
}

pub fn ensure_watcher() -> Result<()> {
    let mut buffer = [0u16; 512];
    let mut bytes = std::mem::size_of_val(&buffer) as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            wide(r"Software\Microsoft\Windows\CurrentVersion\Run").as_ptr(),
            wide("Codex Usage Watcher").as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buffer.as_mut_ptr().cast(),
            &mut bytes,
        )
    };
    let registered = String::from_utf16_lossy(
        &buffer[..buffer.iter().position(|c| *c == 0).unwrap_or(buffer.len())],
    );
    let expected = format!("\"{}\" --watch-codex", std::env::current_exe()?.display());
    // 只有安装程序注册的副本才拉起助手，调试和 CI 启动不会修改登录项。
    if status == ERROR_SUCCESS && registered.eq_ignore_ascii_case(&expected) {
        spawn("--watch-codex")?;
    }
    Ok(())
}

pub fn watch() -> Result<()> {
    let name = object_name("watcher")?;
    let mutex = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    let exists = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    let _mutex = owned(mutex)?;
    if exists {
        return Ok(());
    }
    let stop = QuitEvent::create("stop-watcher")?;
    let mut roots = DesktopRoots::default();
    let mut presence = CodexPresence::default();
    let mut launch_pending = false;
    let mut started: Option<Child> = None;
    let mut terminate_started = false;
    loop {
        if stop.wait(Duration::ZERO)? {
            return Ok(());
        }
        if let Some(child) = started.as_mut() {
            if child.try_wait()?.is_some() {
                started = None;
                terminate_started = false;
            } else if terminate_started {
                // 仅重试助手刚启动的实例，避免冷启动尚未创建退出事件时漏掉通知。
                terminate_started = match signal("quit") {
                    Ok(delivered) => !delivered,
                    Err(error) => {
                        eprintln!("Could not request Codex Usage to quit: {error:#}");
                        false
                    }
                };
            }
        }
        if let Ok(processes) = codex_processes() {
            match presence.update(roots.update(&processes), Instant::now()) {
                Some(Action::Launch) => {
                    launch_pending = true;
                    terminate_started = false;
                }
                Some(Action::Terminate) => {
                    launch_pending = false;
                    terminate_started = match signal("quit") {
                        Ok(delivered) => !delivered && started.is_some(),
                        Err(error) => {
                            eprintln!("Could not request Codex Usage to quit: {error:#}");
                            false
                        }
                    };
                }
                None => (),
            }
            // 快速重启 Codex 时，先等上一轮用量采集保存完毕，再启动新实例。
            if launch_pending {
                match app_is_quitting() {
                    Ok(false) => match spawn("--companion") {
                        Ok(child) => {
                            started = Some(child);
                            launch_pending = false;
                        }
                        Err(error) => eprintln!("Could not launch Codex Usage: {error:#}"),
                    },
                    Ok(true) => (),
                    Err(error) => {
                        eprintln!("Could not check Codex Usage shutdown: {error:#}");
                        launch_pending = false;
                    }
                }
            }
        }
        if stop.wait(POLL_INTERVAL)? {
            return Ok(());
        }
    }
}

pub fn stop() -> Result<()> {
    let executable = std::env::current_exe()?;
    let own_pid = std::process::id();
    let own_session = session(own_pid).context("read current Windows session")?;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        signal("stop-watcher")?;
        signal("quit")?;
        let running = entries()?.iter().any(|entry| {
            if entry.th32ProcessID == own_pid || session(entry.th32ProcessID) != Some(own_session) {
                return false;
            }
            let Ok(handle) = owned(unsafe {
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID)
            }) else {
                return false;
            };
            process_path(handle.as_raw_handle()).is_some_and(|path| {
                path.as_os_str()
                    .eq_ignore_ascii_case(executable.as_os_str())
            })
        });
        if !running {
            return Ok(());
        }
        if Instant::now() >= deadline {
            bail!("Codex Usage did not finish shutting down within 30 seconds")
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: u32, parent: u32, birth: u64) -> Process {
        Process {
            id: ProcessId { pid, birth },
            parent,
            path: PathBuf::from(r"C:\Apps\app\ChatGPT.exe"),
            parent_is_other_app: parent == 1,
        }
    }

    #[test]
    fn matches_desktop_identity_not_cli_or_chatgpt_package() {
        assert!(is_codex_desktop(
            CODEX_FAMILY,
            Path::new(r"C:\WindowsApps\version\app\ChatGPT.exe")
        ));
        assert!(is_codex_desktop(
            CODEX_FAMILY,
            Path::new(r"C:\WindowsApps\version\app\Codex.exe")
        ));
        assert!(!is_codex_desktop(
            "OpenAI.ChatGPT_2p2nqsd0c76g0",
            Path::new(r"C:\Apps\app\ChatGPT.exe")
        ));
        assert!(!is_codex_desktop("", Path::new(r"C:\bin\codex.exe")));
        assert!(!is_codex_desktop(
            CODEX_FAMILY,
            Path::new(r"C:\Apps\app\resources\codex.exe")
        ));
    }

    #[test]
    fn ignores_renderer_churn_and_orphaned_children() {
        let mut roots = DesktopRoots::default();
        let main = process(100, 1, 10);
        let child = process(101, 100, 11);
        assert_eq!(roots.update(&[main.clone(), child.clone()]), vec![main.id]);
        let new_child = process(102, 100, 12);
        assert_eq!(
            roots.update(&[main.clone(), child.clone(), new_child.clone()]),
            vec![main.id]
        );
        assert!(roots.update(&[child, new_child]).is_empty());
        assert!(roots.update(&[]).is_empty());
        let restarted = process(101, 1, 20);
        assert_eq!(roots.update(&[restarted.clone()]), vec![restarted.id]);
    }

    #[test]
    fn pid_reuse_starts_a_new_session() {
        let now = Instant::now();
        let mut presence = CodexPresence::default();
        assert_eq!(
            presence.update(vec![process(100, 1, 10).id], now),
            Some(Action::Launch)
        );
        assert_eq!(
            presence.update(vec![process(100, 1, 20).id], now),
            Some(Action::Launch)
        );
    }

    #[test]
    fn rejects_new_orphans_even_if_their_parent_exited_between_polls() {
        let mut roots = DesktopRoots::default();
        let main = process(100, 1, 10);
        assert_eq!(roots.update(&[main.clone()]), vec![main.id]);
        assert!(roots.update(&[process(101, 100, 11)]).is_empty());
        assert!(
            DesktopRoots::default()
                .update(&[process(101, 100, 11)])
                .is_empty()
        );
    }

    #[test]
    fn recognizes_main_after_its_launcher_exits_without_following_old_children() {
        let mut roots = DesktopRoots::default();
        let main = process(100, 2, 10);
        assert!(roots.update(&[main.clone()]).is_empty());
        assert_eq!(
            roots.update(&[main.clone(), process(101, 100, 11)]),
            vec![main.id]
        );
        assert_eq!(roots.update(&[main.clone()]), vec![main.id]);
    }

    #[test]
    fn native_snapshot_and_quit_events_work() {
        assert!(
            entries()
                .unwrap()
                .iter()
                .any(|entry| entry.th32ProcessID == std::process::id())
        );
        let kind = format!("test-{}", std::process::id());
        assert!(!signal(&kind).unwrap());
        let event = QuitEvent::create(&kind).unwrap();
        assert!(!event.wait(Duration::ZERO).unwrap());
        assert!(signal(&kind).unwrap());
        assert!(event.wait(Duration::from_millis(100)).unwrap());
        drop(event);
        assert!(
            !QuitEvent::create(&kind)
                .unwrap()
                .wait(Duration::ZERO)
                .unwrap()
        );
        codex_processes().unwrap();
    }
}
