import AppKit
import QuartzCore
import NiumaCore

/// 木槌、鱼身及命中反馈独立运动，保留原生按钮的空格与辅助功能操作。
@MainActor
final class WoodfishButton: NSButton {
    /// 以图稿的256坐标系排布，布局变化不会改变敲击接触点。
    private let scene = CALayer()
    /// 鱼身围绕底部轻震，不带动木槌或提示文字。
    private let body = CALayer()
    /// 木槌以握柄末端为支点旋转。
    private let mallet = CALayer()
    /// 接触点的短暂扩散圆环表现敲击力度。
    private let ripple = CAShapeLayer()
    /// 命中后上浮的文字与会话计数对应。
    private let feedback = CATextLayer()
    /// 只在落槌期间存在；接触前的连续输入合并，避免动画与计数脱节。
    private var impactTimer: Timer?
    /// 木槌静止时抬起，为下一次落槌留出明显行程。
    private let restingAngle = -CGFloat.pi * 24 / 180

    /// 配置独立图层；静止时不持有任何刷新计时器。
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(scene)
        scene.name = "woodfish.scene"
        scene.bounds = CGRect(x: 0, y: 0, width: 256, height: 256)
        for (part, asset, pivot, name) in [
            (body, ArtworkAsset.woodfishBody, CGPoint(x: 115, y: 49), "woodfish.body"),
            (mallet, ArtworkAsset.woodfishMallet, CGPoint(x: 222, y: 179), "woodfish.mallet")
        ] {
            part.name = name; part.bounds = scene.bounds
            part.anchorPoint = CGPoint(x: pivot.x / 256, y: pivot.y / 256); part.position = pivot
            part.contents = NSImage(contentsOf: asset.url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            scene.addSublayer(part)
        }
        mallet.setAffineTransform(CGAffineTransform(rotationAngle: restingAngle))
        ripple.name = "woodfish.ripple"; ripple.bounds = CGRect(x: 0, y: 0, width: 38, height: 15)
        ripple.position = CGPoint(x: 134, y: 153)
        ripple.path = CGPath(ellipseIn: ripple.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ripple.fillColor = NSColor.clear.cgColor
        ripple.strokeColor = NSColor(calibratedRed: 0.68, green: 0.49, blue: 0.30, alpha: 0.65).cgColor
        ripple.lineWidth = 2; ripple.opacity = 0; scene.addSublayer(ripple)
        feedback.name = "woodfish.feedback"; feedback.string = "功德 +1"
        feedback.font = NSFont.systemFont(ofSize: 17, weight: .semibold); feedback.fontSize = 17
        feedback.foregroundColor = NSColor(calibratedRed: 0.29, green: 0.43, blue: 0.34, alpha: 1).cgColor
        feedback.alignmentMode = .center; feedback.bounds = CGRect(x: 0, y: 0, width: 110, height: 28)
        feedback.position = CGPoint(x: 65, y: 167); feedback.opacity = 0; scene.addSublayer(feedback)
    }

    /// 按钮只由代码构造，避免缺少分层图稿的归档状态。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// 使用向上的图稿坐标，使落槌、回弹和浮字方向一致。
    override var isFlipped: Bool { false }

    /// 图稿始终居中等比显示，文字与焦点环保留原生清晰度。
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        scene.position = CGPoint(x: bounds.midX, y: bounds.midY + 9)
        scene.setAffineTransform(CGAffineTransform(scaleX: 0.74, y: 0.74))
        feedback.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    /// 常驻提示不参与摇晃，键盘聚焦时显示明确的操作范围。
    override func draw(_ dirtyRect: NSRect) {
        let caption = "敲一下 · 放松一下" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        caption.draw(at: NSPoint(x: bounds.midX - caption.size(withAttributes: attributes).width / 2, y: 8), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8)
            focus.lineWidth = 2; focus.stroke()
        }
    }

    /// 落槌约150毫秒后才产生一次命中；回弹期间可从当前姿态继续敲击。
    func strike(onImpact: @escaping @MainActor @Sendable () -> Void) {
        guard impactTimer == nil else { return }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !reduced {
            let current = (mallet.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? Double(restingAngle)
            animate(mallet, key: "transform.rotation.z", values: [current, -Double.pi / 6, Double.pi / 45, -0.22, -0.55, Double(restingAngle)], times: [0, 0.10, 0.27, 0.38, 0.66, 1], duration: 0.56)
        }
        let timer = Timer(timeInterval: reduced ? 0.01 : 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.impactTimer = nil
                self.showImpact(reduced: reduced)
                onImpact()
            }
        }
        impactTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }

    /// 鱼身轻震、接触涟漪和浮字共用一次命中；减少动态效果时仅淡入文字。
    private func showImpact(reduced: Bool) {
        if !reduced {
            animate(body, key: "transform.scale.y", values: [1, 0.95, 1.02, 0.995, 1], times: [0, 0.12, 0.42, 0.7, 1], duration: 0.36)
            animate(body, key: "transform.rotation.z", values: [0, -0.025, 0.015, 0], times: [0, 0.15, 0.5, 1], duration: 0.32)
            animate(ripple, key: "transform.scale", values: [0.7, 1.8], times: [0, 1], duration: 0.34)
            animate(ripple, key: "opacity", values: [0, 0.65, 0], times: [0, 0.1, 1], duration: 0.34)
            animate(feedback, key: "transform.translation.y", values: [0, 28], times: [0, 1], duration: 0.65)
        }
        animate(feedback, key: "opacity", values: [0, 1, 1, 0], times: [0, 0.12, 0.45, 1], duration: 0.65)
    }

    /// 同一属性替换已有动画，不排队累积；结束后自动回到静止模型值。
    private func animate(_ target: CALayer, key: String, values: [Double], times: [Double], duration: TimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: key)
        animation.values = values; animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.duration = duration
        animation.calculationMode = .linear
        animation.timingFunctions = (1..<values.count).map { _ in CAMediaTimingFunction(name: .easeInEaseOut) }
        target.add(animation, forKey: key)
    }

    /// 关闭、切页或离开时取消未命中回调与所有画面反馈，防止后台补记功德。
    func cancelStrike() {
        impactTimer?.invalidate(); impactTimer = nil
        for part in [body, mallet, ripple, feedback] { part.removeAllAnimations() }
    }

    /// 从窗口移除也主动清理，测试窗口与正常面板遵守相同生命周期。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelStrike() }
        super.viewWillMove(toWindow: newWindow)
    }
}
