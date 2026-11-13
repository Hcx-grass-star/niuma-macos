import AppKit
import NiumaCore

/// 按需展示战报、愿望及木鱼；不持有正式配置文件或后台常驻计时器。
@MainActor
final class CheerContentView: NSStackView {
    /// 保存配置由应用委托原子完成，失败通过面板显示。
    var onSave: ((CheerPreferences) throws -> Void)?
    /// 首页快捷入口复用同一个面板切页。
    var onNavigate: ((Int) -> Void)?
    /// 功德由应用会话持有，关闭面板不丢失也不写盘。
    var onStrike: (() -> Int)?
    /// 请求面板根据当前内容重新布局。
    var onResize: (() -> Void)?
    /// 当前页面：0收入，1战报，2愿望，3木鱼。
    private(set) var page = 0
    /// 当前可显示的累计投影，编辑保存前由委托重新结算。
    private var preferences = CheerPreferences()
    /// 最近一条战报仅驻留本次应用会话。
    private var report: BreakReport?
    /// 所有收入衍生数据服从同一个隐私开关。
    private var hiddenAmounts = false
    /// 工作状态控制自动敲击，不影响手动交互。
    private var working = false
    /// 离开期间立即停止自动敲击。
    private var away = false
    /// 结构改变时才重建，收入跳动只更新文本和进度。
    private var structure = ""
    /// 复用愿望的金额、进度与状态控件。
    private var wishFields: [(CheerWish, NSTextField, CheerProgressView, NSTextField)] = []
    /// 首页使用原型的横向愿望摘要，秒级更新不重建卡片。
    private var homeWish: HomeWishButton?
    /// 复用战报的金额正文。
    private var reportAmount: NSTextField?
    /// 编辑页优先保留输入，秒级收入刷新不覆盖草稿。
    private var editing = false
    /// 被编辑的身份，nil表示新增。
    private var editingID: String?
    /// 名称输入框，隐藏金额时不创建编辑界面。
    private let nameInput = NSTextField()
    /// 目标金额使用原始文本严格解析。
    private let targetInput = NSTextField()
    /// 已有预算输入与真实账户无关。
    private let seedInput = NSTextField()
    /// 行内错误不关闭面板，保留恢复入口。
    private let message = NSTextField(wrappingLabelWithString: "")
    /// 自动敲击的唯一句柄，切页或关闭时销毁。
    private var woodTimer: Timer?
    /// 木鱼命中按钮遵循原生键盘操作。
    private var woodButton: WoodfishButton?
    /// 本次功德数字不与收入混合。
    private var meritLabel: NSTextField?
    /// 自动模式暂停原因在当前页可见。
    private var woodHint: NSTextField?
    /// 当前功德由委托在刷新时同步。
    private var merit = 0

    /// 创建无后台任务的纵向内容区。
    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        message.font = .systemFont(ofSize: 11); message.textColor = .systemRed
    }
    /// 面板只通过代码构造。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// 更新数据并保留输入草稿；只在结构或页面变化时重建控件。
    func render(_ value: CheerPreferences, report: BreakReport?, hidden: Bool, phase: WorkPhase, away: Bool, merit: Int, error: String?) {
        preferences = value; self.report = report; hiddenAmounts = hidden
        working = phase == .working; self.away = away; self.merit = merit
        if hidden && editing { editing = false; structure = "" }
        let key = "\(page)|\(hidden)|\(value.reportsEnabled)|\(value.notificationsEnabled)|\(value.autoWood)|\(value.sound)|\(value.wishes)|\(String(describing: report))|\(error ?? "")"
        if !editing && key != structure { structure = key; build() }
        if !editing {
            if let homeWish {
                if let wish = value.wishes.first {
                    let total = value.total(for: wish)
                    homeWish.update(name: wish.name, detail: hidden ? "愿望进度已隐藏" : IncomeViewController.money(total) + " / " + IncomeViewController.money(wish.target),
                        progress: hidden ? 0 : NSDecimalNumber(decimal: total / wish.target).doubleValue)
                } else { homeWish.update(name: nil, detail: "添加第一个愿望", progress: 0) }
            }
            for (wish, amount, progress, status) in wishFields {
                let total = value.total(for: wish)
                amount.stringValue = hidden ? "•••• / ••••" : IncomeViewController.money(total) + " / " + IncomeViewController.money(wish.target)
                progress.doubleValue = hidden ? 0 : min(100, NSDecimalNumber(decimal: total / wish.target * 100).doubleValue)
                status.stringValue = hidden ? "进度已隐藏" : total >= wish.target ? "已达成 ✓ · 奖励由你决定" : "还差 " + IncomeViewController.money(wish.target - total)
            }
            reportAmount?.stringValue = hidden ? "••••" : report.map { "+" + IncomeViewController.money($0.amount) } ?? "—"
            if let error { message.stringValue = error }
        }
        meritLabel?.stringValue = String(merit)
        syncWood()
    }

    /// 切换页面丢弃未保存草稿，已有配置由委托持有。
    func selectPage(_ index: Int) {
        page = index; editing = false; structure = ""; build(); syncWood(); onResize?()
    }

    /// 关闭前主动解除调度，不依赖计时器自动释放。
    func stop() {
        woodTimer?.invalidate(); woodTimer = nil
        woodButton?.cancelStrike()
    }

    /// 删除旧布局控件与错误展示，后续只构造当前页所需内容。
    private func clearBody() {
        stop()
        for child in arrangedSubviews { removeArrangedSubview(child); child.removeFromSuperview() }
        wishFields = []; homeWish = nil; reportAmount = nil; woodButton = nil; meritLabel = nil; woodHint = nil
    }

    /// 当前页的结构性渲染；每秒只更新已有控件。
    private func build() {
        clearBody()
        message.stringValue = ""
        switch page {
        case 0:
            let heading = text("我的小盼头", size: 11); heading.textColor = PrototypeColors.ink
            let manage = HomeManageButton(title: "管理愿望 ↗", target: self, action: #selector(openWishes))
            let header = NSStackView(views: [heading, NSView(), manage]); header.spacing = 8
            add(header)
            let preview = HomeWishButton(title: "我的小盼头", target: self, action: #selector(openWishes))
            preview.setAccessibilityIdentifier("homeWishPreview"); homeWish = preview; add(preview)
            setCustomSpacing(21, after: preview)
            let charge = text("给自己充个电", size: 11); charge.textColor = PrototypeColors.ink; add(charge)
            let shortcuts = NSStackView(views: [
                HomeShortcutButton(destination: .report, target: self, action: #selector(openReports)),
                HomeShortcutButton(destination: .woodfish, target: self, action: #selector(openWood))
            ])
            shortcuts.distribution = .fillEqually; shortcuts.spacing = 12; add(shortcuts)
        case 1:
            add(text("人歇歇，钱没歇。", size: 19, bold: true))
            if let report {
                add(text("欢迎回来，辛苦了。", size: 12))
                let amount = text("", size: 32, bold: true); amount.setAccessibilityIdentifier("breakReportAmount")
                reportAmount = amount; add(amount)
                let minutes = Int(report.end.timeIntervalSince(report.start) / 60)
                add(note("离开 \(minutes) 分钟 · 计薪 \(Int(report.paidSeconds / 60)) 分钟"))
            } else { add(note("开启后，离开屏幕满 2 分钟且存在计薪收入，返回即可收一份小战报。")) }
            add(note("仅计算离开期间的预估收入，不代表额外工资，也不判断你是否在工作。"))
            add(toggle("返回时生成战报", checked: preferences.reportsEnabled, selector: #selector(toggleReports)))
            add(toggle("通过系统通知提醒查看（不含金额）", checked: preferences.notificationsEnabled, selector: #selector(toggleNotifications)))
            add(note("通知权限被拒绝或专注模式开启时，仍可在此查看最近战报。"))
        case 2:
            let heading = text("努力有了具体的样子。", size: 17, bold: true)
            let plus = action("＋", selector: #selector(newWish))
            plus.widthAnchor.constraint(equalToConstant: 28).isActive = true
            let header = NSStackView(views: [heading, plus]); header.spacing = 6
            heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
            add(header)
            if preferences.wishes.isEmpty { add(note("先放一个小愿望在这里吧。")) }
            for wish in preferences.wishes { addWish(wish) }
        default:
            add(text("功德 +1，班味 −1。", size: 19, bold: true))
            add(note("敲一下，给自己一点松弛感。"))
            let button = WoodfishButton(title: "敲木鱼", target: self, action: #selector(strike))
            button.setAccessibilityIdentifier("woodfishButton")
            button.heightAnchor.constraint(equalToConstant: 190).isActive = true
            woodButton = button; add(button)
            let count = text(String(merit), size: 28, bold: true)
            count.setAccessibilityIdentifier("woodfishMerit"); meritLabel = count
            add(row([text("本次功德", size: 11, secondary: true), count]))
            let hint = note(""); woodHint = hint; add(hint)
            add(toggle("上班自动敲", checked: preferences.autoWood, selector: #selector(toggleAuto)))
            add(toggle("木鱼音效（默认静音）", checked: preferences.sound, selector: #selector(toggleSound)))
            add(note("功德只是一点趣味，不影响工资。"))
        }
        add(message)
        onResize?()
    }

    /// 愿望管理页展示独立愿望的金额、进度和编辑删除动作。
    private func addWish(_ wish: CheerWish) {
        add(text("✦ " + wish.name, size: 13, bold: true))
        let amount = text("", size: 12)
        amount.setAccessibilityIdentifier("wishAmount-" + wish.id); add(amount)
        let progress = CheerProgressView()
        progress.heightAnchor.constraint(equalToConstant: 5).isActive = true; add(progress)
        let status = text("", size: 11, secondary: true); add(status)
        wishFields.append((wish, amount, progress, status))
        let edit = action("编辑", selector: #selector(editWish(_:))); edit.identifier = NSUserInterfaceItemIdentifier(wish.id)
        let delete = action("删除", selector: #selector(deleteWish(_:))); delete.identifier = edit.identifier
        add(row([edit, delete]))
    }

    /// 展示行内编辑器，避免另开窗口导致菜单栏面板失焦关闭。
    private func edit(_ wish: CheerWish?) {
        guard !hiddenAmounts else { message.stringValue = "请先显示金额，再添加或编辑愿望。"; return }
        guard wish != nil || preferences.wishes.count < 3 else { message.stringValue = "最多添加 3 个愿望。"; return }
        editing = true; editingID = wish?.id; clearBody()
        add(text(wish == nil ? "添加一个小盼头" : "编辑这个小盼头", size: 17, bold: true))
        nameInput.stringValue = wish?.name ?? ""
        targetInput.stringValue = wish.map { NSDecimalNumber(decimal: $0.target).stringValue } ?? ""
        seedInput.stringValue = wish.map { NSDecimalNumber(decimal: $0.seed).stringValue } ?? "0"
        for (title, input) in [("愿望名称（1–20字）", nameInput), ("目标金额（元）", targetInput), ("已有金额（元）", seedInput)] {
            add(text(title, size: 11, secondary: true)); add(input)
        }
        nameInput.setAccessibilityIdentifier("wishNameInput"); targetInput.setAccessibilityIdentifier("wishTargetInput"); seedInput.setAccessibilityIdentifier("wishSeedInput")
        add(note("新建从保存时开始累计；编辑保留原来的累计起点。"))
        add(row([action("保存愿望", selector: #selector(saveWish)), action("取消", selector: #selector(cancelEdit))]))
        message.stringValue = ""; add(message); onResize?(); window?.makeFirstResponder(nameInput)
    }

    /// 表单严格解析后交由存储层校验，失败保留输入并显示原因。
    @objc private func saveWish() {
        let name = nameInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[0-9]+(?:\.[0-9]{1,2})?$"#
        guard targetInput.stringValue.range(of: pattern, options: .regularExpression) != nil,
              seedInput.stringValue.range(of: pattern, options: .regularExpression) != nil,
              let target = Decimal(string: targetInput.stringValue, locale: Locale(identifier: "en_US_POSIX")),
              let seed = Decimal(string: seedInput.stringValue, locale: Locale(identifier: "en_US_POSIX")) else {
            message.stringValue = "请填写有效金额，最多两位小数。"; return
        }
        var next = preferences
        if let index = next.wishes.firstIndex(where: { $0.id == editingID }) {
            next.wishes[index].name = name; next.wishes[index].target = target; next.wishes[index].seed = seed
        } else { next.wishes.append(CheerWish(name: name, target: target, seed: seed, baseline: next.earned)) }
        do { try next.validate(); try onSave?(next); editing = false; structure = ""; onNavigate?(2) }
        catch { message.stringValue = error.localizedDescription }
    }

    /// 删除先在同面板显示确认，防止失焦窗口导致误操作。
    @objc private func deleteWish(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        editing = true; editingID = id; clearBody()
        add(text("删除这个愿望？", size: 17, bold: true))
        add(note("仅移除这个预估目标，工资和其他愿望不受影响。"))
        add(row([action("确认删除", selector: #selector(confirmDelete)), action("取消", selector: #selector(cancelEdit))]))
        add(message); onResize?()
    }
    /// 确认后只移除所选愿望，保存失败保留恢复入口。
    @objc private func confirmDelete() {
        var next = preferences; next.wishes.removeAll { $0.id == editingID }
        do { try onSave?(next); editing = false; structure = ""; onNavigate?(2) }
        catch { message.stringValue = error.localizedDescription }
    }
    /// 放弃当前草稿并恢复愿望列表。
    @objc private func cancelEdit() { editing = false; structure = ""; onNavigate?(2) }
    /// 通过按钮标识定位愿望，避免靠显示名称删除或编辑。
    @objc private func editWish(_ sender: NSButton) { edit(preferences.wishes.first { $0.id == sender.identifier?.rawValue }) }
    /// 首次愿望不预置示例价格。
    @objc private func newWish() { edit(nil) }
    /// 首页快捷入口切到愿望页。
    @objc private func openWishes() { onNavigate?(2) }
    /// 首页快捷入口切到最近战报。
    @objc private func openReports() { onNavigate?(1) }
    /// 首页快捷入口切到木鱼页。
    @objc private func openWood() { onNavigate?(3) }

    /// 保存开关失败时重建旧状态，避免控件显示未持久化的值。
    private func change(_ mutation: (inout CheerPreferences) -> Void) {
        var next = preferences; mutation(&next)
        do { try onSave?(next) }
        catch { structure = ""; build(); message.stringValue = error.localizedDescription }
    }
    /// 战报主动开启后委托再请求系统通知权限。
    @objc private func toggleReports() { change { $0.reportsEnabled.toggle() } }
    /// 通知关闭不删除面板战报。
    @objc private func toggleNotifications() { change { $0.notificationsEnabled.toggle() } }
    /// 自动敲击不在背景持续运行。
    @objc private func toggleAuto() { change { $0.autoWood.toggle() } }
    /// 音效必须由用户显式启用。
    @objc private func toggleSound() { change { $0.sound.toggle() } }

    /// 可见性、工作状态和离开状态共同控制唯一调度句柄。
    private func syncWood() {
        let active = WoodfishPolicy.shouldAutoStrike(enabled: preferences.autoWood, working: working,
            visible: page == 3 && window?.isVisible == true, away: away)
        if active && woodTimer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.strike() }
            }
            RunLoop.main.add(timer, forMode: .common); woodTimer = timer
        } else if !active && woodTimer != nil { stop() }
        if away { woodButton?.cancelStrike() }
        woodHint?.stringValue = active ? "自动敲击中 · 每 1.5 秒一下" : preferences.autoWood ? "自动已暂停 · 工作中展开本页恢复" : "点击或聚焦木鱼后按空格敲击"
    }
    /// 木槌接触时结算一次功德与音效，离开页面前取消的落槌不计数。
    @objc private func strike() {
        woodButton?.strike { [weak self] in
            guard let self else { return }
            merit = onStrike?() ?? (merit + 1); meritLabel?.stringValue = String(merit)
            if preferences.sound { NSSound(named: "Pop")?.play() }
        }
    }

    /// 原生文本遵循系统外观，长文案自动换行。
    private func text(_ value: String, size: CGFloat, bold: Bool = false, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value); field.font = .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor; return field
    }
    /// 辅助说明保持可读行高，不承担按钮交互。
    private func note(_ value: String) -> NSTextField { text(value, size: 11, secondary: true) }
    /// 统一内容宽度，隐藏或移除时自动释放布局。
    private func add(_ child: NSView) {
        addArrangedSubview(child); child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    /// 原生按钮自带键盘和辅助功能支持。
    private func action(_ title: String, selector: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector); button.bezelStyle = .rounded; button.controlSize = .small; return button
    }
    /// 开关跟随真实持久化状态，文字不带工资。
    private func toggle(_ title: String, checked: Bool, selector: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: selector); button.state = checked ? .on : .off
        button.font = .systemFont(ofSize: 11); return button
    }
    /// 水平操作组均匀排布，不增加额外容器背景。
    private func row(_ children: [NSView]) -> NSStackView {
        let row = NSStackView(views: children); row.distribution = .fillEqually; row.spacing = 8; return row
    }
}

/// 轻量愿望进度条沿用收入卡片的绿色，不受系统默认蓝色强调色影响。
@MainActor
private final class CheerProgressView: NSView {
    /// 展示值限制在0至100；隐私模式由调用方传入0，辅助功能也不保留原值。
    var doubleValue: Double = 0 {
        didSet { needsDisplay = true; setAccessibilityValue(NSNumber(value: doubleValue)) }
    }
    /// 提供有名称的进度角色，不加载动画或额外渲染资源。
    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator); setAccessibilityLabel("愿望进度")
    }
    /// 进度条只由原生布局创建。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    /// 使用系统动态颜色绘制静态数值标记，进度变化无需后台动画。
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2.5, yRadius: 2.5).fill()
        guard doubleValue > 0 else { return }
        NSColor.systemGreen.setFill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * min(100, max(0, doubleValue)) / 100, height: bounds.height)
        NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
    }
}
