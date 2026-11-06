import AppKit
import NiumaCore

/// 紧邻菜单栏展示收入，使用普通原生窗口避免系统弹出层的额外视图运行时。
@MainActor
final class IncomePanel: NSPanel {
    /// 收入面板支持键盘快捷键和 Esc，同时不创建 Dock 窗口。
    override var canBecomeKey: Bool { true }

    /// 创建按内容尺寸调整的轻量面板，窗口生命周期由应用委托管理。
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                   styleMask: [.borderless], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = .windowBackgroundColor
        level = .popUpMenu
        animationBehavior = .none
        title = AppBuildChannel.current.displayName + " · 当前收入"
    }

    /// 根据菜单栏按钮定位，并将窗口限制在按钮所在屏幕的可见范围。
    func show(below button: NSStatusBarButton) {
        guard let anchorWindow = button.window else { return }
        let anchor = anchorWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? anchor
        let x = min(max(anchor.midX - frame.width / 2, screen.minX), screen.maxX - frame.width)
        setFrameOrigin(NSPoint(x: x, y: max(screen.minY, anchor.minY - frame.height - 6)))
        makeKeyAndOrderFront(nil)
    }

    /// Esc 沿用关闭路径，确保收入视图和刷新任务一起释放。
    override func cancelOperation(_ sender: Any?) { close() }
}
