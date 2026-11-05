import AppKit
import CryptoKit
import Darwin
import Foundation

/// 原生与 Tauri 共用的 macOS 安装归位及旧版本清理，不扫描工资数据目录。
@MainActor
public enum ManagedInstallation {
    /// 两种 macOS 实现共用的正式应用身份。
    public static let identifier = "com.hcxgrassstar.niuma"
    /// 单一应用入口；用户目录仅在系统应用目录没有旧包且不可写时使用。
    public static let applicationName = "牛马上班.app"

    /// 开发运行及安装失败后的单次恢复不执行自动迁移。
    public static func shouldInstall(_ source: URL) -> Bool {
        guard ProcessInfo.processInfo.environment["NIUMA_SKIP_INSTALLATION"] != "1" else { return false }
        return !isInstalledLocation(source)
    }

    /// 只把两个固定应用目录视为正式入口，与一次性故障恢复标志无关。
    public static func isInstalledLocation(_ source: URL) -> Bool {
        let local = URL(fileURLWithPath: "/Applications").appendingPathComponent(applicationName)
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/" + applicationName)
        return source.standardizedFileURL == local || source.standardizedFileURL == user
    }

    /// 启动独立助手并等待它验证源应用，之后调用方才能安全退出。
    public static func beginInstallation(source: URL, helper: URL) throws {
        let process = Process()
        process.executableURL = helper
        process.arguments = ["install", source.path, String(ProcessInfo.processInfo.processIdentifier)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let handshake = output.fileHandleForReading.availableData
        let message = String(data: handshake, encoding: .utf8) ?? ""
        if message.hasPrefix("ERROR:") { return } // 助手负责显示准备阶段失败，调用方不重复弹窗。
        guard message.hasPrefix("READY") else { throw InstallationError.invalidBundle }
    }

    /// 确认用户已运行本包后完成归位；成功启动新入口前不清理下载源与旧备份。
    public static func install(source: URL, parentPID: pid_t, onPrepared: () -> Void) async throws {
        guard parentPID > 1, let parent = NSRunningApplication(processIdentifier: parentPID), parent.bundleURL?.standardizedFileURL == source.standardizedFileURL else { throw InstallationError.invalidBundle }
        let current = try InstalledBundle(url: source, identifier: identifier)
        let manager = FileManager.default
        let destination = try installationDestination()
        let candidates = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
        let lockURL = manager.temporaryDirectory.appendingPathComponent("niuma-installation.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw InstallationError.permission }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw InstallationError.stillRunning }
        defer { flock(descriptor, LOCK_UN) }

        let previous = try? InstalledBundle(url: destination, identifier: identifier)
        // 手动打开旧下载包时使用已安装的更新版本，绝不反向覆盖。
        let useInstalled = previous.map { $0.version > current.version } ?? false
        let transaction = useInstalled ? nil : try BundleReplacement(source: source, destination: destination, identifier: identifier)
        try transaction?.prepare()
        onPrepared()
        do {
            try await waitForExit(parent)
            if let previous, !useInstalled { try await stopApplications(at: previous.url) }
            try transaction?.replace()
            if transaction != nil {
                // 源包已经经用户启动且复制后的签名通过验证；仅清理这份副本的隔离属性，避免再次随机转位。
                let quarantine = Process()
                quarantine.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                quarantine.arguments = ["-d", "-r", "com.apple.quarantine", destination.path]
                quarantine.standardOutput = FileHandle.nullDevice
                quarantine.standardError = FileHandle.nullDevice
                try quarantine.run(); quarantine.waitUntilExit()
            }
            let running = try await launch(destination)
            do {
                try await waitUntilReady(running)
            } catch {
                _ = running.terminate()
                try? await waitForExit(running)
                throw error
            }
        } catch {
            try transaction?.rollback()
            let restore = manager.fileExists(atPath: destination.path) ? destination : source
            _ = try? await launch(restore, restoring: true)
            throw error
        }
        // 旧包回收失败不能回滚已经正常运行的新版；只报告需要用户处理的清理问题。
        try transaction?.commit()
        let installed = try InstalledBundle(url: destination, identifier: identifier)
        let sourceHash = try executableHash(current.executable)
        var copies = candidates + NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier)
        if source.path.contains("/AppTranslocation/") == false { copies.append(source) }
        try await cleanup(current: installed, candidates: copies, downloadedHash: sourceHash)
        registerApplication(destination)
    }

    /// 正常启动后清理已注册的旧副本；等于或高于当前版本的其他构建默认保留。
    public static func cleanupCurrentBundle(_ url: URL) async throws {
        guard isInstalledLocation(url), ProcessInfo.processInfo.environment["NIUMA_INSTALLATION_MANAGED"] != "1" else { return }
        let current = try InstalledBundle(url: url, identifier: identifier)
        try await cleanup(current: current, candidates: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: identifier))
    }

    /// 只处理本用户可写区域内同身份的 .app；下载源同版本时还必须匹配执行文件哈希。
    public static func cleanup(current: InstalledBundle, candidates: [URL], downloadedHash: Data? = nil) async throws {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL.path + "/"
        var seen = Set<String>()
        var failures = false
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, url.standardizedFileURL != current.url,
                  !path.contains("/.Trash/"), !path.contains("/AppTranslocation/"),
                  path.hasPrefix(home) || path.hasPrefix("/Applications/"),
                  let old = try? InstalledBundle(url: url, identifier: identifier) else { continue }
            let isDownloadedCopy = downloadedHash != nil && path.hasPrefix(home + "Downloads/") && old.version == current.version && (try? executableHash(old.executable)) == downloadedHash
            guard old.version < current.version || isDownloadedCopy else { continue }
            do {
                try await stopApplications(at: old.url)
                unregisterApplication(old.url)
                do { try manager.trashItem(at: old.url, resultingItemURL: nil) }
                catch { registerApplication(old.url); throw error }
            } catch { failures = true }
        }
        if failures { throw InstallationError.permission }
    }

    /// 已存在的系统安装始终原位升级，不能通过另建用户副本绕过权限失败。
    private static func installationDestination() throws -> URL {
        let manager = FileManager.default
        let system = URL(fileURLWithPath: "/Applications").appendingPathComponent(applicationName)
        if manager.fileExists(atPath: system.path) || manager.isWritableFile(atPath: "/Applications") { return system }
        let parent = manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent(applicationName)
    }

    /// 使用系统打开接口避免 shell 路径展开，并使新进程跳过重复的归位检查。
    private static func launch(_ url: URL, restoring: Bool = false) async throws -> NSRunningApplication {
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL && !$0.isTerminated && $0.isFinishedLaunching }) {
            if #available(macOS 14.0, *) { existing.activate() }
            else { existing.activate(options: [.activateIgnoringOtherApps]) }
            return existing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = restoring ? ["NIUMA_SKIP_INSTALLATION": "1"] : ["NIUMA_INSTALLATION_MANAGED": "1"]
        return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// 启动完成且进程仍存活才视为安装成功，失败时允许恢复旧正式入口。
    private static func waitUntilReady(_ application: NSRunningApplication) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !application.isFinishedLaunching && !application.isTerminated && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard application.isFinishedLaunching, !application.isTerminated else { throw InstallationError.launch }
    }

    /// 只请求对应包进程正常退出，不强杀保存草稿或系统授权中的应用。
    private static func stopApplications(at url: URL) async throws {
        let target = try InstalledBundle(url: url, identifier: identifier)
        let targetHash = try executableHash(target.executable)
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) where application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            guard let runningURL = application.bundleURL else { continue }
            let exactPath = runningURL.standardizedFileURL == url.standardizedFileURL
            // Gatekeeper 随机转位会改变运行路径；版本与执行文件同时相同才能认定为此旧副本。
            let translocated = runningURL.path.contains("/AppTranslocation/")
                && (try? InstalledBundle(url: runningURL, identifier: identifier)).map { $0.version == target.version && (try? executableHash($0.executable)) == targetHash } == true
            guard exactPath || translocated else { continue }
            guard application.terminate() else { throw InstallationError.stillRunning }
            try await waitForExit(application)
        }
    }

    /// 有限等待父进程或旧应用退出，拒绝在仍占用旧包时继续替换。
    private static func waitForExit(_ application: NSRunningApplication) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !application.isTerminated && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard application.isTerminated else { throw InstallationError.stillRunning }
    }

    /// 下载源与执行中的版本通过内容匹配，不依赖同名文件猜测来源。
    private static func executableHash(_ url: URL) throws -> Data { Data(SHA256.hash(data: try Data(contentsOf: url))) }

    /// 只移除被回收包的打开索引，不重置其他应用或整个启动数据库。
    private static func unregisterApplication(_ url: URL) { updateRegistration(url, removing: true) }

    /// 让系统入口指向已启动的唯一正式安装位置。
    private static func registerApplication(_ url: URL) { updateRegistration(url, removing: false) }

    /// 使用系统工具的独立参数更新单个包注册，不通过 shell 拼接应用路径。
    private static func updateRegistration(_ url: URL, removing: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        process.arguments = [removing ? "-u" : "-f", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { /* 索引刷新失败不影响已完成的文件安装。 */ }
    }
}
