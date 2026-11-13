use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{Cursor, Read},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::{
    menu::{CheckMenuItem, MenuBuilder, MenuItem},
    tray::{MouseButton, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager, State, WindowEvent,
};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_updater::UpdaterExt;

/// 保存可动态更新的托盘收入菜单项，避免每秒重建整份原生菜单。
struct TrayIncomeState {
    /// 托盘菜单首项，仅展示当前收入，不响应点击。
    item: MenuItem<tauri::Wry>,
    /// 三个互斥的展示选项，由同一配置同步选中状态。
    display_items: Vec<CheckMenuItem<tauri::Wry>>,
}

/// 初始化跨平台窗口、系统托盘和自动启动能力。
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .invoke_handler(tauri::generate_handler![
            set_autostart,
            autostart_enabled,
            update_tray_income,
            update_tray_display,
            main_window_visible,
            update_environment,
            open_release_page,
            install_update,
            cleanup_old_versions,
            show_desktop_pet,
            show_income_window,
            import_codex_pet,
            load_codex_pet
        ])
        .setup(|app| {
            // AppKit 初始化后，助手才可验证宿主进程的应用包身份。
            #[cfg(all(target_os = "macos", not(debug_assertions)))]
            if prepare_managed_installation()? {
                app.handle().exit(0);
                return Ok(());
            }
            let income = MenuItem::with_id(app, "income", "当前收入：未显示", false, None::<&str>)?;
            let icon_content = CheckMenuItem::with_id(app, "content-icon", "仅图标", true, true, None::<&str>)?;
            let current_content = CheckMenuItem::with_id(app, "content-current", "当前班次已赚", true, false, None::<&str>)?;
            let month_content = CheckMenuItem::with_id(app, "content-month", "本月预估已赚", true, false, None::<&str>)?;
            let show = MenuItem::with_id(app, "show", "查看当前收入", true, None::<&str>)?;
            #[cfg(target_os = "windows")]
            let pet = MenuItem::with_id(app, "pet", "显示桌面宠物", true, None::<&str>)?;
            let settings = MenuItem::with_id(app, "settings", "打开设置", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出牛马上班", true, None::<&str>)?;
            let menu = MenuBuilder::new(app)
                .item(&income)
                .item(&icon_content)
                .item(&current_content)
                .item(&month_content)
                .separator()
                .item(&show);
            #[cfg(target_os = "windows")]
            let menu = menu.item(&pet);
            let menu = menu
                .item(&settings)
                .separator()
                .item(&quit)
                .build()?;
            let tray = TrayIconBuilder::with_id("main")
                .icon(app.default_window_icon().expect("应用图标缺失").clone())
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| handle_menu_event(app, event.id.as_ref()))
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button: MouseButton::Left, .. } = event {
                        show_main_window(tray.app_handle());
                    }
                })
                .build(app)?;
            tray.set_tooltip(Some("牛马上班 · 点击查看当前收入"))?;
            app.manage(TrayIncomeState { item: income, display_items: vec![icon_content, current_content, month_content] });
            #[cfg(target_os = "windows")]
            create_desktop_pet(app.handle())?;
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_title("牛马上班");
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
                if window.label() == "main" { let _ = window.emit("window-state-changed", ()); }
            }
            if window.label() == "main" && matches!(event, WindowEvent::Focused(_) | WindowEvent::Resized(_)) {
                let _ = window.emit("window-state-changed", ());
            }
        })
        .run(tauri::generate_context!())
        .expect("运行牛马上班失败");
}

/// Windows 专用透明置顶窗口；独立于收入主窗口，关闭时仍沿用隐藏到托盘行为。
#[cfg(target_os = "windows")]
fn create_desktop_pet(app: &AppHandle) -> tauri::Result<()> {
    let window = tauri::WebviewWindowBuilder::new(app, "pet", tauri::WebviewUrl::App("pet.html".into()))
        .title("牛马上班 · 桌面宠物")
        .inner_size(264.0, 284.0)
        .resizable(false)
        .maximizable(false)
        .decorations(false)
        .transparent(true)
        // 原生窗口和 WebView 均以透明色清屏，避免空白区域出现实色底。
        .background_color(tauri::window::Color(0, 0, 0, 0))
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()?;
    // 使用工作区和逻辑像素定位，避免高 DPI 和任务栏导致窗口出屏。
    if let Some(monitor) = window.primary_monitor()? {
        let scale = monitor.scale_factor();
        let area = monitor.work_area();
        let x = (area.position.x as f64 + area.size.width as f64) / scale - 288.0;
        let y = (area.position.y as f64 + area.size.height as f64) / scale - 308.0;
        window.set_position(tauri::LogicalPosition::new(x.max(area.position.x as f64 / scale), y.max(area.position.y as f64 / scale)))?;
    }
    window.show()
}

/// 恢复已隐藏的桌面宠物；仅 Windows 创建该窗口，不改变其他平台入口。
#[tauri::command]
fn show_desktop_pet(app: AppHandle) -> Result<(), String> {
    app.get_webview_window("pet").ok_or("桌面宠物仅在 Windows 版提供。")?
        .show().map_err(|error| error.to_string())
}

/// 由宠物打开完整收入面板，工资与作息仍在原有主窗口配置。
#[tauri::command]
fn show_income_window(app: AppHandle) {
    show_main_window(&app);
}

/// Codex v2 宠物的最小元数据；额外字段会被忽略，以兼容未来资源包扩展。
#[derive(Debug, Deserialize, Serialize)]
struct CodexPetManifest {
    /// 宠物稳定标识，用于应用数据目录名。
    id: String,
    /// 宠物在设置页和运行时展示的名称。
    #[serde(rename = "displayName")]
    display_name: String,
    /// 宠物简介，当前用于导入成功提示。
    #[serde(default)]
    description: String,
    /// Codex v2 图集版本号。
    #[serde(rename = "spriteVersionNumber")]
    sprite_version_number: u8,
}

/// 前端展示所需的已保存宠物资源；图集字节只通过 IPC 返回，不暴露文件路径。
#[derive(Debug, Serialize)]
struct CodexPetResource {
    /// 宠物显示名称。
    #[serde(rename = "displayName")]
    display_name: String,
    /// 宠物简介。
    description: String,
    /// WebP 图集字节，由前端创建短生命周期的 Blob URL。
    #[serde(rename = "spriteBytes")]
    sprite_bytes: Vec<u8>,
}

/// 导入 Codex v2 资源包并激活它；失败时不改变当前已激活资源。
#[tauri::command]
fn import_codex_pet(app: AppHandle, archive: Vec<u8>) -> Result<CodexPetResource, String> {
    if archive.len() > 50 * 1024 * 1024 {
        return Err("资源包超过 50 MB，无法导入。".into());
    }
    let (manifest, sprite_bytes) = read_codex_pet_archive(&archive)?;
    let root = pet_storage_root(&app)?;
    fs::create_dir_all(&root).map_err(|_| "无法创建宠物资源目录。".to_string())?;
    let package_dir = unique_pet_package_dir(&root, &manifest.id);
    fs::create_dir_all(&package_dir).map_err(|_| "无法保存宠物资源。".to_string())?;
    fs::write(package_dir.join("pet.json"), serde_json::to_vec_pretty(&manifest).map_err(|_| "资源元数据无法保存。".to_string())?)
        .map_err(|_| "资源元数据无法保存。".to_string())?;
    fs::write(package_dir.join("spritesheet.webp"), &sprite_bytes)
        .map_err(|_| "宠物图集无法保存。".to_string())?;
    fs::write(root.join("active.json"), serde_json::json!({"package": package_dir.file_name().and_then(|name| name.to_str()).unwrap_or_default()} ).to_string())
        .map_err(|_| "无法记录当前宠物。".to_string())?;
    Ok(CodexPetResource { display_name: manifest.display_name, description: manifest.description, sprite_bytes })
}

/// 读取上次激活的资源；首次启动或资源损坏时返回内置 SVG 回退。
#[tauri::command]
fn load_codex_pet(app: AppHandle) -> Result<Option<CodexPetResource>, String> {
    let root = pet_storage_root(&app)?;
    let active_path = root.join("active.json");
    if !active_path.exists() { return Ok(None); }
    let active: serde_json::Value = serde_json::from_slice(&fs::read(&active_path).map_err(|_| "当前宠物记录无法读取。".to_string())?)
        .map_err(|_| "当前宠物记录已损坏。".to_string())?;
    let package = active.get("package").and_then(serde_json::Value::as_str).ok_or("当前宠物记录无效。")?;
    if package.contains('/') || package.contains('\\') || package == ".." || package.is_empty() {
        return Err("当前宠物记录路径无效。".into());
    }
    let package_dir = root.join(package);
    let manifest = read_manifest(&package_dir.join("pet.json"))?;
    let sprite_bytes = fs::read(package_dir.join("spritesheet.webp")).map_err(|_| "当前宠物图集无法读取。".to_string())?;
    validate_sprite(&sprite_bytes)?;
    Ok(Some(CodexPetResource { display_name: manifest.display_name, description: manifest.description, sprite_bytes }))
}

/// 返回应用专属的持久化宠物目录，不依赖前端传入路径。
fn pet_storage_root(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app.path().app_data_dir().map_err(|_| "无法定位应用数据目录。".to_string())?.join("pets"))
}

/// 从 ZIP 中读取标准文件名，拒绝路径穿越、重复文件和超大条目。
fn read_codex_pet_archive(archive: &[u8]) -> Result<(CodexPetManifest, Vec<u8>), String> {
    let mut zip = zip::ZipArchive::new(Cursor::new(archive)).map_err(|_| "资源包不是有效的 ZIP 文件。".to_string())?;
    let mut manifest_bytes = None;
    let mut sprite_bytes = None;
    for index in 0..zip.len() {
        let mut entry = zip.by_index(index).map_err(|_| "资源包目录无法读取。".to_string())?;
        if entry.is_dir() { continue; }
        let name = entry.enclosed_name().ok_or("资源包包含无效路径。")?;
        let basename = name.file_name().and_then(|value| value.to_str()).unwrap_or_default();
        match basename {
            "pet.json" => {
                if manifest_bytes.is_some() { return Err("资源包包含多个 pet.json。".into()); }
                if entry.size() > 1024 * 1024 { return Err("pet.json 超过 1 MB。".into()); }
                let mut bytes = Vec::with_capacity(entry.size() as usize);
                entry.read_to_end(&mut bytes).map_err(|_| "pet.json 无法读取。".to_string())?;
                manifest_bytes = Some(bytes);
            }
            "spritesheet.webp" => {
                if sprite_bytes.is_some() { return Err("资源包包含多个 spritesheet.webp。".into()); }
                if entry.size() > 20 * 1024 * 1024 { return Err("宠物图集超过 20 MB。".into()); }
                let mut bytes = Vec::with_capacity(entry.size() as usize);
                entry.read_to_end(&mut bytes).map_err(|_| "宠物图集无法读取。".to_string())?;
                sprite_bytes = Some(bytes);
            }
            _ => {}
        }
    }
    let manifest_bytes = manifest_bytes.ok_or("资源包缺少 pet.json。")?;
    let sprite_bytes = sprite_bytes.ok_or("资源包缺少 spritesheet.webp。")?;
    let manifest: CodexPetManifest = serde_json::from_slice(&manifest_bytes).map_err(|_| "pet.json 不是有效的 JSON。".to_string())?;
    validate_manifest(&manifest)?;
    validate_sprite(&sprite_bytes)?;
    Ok((manifest, sprite_bytes))
}

/// 读取并校验已保存的宠物元数据。
fn read_manifest(path: &Path) -> Result<CodexPetManifest, String> {
    let manifest: CodexPetManifest = serde_json::from_slice(&fs::read(path).map_err(|_| "pet.json 无法读取。".to_string())?)
        .map_err(|_| "pet.json 不是有效的 JSON。".to_string())?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

/// 校验 Codex v2 的最低兼容契约。
fn validate_manifest(manifest: &CodexPetManifest) -> Result<(), String> {
    if manifest.id.trim().is_empty() || manifest.display_name.trim().is_empty() { return Err("pet.json 缺少宠物 id 或 displayName。".into()); }
    if manifest.sprite_version_number != 2 { return Err("只支持 Codex v2 宠物资源包。".into()); }
    Ok(())
}

/// 只接受 1536×2288 的 WebP 图集，避免安装错误格式导致运行时空白。
fn validate_sprite(bytes: &[u8]) -> Result<(), String> {
    let (width, height) = webp_dimensions(bytes).ok_or("spritesheet.webp 不是可识别的 WebP 图像。")?;
    if (width, height) != (1536, 2288) { return Err(format!("宠物图集尺寸必须为 1536×2288，当前为 {width}×{height}。")); }
    Ok(())
}

/// 解析 VP8、VP8L 和 VP8X WebP 头部尺寸，不引入完整图像解码依赖。
fn webp_dimensions(bytes: &[u8]) -> Option<(u32, u32)> {
    if bytes.len() < 20 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WEBP" { return None; }
    let chunk = &bytes[12..16];
    let size = u32::from_le_bytes(bytes[16..20].try_into().ok()?) as usize;
    let end = 20usize.checked_add(size)?.min(bytes.len());
    let data = &bytes[20..end];
    match chunk {
        b"VP8X" if data.len() >= 10 => Some((1 + (u32::from(data[4]) | (u32::from(data[5]) << 8) | (u32::from(data[6]) << 16)), 1 + (u32::from(data[7]) | (u32::from(data[8]) << 8) | (u32::from(data[9]) << 16)))),
        b"VP8L" if data.len() >= 6 && data[0] == 0x2f => Some((1 + (u32::from(data[1]) | (u32::from(data[2]) << 8) | ((u32::from(data[3]) & 0x3f) << 16)), 1 + ((u32::from(data[3]) >> 6) | (u32::from(data[4]) << 2) | ((u32::from(data[5]) & 0xf) << 10)))),
        b"VP8 " => {
            let marker = data.windows(3).position(|window| window == &[0x9d, 0x01, 0x2a])?;
            if data.len() < marker + 10 { return None; }
            let width = u16::from_le_bytes(data[marker + 3..marker + 5].try_into().ok()?) & 0x3fff;
            let height = u16::from_le_bytes(data[marker + 5..marker + 7].try_into().ok()?) & 0x3fff;
            Some((u32::from(width), u32::from(height)))
        }
        _ => None,
    }
}

/// 生成不含路径分隔符的目录名，并在同名导入时追加时间戳。
fn unique_pet_package_dir(root: &Path, id: &str) -> PathBuf {
    let safe_id: String = id.chars().filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-' || *ch == '_').take(64).collect();
    let safe_id = if safe_id.is_empty() { "imported-pet" } else { &safe_id };
    let base = root.join(safe_id);
    if !base.exists() { return base; }
    let timestamp = SystemTime::now().duration_since(UNIX_EPOCH).map(|value| value.as_nanos()).unwrap_or_default();
    root.join(format!("{safe_id}-{timestamp}"))
}

#[cfg(test)]
mod tests {
    use super::{validate_manifest, webp_dimensions, CodexPetManifest};

    /// VP8X 头部应能解析出 Codex v2 要求的图集尺寸。
    #[test]
    fn parses_vp8x_dimensions() {
        let width_minus_one = 1535u32.to_le_bytes();
        let height_minus_one = 2287u32.to_le_bytes();
        let mut bytes = b"RIFF\0\0\0\0WEBPVP8X\x0A\0\0\0".to_vec();
        bytes.extend([0, 0, 0, 0]);
        bytes.extend([width_minus_one[0], width_minus_one[1], width_minus_one[2]]);
        bytes.extend([height_minus_one[0], height_minus_one[1], height_minus_one[2]]);
        assert_eq!(webp_dimensions(&bytes), Some((1536, 2288)));
    }

    /// 非 v2 资源不能通过导入契约。
    #[test]
    fn rejects_non_v2_manifest() {
        let manifest = CodexPetManifest {
            id: "demo".into(),
            display_name: "Demo".into(),
            description: String::new(),
            sprite_version_number: 1,
        };
        assert!(validate_manifest(&manifest).is_err());
    }
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

/// 同步托盘悬停提示和只读菜单项；金额文本由前端同一收入快照格式化。
#[tauri::command]
fn update_tray_income(
    app: AppHandle,
    state: State<'_, TrayIncomeState>,
    enabled: bool,
    text: String,
    content: Option<String>,
) -> Result<(), String> {
    let content = content.as_deref().unwrap_or(if enabled { "current" } else { "icon" });
    let label = if content == "month" { "本月预估已赚" } else { "当前班次已赚" };
    for (index, option) in ["icon", "current", "month"].iter().enumerate() {
        state.display_items[index].set_checked(content == *option).map_err(|error| error.to_string())?;
    }
    let (menu_text, tooltip) = if enabled {
        (format!("{label}：{text}"), format!("牛马上班 · {label} {text}"))
    } else {
        ("当前收入：未显示".into(), "牛马上班 · 点击查看当前收入".into())
    };
    state.item.set_text(menu_text).map_err(|error| error.to_string())?;
    let tray = app.tray_by_id("main").ok_or("托盘图标尚未就绪")?;
    // Windows 托盘不支持标题，继续使用悬停提示与菜单；macOS 菜单栏直接展示金额。
    #[cfg(target_os = "macos")]
    tray.set_title(if enabled { Some(text.as_str()) } else { None }).map_err(|error| error.to_string())?;
    tray.set_tooltip(Some(tooltip)).map_err(|error| error.to_string())
}

/// macOS 菜单栏显示压缩文本，Windows 通过完整提示与托盘菜单展示。
#[tauri::command]
fn update_tray_display(
    app: AppHandle,
    state: State<'_, TrayIncomeState>,
    text: String,
    full_text: String,
    content: String,
) -> Result<(), String> {
    for (index, option) in ["icon", "current", "month"].iter().enumerate() {
        state.display_items[index].set_checked(content == *option).map_err(|error| error.to_string())?;
    }
    let tooltip = if full_text.is_empty() { "牛马上班 · 点击查看".to_string() } else { full_text };
    state.item.set_text(&tooltip).map_err(|error| error.to_string())?;
    let tray = app.tray_by_id("main").ok_or("托盘图标尚未就绪")?;
    #[cfg(target_os = "macos")]
    tray.set_title(if text.is_empty() { None } else { Some(text.as_str()) }).map_err(|error| error.to_string())?;
    #[cfg(not(target_os = "macos"))]
    let _ = text;
    tray.set_tooltip(Some(tooltip)).map_err(|error| error.to_string())
}

/// 返回真实显示与最小化状态，供前端暂停隐藏页面的刷新任务。
#[tauri::command]
fn main_window_visible(app: AppHandle) -> Result<bool, String> {
    let window = app.get_webview_window("main").ok_or("窗口尚未就绪")?;
    Ok(window.is_visible().map_err(|error| error.to_string())?
        && !window.is_minimized().map_err(|error| error.to_string())?)
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
            let status = std::process::Command::new(helper).args(["ready", &bundle.to_string_lossy(), &std::process::id().to_string()]).status()
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
        "content-icon" | "content-current" | "content-month" => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.emit("set-tray-content", id.strip_prefix("content-").unwrap_or("icon"));
            }
        }
        "show" => show_main_window(app),
        "pet" => { let _ = show_desktop_pet(app.clone()); }
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
        let _ = window.emit("window-state-changed", ());
    }
}
