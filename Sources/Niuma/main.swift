import AppKit
import NiumaCore
import NiumaInstallation

// 正式包先完成归位及覆盖，避免旧版仍在运行时直接把用户送回旧入口。
if Bundle.main.object(forInfoDictionaryKey: "NiumaInstallOnLaunch") as? Bool == true,
   ManagedInstallation.shouldInstall(Bundle.main.bundleURL) {
    do {
        try ManagedInstallation.beginInstallation(source: Bundle.main.bundleURL, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NiumaInstaller"))
        exit(0)
    } catch {
        let alert = NSAlert()
        alert.messageText = "未能自动安装应用"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

// 手动重复启动二进制时复用已经运行的同一应用，不创建第二个菜单栏。
if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: AppDelegate.identifier)
    .first(where: {
        guard $0.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        let current = try? UpdateVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
        let other = $0.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }.flatMap { try? UpdateVersion($0) }
        guard let current, let other else { return true }
        return other >= current
    }) {
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
