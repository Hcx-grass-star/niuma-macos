import AppKit
import NiumaCore

/// 首页愿望摘要按原型横向排布，整行仍是可通过键盘和辅助功能操作的原生按钮。
@MainActor
final class HomeWishButton: NSButton {
    /// 已保存愿望的名称；空状态使用添加入口文案。
    private var wishName = "给努力一个小目标"
    /// 当前投影金额或隐私占位，由同一个隐私开关同步。
    private var detail = "添加第一个愿望"
    /// 只绘制0至1的进度，隐私模式下归零。
    private var progress: Double = 0
    /// 空状态显示星标，已有愿望沿用原型的耳机图标。
    private var hasWish = false
    /// 为图标、名称、金额及进度保留原型需要的自然高度。
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 60) }
    /// 使用从上到下的坐标排布图标和文字，避免系统按钮单行排版影响布局。
    override var isFlipped: Bool { true }

    /// 更新摘要及辅助功能值，金额隐藏时不在提示或可访问文本里保留原值。
    func update(name: String?, detail: String, progress: Double) {
        wishName = name ?? "给努力一个小目标"; hasWish = name != nil
        self.detail = detail; self.progress = min(1, max(0, progress))
        setAccessibilityLabel(wishName); setAccessibilityValue(detail)
        toolTip = wishName + " · " + detail; needsDisplay = true
    }

    /// 图标在左、文字与进度在右，末端箭头提示整行可以进入管理页。
    override func draw(_ dirtyRect: NSRect) {
        PrototypeColors.soft.setFill()
        NSBezierPath(roundedRect: NSRect(x: 6, y: 4, width: 44, height: 52), xRadius: 10, yRadius: 10).fill()
        homeText(hasWish ? "🎧" : "✦", in: NSRect(x: 12, y: 15, width: 32, height: 34), size: 24, color: PrototypeColors.ink, alignment: .center)
        let width = max(0, bounds.width - 82)
        homeText(wishName, in: NSRect(x: 62, y: 5, width: width, height: 18), size: 12, color: PrototypeColors.ink, bold: true)
        homeText(detail, in: NSRect(x: 62, y: 27, width: width, height: 15), size: 10, color: PrototypeColors.muted)
        let track = NSRect(x: 62, y: 49, width: width, height: 5)
        PrototypeColors.line.setFill(); NSBezierPath(roundedRect: track, xRadius: 2.5, yRadius: 2.5).fill()
        if progress > 0 {
            PrototypeColors.green.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * progress, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        }
        homeText("›", in: NSRect(x: bounds.width - 10, y: 22, width: 10, height: 20), size: 16, color: PrototypeColors.ink, alignment: .center)
        homeFocus(self)
    }
}

/// 原型的纯文字管理入口，不受系统圆角按钮边框和渐变影响。
@MainActor
final class HomeManageButton: NSButton {
    /// 与11号正文同高，宽度只覆盖文字，保持标题左右对齐。
    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 17) }
    /// 从顶部排布文字，与同一行的标题对齐。
    override var isFlipped: Bool { true }
    /// 按原型绘制绿色文字，焦点环仍明确表示键盘操作位置。
    override func draw(_ dirtyRect: NSRect) {
        homeText(title, in: bounds, size: 11, color: PrototypeColors.green, alignment: .right)
        homeFocus(self)
    }
}

/// 原型的双列功能卡片，图标、标题和说明分层排列，整张卡片均可点击。
@MainActor
final class HomeShortcutButton: NSButton {
    /// 两个固定入口共用同样的卡片尺寸和内边距。
    enum Destination { case report, woodfish }
    /// 当前入口决定图标与说明，不持有业务数据或额外计时器。
    private let destination: Destination
    /// 木鱼使用已选定的本地图稿，避免恢复Emoji木头图标。
    private let woodfish: NSImage?
    /// 13点内边距及三层内容对应原型98点高的卡片。
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 98) }
    /// 卡片从上到下绘制图标、标题与辅助说明。
    override var isFlipped: Bool { true }

    /// 建立真正的原生按钮入口，系统仅负责点击、键盘和辅助功能。
    init(destination: Destination, target: AnyObject, action: Selector) {
        self.destination = destination
        woodfish = destination == .woodfish ? NSImage(contentsOf: ArtworkAsset.woodfish.url) : nil
        super.init(frame: .zero)
        title = destination == .report ? "摸鱼战报" : "敲敲木鱼"
        self.target = target; self.action = action
        setAccessibilityIdentifier(destination == .report ? "homeReportCard" : "homeWoodfishCard")
        setAccessibilityHelp(destination == .report ? "回来后，收一份小惊喜" : "敲走一点班味")
    }
    /// 卡片只通过代码创建，保证目的页与图案一致。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// 实体浅绿底不受玻璃染色影响；按压时轻微加深提供反馈。
    override func draw(_ dirtyRect: NSRect) {
        let background = cell?.isHighlighted == true ? PrototypeColors.soft.blended(withFraction: 0.06, of: PrototypeColors.green)! : PrototypeColors.soft
        background.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
        if destination == .report {
            homeText("☕", in: NSRect(x: 13, y: 13, width: 28, height: 29), size: 21, color: PrototypeColors.ink)
        } else {
            woodfish?.draw(in: NSRect(x: 11, y: 9, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        homeText(title, in: NSRect(x: 13, y: 49, width: bounds.width - 26, height: 18), size: 12, color: PrototypeColors.ink, bold: true)
        homeText(destination == .report ? "回来后，收一份小惊喜" : "敲走一点班味", in: NSRect(x: 13, y: 72, width: bounds.width - 26, height: 16), size: 10, color: PrototypeColors.muted)
        homeFocus(self)
    }
}

/// 首页自绘文字采用原型字号与语义色；长名称截断但辅助功能保留全文。
@MainActor
private func homeText(_ value: String, in rect: NSRect, size: CGFloat, color: NSColor, bold: Bool = false, alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail; paragraph.alignment = alignment
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
}

/// 只在键盘聚焦时绘制焦点环，保持卡片可用而不引入常驻边框。
@MainActor
private func homeFocus(_ button: NSButton) {
    if button.window?.firstResponder === button {
        NSColor.keyboardFocusIndicatorColor.setStroke()
        NSBezierPath(roundedRect: button.bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).stroke()
    }
}
