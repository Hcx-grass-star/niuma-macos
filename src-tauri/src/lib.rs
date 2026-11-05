use tauri::{
    menu::{MenuBuilder, MenuItem},
    tray::{MouseButton, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, WindowEvent,
};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_updater::UpdaterExt;

/// 初始化跨平台窗口、系统托盘和自动启动能力。
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[cfg(all(target_os = "macos", not(debug_assertions)))]
    if prepare_managed_installation().expect("无法启动应用安装助手") {
        return;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .invoke_handler(tauri::generate_handler![set_autostart, autostart_enabled, update_environment, open_release_page, install_update, cleanup_old_versions])
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

/// 使用固定更新源和内置公钥校验安装包；前端不能传入任意 URL 或关闭签名验证。
#[tauri::command]
async fn install_update(app: AppHandle) -> Result<(), String> {
    let updater = app.updater().map_err(|_| "更新安装器初始化失败，请使用安装包升级。")?;
    let update = updater.check().await.map_err(|_| "暂时无法读取自动更新包，请稍后重试或手动下载。")?
        .ok_or("当前没有可安装的新版本。")?;
    let download_app = app.clone();
    let finished_app = app.clone();
    let mut downloaded = 0u64;
    update.download_and_install(move |chunk, total| {
        downloaded += chunk as u64;
        let progress = total.filter(|total| *total > 0).map(|total| (downloaded.saturating_mul(100) / total).min(100)).unwrap_or(0);
        let _ = download_app.emit("update-progress", progress);
    }, move || { let _ = finished_app.emit("update-progress", 100u64); })
        .await.map_err(|_| "更新未完成，请重试或手动下载安装。")?;
    // Windows 安装器会退出并重新启动应用；其余平台在原位替换成功后重启。
    #[cfg(not(target_os = "windows"))]
    app.restart();
    #[cfg(target_os = "windows")]
    Ok(())
}

/// 只在新版 UI 完成初始化后清理旧副本，Windows 的覆盖由 NSIS/MSI 自身完成。
#[tauri::command]
async fn cleanup_old_versions(app: AppHandle) -> Result<(), String> {
    #[cfg(all(target_os = "macos", not(debug_assertions)))]
    {
        let helper = app.path().resource_dir().map_err(|_| "无法定位安装助手。")?.join("NiumaInstaller");
        let bundle = macos_bundle_path()?;
        tauri::async_runtime::spawn_blocking(move || {
            let status = std::process::Command::new(helper).args(["cleanup", &bundle.to_string_lossy()]).status()
                .map_err(|_| "新版正常运行，但无法启动旧版本清理。".to_string())?;
            if status.success() { Ok(()) } else { Err("新版正常运行，但旧版本清理未完成，请退出旧版后重试。".to_string()) }
        }).await.map_err(|_| "旧版本清理未完成。".to_string())?
    }
    #[cfg(any(not(target_os = "macos"), debug_assertions))]
    { let _ = app; Ok(()) }
}

/// 从当前执行文件推导宿主包，拒绝前端或环境变量指定任意清理路径。
#[cfg(all(target_os = "macos", not(debug_assertions)))]
fn macos_bundle_path() -> Result<std::path::PathBuf, String> {
    let executable = std::env::current_exe().map_err(|_| "无法读取应用位置。")?;
    let bundle = executable.ancestors().nth(3).ok_or("应用包结构无效。")?;
    if bundle.extension().and_then(|value| value.to_str()) != Some("app") { return Err("应用包结构无效。".into()); }
    Ok(bundle.to_path_buf())
}

/// 手动打开下载的正式包时先归位，助手准备完成后退出当前进程并由它启动正式入口。
#[cfg(all(target_os = "macos", not(debug_assertions)))]
fn prepare_managed_installation() -> Result<bool, String> {
    use std::io::BufRead;
    let bundle = macos_bundle_path()?;
    let helper = bundle.join("Contents/Resources/NiumaInstaller");
    let plan = std::process::Command::new(&helper).args(["plan", &bundle.to_string_lossy()]).status()
        .map_err(|_| "无法启动应用安装助手。")?;
    if plan.code() != Some(10) { return if plan.success() { Ok(false) } else { Err("无法核对安装位置。".into()) }; }
    let mut child = std::process::Command::new(helper)
        .args(["install", &bundle.to_string_lossy(), &std::process::id().to_string()])
        .stdout(std::process::Stdio::piped()).spawn().map_err(|_| "无法准备安装应用。")?;
    let mut line = String::new();
    std::io::BufReader::new(child.stdout.take().ok_or("无法读取安装状态。")?).read_line(&mut line)
        .map_err(|_| "安装助手未完成准备。")?;
    if !line.starts_with("READY") && !line.starts_with("ERROR:") { return Err("安装助手未完成准备。".into()); }
    Ok(true)
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
