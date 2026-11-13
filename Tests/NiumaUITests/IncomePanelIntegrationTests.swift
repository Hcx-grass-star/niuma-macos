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
    /// 可选事件诊断观察者，记录焦点竞争而不改写应用事件处理。
    static var eventObservers: [NSObjectProtocol] = []
    /// 上一个资源点位的内核计数，用于计算两个点位之间的平均 CPU。
    static var previousUsage: rusage_info_v4?
    /// 上一个资源点位的单调时钟，避免系统时钟调整影响 CPU 比例。
    static var previousUptime: TimeInterval = 0
    /// 关闭前持有的弱引用，用于证明控制器实际释放。
    static weak var closedController: NSViewController?

    /// 检查设置控制器没有被窗口或回调继续持有。
    static weak var closedSettings: NSWindowController?
    /// 验证 AppKit 没有继续保留已关闭设置的窗口和后备缓冲区。
    static weak var closedSettingsWindow: NSWindow?
    /// 验证原生玻璃视图没有在面板关闭后被观察者或父视图保留。
    static weak var closedGlassView: NSView?
    /// 保存返回的两个窗口状态都必须实际验收，防止异步回调未执行却误判释放成功。
    static var appearanceChecks = 0

    /// 创建隔离工资配置并启动 AppKit，任一断言失败立即返回非零。
    static func main() throws {
        require(AppBuildChannel.current == .test, "UI 验证必须运行在显式测试包中")
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.set(false, forKey: "updates.enabled")
        var settings = WorkSettings()
        settings.salary = 21000
        settings.menuBarDisplay = .current
        settings.chinaHolidayEnabled = true
        settings.panelAppearance.glassEnabled = CommandLine.arguments.contains("--glass-enabled")
        let store = SettingsStore(directory: directory)
        try store.save(settings)
        print("PID: \(getpid())")
        print("测试配置：\(directory.path)；更新偏好：\(defaultsName)")
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
        if ProcessInfo.processInfo.environment["NIUMA_UI_TRACE"] == "1" {
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                eventObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    let eventName = note.name.rawValue
                    let objectType = note.object.map { String(describing: type(of: $0)) } ?? "nil"
                    MainActor.assumeIsolated {
                        let panel = NSApp.windows.compactMap { $0 as? IncomePanel }.first
                        let front = NSWorkspace.shared.frontmostApplication
                        let mouseAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
                        let keyAge = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
                        print("event tick=\(tick) \(eventName) object=\(objectType) active=\(NSApp.isActive) panelVisible=\(panel?.isVisible ?? false) panelKey=\(panel?.isKeyWindow ?? false) front=\(front?.bundleIdentifier ?? "unknown") frontPID=\(front?.processIdentifier ?? 0) mouseAge=\(mouseAge) keyAge=\(keyAge)")
                        fflush(nil)
                    }
                })
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { advance() }
        }
        app.run()
    }

    /// 检查阶段条件；失败时仍先清理本次创建的配置与偏好。
    static func require(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: " + message); finish(code: 1) }
    }

    /// 按阶段执行菜单生命周期检查，或执行后台菜单栏入口的回归检查。
    static func advance() {
        tick += 1
        if CommandLine.arguments.contains("--panel-resources") { advancePanelResources(); return }
        if CommandLine.arguments.contains("--appearance-config") { advanceAppearanceConfiguration(); return }
        if CommandLine.arguments.contains("--panel-regression") { advancePanelRegression(); return }
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

    /// 在不打开设置或生成位图的情况下，分别采样可见面板和收起后的稳定区间。
    static func advancePanelResources() {
        if tick == 1 { NSApp.activate(ignoringOtherApps: true) }
        if tick == 3 { sample("resource-idle"); NSApp.mainMenu!.items[0].submenu!.performActionForItem(at: 0) }
        if tick == 8 {
            require(NSApp.windows.contains { $0 is IncomePanel && $0.isVisible }, "资源采样期间面板应展开")
            sample("resource-panel-warm")
        }
        if tick == 18 {
            let panel = NSApp.windows.compactMap { $0 as? IncomePanel }.first!
            require(panel.isVisible, "可见面板采样不能包含被提前关闭的区间")
            sample("resource-panel-stable")
            panel.close()
        }
        if tick == 23 { sample("resource-closed-warm") }
        if tick == 33 {
            require(!NSApp.windows.contains { $0 is IncomePanel && $0.isVisible }, "后台采样时不得保留可见面板")
            sample("resource-closed-stable")
            finish(code: 0)
        }
    }

    /// 通过真实设置控件保存、取消和再次修改外观，检查材质与工资配置的一致性。
    static func advanceAppearanceConfiguration() {
        let commands = NSApp.mainMenu!.items[0].submenu!
        var expected = PanelAppearanceSettings()
        expected.glassEnabled = true
        expected.mode = .dark
        expected.tintHex = "3377BB"
        do {
            if tick == 3 { sample("appearance-idle"); commands.performActionForItem(at: 1) }
            if tick == 5 {
                let window = visibleSettingsWindow()
                let controls = appearanceControls(in: window)
                require(controls.mode.indexOfSelectedItem == 0 && controls.glass.state == .off && controls.tintEnabled.state == .off,
                        "初始外观应跟随系统、关闭玻璃与自定义染色")
                controls.glass.state = .on
                controls.mode.selectItem(at: 2)
                NSApp.sendAction(controls.mode.action!, to: controls.mode.target, from: controls.mode)
                require(window.appearance?.name == .darkAqua, "设置窗口应预览深色草稿")
                controls.tintEnabled.state = .on
                NSApp.sendAction(controls.tintEnabled.action!, to: controls.tintEnabled.target, from: controls.tintEnabled)
                require(controls.tint.isEnabled, "启用染色后应能选择颜色")
                controls.tint.color = expected.nativeTintColor!
                settingsButton("保存并返回", in: window).performClick(nil)
                let error = descendants(of: window.contentView!).compactMap { $0 as? NSTextField }
                    .first { $0.accessibilityIdentifier() == "settingsError" }
                print("保存动作后：visible=\(window.isVisible)，表单错误=\(error?.stringValue ?? "无")")
                // 保存动作先排入返回面板的任务，紧随其后检查；不假定其他应用两秒内不会取得焦点。
                DispatchQueue.main.async { [expected] in
                    do { try verifySavedAppearance(expected) }
                    catch { require(false, "保存后的外观检查失败：\(error)") }
                }
            }
            if tick == 9 {
                require(appearanceChecks == 1 && closedController == nil && closedGlassView == nil, "收起面板应释放已验收的内容与原生玻璃")
                sample("appearance-after-glass")
                commands.performActionForItem(at: 1)
            }
            if tick == 11 {
                let window = visibleSettingsWindow()
                let controls = appearanceControls(in: window)
                require(controls.mode.indexOfSelectedItem == 2 && controls.glass.state == .on
                    && controls.tint.color.panelTintHex == "3377BB", "再次打开设置应恢复已保存外观")
                controls.mode.selectItem(at: 1)
                controls.glass.state = .off
                controls.tintEnabled.state = .off
                settingsButton("取消修改", in: window).performClick(nil)
                require(try SettingsStore(directory: directory).load()!.panelAppearance == expected, "取消外观草稿不得写入配置")
                commands.performActionForItem(at: 1)
            }
            if tick == 13 {
                let window = visibleSettingsWindow()
                let controls = appearanceControls(in: window)
                require(controls.mode.indexOfSelectedItem == 2, "取消后再次打开应保留已保存主题")
                controls.glass.state = .off
                controls.mode.selectItem(at: 1)
                controls.tintEnabled.state = .off
                settingsButton("保存并返回", in: window).performClick(nil)
                var plain = PanelAppearanceSettings(); plain.mode = .light
                DispatchQueue.main.async { [plain] in
                    do { try verifySavedAppearance(plain) }
                    catch { require(false, "普通背景检查失败：\(error)") }
                }
            }
            if tick == 15 {
                require(appearanceChecks == 2 && closedController == nil, "两次保存返回与关闭释放都必须完成")
                print("PASS: 外观控件保存与取消、重载、原生玻璃嵌入与释放、主题、染色及普通圆角回退")
                finish(code: 0)
            }
        } catch { require(false, "外观集成检查失败：\(error)") }
    }

    /// 在真实保存返回任务之后检查焦点、文件、材质和尺寸，再关闭并由后续阶段验证释放。
    static func verifySavedAppearance(_ expected: PanelAppearanceSettings) throws {
        guard let panel = NSApp.windows.compactMap({ $0 as? IncomePanel }).first else {
            require(false, "保存外观后应创建收入面板"); return
        }
        require(panel.isVisible && panel.isKeyWindow, "保存外观后应返回收入面板并取得焦点")
        let background = panel.contentViewController!.view as! IncomePanelBackgroundView
        let saved = try SettingsStore(directory: directory).load()!
        require(saved.panelAppearance == expected && saved.salary == 21000, "保存重载应保留外观且不改变工资")
        require(background.appearance?.name == expected.mode.nativeAppearance?.name, "收入面板应使用已保存主题")
        if #available(macOS 26.0, *) {
            let glasses = descendants(of: background).compactMap { $0 as? NSGlassEffectView }
            let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            require(glasses.count == (expected.glassEnabled && !reduced ? 1 : 0), "应按设置和系统可读性使用唯一玻璃或普通背景")
            if let glass = glasses.first {
                require(glass.contentView === background.contentView, "业务控件必须嵌入原生玻璃的contentView")
                require(glass.cornerRadius == 12 && glass.tintColor?.panelTintHex == expected.tintHex, "玻璃应保留圆角与染色")
                closedGlassView = glass
            }
        }
        require(background.contentView.bounds.size == background.bounds.size, "原生材质不应挤压业务布局")
        if !expected.glassEnabled { verifyPanelAppearance(panel) }
        sample(expected.glassEnabled ? "appearance-glass-panel" : "appearance-normal-panel")
        appearanceChecks += 1
        closedController = panel.contentViewController
        panel.close()
    }

    /// 在异步窗口切换完成后检查设置页，失败时保留窗口诊断并正常清理测试数据。
    static func visibleSettingsWindow() -> NSWindow {
        let window = NSApp.windows.first { $0.isVisible && $0.windowController is SettingsWindowController }
        if window == nil {
            print("tick=\(tick) 窗口：" + NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) settings=\($0.windowController is SettingsWindowController)" }.joined(separator: "; "))
        }
        require(window != nil, "设置窗口应展开")
        return window!
    }

    /// 从真实设置表单定位外观控件，不绕过保存路径修改应用配置。
    static func appearanceControls(in window: NSWindow) -> (glass: NSButton, mode: NSPopUpButton, tintEnabled: NSButton, tint: NSColorWell) {
        let views = descendants(of: window.contentView!)
        return (views.first { $0.accessibilityIdentifier() == "panelGlassEnabled" } as! NSButton,
                views.first { $0.accessibilityIdentifier() == "appearanceMode" } as! NSPopUpButton,
                views.first { $0.accessibilityIdentifier() == "panelTintEnabled" } as! NSButton,
                views.first { $0.accessibilityIdentifier() == "panelTintColor" } as! NSColorWell)
    }

    /// 通过表单按钮触发正式保存或取消动作，包含校验、持久化和窗口切换。
    static func settingsButton(_ title: String, in window: NSWindow) -> NSButton {
        let button = descendants(of: window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }
        require(button != nil, "设置表单中缺少按钮：\(title)")
        print("表单动作：\(title)，enabled=\(button!.isEnabled)，key=\(window.isKeyWindow)")
        return button!
    }

    /// 派发状态栏和控件动作，检查焦点、圆角与关闭路径；不模拟系统鼠标。
    static func advancePanelRegression() {
        if tick == 1 { NSApp.deactivate() }
        if tick == 3 {
            require(!NSApp.isActive, "回归检查必须从应用未激活的状态开始")
            print("before status action: active=\(NSApp.isActive)")
            sample("regression-idle")
            statusButton().performClick(nil)
        }
        if tick == 5 {
            guard let panel = NSApp.windows.compactMap({ $0 as? IncomePanel }).first else {
                require(false, "状态栏动作应创建面板"); return
            }
            print("after status action: active=\(NSApp.isActive) visible=\(panel.isVisible) key=\(panel.isKeyWindow) hides=\(panel.hidesOnDeactivate)")
            require(panel.isVisible && panel.isKeyWindow, "后台状态栏动作应展开面板并取得键盘焦点")
            sample("regression-panel")
            verifyPanelAppearance(panel)
            closedController = panel.contentViewController
            statusButton().performClick(nil)
        }
        if tick == 7 {
            require(closedController == nil, "再次点击菜单栏应收起并释放收入控制器")
            statusButton().performClick(nil)
        }
        if tick == 9 {
            let panel = NSApp.windows.compactMap { $0 as? IncomePanel }.first!
            require(panel.isVisible && panel.isKeyWindow, "收起后应能再次通过状态栏展开")
            let privacy = descendants(of: panel.contentView!).compactMap { $0 as? NSButton }
                .first { $0.toolTip == "隐藏金额" }
            require(privacy != nil, "收入面板应包含隐私入口")
            privacy?.performClick(nil)
            let amounts = descendants(of: panel.contentView!).compactMap { $0 as? NSTextField }
                .filter { ["currentIncome", "monthToDateIncome", "yearToDateIncome"].contains($0.accessibilityIdentifier()) }
            require(amounts.count == 3 && amounts.allSatisfy { $0.stringValue == "••••" }, "隐私按钮应隐藏所有金额")
            privacy?.performClick(nil)
            require(amounts.allSatisfy { $0.stringValue.hasPrefix("¥") }, "隐私按钮应能恢复所有金额")
            // 在同一进程创建另一窗口触发真实 AppKit 失焦通知，不直接调用委托回调。
            let other = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.makeKeyAndOrderFront(nil)
            require(!panel.isVisible && panel.contentViewController == nil, "其他窗口取得焦点应收起并释放面板")
            other.close()
            statusButton().performClick(nil)
            require(panel.isVisible && panel.isKeyWindow, "失焦关闭后状态栏仍应能展开")
            panel.cancelOperation(nil)
            require(!panel.isVisible, "Esc 处理应收起面板")
            statusButton().performClick(nil)
            let settings = descendants(of: panel.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "设置" }
            require(settings != nil, "面板应包含设置入口")
            settings?.performClick(nil)
        }
        if tick == 12 {
            let windows = NSApp.windows.filter { $0.isVisible && $0.windowController is SettingsWindowController }
            require(windows.count == 1, "面板设置入口应打开唯一设置窗口")
            sample("regression-settings")
            closedSettings = windows[0].windowController
            closedSettingsWindow = windows[0]
            windows[0].close()
        }
        if tick == 15 {
            require(closedSettings == nil && closedSettingsWindow == nil, "设置关闭后应释放窗口与控制器")
            sample("regression-after-close")
            print("PASS: 后台状态栏动作、重复切换、深浅色圆角像素、隐私切换、AppKit失焦通知、Esc处理及面板设置入口")
            finish(code: 0)
        }
    }

    /// 从应用自己的状态栏窗口查找按钮，沿正式 target/action 链触发展开或收起。
    static func statusButton() -> NSStatusBarButton {
        let button = NSApp.windows.compactMap { $0.contentView }
            .flatMap { descendants(of: $0) }.compactMap { $0 as? NSStatusBarButton }.first
        require(button != nil, "应找到正式状态栏按钮")
        return button!
    }

    /// 对实际收入视图离屏渲染，检查深浅外观的透明四角及不透明内部，并可保存证据。
    static func verifyPanelAppearance(_ panel: IncomePanel) {
        require(!panel.isOpaque && panel.backgroundColor == .clear && panel.hasShadow, "圆角窗口应透明且保留阴影")
        let view = panel.contentViewController!.view
        let originalAppearance = view.appearance
        defer { view.appearance = originalAppearance }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: name)
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            for (x, y) in [(0, 0), (bitmap.pixelsWide - 1, 0), (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)] {
                require(bitmap.colorAt(x: x, y: y)!.alphaComponent < 0.01, "\(name.rawValue)四角应为透明像素")
            }
            require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)!.alphaComponent > 0.99, "圆角内部应有完整背景")
            if let output = ProcessInfo.processInfo.environment["NIUMA_UI_ARTIFACTS"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("income-panel-\(name.rawValue).png"))
                } catch { require(false, "无法写入面板渲染证据：\(error)") }
            }
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

    /// 记录 physical footprint 和上一个点位以来的平均 CPU，不将点位当作持续上限。
    static func sample(_ stage: String) {
        var info = rusage_info_v4()
        let result = withUnsafeMutableBytes(of: &info) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self))
        }
        require(result == 0, "内核资源指标读取")
        print(String(format: "%@: %.2f MB; lifetime peak %.2f MB", stage,
                     Double(info.ri_phys_footprint) / 1_000_000, Double(info.ri_lifetime_max_phys_footprint) / 1_000_000))
        let uptime = ProcessInfo.processInfo.systemUptime
        if let previousUsage {
            let cpu = Double(info.ri_user_time - previousUsage.ri_user_time + info.ri_system_time - previousUsage.ri_system_time)
                / 1_000_000_000 / (uptime - previousUptime) * 100
            print(String(format: "%@: interval %.2f s; CPU %.4f%%", stage, uptime - previousUptime, cpu))
        }
        previousUsage = info
        previousUptime = uptime
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
