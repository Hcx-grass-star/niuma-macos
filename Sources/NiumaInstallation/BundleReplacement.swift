import Foundation
import NiumaCore

/// 已核实身份的应用包；不把同名目录或符号链接当成可替换应用。
public struct InstalledBundle {
    /// 应用包的真实路径。
    public let url: URL
    /// 用于阻止降级及筛选旧副本的正式版本。
    public let version: UpdateVersion
    /// 实际可执行文件，用于确认下载副本与已启动应用一致。
    public let executable: URL

    /// 校验包身份、版本及执行文件；任何失败都先于移动旧应用。
    public init(url: URL, identifier: String) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard url.pathExtension == "app", values.isSymbolicLink != true, values.isDirectory == true else { throw InstallationError.invalidBundle }
        let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == identifier,
              let rawVersion = info["CFBundleShortVersionString"] as? String,
              let name = info["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/"), !name.contains("\\") else { throw InstallationError.invalidBundle }
        let binary = url.appendingPathComponent("Contents/MacOS/" + name)
        let binaryValues = try binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard binaryValues.isRegularFile == true, binaryValues.isSymbolicLink != true, FileManager.default.isExecutableFile(atPath: binary.path) else { throw InstallationError.invalidBundle }
        self.url = url.standardizedFileURL
        version = try UpdateVersion(rawVersion)
        executable = binary
    }
}

/// 安装失败只描述恢复方式，不包含工资或排班内容。
public enum InstallationError: String, Error, LocalizedError {
    case invalidBundle = "应用包身份或版本无效，未替换旧版本。"
    case downgrade = "已安装更新版本，不会降级覆盖。"
    case signature = "应用完整性校验未通过，未替换旧版本。"
    case permission = "无法写入应用程序目录，旧版本已保留。请使用 Finder 授权安装。"
    case stillRunning = "旧版本尚未退出，已保留原应用。请退出旧版本后重试。"
    case launch = "新版未能正常启动，已恢复原应用。"
    /// 界面直接展示的中文失败原因。
    public var errorDescription: String? { rawValue }
}

/// 同目录暂存与备份使手动升级可以在启动失败时恢复，确认成功后才丢弃旧包。
public final class BundleReplacement {
    /// 本次准备安装的、经过身份校验的源应用。
    public let source: InstalledBundle
    /// 唯一正式安装位置。
    public let destination: URL
    /// 本次事务专属的暂存应用，不占用正式入口。
    private let staged: URL
    /// 旧正式应用的备份，提交前不删除。
    private let backup: URL
    /// 文件操作不涉及应用包外的用户配置。
    private let manager = FileManager.default
    /// 安装目标是否已被本次事务替换，用于精确回滚。
    private var replaced = false
    /// 事务开始时是否存在旧正式应用。
    private var hadPrevious = false
    /// 目标应用的固定身份。
    private let identifier: String

    /// 只接受同身份、无降级的覆盖；原有目录不是本应用时拒绝操作。
    public init(source: URL, destination: URL, identifier: String) throws {
        self.source = try InstalledBundle(url: source, identifier: identifier)
        self.destination = destination.standardizedFileURL
        self.identifier = identifier
        guard destination.pathExtension == "app", source.standardizedFileURL.path != self.destination.path else { throw InstallationError.invalidBundle }
        if manager.fileExists(atPath: destination.path) {
            let previous = try InstalledBundle(url: destination, identifier: identifier)
            guard previous.version <= self.source.version else { throw InstallationError.downgrade }
        }
        let parent = destination.deletingLastPathComponent()
        let token = UUID().uuidString
        staged = parent.appendingPathComponent(".niuma-stage-" + token + ".app")
        backup = parent.appendingPathComponent(".niuma-previous-" + token + ".app")
    }

    /// 在触碰旧应用前完成完整复制和签名校验，断网或磁盘不足不会破坏旧入口。
    public func prepare() throws {
        guard manager.isWritableFile(atPath: destination.deletingLastPathComponent().path) else { throw InstallationError.permission }
        do {
            try manager.copyItem(at: source.url, to: staged)
            _ = try InstalledBundle(url: staged, identifier: identifier)
            try Self.verifySignature(staged)
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    /// 旧进程退出后才切换正式入口；保留旧包直到调用 commit。
    public func replace() throws {
        do {
            hadPrevious = manager.fileExists(atPath: destination.path)
            if hadPrevious {
                let previous = try InstalledBundle(url: destination, identifier: identifier)
                guard previous.version <= source.version else { throw InstallationError.downgrade }
            }
            if hadPrevious { try manager.moveItem(at: destination, to: backup) }
            do { try manager.moveItem(at: staged, to: destination); replaced = true }
            catch {
                if hadPrevious { try manager.moveItem(at: backup, to: destination) }
                throw error
            }
        } catch {
            try? manager.removeItem(at: staged)
            throw error
        }
    }

    /// 新版启动成功后将旧包移入废纸篓；清理失败仍保留已正常运行的新应用。
    public func commit(trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) throws {
        guard replaced else { return }
        if hadPrevious { try trash(backup) }
        replaced = false
    }

    /// 新版启动失败时恢复旧入口，下载的源应用及用户数据始终不删除。
    public func rollback() throws {
        if replaced {
            let installed = try InstalledBundle(url: destination, identifier: identifier)
            guard installed.version == source.version else { throw InstallationError.downgrade }
            try manager.removeItem(at: destination)
            if hadPrevious { try manager.moveItem(at: backup, to: destination) }
            replaced = false
        }
        if manager.fileExists(atPath: staged.path) { try manager.removeItem(at: staged) }
    }

    /// 使用系统代码签名校验，不以版本号或文件名替代完整性验证。
    public static func verifySignature(_ bundle: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw InstallationError.signature }
    }
}
