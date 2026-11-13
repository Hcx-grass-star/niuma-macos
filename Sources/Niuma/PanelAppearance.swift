import AppKit
import NiumaCore

extension AppearanceMode {
    /// nil 表示继承系统主题，显式主题只作用于本应用自己的窗口和视图。
    @MainActor var nativeAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension PanelAppearanceSettings {
    /// 把已校验的六位 RGB 配置转为系统玻璃和颜色选择器共同使用的 sRGB 颜色。
    @MainActor var nativeTintColor: NSColor? {
        guard let tintHex, let rgb = UInt32(tintHex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                       green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

extension NSColor {
    /// 将颜色选择器的颜色统一保存为 sRGB，丢弃未提供配置入口的透明度。
    var panelTintHex: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
