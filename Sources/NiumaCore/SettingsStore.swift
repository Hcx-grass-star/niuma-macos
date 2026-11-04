import Foundation

/// 用单一 JSON 文件保存配置；调用方可注入测试专属目录。
public struct SettingsStore: Sendable {
    /// 配置所属目录，不处理目录之外的文件。
    public let directory: URL

    /// 实际配置文件位置，便于交付和清理时明确路径。
    public var fileURL: URL { directory.appendingPathComponent("settings.json") }

    /// 为给定的应用专属目录创建存储对象，不提前写入文件。
    public init(directory: URL) { self.directory = directory }

    /// 读取已保存配置；文件不存在返回空，损坏时保留原文件并报错。
    public func load() throws -> WorkSettings? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let settings = try JSONDecoder().decode(WorkSettings.self, from: Data(contentsOf: fileURL))
            try settings.validate()
            return settings
        } catch { throw SettingsError.invalidStorage }
    }

    /// 校验后原子替换配置，写入失败不发布新配置。
    public func save(_ settings: WorkSettings) throws {
        try settings.validate()
        let data = try JSONEncoder().encode(settings)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
    }

    /// 只移除应用自己的配置文件；不删除目录中的未知文件。
    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) }
        if FileManager.default.fileExists(atPath: directory.path),
           try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
