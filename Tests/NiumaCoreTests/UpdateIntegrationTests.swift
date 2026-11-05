import Foundation
import NiumaCore

/// 用真实本地发布接口验证更新能力，不读取用户偏好或访问远端发布。
struct UpdateIntegrationTests {
    /// 验证版本和限频规则；配置测试接口时附加真实 HTTP 请求链路。
    static func run() async throws {
        try expectEqual(try UpdateVersion("v0.10.0") > UpdateVersion("0.2.0"), true)
        try expectThrows { _ = try UpdateVersion("1.2.3-beta") }
        try expectThrows { _ = try UpdateVersion("1.02.3") }
        let now = Date(timeIntervalSince1970: 100000)
        try expectEqual(UpdatePolicy.shouldCheck(enabled: true, lastAttempt: nil, now: now), true)
        try expectEqual(UpdatePolicy.shouldCheck(enabled: false, lastAttempt: nil, now: now), false)
        try expectEqual(UpdatePolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-86399), now: now), false)
        try expectEqual(UpdatePolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(-86400), now: now), true)
        try expectEqual(UpdatePolicy.shouldCheck(enabled: true, lastAttempt: now.addingTimeInterval(100), now: now), false)
        guard let base = ProcessInfo.processInfo.environment["NIUMA_UPDATE_TEST_URL"] else {
            print("PASS: 更新版本和24小时限频；HTTP集成请运行 npm run test:updates")
            return
        }
        for (name, expected) in [("available", "available"), ("missing", "unpublished"), ("draft", "unpublished"), ("prerelease", "unpublished")] {
            let result = try await UpdateService(endpoint: URL(string: base + "/" + name)!).check(currentVersion: "0.2.0")
            switch result {
            case .available(let release):
                try expectEqual(expected, "available")
                try expectEqual(release.version, "0.3.0")
                try expectEqual(release.notes, "测试更新说明 <b>保持原文</b>")
            case .unpublished: try expectEqual(expected, "unpublished")
            default: throw CheckFailure(message: "更新响应状态不符合期望")
            }
        }
        for version in ["0.3.0", "0.4.0"] {
            let result = try await UpdateService(endpoint: URL(string: base + "/available")!).check(currentVersion: version)
            guard case .upToDate = result else { throw CheckFailure(message: "不应提示降级或重复更新") }
        }
        let unsupported = try await UpdateService(endpoint: URL(string: base + "/windows-only")!).check(currentVersion: "0.2.0")
        guard case .unavailable = unsupported else { throw CheckFailure(message: "不应提示下载其他平台安装包") }
        for name in ["limited", "server-error", "invalid", "unsafe-url", "slow", "disconnect"] {
            do {
                _ = try await UpdateService(endpoint: URL(string: base + "/" + name)!, timeout: name == "slow" ? 0.03 : 2).check(currentVersion: "0.2.0")
                throw CheckFailure(message: "无效发布或网络失败应明确失败")
            } catch is CheckFailure { throw CheckFailure(message: "无效发布或网络失败应明确失败") }
            catch { /* 网络或响应错误是本场景期望的外部结果。 */ }
        }
        print("PASS: Swift 更新版本、限频与真实HTTP集成")
    }
}
