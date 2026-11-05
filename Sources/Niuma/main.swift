import AppKit

// 手动重复启动二进制时复用已经运行的同一应用，不创建第二个菜单栏。
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.identifier)
    .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    // 无参 activate() 自 macOS 14 起提供，旧系统使用带选项的等价调用。
    if #available(macOS 14.0, *) { existing.activate() }
    else { existing.activate(options: [.activateIgnoringOtherApps]) }
    exit(0)
}

// 使用原生 accessory 生命周期，仅保留菜单栏与按需打开的设置窗口。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
// 显式保留委托，确保应用运行期间菜单栏及回调保持有效。
let delegate = AppDelegate()
application.delegate = delegate
application.run()
