import AppKit
import Darwin
import NiumaCore

/// 在隔离配置下验证真实应用菜单、窗口释放、金额格式与面板布局。
@main @MainActor
struct IncomePanelIntegrationTests {
    /// 测试拥有的临时配置根目录，退出时删除。
    static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-ui-" + UUID().uuidString)
    /// 独立更新偏好，不触发网络检查或改动正式偏好。
    static let defaultsName = "niuma-ui-" + UUID().uuidString
    /// 保留真实应用委托，覆盖正式的菜单和窗口生命周期。
    static var delegate: AppDelegate!
    /// 当前验证阶段，所有界面动作均运行在主线程。
    static var tick = 0
    /// 驱动阶段切换的唯一测试定时器。
    static var timer: Timer?
    /// 关闭前持有的弱引用，用于证明控制器实际释放。
    static weak var closedController: NSViewController?

    /// 检查设置控制器没有被窗口或回调继续持有。
    static weak var closedSettings: NSWindowController?
    /// 验证 AppKit 没有继续保留已关闭设置的窗口和后备缓冲区。
    static weak var closedSettingsWindow: NSWindow?

    /// 创建隔离工资配置并启动 AppKit，任一断言失败立即返回非零。
    static func main() throws {
        require(AppBuildChannel.current == .test, "UI 验证必须运行在显式测试包中")
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(false, forKey: "updates.enabled")
        var settings = WorkSettings()
        settings.salary = 21000
        settings.menuBarDisplay = .current
        settings.chinaHolidayEnabled = true
        let store = SettingsStore(directory: directory)
        try store.save(settings)
        print("PID: \(getpid())")
        fflush(nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--build-channel-only") {
            let controller = SettingsWindowController(settings: settings, dataPath: store.fileURL.path,
                updates: UpdateController(defaults: defaults, currentVersion: "0.3.1"),
                onSave: { _ in require(false, "环境验证不得保存工资") },
                onReset: { require(false, "环境验证不得重置配置") })
            verifyBuildChannel(in: controller.window!)
            print("PASS: 测试环境名称、自启动入口禁用及直接动作调用保护")
            finish(code: 0)
        }
        delegate = AppDelegate(store: store, updates: UpdateController(defaults: defaults, currentVersion: "0.3.1"))
        app.delegate = delegate
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { advance() }
        }
        app.run()
    }

    /// 检查阶段条件；失败时仍先清理本次创建的配置与偏好。
    static func require(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: " + message); finish(code: 1) }
    }

    /// 通过正式菜单触发窗口，验证关闭、再次打开和设置取消均可正常使用。
    static func advance() {
        tick += 1
        let commands = NSApp.mainMenu!.items[0].submenu!
        if tick == 3 { sample("idle"); commands.performActionForItem(at: 0) }
        if tick == 8 {
            let panel = NSApp.windows.compactMap { $0 as? IncomePanel }.first!
            require(panel.isVisible, "收入面板应展开")
            closedController = panel.contentViewController
            require(closedController != nil, "收入控制器应存在")
            require(IncomeViewController.money(Decimal(string: "1234.565")) == "¥1,234.57", "人民币格式及舍入")
            sample("panel")
            panel.cancelOperation(nil)
        }
        if tick == 10 {
            require(closedController == nil, "关闭后控制器应释放")
            sample("after-close")
            commands.performActionForItem(at: 0)
        }
        if tick == 12 {
            require(NSApp.windows.contains { $0 is IncomePanel && $0.isVisible }, "收入面板应能再次打开")
            delegate.applicationDidResignActive(Notification(name: NSApplication.didResignActiveNotification))
        }
        if tick == 14 {
            require(!NSApp.windows.contains { $0 is IncomePanel && $0.isVisible }, "离开应用应收起面板")
            print("设置菜单可用：\(commands.items[1].isEnabled)")
            commands.performActionForItem(at: 1)
        }
        if tick == 18 {
            let windows = NSApp.windows.filter { $0.isVisible && $0.windowController is SettingsWindowController }
            if windows.count != 1 {
                print("窗口诊断：" + NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) settings=\($0.windowController is SettingsWindowController)" }.joined(separator: "; "))
            }
            require(windows.count == 1, "设置窗口应唯一且可见")
            verifyBuildChannel(in: windows[0])
            sample("settings")
            closedSettings = windows[0].windowController
            closedSettingsWindow = windows[0]
            windows[0].close()
        }
        if tick == 90 { finish(code: 0) }
        if tick == 22 {
            require(closedSettings == nil, "设置控制器关闭后应释放")
            require(closedSettingsWindow == nil, "设置窗口关闭后应释放")
            sample("after-settings")
            print("PASS: 原生菜单、面板再次打开、Esc、失焦收起、控制器释放、设置取消及人民币格式")
            if ProcessInfo.processInfo.environment["NIUMA_MEMORY_INSPECT"] != "1" { finish(code: 0) }
        }
    }

    /// 验证真实设置页可辨别测试包，且直接调用动作也不能绕过环境限制。
    static func verifyBuildChannel(in window: NSWindow) {
        require(window.title.contains("测试版"), "测试包设置标题应标注环境")
        guard let login = descendants(of: window.contentView!).first(where: {
            $0.accessibilityIdentifier() == "loginAtStartup"
        }) as? NSButton else { require(false, "应存在登录启动入口"); return }
        require(!login.isEnabled && login.state == .off, "测试包必须禁用登录启动")
        require(NSApp.sendAction(login.action!, to: login.target, from: login), "验证自启动动作的环境保护")
        require(!login.isEnabled && login.state == .off, "直接调用也不能绕过环境保护")
    }

    /// 遍历真实设置视图，定位有稳定可访问标识的控件。
    static func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    /// 记录同一内核口径的短时实测，不把设置期超预算隐藏为验收通过。
    static func sample(_ stage: String) {
        var info = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &info) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        require(result == 0, "内核资源指标读取")
        print(String(format: "%@: %.2f MB; lifetime peak %.2f MB", stage,
                     Double(info.ri_phys_footprint) / 1_000_000, Double(info.ri_lifetime_max_phys_footprint) / 1_000_000))
        fflush(nil)
    }

    /// 删除测试自己的数据并退出，保留控制台结果供调用方归档。
    static func finish(code: Int32) -> Never {
        timer?.invalidate()
        delegate?.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        exit(code)
    }
}
