import AppKit
import NiumaCore

/// 使用语义颜色绘制轻量圆角卡片，随系统外观更新而无需背景动画。
@MainActor
private final class IncomePanelSurface: NSView {
    /// 收入卡片使用低饱和强调色，倒计时区域使用中性底色。
    let accented: Bool

    /// 创建普通原生容器，不添加图像缓存或额外刷新任务。
    init(accented: Bool) {
        self.accented = accented
        super.init(frame: .zero)
    }

    /// 卡片仅由代码创建。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// 根据当前外观即时解析系统颜色，避免固定 CGColor 在深色模式失效。
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        (accented ? NSColor.systemGreen.withAlphaComponent(0.065) : NSColor.controlBackgroundColor).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}

/// 展示紧凑的收入卡片与对齐的倒计时列表；隐藏后仍由应用释放视图。
@MainActor
final class IncomeViewController: NSViewController {
    /// 复用原生金额格式化器，避免每秒重复创建 ICU 状态。
    private static let moneyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()
    /// 用于把下一次工作边界显示成用户熟悉的本地时间。
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    /// 当前收入显示块，继续尊重用户的显示开关。
    private let currentSection = NSStackView()
    /// 月度汇总金额，保留正式版既有指标。
    private let monthAmount = NSTextField(labelWithString: "—")
    /// 月度指标块，可由原设置隐藏。
    private let monthSection = NSStackView()
    /// 年度指标块，可由原设置隐藏。
    private let yearSection = NSStackView()
    /// 收入卡片在所有指标关闭时整体隐藏。
    private var incomeCard: NSView?
    /// 面板宽度由收入视图统一定义，防止弹出容器与内容尺寸漂移。
    static let panelWidth: CGFloat = 340
    /// 主金额使用等宽数字，保证刷新时小数点位置稳定。
    private let amount = NSTextField(labelWithString: "—")
    /// 顶部工作状态，颜色随当前阶段改变。
    private let status = NSTextField(labelWithString: "尚未设置")
    /// 年度金额作为次要信息，保持标题在上、金额在下。
    private let yearAmount = NSTextField(labelWithString: "—")
    /// 用户可关闭的鼓励内容，位于操作区上方。
    private let quote = NSTextField(wrappingLabelWithString: "设置一下，看看时间值多少钱。")
    /// 顶部隐私入口，与金额隐藏状态共用持久化设置。
    private let privacy = NSButton()
    /// 所有内容按自然高度排布，取消旧面板的大块固定留白。
    private let content = NSStackView()
    /// 倒计时区域在没有启用事件时整体隐藏。
    private let countdownSection = NSStackView()
    /// 固定三条摘要行，不在每秒刷新时创建或销毁控件。
    private var countdownRows: [(row: NSStackView, title: NSTextField, value: NSTextField)] = []
    /// 列表分隔线按实际可见行数显示。
    private var countdownSeparators: [NSBox] = []
    /// 打开独立倒计时管理窗口。
    var onCountdowns: (() -> Void)?
    /// 打开工资和作息设置。
    var onSettings: (() -> Void)?
    /// 保存并切换金额隐私状态。
    var onPrivacy: (() -> Void)?

    /// 四页导航保留收入为默认入口，不改变倒计时及设置快捷键。
    private let navigation = PrototypeTabs()
    /// 打气内容只在面板存活期间创建，隐藏时解除自动木鱼任务。
    private let cheerContent = CheerContentView()
    /// 保存打气配置的应用级入口。
    var onSaveCheer: ((CheerPreferences) throws -> Void)?
    /// 页面切换后请求同步当前工资及打气投影。
    var onCheerPageChange: (() -> Void)?
    /// 功德由应用会话累加，不计入收入。
    var onStrike: (() -> Int)?

    /// 创建顶部工具栏、收入卡片、倒计时列表和底部操作区。
    override func loadView() {
        let background = IncomePanelBackgroundView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 380))
        view = background
        let contentView = background.contentView
        let icon = NSImageView(image: NSImage(contentsOf: ArtworkAsset.cow.url)!)
        icon.contentTintColor = .systemGreen
        icon.widthAnchor.constraint(equalToConstant: 17).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 17).isActive = true
        let brand = label(AppBuildChannel.current.displayName, size: 12, weight: .semibold)
        status.font = .systemFont(ofSize: 10, weight: .medium)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        privacy.image = NSImage(systemSymbolName: "eye", accessibilityDescription: "隐藏金额")
        privacy.isBordered = false
        privacy.imagePosition = .imageOnly
        privacy.target = self
        privacy.action = #selector(togglePrivacy)
        privacy.widthAnchor.constraint(equalToConstant: 26).isActive = true
        privacy.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let header = horizontal([icon, brand, NSView(), status, privacy], spacing: 7)

        amount.font = .monospacedDigitSystemFont(ofSize: 40, weight: .semibold)
        amount.textColor = .labelColor
        amount.lineBreakMode = .byTruncatingMiddle
        amount.setAccessibilityIdentifier("currentIncome")
        yearAmount.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        yearAmount.textColor = .labelColor
        yearAmount.lineBreakMode = .byTruncatingMiddle
        yearAmount.setAccessibilityIdentifier("yearToDateIncome")
        monthAmount.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        monthAmount.lineBreakMode = .byTruncatingMiddle
        monthAmount.setAccessibilityIdentifier("monthToDateIncome")
        for (section, title, value) in [(currentSection, "当前已赚", amount), (monthSection, "本月预估已赚", monthAmount), (yearSection, "本年预估已赚", yearAmount)] {
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 5
            let heading = label(title, size: section === currentSection ? 11 : 10, secondary: true)
            section.addArrangedSubview(heading)
            section.addArrangedSubview(value)
            value.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        let income = vertical([currentSection, monthSection, yearSection], spacing: 12)
        let incomeCard = card(income, accented: true, inset: 16)
        self.incomeCard = incomeCard

        let countdownList = vertical([], spacing: 0)
        for index in 0..<3 {
            let name = label("", size: 12)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            name.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let value = label("", size: 12, weight: .medium)
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            value.alignment = .right
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.required, for: .horizontal)
            let row = horizontal([name, value], spacing: 10)
            row.distribution = .fill
            row.heightAnchor.constraint(equalToConstant: 35).isActive = true
            value.widthAnchor.constraint(lessThanOrEqualTo: row.widthAnchor, multiplier: 0.72).isActive = true
            countdownRows.append((row, name, value))
            countdownList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: countdownList.widthAnchor).isActive = true
            if index < 2 {
                let line = separator()
                countdownSeparators.append(line)
                countdownList.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: countdownList.widthAnchor).isActive = true
            }
        }
        let clock = NSImageView(image: NSImage(systemSymbolName: "clock", accessibilityDescription: nil)!)
        clock.contentTintColor = .secondaryLabelColor
        clock.widthAnchor.constraint(equalToConstant: 12).isActive = true
        clock.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let countdownHeader = horizontal([clock, label("倒计时", size: 10, weight: .medium, secondary: true), NSView()], spacing: 5)
        countdownSection.orientation = .vertical
        countdownSection.alignment = .leading
        countdownSection.spacing = 7
        countdownSection.addArrangedSubview(countdownHeader)
        let countdownCard = card(countdownList, accented: false, inset: 12)
        countdownSection.addArrangedSubview(countdownCard)
        countdownCard.widthAnchor.constraint(equalTo: countdownSection.widthAnchor).isActive = true
        countdownSection.isHidden = true

        quote.font = .systemFont(ofSize: 10)
        quote.textColor = .secondaryLabelColor
        quote.alignment = .center
        quote.maximumNumberOfLines = 2
        let countdownButton = button("倒计时", symbol: "calendar.badge.clock", action: #selector(openCountdowns))
        let settings = button("设置", symbol: "slider.horizontal.3", action: #selector(openSettings))
        let quit = button("退出", symbol: "power", action: #selector(NSApplication.terminate(_:)))
        quit.target = NSApp
        let footer = horizontal([countdownButton, settings, NSView(), quit], spacing: 14)
        footer.heightAnchor.constraint(equalToConstant: 26).isActive = true

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        navigation.selectedSegment = 0
        navigation.target = self; navigation.action = #selector(changeCheerPage)
        navigation.setAccessibilityIdentifier("cheerNavigation")
        cheerContent.onSave = { [weak self] next in try self?.onSaveCheer?(next) }
        cheerContent.onNavigate = { [weak self] index in self?.selectCheerPage(index) }
        cheerContent.onStrike = { [weak self] in self?.onStrike?() ?? 0 }
        cheerContent.onResize = { [weak self] in
            guard let self else { return }
            self.resizePanel()
            if let window = self.view.window { window.setContentSize(self.preferredContentSize) }
        }
        for item in [header, navigation, incomeCard, countdownSection, quote, cheerContent, separator(), footer] {
            content.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        content.setCustomSpacing(8, after: quote)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            content.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -12)
        ])
        resizePanel()
    }

    /// 同步收入、状态与隐私展示，不增加计时器或修改计算口径。
    func render(_ snapshot: IncomeSnapshot, settings: WorkSettings?, error: String? = nil) {
        _ = view
        (view as? IncomePanelBackgroundView)?.apply(settings?.panelAppearance ?? PanelAppearanceSettings())
        currentSection.isHidden = settings?.showCurrentIncome == false
        monthSection.isHidden = settings?.showMonthlyIncome == false
        yearSection.isHidden = settings?.showYearlyIncome == false
        incomeCard?.isHidden = navigation.selectedSegment != 0 || (currentSection.isHidden && monthSection.isHidden && yearSection.isHidden)
        let hidden = settings?.hideAmounts == true
        amount.stringValue = hidden ? "••••" : Self.money(snapshot.amount)
        amount.font = .monospacedDigitSystemFont(ofSize: amount.stringValue.count > 13 ? 27 : 40, weight: .semibold)
        monthAmount.stringValue = hidden ? "••••" : Self.money(snapshot.monthToDateAmount)
        yearAmount.stringValue = hidden ? "••••" : Self.money(snapshot.yearToDateAmount)
        yearAmount.font = .monospacedDigitSystemFont(ofSize: yearAmount.stringValue.count > 17 ? 16 : 20, weight: .medium)
        status.stringValue = "● " + (error == nil ? statusText(for: snapshot) : "检查设置")
        status.textColor = error != nil ? .systemRed : snapshot.phase == .working ? .systemGreen : .secondaryLabelColor
        quote.stringValue = error ?? encouragement(for: snapshot)
        quote.isHidden = navigation.selectedSegment != 0 || (error == nil && settings?.encouragement == false)
        privacy.toolTip = hidden ? "显示金额" : "隐藏金额"
        privacy.setAccessibilityLabel(privacy.toolTip)
        privacy.image = NSImage(systemSymbolName: hidden ? "eye.slash" : "eye", accessibilityDescription: privacy.toolTip)
        resizePanel()
    }

    /// 只更新三条复用行的值，长标题截断后可通过悬停读取全文。
    func renderCountdowns(_ snapshots: [CountdownSnapshot]) {
        _ = view
        for (index, fields) in countdownRows.enumerated() {
            let snapshot = index < snapshots.count ? snapshots[index] : nil
            fields.row.isHidden = snapshot == nil
            let name = snapshot?.event.title ?? ""
            let value = snapshot?.detailText ?? ""
            if fields.title.stringValue != name { fields.title.stringValue = name }
            if fields.value.stringValue != value { fields.value.stringValue = value }
            fields.row.toolTip = snapshot.map { $0.event.title + "：" + $0.detailText }
            if index < countdownSeparators.count { countdownSeparators[index].isHidden = index + 1 >= min(3, snapshots.count) }
        }
        countdownSection.isHidden = navigation.selectedSegment != 0 || snapshots.isEmpty
        resizePanel()
    }

    /// 将已结算投影展示到同一个面板，隐私设置覆盖所有新增金额入口。
    func renderCheer(_ preferences: CheerPreferences, report: BreakReport?, hidden: Bool, phase: WorkPhase, away: Bool, merit: Int, error: String?) {
        _ = view
        cheerContent.render(preferences, report: report, hidden: hidden, phase: phase, away: away, merit: merit, error: error)
        resizePanel()
    }

    /// 通知点击与页面快捷入口走同一切换路径。
    func selectCheerPage(_ index: Int) {
        _ = view
        navigation.selectedSegment = index
        cheerContent.selectPage(index)
        onCheerPageChange?()
    }

    /// 面板关闭前显式停掉自动敲击，防止隐藏后台继续运行。
    func stopCheer() { cheerContent.stop() }

    /// 导航选择不新建窗口，保留现有失焦收起语义。
    @objc private func changeCheerPage() { selectCheerPage(navigation.selectedSegment) }

    /// 内容高度变化时才调整面板，避免秒级计时导致窗口反复布局。
    private func resizePanel() {
        view.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.panelWidth, height: ceil(content.fittingSize.height) + 26)
        guard preferredContentSize != size else { return }
        preferredContentSize = size
        view.setFrameSize(size)
    }

    /// 统一系统文字样式，动态颜色保持浅色与深色外观对比度。
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    /// 纵向内容保持自然高度，隐藏项不保留空行。
    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for item in views { item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    /// 横向标题和数值沿中心对齐，弹性空间交由原生布局分配。
    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    /// 卡片仅负责边距与背景，不引入单独刷新机制。
    private func card(_ contents: NSView, accented: Bool, inset: CGFloat) -> NSView {
        let surface = IncomePanelSurface(accented: accented)
        contents.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: inset),
            contents.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -inset),
            contents.topAnchor.constraint(equalTo: surface.topAnchor, constant: inset),
            contents.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -inset)
        ])
        return surface
    }

    /// 低对比分隔线表达分组，避免重复边框抢占金额注意力。
    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    /// 可操作按钮保持标准 target/action 和键盘焦点，图标只提供辅助识别。
    private func button(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    /// 打开倒计时配置。
    @objc private func openCountdowns() { onCountdowns?() }

    /// 在展示边界舍入人民币，不改变核心计算精度。
    static func money(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        return "¥" + (moneyFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "—")
    }

    /// 按现有工作状态选择鼓励内容，并说明下一次会发生什么。
    private func encouragement(for snapshot: IncomeSnapshot) -> String {
        switch snapshot.phase {
        case .unconfigured: return "设置一下，看看时间值多少钱。"
        case .before: return "还有 " + remainingText(to: snapshot.nextBoundary) + " 开始今天的班。"
        case .resting: return "休息一下，" + clockText(snapshot.nextBoundary) + " 继续计薪。"
        case .finished: return "今天的班结束了，辛苦了。"
        case .off:
            if let reason = snapshot.scheduleReason { return "今天是" + reason + "，好好休息。" }
            return "今天休息，好好生活。"
        case .working:
            if snapshot.progress >= 0.75 { return "今天的努力，正在慢慢兑现。" }
            if snapshot.progress >= 0.5 { return "每一秒，都在为生活攒一点底气。" }
            if snapshot.progress >= 0.25 { return "已经攒下了一点小小的底气。" }
            return "新的一班，慢慢攒下生活的底气。"
        }
    }

    /// 根据状态生成顶部短标签，让用户无需打开设置理解当前状态。
    private func statusText(for snapshot: IncomeSnapshot) -> String {
        switch snapshot.phase {
        case .unconfigured: return "尚未设置"
        case .before: return "未开始"
        case .working: return "上班中"
        case .resting: return "休息中"
        case .finished: return "已下班"
        case .off: return "休息日"
        }
    }

    /// 将未来边界转换成紧凑的小时和分钟文案。
    private func remainingText(to date: Date?) -> String {
        guard let date else { return "稍后" }
        let seconds = max(0, Int(date.timeIntervalSinceNow.rounded()))
        if seconds < 60 { return "不到 1 分钟" }
        let minutes = seconds / 60
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0 && remainder > 0 { return "\(hours) 小时 \(remainder) 分钟" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(remainder) 分钟"
    }

    /// 将边界时间显示为本地时钟时间；缺失时给出可理解的退化文案。
    private func clockText(_ date: Date?) -> String {
        guard let date else { return "稍后" }
        return Self.clockFormatter.string(from: date)
    }

    /// 工资和作息设置由应用管理生命周期。
    @objc private func openSettings() { onSettings?() }

    /// 由持久化层完成隐私切换，保存失败时保持原状态。
    @objc private func togglePrivacy() { onPrivacy?() }
}
