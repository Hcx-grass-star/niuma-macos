import AppKit
import NiumaCore

/// 从顶部开始显示长表单，新增多条时仍能找到菜单栏设置。
@MainActor
private final class CountdownDocument: NSView {
    /// 让 NSScrollView 的起点与表单阅读顺序一致。
    override var isFlipped: Bool { true }
}

/// 一行事件草稿，仅在用户保存时写入配置。
@MainActor
private struct CountdownRow {
    /// 原事件用于保留稳定标识。
    let event: CountdownEvent
    /// 用户自定义标题。
    let title: NSTextField
    /// 控制是否在面板和主倒计时选择中出现。
    let enabled: NSButton
    /// 目标规则选择。
    let type: NSPopUpButton
    /// 固定事件的本地日期时间。
    let date: NSDatePicker
}
/// 独立管理倒计时与菜单栏布局，不要求先输入工资。
@MainActor
final class CountdownWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// 已保存配置作为编辑草稿的初值。
    private let original: CountdownPreferences
    /// 旧工资菜单开关仅用于兼容显示初始状态。
    private let legacyIncome: Bool
    /// 保存成功后由应用重新调度。
    private let onSave: (CountdownPreferences) throws -> Void
    /// 窗口关闭时释放全部编辑器。
    var onClose: (() -> Void)?
    /// 有界事件编辑行。
    private var rows: [CountdownRow] = []
    /// 可滚动的事件容器。
    private let list = NSStackView()
    /// 添加预设只提供初始标题，保存后可自由修改。
    private let preset = NSPopUpButton()
    /// 菜单栏显示的四种组合。
    private let mode = NSPopUpButton()
    /// 用户选择的主事件。
    private let primary = NSPopUpButton()
    /// 自动和几个固定宽度档位。
    private let widthMode = NSPopUpButton()
    /// 自定义总宽度，以 pt 为单位。
    private let width = NSTextField(string: "120")
    /// 保存失败保留输入，提供可见原因。
    private let error = NSTextField(wrappingLabelWithString: "")
    /// 本地预览宽度，避免用户反复保存试验。
    private let preview = NSTextField(labelWithString: "菜单栏宽度包含图标；窄宽度优先显示时间。")

    /// 创建一个可关闭的滚动窗口，所有更改保存前均为草稿。
    init(preferences: CountdownPreferences, legacyIncome: Bool, onSave: @escaping (CountdownPreferences) throws -> Void) {
        original = preferences; self.legacyIncome = legacyIncome; self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "牛马上班 · 倒计时与菜单栏"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildForm()
        window.center()
    }
    /// 不支持从归档创建依赖不完整的窗口。
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    /// 关闭时移除对编辑器的引用。
    func windowWillClose(_ notification: Notification) { onClose?() }
    /// 创建简单表单，复用系统原生输入与日期选择器。
    private func buildForm() {
        guard let window else { return }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = true; scroll.autoresizingMask = [.width, .height]
        window.contentView = scroll
        let container = CountdownDocument()
        container.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = container
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -22)
        ])
        let heading = NSTextField(labelWithString: "倒计时与菜单栏")
        heading.font = .systemFont(ofSize: 21, weight: .medium)
        stack.addArrangedSubview(heading)
        let hint = NSTextField(wrappingLabelWithString: "离职、放假或任何期待的事。固定事件可独立使用；下班倒计时沿用已保存的每周作息。")
        hint.textColor = .secondaryLabelColor; hint.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(hint)
        mode.addItems(withTitles: ["仅图标", "当前收入", "主倒计时", "收入与主倒计时"])
        let modes: [MenuBarMode] = [.icon, .income, .countdown, .both]
        mode.selectItem(at: modes.firstIndex(of: original.menuMode ?? (legacyIncome ? .income : .icon))!)
        stack.addArrangedSubview(horizontal([NSTextField(labelWithString: "显示内容"), mode]))
        stack.addArrangedSubview(horizontal([NSTextField(labelWithString: "主倒计时"), primary]))
        widthMode.addItems(withTitles: ["自动", "窄 80 pt", "标准 120 pt", "宽 180 pt", "自定义"])
        let widths: [Double?] = [nil, 80, 120, 180]
        widthMode.selectItem(at: widths.firstIndex(of: original.menuWidth) ?? 4)
        width.stringValue = String(Int(original.menuWidth ?? 120))
        width.widthAnchor.constraint(equalToConstant: 64).isActive = true
        widthMode.target = self; widthMode.action = #selector(changeWidth)
        stack.addArrangedSubview(horizontal([NSTextField(labelWithString: "总宽度"), widthMode, width, NSTextField(labelWithString: "pt（60–240）")]))
        preview.font = .systemFont(ofSize: 11); preview.textColor = .secondaryLabelColor
        stack.addArrangedSubview(preview)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 12
        stack.addArrangedSubview(list)
        list.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for event in original.events { rows.append(makeRow(event)) }
        preset.addItems(withTitles: ["离职", "放假", "自定义", "下班"])
        stack.addArrangedSubview(horizontal([preset, NSButton(title: "添加倒计时", target: self, action: #selector(add))]))
        error.textColor = .systemRed; error.preferredMaxLayoutWidth = 460
        stack.addArrangedSubview(error)
        stack.addArrangedSubview(horizontal([NSButton(title: "保存", target: self, action: #selector(save)), NSButton(title: "取消", target: self, action: #selector(cancel))]))
        rebuild(); changeWidth()
    }
    /// 横向对齐表单控件。
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY
        return stack
    }
    /// 编辑行使用系统日期控件，避免自行解析日期字符串。
    private func makeRow(_ event: CountdownEvent) -> CountdownRow {
        let title = NSTextField(string: event.title); title.delegate = self; title.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let enabled = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(updatePrimary))
        enabled.state = event.enabled ? .on : .off
        let type = NSPopUpButton(); type.addItems(withTitles: ["指定时间", "下一次下班"])
        type.selectItem(at: event.type == .fixed ? 0 : 1); type.target = self; type.action = #selector(changeType)
        let date = NSDatePicker(); date.datePickerElements = [.yearMonthDay, .hourMinute]; date.datePickerStyle = .textFieldAndStepper
        date.dateValue = event.targetAt ?? Date().addingTimeInterval(86400); date.isHidden = event.type == .nextWorkEnd
        return CountdownRow(event: event, title: title, enabled: enabled, type: type, date: date)
    }
    /// 重建结构时保留现有输入控件，不丢失草稿。
    private func rebuild() {
        for view in list.arrangedSubviews { list.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            let remove = NSButton(title: "删除", target: self, action: #selector(remove(_:))); remove.tag = index
            let block = NSStackView(views: [horizontal([row.enabled, row.title, remove]), horizontal([row.type, row.date])])
            block.orientation = .vertical; block.alignment = .leading; block.spacing = 6
            list.addArrangedSubview(block)
        }
        updatePrimary()
    }
    /// 主倒计时选择只包含启用事件，并按标识保留选择。
    @objc private func updatePrimary() {
        let selected = primary.numberOfItems == 0 ? original.menuCountdownID : primary.selectedItem?.representedObject as? String
        primary.removeAllItems(); primary.addItem(withTitle: "自动选择最近事件")
        for row in rows where row.enabled.state == .on {
            primary.addItem(withTitle: row.title.stringValue)
            primary.lastItem?.representedObject = row.event.id
            if row.event.id == selected { primary.select(primary.lastItem) }
        }
    }
    /// 标题修改后同步主事件选项，并保留当前选择。
    func controlTextDidChange(_ notification: Notification) { updatePrimary() }

    /// 规则切换时隐藏无关的固定日期输入。
    @objc private func changeType() { for row in rows { row.date.isHidden = row.type.indexOfSelectedItem == 1 } }
    /// 自定义输入仅在对应档位可编辑。
    @objc private func changeWidth() { width.isEnabled = widthMode.indexOfSelectedItem == 4 }
    /// 快捷预设只决定初始标题与规则。
    @objc private func add() {
        guard rows.count < 20 else { error.stringValue = "最多添加 20 条倒计时。"; return }
        rows.append(makeRow(CountdownEvent(title: preset.titleOfSelectedItem ?? "自定义", type: preset.indexOfSelectedItem == 3 ? .nextWorkEnd : .fixed, targetAt: Date().addingTimeInterval(86400))))
        rebuild()
    }
    /// 只移除选中的本地草稿，保存后才生效。
    @objc private func remove(_ sender: NSButton) { rows.remove(at: sender.tag); rebuild() }
    /// 校验与原子保存完成后关闭，失败保留草稿。
    @objc private func save() {
        var next = original
        next.events = rows.map { CountdownEvent(id: $0.event.id, title: $0.title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), type: $0.type.indexOfSelectedItem == 0 ? .fixed : .nextWorkEnd, targetAt: $0.date.dateValue, enabled: $0.enabled.state == .on) }
        next.menuMode = [MenuBarMode.icon, .income, .countdown, .both][mode.indexOfSelectedItem]
        next.menuCountdownID = primary.selectedItem?.representedObject as? String
        let widths: [Double?] = [nil, 80, 120, 180]
        if widthMode.indexOfSelectedItem == 4 {
            guard let value = Double(width.stringValue) else { error.stringValue = "请输入有效宽度。"; return }
            next.menuWidth = value
        } else { next.menuWidth = widths[widthMode.indexOfSelectedItem] }
        do { try onSave(next); close() } catch { self.error.stringValue = error.localizedDescription }
    }
    /// 放弃未保存的事件和布局更改。
    @objc private func cancel() { close() }
}
