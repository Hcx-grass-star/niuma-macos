use tauri::{
    menu::{MenuBuilder, MenuItem},
    tray::{MouseButton, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, WindowEvent,
};
use tauri_plugin_autostart::ManagerExt;

/// 初始化跨平台窗口、系统托盘和自动启动能力。
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .invoke_handler(tauri::generate_handler![set_autostart, autostart_enabled, update_environment, open_release_page])
        .setup(|app| {
            let show = MenuItem::with_id(app, "show", "查看当前收入", true, None::<&str>)?;
            let settings = MenuItem::with_id(app, "settings", "打开设置", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出牛马上班", true, None::<&str>)?;
            let menu = MenuBuilder::new(app)
                .item(&show)
                .item(&settings)
                .separator()
                .item(&quit)
                .build()?;
            TrayIconBuilder::new()
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| handle_menu_event(app, event.id.as_ref()))
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, .. } = event {
                        show_main_window(tray.app_handle());
                    }
                })
                .build(app)?;
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_title("牛马上班");
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("运行牛马上班失败");
}

/// 开关系统登录启动；状态由 macOS LaunchAgent 或 Windows 注册表负责保存。
#[tauri::command]
fn set_autostart(app: AppHandle, enabled: bool) -> Result<(), String> {
    if enabled {
        app.autolaunch().enable().map_err(|error| error.to_string())
    } else {
        app.autolaunch().disable().map_err(|error| error.to_string())
    }
}

/// 读取系统实际登录启动状态，避免用本地配置猜测是否注册成功。
#[tauri::command]
fn autostart_enabled(app: AppHandle) -> Result<bool, String> {
    app.autolaunch().is_enabled().map_err(|error| error.to_string())
}

/// 从正式应用包返回真实版本与操作系统，避免前端硬编码版本导致重复提示。
#[tauri::command]
fn update_environment(app: AppHandle) -> (String, String) {
    (app.package_info().version.to_string(), std::env::consts::OS.to_string())
}

/// 只允许打开本仓库正式版本页；参数按独立进程参数传递，不经过 shell。
#[tauri::command]
fn open_release_page(url: String) -> Result<(), String> {
    let prefix = "https://github.com/Hcx-grass-star/niuma-macos/releases/tag/";
    let tag = url.strip_prefix(prefix).ok_or("无效的发布页面")?;
    if tag.is_empty() || !tag.bytes().all(|byte| byte.is_ascii_digit() || byte == b'.' || byte == b'v') {
        return Err("无效的发布页面".into());
    }
    #[cfg(target_os = "macos")]
    let result = std::process::Command::new("open").arg(&url).spawn();
    #[cfg(target_os = "windows")]
    let result = std::process::Command::new("rundll32.exe").args(["url.dll,FileProtocolHandler", &url]).spawn();
    #[cfg(target_os = "linux")]
    let result = std::process::Command::new("xdg-open").arg(&url).spawn();
    result.map(|_| ()).map_err(|_| "无法打开下载页面，请重试。".into())
}

/// 将托盘菜单动作映射到窗口显示、设置页和应用退出。
fn handle_menu_event(app: &AppHandle, id: &str) {
    match id {
        "show" => show_main_window(app),
        "settings" => {
            show_main_window(app);
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.emit("open-settings", ());
            }
        }
        "quit" => app.exit(0),
        _ => {}
    }
}

/// 显示并聚焦主窗口，供托盘左键和菜单重复使用。
fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.set_focus();
    }
}
