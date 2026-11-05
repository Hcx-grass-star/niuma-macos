import AppKit
import NiumaCore

/// 展示当前班次、本月和本年预估收入、工作状态和一句鼓励。
@MainActor
final class IncomeViewController: NSViewController {
    /// 主显示金额，使用等宽数字避免按秒刷新时跳动。
    private let amount = NSTextField(labelWithString: "—")
    /// 当前班次状态。
    private let status = NSTextField(labelWithString: "尚未设置")
    /// 本班预估说明，兼顾收入含义和隐私状态。
    private let estimate = NSTextField(labelWithString: "本班预估")
    /// 本月截至当前的预估金额，跨月班次只计本月区间。
    private let monthAmount = NSTextField(labelWithString: "—")
    /// 本年累计预估金额，按当前工资和排班规则回算。
    private let yearAmount = NSTextField(labelWithString: "—")
    /// 本年累计金额的说明文字。
    private let yearEstimate = NSTextField(labelWithString: "本年预估已赚")
    /// 提醒本年金额沿用当前配置，避免被误认为历史到账记录。
    private let yearBasis = NSTextField(labelWithString: "按当前工资和排班回算")
    /// 可关闭的上班鼓励文案。
    private let quote = NSTextField(wrappingLabelWithString: "设置一下，看看时间值多少钱。")
    /// 当前班次的金额、标题及说明作为整块控制显示。
    private let currentSection = NSStackView()
    /// 本月累计的金额与标题容器。
    private let monthSection = NSStackView()
    /// 本年累计的金额、标题与回算说明容器。
    private let yearSection = NSStackView()
    /// 收入面板主布局，用于根据可见内容计算紧凑高度。
    private let contentStack = NSStackView()
    /// 隐藏工资的入口与可访问性描述。
    private let privacy = NSButton()
    /// 负责打开工资作息设置的操作。
    var onSettings: (() -> Void)?
    /// 负责保存并切换金额隐私的操作。
    var onPrivacy: (() -> Void)?

    /// 创建接近已评审原型的原生弹出面板。
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 480))
        let brand = NSTextField(labelWithString: "牛马上班")
        brand.font = .systemFont(ofSize: 13, weight: .medium)
        let icon = NSImageView(image: NSImage(systemSymbolName: "leaf", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemGreen
        privacy.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "隐藏金额")
        privacy.bezelStyle = .inline
        privacy.target = self
        privacy.action = #selector(togglePrivacy)
        let header = NSStackView(views: [icon, brand, NSView(), privacy])
        header.orientation = .horizontal
        let title = NSTextField(labelWithString: "当前已赚")
        title.textColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13)
        amount.font = .monospacedDigitSystemFont(ofSize: 48, weight: .medium)
        amount.alignment = .center
        amount.lineBreakMode = .byTruncatingMiddle
        amount.setAccessibilityIdentifier("currentIncome")
        status.font = .systemFont(ofSize: 12, weight: .medium)
        status.textColor = .systemGreen
        estimate.font = .systemFont(ofSize: 11)
        estimate.textColor = .secondaryLabelColor
        monthAmount.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        monthAmount.alignment = .center
        monthAmount.lineBreakMode = .byTruncatingMiddle
        monthAmount.setAccessibilityIdentifier("monthToDateIncome")
        yearAmount.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        yearAmount.alignment = .center
        yearAmount.lineBreakMode = .byTruncatingMiddle
        yearAmount.setAccessibilityIdentifier("yearToDateIncome")
        yearEstimate.font = .systemFont(ofSize: 11)
        yearEstimate.textColor = .secondaryLabelColor
        yearBasis.font = .systemFont(ofSize: 11)
        yearBasis.textColor = .secondaryLabelColor
        quote.font = .systemFont(ofSize: 12)
        quote.textColor = .secondaryLabelColor
        quote.alignment = .center
        let settings = NSButton(title: "设置", target: self, action: #selector(openSettings))
        settings.bezelStyle = .inline
        let quit = NSButton(title: "退出", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .inline
        let footer = NSStackView(views: [NSView(), settings, quit])
        footer.orientation = .horizontal
        footer.spacing = 12
        let separator = NSBox()
        separator.boxType = .separator
        let monthTitle = NSTextField(labelWithString: "本月预估已赚")
        monthTitle.font = .systemFont(ofSize: 11)
        monthTitle.textColor = .secondaryLabelColor
        configureSection(currentSection, views: [title, amount, estimate], identifier: "currentIncomeSection")
        configureSection(monthSection, views: [monthAmount, monthTitle], identifier: "monthlyIncomeSection")
        configureSection(yearSection, views: [yearAmount, yearEstimate, yearBasis], identifier: "yearlyIncomeSection")
        let stack = contentStack
        for child in [header, spacer(13), status, spacer(8), currentSection, monthSection, yearSection,
                      spacer(14), quote, spacer(12), separator, footer] {
            stack.addArrangedSubview(child)
        }
        stack.detachesHiddenViews = true
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            currentSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            monthSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            yearSection.widthAnchor.constraint(equalTo: stack.widthAnchor),
            amount.widthAnchor.constraint(equalTo: currentSection.widthAnchor),
            yearAmount.widthAnchor.constraint(equalTo: yearSection.widthAnchor),
            monthAmount.widthAnchor.constraint(equalTo: monthSection.widthAnchor),
            quote.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor)
        ])
    }

    /// 同步展示当前、本月和本年预估金额，共用隐私开关，错误时不展示旧金额。
    func render(_ snapshot: IncomeSnapshot, settings: WorkSettings?, error: String? = nil) {
        // 读取 view 会按需触发 loadView；loadViewIfNeeded() 需 macOS 14，故不直接调用。
        _ = view
        let hidden = settings?.hideAmounts == true
        amount.stringValue = hidden ? "••••" : Self.money(snapshot.amount)
        amount.font = .monospacedDigitSystemFont(ofSize: amount.stringValue.count > 13 ? 30 : 48, weight: .medium)
        monthAmount.stringValue = hidden ? "••••" : Self.money(snapshot.monthToDateAmount)
        monthAmount.font = .monospacedDigitSystemFont(ofSize: monthAmount.stringValue.count > 13 ? 18 : 22, weight: .medium)
        yearAmount.stringValue = hidden ? "••••" : Self.money(snapshot.yearToDateAmount)
        yearAmount.font = .monospacedDigitSystemFont(ofSize: yearAmount.stringValue.count > 13 ? 18 : 22, weight: .medium)
        let labels: [WorkPhase: String] = [
            .unconfigured: "尚未设置", .before: "尚未上班", .working: "上班中",
            .resting: "休息中", .finished: "本班已结束", .off: "休息日"
        ]
        status.stringValue = error == nil ? labels[snapshot.phase]! : "需要检查设置"
        if error == nil, settings?.chinaHolidayEnabled == true,
           let reason = snapshot.scheduleReason, ["节假日休息", "调休上班"].contains(reason) {
            status.stringValue += " · " + reason
        }
        status.toolTip = snapshot.scheduleReason
        currentSection.isHidden = settings?.showCurrentIncome == false
        monthSection.isHidden = settings?.showMonthlyIncome == false
        yearSection.isHidden = settings?.showYearlyIncome == false
        quote.stringValue = error ?? encouragement(for: snapshot)
        quote.isHidden = error == nil && settings?.encouragement == false
        privacy.toolTip = hidden ? "显示金额" : "隐藏金额"
        privacy.setAccessibilityLabel(hidden ? "显示金额" : "隐藏金额")
        privacy.image = NSImage(systemSymbolName: hidden ? "eye.slash" : "eye", accessibilityDescription: privacy.toolTip)
        let size = NSSize(width: 360, height: max(180, contentStack.fittingSize.height + 34))
        preferredContentSize = size
        view.setFrameSize(size)
    }

    /// 将金额和说明组成可整体收起的区域，避免隐藏金额后留下对应标题和空白。
    private func configureSection(_ section: NSStackView, views: [NSView], identifier: String) {
        section.orientation = .vertical
        section.alignment = .centerX
        section.spacing = 7
        section.setAccessibilityIdentifier(identifier)
        for child in views { section.addArrangedSubview(child) }
    }

    /// 仅在展示边界舍入人民币金额，不改变内部计算精度。
    static func money(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        formatter.locale = Locale(identifier: "zh_CN")
        return "¥" + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—")
    }

    /// 按当前状态和已达到的节点选取一条文案，不补播历史节点。
    private func encouragement(for snapshot: IncomeSnapshot) -> String {
        switch snapshot.phase {
        case .unconfigured: return "设置一下，看看时间值多少钱。"
        case .before: return "慢慢来，今天也会有收获。"
        case .resting: return "休息一下，生活也需要留白。"
        case .finished: return "今天的努力，已经攒起来了。"
        case .off: return "好好生活，也是一件正经事。"
        case .working:
            if snapshot.progress >= 0.75 { return "今天的努力，正在慢慢兑现。" }
            if snapshot.progress >= 0.5 { return "每一秒，都在为生活攒一点底气。" }
            if snapshot.progress >= 0.25 { return "已经攒下了一点小小的底气。" }
            return "新的一班，慢慢攒下生活的底气。"
        }
    }

    /// 创建受约束的留白，保持收入面板的内容层级。
    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    /// 将设置入口交给应用生命周期统一处理。
    @objc private func openSettings() { onSettings?() }

    /// 将隐私切换交给持久化层处理，失败不假装已经保存。
    @objc private func togglePrivacy() { onPrivacy?() }
}
