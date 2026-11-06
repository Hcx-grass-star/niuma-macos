import AppKit
import Darwin
import NiumaInstallation
import ServiceManagement
import NiumaCore

/// 管理唯一菜单栏入口、面板、配置和按需刷新的应用生命周期。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 同一环境跨更新保持身份稳定，不同环境隔离配置目录及单实例判断。
    static let identifier = AppBuildChannel.current.bundleIdentifier
    /// 实际配置存储，不包含收入历史或按秒日志。
    private let store: SettingsStore
    /// 复用有界排班计数，避免收入按秒刷新时重复遍历本年日期。
    private var incomeEngine = IncomeEngine()
    /// 只有成功保存的配置才能成为当前计算依据。
    private var settings: WorkSettings?
    /// 必须保留菜单栏项，否则系统会将其移除。
    private var statusItem: NSStatusItem?
    /// 首次查看收入时才创建窗口，纯菜单栏运行时不加载面板资源。
    private lazy var incomePanel: IncomePanel = {
        let panel = IncomePanel()
        panel.delegate = self
        return panel
    }()
    /// 仅在面板展开期间持有原生收入视图，收起后释放。
    private var income: IncomeViewController?
    /// 当前唯一设置窗口，避免重复入口消耗资源。
    private var settingsWindow: SettingsWindowController?
    /// 至多一个刷新任务，隐藏且仅图标时为空。
    private var refreshTimer: Timer?
    /// 读取配置失败时保留错误，不静默生成示例工资。
    private var configurationError: String?
    /// 独立于工资计算的公开版本检查和检查偏好。
    private let updates: UpdateController

    /// 默认按包环境选择配置；集成验证可注入独立存储与更新偏好，避免修改用户数据。
    init(store: SettingsStore = SettingsStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(identifier, isDirectory: true)), updates: UpdateController = UpdateController()) {
        self.store = store
        self.updates = updates
        super.init()
    }

    /// 加载本地配置并创建菜单栏，只有首次使用才打开设置。
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { settings = try store.load() }
        catch { configurationError = error.localizedDescription }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(handleStatusClick)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.setAccessibilityLabel(AppBuildChannel.current.displayName)
        item.button?.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: AppBuildChannel.current.displayName)
        item.button?.image?.isTemplate = true
        statusItem = item
        configureMainMenu()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged),
                                                         name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                                               name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                                               name: .NSSystemClockDidChange, object: nil)
        refresh()
        if settings == nil { showSettings() }
        updates.start()
        do { try ManagedInstallation.confirmStartup() }
        catch { showAlert(error.localizedDescription) }
        // 菜单栏已创建后才回收旧副本；开发包不进行自动清理。
        if Bundle.main.object(forInfoDictionaryKey: "NiumaInstallOnLaunch") as? Bool == true {
            Task { @MainActor in
                do { try await ManagedInstallation.cleanupCurrentBundle(Bundle.main.bundleURL) }
                catch { showAlert(error.localizedDescription) }
            }
        }
    }

    /// 退出时释放定时任务和观察者，不保留独立后台进程。
    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
        refreshTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// 切换到其他应用时收起收入窗口并释放视图。
    func applicationDidResignActive(_ notification: Notification) {
        if income != nil && incomePanel.isVisible { incomePanel.close() }
    }

    /// 重复打开现有应用时复用同一个菜单栏和设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settings == nil { showSettings() }
        else { toggleIncomePanel() }
        return false
    }

    /// 左键继续查看收入，右键直接选择菜单栏的展示指标。
    @objc private func handleStatusClick() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { toggleIncomePanel(); return }
        let menu = NSMenu()
        for (index, display) in MenuBarDisplay.allCases.enumerated() {
            let item = NSMenuItem(title: display.title, action: #selector(changeMenuBarDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = (settings?.menuBarDisplay ?? .icon) == display ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "退出牛马上班", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        if let button = statusItem?.button, let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: button)
        }
    }

    /// 明确选择后保存展示偏好，不改变金额隐藏状态或工资排班。
    @objc private func changeMenuBarDisplay(_ sender: NSMenuItem) {
        guard var next = settings else { showSettings(); return }
        next.menuBarDisplay = MenuBarDisplay.allCases[sender.tag]
        next.menuBarIncome = next.menuBarDisplay != .icon
        do { try save(next) }
        catch { showAlert(error.localizedDescription) }
    }

    /// 从菜单栏直接展开并取得面板焦点，不依赖异步应用激活；收起时按需停止刷新。
    @objc private func toggleIncomePanel() {
        if income != nil && incomePanel.isVisible { incomePanel.close() }
        else if let button = statusItem?.button {
            let controller = IncomeViewController()
            controller.onSettings = { [weak self] in self?.showSettings() }
            controller.onPrivacy = { [weak self] in self?.togglePrivacy() }
            income = controller
            incomePanel.contentViewController = controller
            refresh()
            incomePanel.show(below: button)
            refresh()
        }
    }

    /// 面板失去键盘焦点时收起，保持点击其他应用即关闭的交互。
    func windowDidResignKey(_ notification: Notification) {
        if income != nil && incomePanel.isVisible { incomePanel.close() }
    }

    /// 关闭后释放收入视图；下一轮事件再归还分配器中已空闲的页面。
    func windowWillClose(_ notification: Notification) {
        incomePanel.contentViewController = nil
        income = nil
        refresh()
        reclaimClosedViews()
    }

    /// 留出一次事件循环释放窗口临时对象，再归还空闲页；不增加常驻轮询。
    private func reclaimClosedViews() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// 更新收入及菜单栏，并仅为可见、会变化的金额安排刷新。
    @objc private func refresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        do {
            let snapshot = try incomeEngine.evaluate(settings, at: Date())
            income?.render(snapshot, settings: settings, error: configurationError)
            if let income, incomePanel.contentLayoutRect.size != income.preferredContentSize {
                incomePanel.setContentSize(income.preferredContentSize)
            }
            guard let button = statusItem?.button else { return }
            let menuAmount = settings?.menuBarAmount(in: snapshot)
            let title = menuAmount.map { " " + IncomeViewController.money($0) } ?? ""
            if button.title != title { button.title = title }
            let toolTip = AppBuildChannel.current.displayName + " · " + (menuAmount == nil ? "左键查看收入，右键选择显示内容" : (settings?.menuBarDisplay.title ?? ""))
            if button.toolTip != toolTip { button.toolTip = toolTip }
            let needsUpdates = (income != nil && incomePanel.isVisible) || (settings?.menuBarDisplay != .icon && settings?.hideAmounts == false)
            guard needsUpdates, configurationError == nil else { return }
            let delay: TimeInterval?
            if snapshot.phase == .working { delay = 1 }
            else { delay = snapshot.nextBoundary.map { max(0.1, $0.timeIntervalSinceNow) } }
            if let delay {
                let timer = Timer(timeInterval: delay, target: self, selector: #selector(refresh), userInfo: nil, repeats: false)
                timer.tolerance = min(1, delay * 0.1)
                RunLoop.main.add(timer, forMode: .common)
                refreshTimer = timer
            }
        } catch {
            let empty = try! IncomeEngine().evaluate(nil, at: Date())
            income?.render(empty, settings: settings, error: error.localizedDescription)
            statusItem?.button?.title = ""
        }
    }

    /// 唤醒、时区或系统时间变化时直接重新估算，不追赶计时器事件。
    @objc private func environmentChanged(_ notification: Notification) {
        incomeEngine = IncomeEngine()
        refresh()
        updates.check(manual: false)
    }

    /// 成功写入后才发布隐私偏好，失败时给出可见错误。
    private func togglePrivacy() {
        guard var next = settings else { showSettings(); return }
        next.hideAmounts.toggle()
        do { try save(next) }
        catch { showAlert(error.localizedDescription) }
    }

    /// 保存已验证配置后刷新同一班次，不保留旧收入累计值。
    private func save(_ next: WorkSettings) throws {
        _ = try IncomeEngine().evaluate(next, at: Date())
        try store.save(next)
        settings = next
        configurationError = nil
        refresh()
    }

    /// 先关闭真实登录启动，再删除专属配置，失败时保持可恢复状态。
    private func reset() throws {
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval { try service.unregister() }
        guard service.status != .enabled, service.status != .requiresApproval else {
            throw NSError(domain: Self.identifier, code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "登录启动尚未关闭，未清除工资设置。请检查系统设置后重试。"])
        }
        try store.clear()
        updates.reset()
        settings = nil
        configurationError = nil
        settingsWindow = nil
        refresh()
        DispatchQueue.main.async { [weak self] in self?.showSettings() }
    }

    /// 复用设置页及未保存草稿；用户打开时显式激活并前置窗口，避免被其他应用遮挡。
    private func showSettings() {
        if income != nil { incomePanel.close() }
        if settingsWindow?.window?.isVisible != true {
            settingsWindow = SettingsWindowController(settings: settings ?? WorkSettings(), dataPath: store.fileURL.path, updates: updates,
                                                       onSave: { [weak self] value in
                                                           try self?.save(value)
                                                           DispatchQueue.main.async { [weak self] in self?.toggleIncomePanel() }
                                                       },
                                                       onReset: { [weak self] in try self?.reset() })
            settingsWindow?.onClose = { [weak self] in
                self?.updates.onChange = nil
                self?.settingsWindow = nil
                self?.reclaimClosedViews()
            }
        }
        settingsWindow?.showWindow(nil)
        // 设置入口需要主动取得焦点；普通 activate() 的协作请求可能被当前前台应用拒绝。
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        settingsWindow?.window?.orderFrontRegardless()
        if let configurationError { showAlert(configurationError) }
    }

    /// 提供标准的设置、查看与退出快捷键，使原生操作可通过键盘完成。
    private func configureMainMenu() {
        let menu = NSMenu()
        let root = NSMenuItem(title: AppBuildChannel.current.displayName, action: nil, keyEquivalent: "")
        let commands = NSMenu(title: AppBuildChannel.current.displayName)
        let show = NSMenuItem(title: "查看当前收入", action: #selector(toggleIncomePanel), keyEquivalent: "i")
        show.target = self
        commands.addItem(show)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        commands.addItem(settings)
        let update = NSMenuItem(title: "检查更新…", action: #selector(checkUpdates), keyEquivalent: "")
        update.target = self
        commands.addItem(update)
        commands.addItem(.separator())
        commands.addItem(NSMenuItem(title: "退出牛马上班", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        root.submenu = commands
        menu.addItem(root)
        NSApp.mainMenu = menu
    }

    /// 将标准设置快捷键连接到现有窗口生命周期。
    @objc private func openSettingsFromMenu() { showSettings() }

    /// 菜单栏应用激活时允许通过标准菜单手动检查版本。
    @objc private func checkUpdates() { updates.check(manual: true) }

    /// 用原生提示明确说明配置错误，不把敏感配置写到日志。
    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "请检查设置"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
