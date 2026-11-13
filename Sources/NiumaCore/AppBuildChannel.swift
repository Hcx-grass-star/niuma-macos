import Foundation

/// 应用包内固定的运行环境，统一用于身份展示与系统自启动权限。
public enum AppBuildChannel: String, Sendable {
    case production, development, test

    /// 从当前应用包读取环境；命令行运行、缺失或错误配置均按开发版处理。
    public static let current = AppBuildChannel(value: Bundle.main.object(forInfoDictionaryKey: "NiumaBuildChannel"))

    /// 解析包配置，只有明确的 production 才能获得正式版能力。
    public init(value: Any?) {
        self = (value as? String).flatMap(Self.init(rawValue:)) ?? .development
    }

    /// 面向用户的环境名称，便于在设置中核对当前运行包。
    public var title: String {
        switch self {
        case .production: return "正式版"
        case .development: return "开发版"
        case .test: return "测试版"
        }
    }

    /// 正式版沿用产品名称，其他环境始终携带醒目的环境后缀。
    public var displayName: String {
        self == .production ? "牛马上班" : "牛马上班（" + title + "）"
    }

    /// 非正式包使用独立应用身份与配置目录，避免被当作已运行的正式应用。
    public var bundleIdentifier: String {
        let base = "com.hcxgrassstar.niuma"
        return self == .production ? base : base + "." + rawValue
    }

    /// 仅正式应用允许向系统登记登录启动，防止测试包产生残留记录。
    public var allowsLoginItemRegistration: Bool { self == .production }
}
