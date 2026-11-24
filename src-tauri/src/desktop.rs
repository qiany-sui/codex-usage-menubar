use anyhow::{Context, Result};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock, mpsc};
use std::time::{Duration, Instant, SystemTime};
use tauri::menu::{Menu, MenuItem};
use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
use tauri::{
    AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, Rect, RunEvent, State,
    WebviewWindow, WindowEvent,
};
use tauri_plugin_dialog::DialogExt;
use usage_core::model::{UsageSnapshot, unix_seconds};
use usage_core::service::{RefreshReason, UsageService};
use usage_core::sessions::SESSION_DIRECTORIES;

const WINDOW: &str = "usage";
const EVENT: &str = "usage-snapshot";
const TRAY: &str = "usage";

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct ViewState {
    snapshot: Option<UsageSnapshot>,
    message: Option<String>,
    refreshing: bool,
}

enum Request {
    Refresh(RefreshReason),
    Home(PathBuf),
    Quit,
}

struct Desktop {
    requests: mpsc::Sender<Request>,
    view: RwLock<ViewState>,
    quitting: Arc<AtomicBool>,
    choosing_home: AtomicBool,
}

impl Desktop {
    fn publish(&self, app: &AppHandle, view: ViewState) {
        if let Ok(mut latest) = self.view.write() {
            *latest = view.clone();
        }
        if let Some(tray) = app.tray_by_id(TRAY) {
            let quota = view
                .snapshot
                .as_ref()
                .and_then(|snapshot| snapshot.quota.as_ref());
            let subtitle = quota.map(|quota| {
                let stale = quota.is_stale(now())
                    || view
                        .snapshot
                        .as_ref()
                        .is_some_and(|snapshot| snapshot.quota_refresh_failed);
                let remaining = (100.0 - quota.used_percent).clamp(0.0, 100.0);
                format!("{remaining:.0}%{}", if stale { " ·" } else { "" })
            });
            let tooltip = subtitle.as_ref().map_or_else(
                || "Codex Usage".to_string(),
                |title| format!("Codex Usage · 周额度剩余 {title}"),
            );
            let _ = tray.set_tooltip(Some(tooltip));
            #[cfg(target_os = "macos")]
            let _ = tray.set_title(subtitle);
        }
        let _ = app.emit(EVENT, view);
    }

    fn show_error(&self, app: &AppHandle, message: &str) {
        let snapshot = self.view.read().ok().and_then(|view| view.snapshot.clone());
        self.publish(
            app,
            ViewState {
                snapshot,
                message: Some(message.to_string()),
                refreshing: false,
            },
        );
    }

    fn exit(&self) {
        if !self.quitting.swap(true, Ordering::AcqRel) {
            let _ = self.requests.send(Request::Quit);
        }
    }
}

#[tauri::command]
fn current_usage(state: State<'_, Arc<Desktop>>) -> Result<ViewState, String> {
    state
        .view
        .read()
        .map(|value| value.clone())
        .map_err(|_| "无法读取当前用量".into())
}

#[tauri::command]
fn refresh_usage(state: State<'_, Arc<Desktop>>) {
    let _ = state.requests.send(Request::Refresh(RefreshReason::Manual));
}

#[tauri::command]
fn select_codex_home(app: AppHandle) {
    let desktop = app.state::<Arc<Desktop>>().inner().clone();
    if desktop.choosing_home.swap(true, Ordering::AcqRel) {
        return;
    }
    let mut dialog = app
        .dialog()
        .file()
        .set_title("选择包含 sessions 的 Codex Home");
    if let Some(window) = app.get_webview_window(WINDOW) {
        dialog = dialog.set_parent(&window);
    }
    dialog.pick_folder(move |selection| {
        desktop.choosing_home.store(false, Ordering::Release);
        if let Some(path) = selection.and_then(|value| value.into_path().ok()) {
            let _ = desktop.requests.send(Request::Home(path));
        }
    });
}

#[tauri::command]
fn exit_usage(state: State<'_, Arc<Desktop>>) {
    state.exit();
}

#[tauri::command]
fn legacy_interface_style() -> Option<String> {
    #[cfg(target_os = "macos")]
    return crate::macos::legacy_interface_style();
    #[cfg(not(target_os = "macos"))]
    None
}

#[tauri::command]
fn hide_usage(window: WebviewWindow) {
    let _ = window.hide();
}

#[tauri::command]
fn resize_usage_panel(app: AppHandle, window: WebviewWindow, has_model_rows: bool) {
    let height = if has_model_rows { 466.0 } else { 440.0 };
    let _ = window.set_size(LogicalSize::new(360.0, height));
    if let Some(rect) = app
        .tray_by_id(TRAY)
        .and_then(|tray| tray.rect().ok().flatten())
    {
        position_panel(&window, rect);
    }
}

fn position_panel(window: &WebviewWindow, rect: Rect) {
    // 不同显示器可能有不同缩放比例，先找托盘所在的屏幕，再计算面板位置。
    let icon = rect.position.to_physical::<f64>(1.0);
    let icon_size = rect.size.to_physical::<f64>(1.0);
    let x = icon.x + icon_size.width / 2.0;
    let y = icon.y + icon_size.height / 2.0;
    let Ok(Some(monitor)) = window.monitor_from_point(x, y) else {
        return;
    };
    let Ok(window_size) = window.outer_size() else {
        return;
    };
    let Ok(window_scale) = window.scale_factor() else {
        return;
    };
    let panel = window_size
        .to_logical::<f64>(window_scale)
        .to_physical::<f64>(monitor.scale_factor());
    let area = monitor.work_area();
    let left = f64::from(area.position.x);
    let top = f64::from(area.position.y);
    let right = left + f64::from(area.size.width);
    let bottom = top + f64::from(area.size.height);
    let gap = 4.0 * monitor.scale_factor();
    let below = icon.y + icon_size.height + gap;
    let preferred_y = if below + panel.height <= bottom {
        below
    } else {
        icon.y - panel.height - gap
    };
    let _ = window.set_position(PhysicalPosition::new(
        (x - panel.width / 2.0).clamp(left, (right - panel.width).max(left)),
        preferred_y.clamp(top, (bottom - panel.height).max(top)),
    ));
}

fn show_window(app: &AppHandle, refresh: bool) {
    if let Some(window) = app.get_webview_window(WINDOW) {
        if let Some(rect) = app
            .tray_by_id(TRAY)
            .and_then(|tray| tray.rect().ok().flatten())
        {
            position_panel(&window, rect);
        }
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
        if refresh && let Some(desktop) = app.try_state::<Arc<Desktop>>() {
            let _ = desktop
                .requests
                .send(Request::Refresh(RefreshReason::Opened));
        }
    }
}

pub fn run() -> Result<()> {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| {
            show_window(app, true)
        }))
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            current_usage,
            refresh_usage,
            select_codex_home,
            exit_usage,
            legacy_interface_style,
            hide_usage,
            resize_usage_panel
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);

            let app_handle = app.handle();
            let root = data_directory(app_handle)?;
            let profile = app.path().home_dir()?;
            #[cfg(target_os = "macos")]
            crate::macos::register_companion();
            let (requests, input) = mpsc::channel();
            let desktop = Arc::new(Desktop {
                requests,
                view: RwLock::new(ViewState {
                    refreshing: true,
                    ..ViewState::default()
                }),
                quitting: Arc::default(),
                choosing_home: AtomicBool::new(false),
            });
            app.manage(desktop.clone());

            let open = MenuItem::with_id(app, "open", "打开 Codex Usage", true, None::<&str>)?;
            let refresh = MenuItem::with_id(app, "refresh", "刷新", true, None::<&str>)?;
            let home = MenuItem::with_id(app, "home", "选择目录…", true, None::<&str>)?;
            let close = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &refresh, &home, &close])?;
            TrayIconBuilder::with_id(TRAY)
                .icon(
                    app.default_window_icon()
                        .context("missing tray icon")?
                        .clone(),
                )
                .tooltip("Codex Usage")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| {
                    let desktop = app.state::<Arc<Desktop>>();
                    match event.id().as_ref() {
                        "open" => show_window(app, true),
                        "refresh" => {
                            let _ = desktop
                                .requests
                                .send(Request::Refresh(RefreshReason::Manual));
                        }
                        "home" => {
                            show_window(app, false);
                            select_codex_home(app.clone());
                        }
                        "quit" => desktop.exit(),
                        _ => (),
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        ..
                    } = event
                    {
                        let app = tray.app_handle();
                        if let Some(window) = app.get_webview_window(WINDOW)
                            && window.is_focused().unwrap_or(false)
                        {
                            let _ = window.hide();
                        } else {
                            show_window(app, true);
                        }
                    }
                })
                .build(app)?;

            let handle = app.handle().clone();
            std::thread::Builder::new()
                .name("usage-runtime".into())
                .spawn(move || worker(handle, desktop, input, root, profile))?;
            if !std::env::args_os().any(|arg| arg == "--companion") {
                show_window(app.handle(), false);
            }
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                let _ = window.hide();
            }
            WindowEvent::Focused(false)
                if window
                    .try_state::<Arc<Desktop>>()
                    .is_some_and(|desktop| !desktop.choosing_home.load(Ordering::Acquire)) =>
            {
                let _ = window.hide();
            }
            _ => (),
        })
        .build(tauri::generate_context!())?;

    app.run(|app, event| match event {
        #[cfg(target_os = "macos")]
        RunEvent::Reopen { .. } => show_window(app, true),
        RunEvent::ExitRequested {
            code: None, api, ..
        } => {
            if let Some(desktop) = app.try_state::<Arc<Desktop>>() {
                api.prevent_exit();
                desktop.exit();
            }
        }
        _ => (),
    });
    Ok(())
}

fn data_directory(app: &AppHandle) -> Result<PathBuf> {
    // 路径沿用两个 Swift 版本的数据库位置。
    Ok(app.path().local_data_dir()?.join("Codex Usage"))
}

fn worker(
    app: AppHandle,
    desktop: Arc<Desktop>,
    input: mpsc::Receiver<Request>,
    root: PathBuf,
    profile: PathBuf,
) {
    let preference = root.join("codex-home.txt");
    let mut core = open_service(&root, &profile, &preference, &desktop.quitting);
    let changed = Arc::new(AtomicBool::new(false));
    let mut watched_home: Option<PathBuf> = None;
    let mut watcher: Option<RecommendedWatcher> = None;
    let mut pending = Some(Request::Refresh(RefreshReason::Startup));
    let mut last_tick = Instant::now();
    loop {
        let before_wait = now();
        let request = pending
            .take()
            .or_else(|| input.recv_timeout(Duration::from_secs(1)).ok());
        if desktop.quitting.load(Ordering::Acquire) {
            if let Ok(core) = core {
                let _ = core.close();
            }
            app.exit(0);
            return;
        }

        let clock = now();
        let woke = (clock - before_wait).abs() > 20.0;
        let elapsed = last_tick.elapsed();
        let refresh = match request {
            Some(Request::Refresh(reason)) => Some(reason),
            Some(Request::Home(path)) => {
                if core.is_err() {
                    core = open_service(&root, &profile, &preference, &desktop.quitting);
                }
                match core.as_mut() {
                    Ok(core) => match select_home(&preference, core, path) {
                        Ok(()) => Some(RefreshReason::Manual),
                        Err(_) => {
                            desktop.show_error(
                                &app,
                                "请选择包含 sessions 或 archived_sessions 的可读目录。",
                            );
                            None
                        }
                    },
                    Err(_) => {
                        desktop.show_error(&app, "无法打开用量数据库，请检查应用数据目录。");
                        None
                    }
                }
            }
            Some(Request::Quit) => continue,
            None if woke => Some(RefreshReason::Wake),
            None if elapsed >= Duration::from_secs(60) => {
                last_tick = Instant::now();
                Some(RefreshReason::Scheduled)
            }
            None if changed.swap(false, Ordering::AcqRel) => Some(RefreshReason::SessionsChanged),
            None => None,
        };

        if let Some(reason) = refresh {
            if core.is_err() {
                core = open_service(&root, &profile, &preference, &desktop.quitting);
            }
            if let Ok(core) = core.as_mut() {
                refresh_and_publish(&app, &desktop, core, reason, clock);
                let home = core.codex_home();
                if watched_home != home {
                    watcher = home
                        .as_ref()
                        .and_then(|home| watch(home, Arc::clone(&changed)).ok());
                    watched_home = home;
                }
                continue;
            }
            desktop.show_error(&app, "无法打开用量数据库，请检查应用数据目录。");
        } else if let Ok(core) = core.as_mut() {
            match core.poll_quota(clock) {
                Ok(Some(snapshot)) => publish(&app, &desktop, core, snapshot, false),
                Ok(None) => (),
                Err(_) => desktop.show_error(&app, "读取额度更新失败，请点击刷新重试。"),
            }
        }
        // 直到切换 Codex Home 或退出，持续持有目录监听。
        let _ = watcher.as_ref();
    }
}

fn open_service(
    root: &Path,
    profile: &Path,
    preference: &Path,
    quitting: &Arc<AtomicBool>,
) -> Result<UsageService> {
    fs::create_dir_all(root)?;
    let saved = fs::read_to_string(preference)
        .ok()
        .map(PathBuf::from)
        .filter(|path| UsageService::valid_selected_home(path));
    #[cfg(target_os = "macos")]
    let saved = saved.or_else(crate::macos::legacy_home);
    UsageService::open(&root.join("usage.sqlite"), profile.to_path_buf(), saved)
        .map(|service| service.with_quit_signal(quitting.clone()))
}

fn select_home(preference: &Path, core: &mut UsageService, path: PathBuf) -> Result<()> {
    let text = path.to_str().context("invalid Codex Home path")?;
    anyhow::ensure!(
        UsageService::valid_selected_home(&path),
        "invalid Codex Home"
    );
    let temporary = preference.with_extension("tmp");
    fs::write(&temporary, text)?;
    fs::rename(temporary, preference)?;
    core.select_home(path)
}

fn refresh_and_publish(
    app: &AppHandle,
    desktop: &Desktop,
    core: &mut UsageService,
    reason: RefreshReason,
    now: f64,
) {
    match core.refresh(reason, now, |snapshot| {
        desktop.publish(
            app,
            ViewState {
                snapshot: Some(snapshot),
                message: None,
                refreshing: true,
            },
        )
    }) {
        Ok(snapshot) => publish(app, desktop, core, snapshot, false),
        Err(_) => desktop.show_error(app, "读取用量失败，请点击刷新重试。"),
    }
}

fn publish(
    app: &AppHandle,
    desktop: &Desktop,
    core: &UsageService,
    snapshot: UsageSnapshot,
    refreshing: bool,
) {
    let message = if core.codex_home().is_none() {
        Some("未找到 Codex Home。".into())
    } else if !core.has_server() {
        Some("官方额度暂不可用，正在显示本机统计和已缓存的数据。".into())
    } else if snapshot.quota.is_none() {
        Some("暂未取得官方周额度，请确认 Codex CLI 已登录。".into())
    } else {
        None
    };
    desktop.publish(
        app,
        ViewState {
            snapshot: Some(snapshot),
            message,
            refreshing,
        },
    );
}

fn watch(home: &Path, changed: Arc<AtomicBool>) -> Result<RecommendedWatcher> {
    let mut watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
        if event.is_ok_and(|event| !matches!(event.kind, EventKind::Access(_))) {
            changed.store(true, Ordering::Release);
        }
    })?;
    for directory in SESSION_DIRECTORIES {
        let path = home.join(directory);
        if fs::symlink_metadata(&path)
            .is_ok_and(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
        {
            watcher.watch(&path, RecursiveMode::Recursive)?;
        }
    }
    Ok(watcher)
}

fn now() -> f64 {
    unix_seconds(SystemTime::now())
}
