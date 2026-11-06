import Foundation

/// 收入面板和设置窗口共同使用的外观偏好，系统模式随系统主题变化。
public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    /// 设置选择器中使用的中文名称。
    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 与工资计算无关的面板外观；默认保留普通背景，避免自动增加渲染开销。
public struct PanelAppearanceSettings: Codable, Equatable, Sendable {
    /// 用户明确开启后，在支持的系统上使用原生液态玻璃。
    public var glassEnabled = false
    /// 收入面板和设置窗口的深浅外观。
    public var mode: AppearanceMode = .system
    /// 可选 sRGB 染色，格式为六位十六进制 RGB，不包含井号或透明度。
    public var tintHex: String?

    /// 创建兼容现有面板的低开销默认外观。
    public init() {}

    /// 拒绝无法还原为 sRGB 的染色值，避免保存后与实际显示不一致。
    public func validate() throws {
        guard let tintHex else { return }
        // 收入计算也会校验配置，六个 ASCII 字节直接检查，避免每秒创建正则状态。
        guard tintHex.utf8.count == 6, tintHex.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else {
            throw SettingsError.invalidPanelTint
        }
    }
}
