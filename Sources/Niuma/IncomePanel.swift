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
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        // 状态栏点击时应用可以仍在后台，面板自行取得键盘焦点并由失焦回调关闭。
        hidesOnDeactivate = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
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

/// 按用户配置选择原生玻璃或圆角绘制，全部内容随面板关闭一起释放。
@MainActor
final class IncomePanelBackgroundView: NSView {
    /// 业务控件始终放在此容器，玻璃模式通过系统 contentView 嵌入它。
    let contentView = NSView()
    /// 面板外缘圆角，布局内边距保证所有控件都位于圆角内侧。
    private let cornerRadius: CGFloat = 12
    /// 仅开启玻璃且系统支持时持有；基类类型允许兼容 macOS 13。
    private var glassView: NSView?
    /// 已应用配置，避免收入秒级刷新时重建材质或更新外观。
    private var appliedSettings: PanelAppearanceSettings?
    /// 观察者所属通知中心，关闭面板时无需访问系统单例即可移除观察者。
    private let accessibilityNotifications = NSWorkspace.shared.notificationCenter

    /// 创建唯一内容容器，只在面板存活期间监听辅助功能显示变化。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView.frame = bounds
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
        accessibilityNotifications.addObserver(self, selector: #selector(updateMaterial(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    /// 面板背景只由应用创建，不从归档恢复。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 收起后移除辅助功能观察，不继续处理后台材质变化。
    deinit { accessibilityNotifications.removeObserver(self) }

    /// 普通背景的内容容器与最终面板尺寸保持一致，避免连续切页时旧高度裁切顶部。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if contentView.superview === self { contentView.frame = bounds }
    }

    /// 相同配置直接返回，避免收入刷新时查询系统外观或重建材质。
    func apply(_ settings: PanelAppearanceSettings) {
        guard appliedSettings != settings else { return }
        appliedSettings = settings
        appearance = settings.mode.nativeAppearance
        updateMaterial(nil)
    }

    /// 仅由配置变化或辅助功能通知触发材质更新，不安排额外轮询。
    @objc private func updateMaterial(_ notification: Notification?) {
        guard let settings = appliedSettings else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        if #available(macOS 26.0, *), settings.glassEnabled && !reduced {
            let glass: NSGlassEffectView
            if let current = glassView as? NSGlassEffectView { glass = current }
            else {
                contentView.removeFromSuperview()
                glass = NSGlassEffectView(frame: bounds)
                glass.autoresizingMask = [.width, .height]
                glass.style = .regular
                glass.cornerRadius = cornerRadius
                glass.contentView = contentView
                addSubview(glass)
                glassView = glass
            }
            glass.tintColor = settings.nativeTintColor
        } else if let glass = glassView {
            contentView.removeFromSuperview()
            glass.removeFromSuperview()
            glassView = nil
            contentView.frame = bounds
            addSubview(contentView)
        }
        needsDisplay = true
        window?.invalidateShadow()
    }

    /// 普通模式保持原生圆角和轻微染色；玻璃模式的背景完全交给系统绘制。
    override func draw(_ dirtyRect: NSRect) {
        guard glassView == nil else { return }
        let tint = appliedSettings?.nativeTintColor
        let color = tint.flatMap { NSColor.windowBackgroundColor.blended(withFraction: 0.12, of: $0) }
            ?? NSColor.windowBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    /// 深浅外观切换后重新解析系统颜色，不缓存上一种主题的背景。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
