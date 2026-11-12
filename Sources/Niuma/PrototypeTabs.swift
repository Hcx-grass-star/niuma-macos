import AppKit

/// 原型的浅灰绿导航与白色选中项，避免系统分段控件受强调色、玻璃和系统版本影响。
@MainActor
final class PrototypeTabs: NSControl {
    /// 当前页面索引；程序切页和鼠标键盘操作共用同一选中状态。
    var selectedSegment = 0 {
        didSet { for (index, button) in buttons.enumerated() { button.state = index == selectedSegment ? .on : .off; button.needsDisplay = true } }
    }
    /// 原生按钮保留键盘和辅助功能操作，不用绘制文字模拟不可点击标签。
    private var buttons: [NSButton] = []
    /// 导航高度与原型内边距一致，不随系统控件尺寸膨胀。
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 36) }
    /// 以四个均分原生按钮建立页面切换，外围只绘制固定的原型底色。
    init() {
        super.init(frame: .zero)
        for (index, title) in ["收入", "战报", "愿望", "木鱼"].enumerated() {
            let button = PrototypeTabButton(title: title, target: self, action: #selector(selectTab(_:)))
            button.tag = index; button.isBordered = false; button.setButtonType(.pushOnPushOff)
            button.setAccessibilityIdentifier("cheerTab-\(index)"); buttons.append(button)
        }
        let stack = NSStackView(views: buttons); stack.distribution = .fillEqually; stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        for button in buttons { button.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setAccessibilityRole(.group); setAccessibilityElement(true); setAccessibilityLabel("面板页面")
        setAccessibilityChildren(buttons)
        selectedSegment = 0
    }
    /// 导航只通过代码创建。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    /// 使用与原型相同的实体背景，玻璃染色不会改变导航颜色。
    override func draw(_ dirtyRect: NSRect) {
        PrototypeColors.soft.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
    /// 选择后通过标准target/action通知收入控制器，不创建新窗口。
    @objc private func selectTab(_ sender: NSButton) { selectedSegment = sender.tag; sendAction(action, to: target) }
}

/// 只改变原生按钮的外观绘制，键盘触发和可访问性仍交给NSButton。
@MainActor
private final class PrototypeTabButton: NSButton {
    /// 选中项为白底深字，未选中项为透明底次要字色，没有系统渐变或竖线。
    override func draw(_ dirtyRect: NSRect) {
        if state == .on { PrototypeColors.paper.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: state == .on ? PrototypeColors.ink : PrototypeColors.muted, .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 0, y: (bounds.height-height)/2, width: bounds.width, height: height), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).stroke()
        }
    }
}

/// 原型的深浅色语义值；动态解析后也支持用户保留的面板主题。
@MainActor
enum PrototypeColors {
    /// 导航轨道对应原型soft色。
    static let soft = color(light: 0xf2f6ef, dark: 0x293b30)
    /// 选中页背景对应原型paper色。
    static let paper = color(light: 0xffffff, dark: 0x23322a)
    /// 主文字对应原型ink色。
    static let ink = color(light: 0x263c32, dark: 0xe1e9df)
    /// 未选中文字对应原型muted色。
    static let muted = color(light: 0x708078, dark: 0xacb9ae)
    /// 愿望进度和文字入口对应原型green色，避免系统强调色改变视觉。
    static let green = color(light: 0x3e6951, dark: 0x9dbb94)
    /// 愿望进度轨道对应原型line色。
    static let line = color(light: 0xe3e9e1, dark: 0x3b4c3e)
    /// 将原型RGB转换为动态系统颜色，避免全局强制浅色。
    private static func color(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 255)/255, green: CGFloat(rgb >> 8 & 255)/255, blue: CGFloat(rgb & 255)/255, alpha: 1)
        }
    }
}
