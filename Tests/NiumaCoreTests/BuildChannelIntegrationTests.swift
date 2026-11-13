import Foundation
import NiumaCore

/// 使用真实包配置验证环境识别、展示名称和登录启动准入。
struct BuildChannelIntegrationTests {
    /// 正式、开发、测试及错误配置都经磁盘 Info.plist 和 Bundle 读取验证。
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-channel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(Any?, AppBuildChannel)] = [
            ("production", .production), ("development", .development), ("test", .test),
            (nil, .development), ("prod", .development), (true, .development)
        ]
        for (index, entry) in cases.enumerated() {
            let bundleURL = directory.appendingPathComponent("Channel-\(index).bundle")
            let contents = bundleURL.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "niuma.channel-test.\(UUID().uuidString)", "CFBundlePackageType": "BNDL"]
            info["NiumaBuildChannel"] = entry.0
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            guard let bundle = Bundle(url: bundleURL) else { throw CheckFailure(message: "无法读取环境测试包") }
            let channel = AppBuildChannel(value: bundle.object(forInfoDictionaryKey: "NiumaBuildChannel"))
            try expectEqual(channel, entry.1)
            try expectEqual(channel.allowsLoginItemRegistration, entry.1 == .production)
        }
        try expectEqual(AppBuildChannel.production.displayName, "牛马上班")
        try expectEqual(AppBuildChannel.development.displayName, "牛马上班（开发版）")
        try expectEqual(AppBuildChannel.test.displayName, "牛马上班（测试版）")
        try expectEqual(AppBuildChannel.production.bundleIdentifier, "com.hcxgrassstar.niuma")
        try expectTrue(AppBuildChannel.production.bundleIdentifier != AppBuildChannel.development.bundleIdentifier)
        try expectTrue(AppBuildChannel.test.bundleIdentifier != AppBuildChannel.development.bundleIdentifier)
    }
}
