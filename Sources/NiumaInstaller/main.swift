import AppKit
import Foundation
import NiumaInstallation

// Tauri 和原生应用使用同一助手；所有操作只针对固定应用身份。
let arguments = CommandLine.arguments
Task { @MainActor in
    var handedOff = false
    do {
        guard arguments.count >= 3 else { throw InstallationError.invalidBundle }
        let source = URL(fileURLWithPath: arguments[2])
        switch arguments[1] {
        case "plan": exit(ManagedInstallation.shouldInstall(source) ? 10 : 0)
        case "install":
            guard arguments.count == 4, let pid = Int32(arguments[3]) else { throw InstallationError.invalidBundle }
            try await ManagedInstallation.install(source: source, parentPID: pid) {
                handedOff = true
                FileHandle.standardOutput.write(Data("READY\n".utf8))
            }
        case "cleanup": try await ManagedInstallation.cleanupCurrentBundle(source)
        default: throw InstallationError.invalidBundle
        }
        exit(0)
    } catch {
        if !handedOff { FileHandle.standardOutput.write(Data(("ERROR: " + error.localizedDescription + "\n").utf8)) }
        if arguments.count > 1 && arguments[1] == "install" {
            NSApp.setActivationPolicy(.accessory)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "安装或旧版本清理未完成"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
        exit(1)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
