import AppKit
import NiumaInstallation
import ServiceManagement
import NiumaCore

/// 管理唯一菜单栏入口、面板、配置和按需刷新的应用生命周期。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    /// 跨更新保持稳定的应用身份，也用于配置目录和单实例判断。
    static let identifier = "com.hcxgrassstar.niuma"
    /// 实际配置存储，不包含收入历史或按秒日志。
    private let store = SettingsStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(identifier, isDirectory: true))
    /// 只有成功保存的配置才能成为当前计算依据。
    private var settings: WorkSettings?
    /// 必须保留菜单栏项，否则系统会将其移除。
    private var statusItem: NSStatusItem?
    /// 可收起的收入面板。
    private let popover = NSPopover()
    /// 仅在面板展开期间持有原生收入视图，收起后释放。
    private var income: IncomeViewController?
    /// 当前唯一设置窗口，避免重复入口消耗资源。
    private var settingsWindow: SettingsWindowController?
    /// 至多一个刷新任务，隐藏且仅图标时为空。
    private var refreshTimer: Timer?
    /// 读取配置失败时保留错误，不静默生成示例工资。
    private var configurationError: String?
    /// 独立于工资计算的公开版本检查和检查偏好。
    private let updates = UpdateController()

    /// 加载本地配置并创建菜单栏，只有首次使用才打开设置。
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { settings = try store.load() }
        catch { configurationError = error.localizedDescription }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.setAccessibilityLabel("牛马上班")
        item.button?.image = NSImage(systemSymbolName: "leaf", accessibilityDescription: "牛马上班")
        item.button?.image?.isTemplate = true
        statusItem = item
        configureMainMenu()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 360, height: 420)
        popover.delegate = self
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(environmentChanged),
                                                         name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                                               name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentChanged),
                                               name: .NSSystemClockDidChange, object: nil)
        refresh()
        if settings == nil { showSettings() }
        updates.start()
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

    /// 重复打开现有应用时复用同一个菜单栏和设置窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settings == nil { showSettings() }
        else { togglePopover() }
        return false
    }

    /// 展开时按实际时间重算，收起时按需停止秒级刷新。
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem?.button {
            let controller = IncomeViewController()
            controller.onSettings = { [weak self] in self?.showSettings() }
            controller.onPrivacy = { [weak self] in self?.togglePrivacy() }
            income = controller
            popover.contentViewController = controller
            refresh()
            activateApplication()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            controller.view.window?.title = "牛马上班 · 当前收入"
            controller.view.window?.makeKey()
            refresh()
        }
    }

    /// 系统关闭弹出面板后重新判断是否仍需刷新菜单栏金额。
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        income = nil
        refresh()
    }

    /// 把应用带到前台；无参 activate() 自 macOS 14 起提供，旧系统走等价选项。
    private func activateApplication() {
        if #available(macOS 14.0, *) { NSApp.activate() }
        else { NSApp.activate(ignoringOtherApps: true) }
    }

    /// 更新收入及菜单栏，并仅为可见、会变化的金额安排刷新。
    @objc private func refresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        do {
            let snapshot = try IncomeEngine().evaluate(settings, at: Date())
            income?.render(snapshot, settings: settings, error: configurationError)
            guard let button = statusItem?.button else { return }
            let showMoney = settings?.menuBarIncome == true && settings?.hideAmounts == false && snapshot.amount != nil
            button.title = showMoney ? " " + IncomeViewController.money(snapshot.amount) : ""
            button.toolTip = "牛马上班 · 点击查看当前收入"
            let needsUpdates = popover.isShown || (settings?.menuBarIncome == true && settings?.hideAmounts == false)
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
    @objc private func environmentChanged(_ notification: Notification) { refresh(); updates.check(manual: false) }

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
        popover.performClose(nil)
        if settingsWindow?.window?.isVisible != true {
            settingsWindow = SettingsWindowController(settings: settings ?? WorkSettings(), dataPath: store.fileURL.path, updates: updates,
                                                       onSave: { [weak self] value in
                                                           try self?.save(value)
                                                           DispatchQueue.main.async { [weak self] in self?.togglePopover() }
                                                       },
                                                       onReset: { [weak self] in try self?.reset() })
            settingsWindow?.onClose = { [weak self] in self?.updates.onChange = nil; self?.settingsWindow = nil }
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
        let root = NSMenuItem(title: "牛马上班", action: nil, keyEquivalent: "")
        let commands = NSMenu(title: "牛马上班")
        let show = NSMenuItem(title: "查看当前收入", action: #selector(togglePopover), keyEquivalent: "i")
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
