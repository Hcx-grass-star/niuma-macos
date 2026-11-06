import AppKit
import NiumaCore

/// 在真实 NSStatusItem 和编辑器上验证显示宽度、隐私及唯一刷新任务。
@main
struct CountdownUIIntegrationTests {
    /// 从委托读取受测对象，仅用于集成断言，不修改实现状态。
    @MainActor static func value<T>(_ object: Any, _ name: String) -> T? {
        Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
    }
    /// 运行真实 AppKit 生命周期，使用独立配置和 UserDefaults，不读取工资数据。
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let domain = "niuma-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(false, forKey: "updates.enabled")
        defer { defaults.removePersistentDomain(forName: domain) }
        var work = WorkSettings(); work.salary = 1000; work.hideAmounts = true
        try SettingsStore(directory: directory).save(work)
        var preferences = CountdownPreferences()
        preferences.events = [CountdownEvent(title: "离职与美好生活", targetAt: Date().addingTimeInterval(7200))]
        preferences.menuCountdownID = preferences.events[0].id
        let store = CountdownStore(directory: directory)
        let notification = Notification(name: NSApplication.didFinishLaunchingNotification)
        for width in [60.0, 120, 240] {
            preferences.menuWidth = width; preferences.menuMode = .both
            try store.save(preferences)
            let delegate = AppDelegate(store: SettingsStore(directory: directory), updates: UpdateController(defaults: defaults))
            delegate.applicationDidFinishLaunching(notification)
            let item: NSStatusItem = value(delegate, "statusItem")!
            precondition(item.length == width)
            precondition(item.button?.title.contains("¥") == false)
            precondition(item.button?.title.isEmpty == false)
            precondition(item.button?.toolTip?.contains("离职与美好生活") == true)
            let timer: Timer? = value(delegate, "refreshTimer")
            precondition(timer?.isValid == true)
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            precondition(timer?.isValid == false)
            NSStatusBar.system.removeStatusItem(item)
        }
        preferences.menuMode = .icon
        try store.save(preferences)
        let delegate = AppDelegate(store: SettingsStore(directory: directory), updates: UpdateController(defaults: defaults))
        delegate.applicationDidFinishLaunching(notification)
        let timer: Timer? = value(delegate, "refreshTimer")
        precondition(timer == nil)
        let item: NSStatusItem = value(delegate, "statusItem")!
        precondition(item.button?.title == "")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        NSStatusBar.system.removeStatusItem(item)
        var saved: CountdownPreferences?
        let editor = CountdownWindowController(preferences: preferences, legacyIncome: false, onSave: { saved = $0 })
        editor.showWindow(nil)
        let save: NSButton = findButton(editor.window!.contentView!, title: "保存")!
        save.performClick(nil)
        precondition(saved == preferences)
        print("PASS: 原生 60/120/240 pt 实际宽度、金额隐私、隐藏停止刷新、编辑器保存与退出释放")
    }
    /// 递归寻找真实按钮，模拟保存操作验证表单与持久化回调。
    @MainActor static func findButton(_ view: NSView, title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.compactMap { findButton($0, title: title) }.first
    }
}
