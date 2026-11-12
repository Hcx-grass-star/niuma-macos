import Foundation

/// 原生面板与菜单栏共用的本地图稿；PNG兼容旧系统，不在运行时依赖SVG解析器。
public enum ArtworkAsset: String, CaseIterable {
    case cow = "AppIcon", menuBarCow = "MenuBarCow", woodfish = "Woodfish"
    /// 独立鱼身与木槌供敲击动画分别变形，首页继续使用完整图标。
    case woodfishBody = "WoodfishBody", woodfishMallet = "WoodfishMallet"
    /// 资源随已有核心Bundle打包，测试包与正式包使用同一份图稿。
    public var url: URL { Bundle.module.url(forResource: rawValue, withExtension: "png")! }
}
