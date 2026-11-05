import AppKit
import NiumaCore
import Sparkle

/// 管理版本检查偏好和异步状态，与工资配置及收入刷新任务独立。
@MainActor
final class UpdateController: NSObject {
    /// 应用包内的真实版本，未打包的开发程序没有版本时禁止伪造版本。
    let currentVersion: String
    /// 版本元数据请求服务。
    private let service: UpdateService
    /// 单独保存检查偏好与最近自动尝试时间，不改工资 JSON。
    private let defaults: UserDefaults
    /// 成熟安装器负责签名校验、覆盖、权限及重启；不另建自动检查计时器。
    private lazy var installer = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    /// 24 小时低频检查任务。
    private var timer: Timer?
    /// 设置页读取的当前检查结果。
    private(set) var status = "尚未检查更新。"
    /// 防止多次点击发出并行请求。
    private(set) var isChecking = false
    /// 检测到的可用新版，供设置页下载入口使用。
    private(set) var release: UpdateRelease?
    /// 设置页打开期间接收状态变化，关闭后可释放界面。
    var onChange: (() -> Void)?
    /// 默认开启；只有用户明确关闭时才停止自动请求。
    var automaticEnabled: Bool { defaults.object(forKey: "updates.enabled") as? Bool ?? true }

    /// 注入隔离偏好或本地服务供验证；正式应用从包内读取版本。
    init(defaults: UserDefaults = .standard, service: UpdateService = UpdateService(), currentVersion: String? = nil) {
        self.defaults = defaults
        self.service = service
        self.currentVersion = currentVersion ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        super.init()
    }

    /// 启动时检查，应用持续运行时每天检查一次，所有请求仍受持久化限频保护。
    func start() {
        check(manual: false)
        timer = Timer.scheduledTimer(timeInterval: 86400, target: self, selector: #selector(checkAutomatically), userInfo: nil, repeats: true)
        timer?.tolerance = 60
    }

    /// 退出时停止低频任务。
    func stop() { timer?.invalidate(); timer = nil }

    /// 偏好立即生效，取消修改工资不会撤销这个独立设置。
    func setAutomaticEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "updates.enabled")
        onChange?()
        if enabled { check(manual: false) }
    }

    /// 重置时清除本应用拥有的更新偏好和最近检查时间。
    func reset() {
        defaults.removeObject(forKey: "updates.enabled")
        defaults.removeObject(forKey: "updates.lastAutomaticAttempt")
        release = nil
        status = "尚未检查更新。"
        onChange?()
    }

    /// 自动失败只更新设置页状态；手动检查明确反馈，发现新版才主动提示。
    func check(manual: Bool) {
        guard !isChecking else { return }
        let now = Date()
        if !manual {
            let last = defaults.object(forKey: "updates.lastAutomaticAttempt") as? Date
            guard UpdatePolicy.shouldCheck(enabled: automaticEnabled, lastAttempt: last, now: now) else { return }
            defaults.set(now, forKey: "updates.lastAutomaticAttempt")
        }
        isChecking = true
        release = nil
        status = "正在检查更新…"
        onChange?()
        Task { [self] in
            do {
                let result = try await service.check(currentVersion: currentVersion)
                isChecking = false
                switch result {
                case .available(let value): release = value; status = "发现新版本 " + value.version
                case .upToDate: status = "已是最新版。"
                case .unpublished: status = "暂无可用正式版本，请稍后重试。"
                case .unavailable: status = "新版尚未提供 macOS 安装包。"
                }
                onChange?()
                if manual || (release != nil && automaticEnabled) { presentResult() }
            } catch {
                isChecking = false
                status = error.localizedDescription
                onChange?()
                if manual { presentResult() }
            }
        }
    }

    /// 明确点击更新后才下载安装，成功后原位替换并由 Sparkle 重启。
    func installUpdate() {
        guard release != nil else { return }
        installer.checkForUpdates(nil)
    }

    /// 打开已由核心校验的本项目正式发布页。
    func openRelease() {
        guard let release else { return }
        if !NSWorkspace.shared.open(release.pageURL) { status = "无法打开下载页面，请重试。"; onChange?() }
    }

    /// 定时器统一经过限频和开关检查。
    @objc private func checkAutomatically() { check(manual: false) }

    /// 展示纯文本说明，用户可安装并重启，或选择手动下载。
    private func presentResult() {
        let alert = NSAlert()
        alert.messageText = release.map { "发现新版本 " + $0.version } ?? status
        alert.informativeText = "当前版本：" + currentVersion
        if let release {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 150))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false
            text.isRichText = false
            text.string = release.notes
            text.font = .systemFont(ofSize: 12)
            scroll.documentView = text
            alert.accessoryView = scroll
            alert.addButton(withTitle: "安装更新")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "手动下载")
        } else { alert.addButton(withTitle: "好") }
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, release != nil { installUpdate() }
        if response == .alertThirdButtonReturn, release != nil { openRelease() }
    }
}
