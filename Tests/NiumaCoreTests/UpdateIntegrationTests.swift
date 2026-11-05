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
            let result = try await UpdateService(endpoint: URL(string: base + "/" + name)!, manifestEndpoint: nil).check(currentVersion: "0.2.0")
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
            let result = try await UpdateService(endpoint: URL(string: base + "/available")!, manifestEndpoint: nil).check(currentVersion: version)
            guard case .upToDate = result else { throw CheckFailure(message: "不应提示降级或重复更新") }
        }
        let unsupported = try await UpdateService(endpoint: URL(string: base + "/windows-only")!, manifestEndpoint: nil).check(currentVersion: "0.2.0")
        guard case .unavailable = unsupported else { throw CheckFailure(message: "不应提示下载其他平台安装包") }
        for name in ["limited", "server-error", "invalid", "unsafe-url", "slow", "disconnect"] {
            do {
                _ = try await UpdateService(endpoint: URL(string: base + "/" + name)!, manifestEndpoint: nil, timeout: name == "slow" ? 0.03 : 2).check(currentVersion: "0.2.0")
                throw CheckFailure(message: "无效发布或网络失败应明确失败")
            } catch is CheckFailure { throw CheckFailure(message: "无效发布或网络失败应明确失败") }
            catch { /* 网络或响应错误是本场景期望的外部结果。 */ }
        }
        let limited = URL(string: base + "/limited")!
        let primary = URL(string: base + "/manifest-available")!
        let before = try await requestCounts(base)["limited", default: 0]
        let staticResult = try await UpdateService(endpoint: limited, manifestEndpoint: primary).check(currentVersion: "0.2.0")
        guard case .available(let release) = staticResult else { throw CheckFailure(message: "静态源正常时不应受 API 限流影响") }
        try expectEqual(release.version, "0.3.0")
        try expectEqual(release.notes, "测试更新说明 <b>保持原文</b>")
        try expectEqual(try await requestCounts(base)["limited", default: 0], before)
        for version in ["0.3.0", "0.4.0"] {
            guard case .upToDate = try await UpdateService(endpoint: limited, manifestEndpoint: primary).check(currentVersion: version) else {
                throw CheckFailure(message: "静态源不得提示重复更新或降级")
            }
        }
        guard case .unavailable = try await UpdateService(endpoint: limited, manifestEndpoint: URL(string: base + "/manifest-windows-only")!).check(currentVersion: "0.2.0") else {
            throw CheckFailure(message: "静态源缺少 macOS 包时应明确不可用")
        }
        for name in ["missing", "limited", "invalid", "unsafe-url", "unsafe-page", "wrong-tag", "prerelease", "bad-notes", "oversized", "disconnect", "slow"] {
            let apiBefore = try await requestCounts(base)["available", default: 0]
            let result = try await UpdateService(endpoint: URL(string: base + "/available")!, manifestEndpoint: URL(string: base + "/manifest-" + name)!, timeout: name == "slow" ? 0.03 : 2).check(currentVersion: "0.2.0")
            guard case .available = result else { throw CheckFailure(message: "静态源失败应回退 API：" + name) }
            try expectEqual(try await requestCounts(base)["available", default: 0], apiBefore + 1)
        }
        do {
            _ = try await UpdateService(endpoint: limited, manifestEndpoint: URL(string: base + "/manifest-missing")!).check(currentVersion: "0.2.0")
            throw CheckFailure(message: "双源失败不应冒充已是最新版")
        } catch let error as UpdateError { try expectEqual(error, .rateLimited) }
        print("PASS: Swift 静态源优先、API限流隔离、失败回退、URL校验与双源错误（真实HTTP）")
    }

    /// 读取隔离服务器计数，证明回退次数并避免用预期替代真实请求证据。
    private static func requestCounts(_ base: String) async throws -> [String: Int] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: base + "/counts")!)
        return try JSONDecoder().decode([String: Int].self, from: data)
    }
}
