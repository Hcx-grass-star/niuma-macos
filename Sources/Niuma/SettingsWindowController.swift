import AppKit
import ServiceManagement
import NiumaCore

/// 设置页的文档视图从顶部开始排布，适配较短屏幕的滚动。
@MainActor
private final class FormDocument: NSView {
    /// 使用符合表单阅读顺序的自上而下坐标系。
    override var isFlipped: Bool { true }
}

/// 一条可编辑的非计薪休息行。
@MainActor
private struct RestRow {
    /// 本地休息开始时刻的输入框。
    let start: NSTextField
    /// 本地休息结束时刻的输入框。
    let end: NSTextField
}

/// 编辑工资及作息草稿，保存失败时保留输入且不改变当前收入。
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    /// 打开窗口时的已保存设置，作为草稿初始值。
    private let original: WorkSettings
    /// 应用专属配置路径，供用户清理时准确定位。
    private let dataPath: String
    /// 成功保存后由应用统一刷新菜单栏与收入面板。
    private let onSave: (WorkSettings) throws -> Void
    /// 用户确认后由应用先关闭自动启动，再清理配置。
    private let onReset: () throws -> Void
    /// 与工资草稿独立的版本检查服务。
    private let updates: UpdateController
    /// 窗口关闭时释放表单，降低后台常驻内存。
    var onClose: (() -> Void)?
    /// 打开独立倒计时与菜单栏宽度配置，保留工资草稿。
    var onCountdowns: (() -> Void)?
    /// 月薪或日薪选择。
    private let payMode = NSPopUpButton()
    /// 工资输入，根据隐私状态选用普通或安全文本框。
    private let salary: NSTextField
    /// 直接说明当前工资输入口径。
    private let salaryLabel = NSTextField(labelWithString: "每月工资（元）")
    /// 每周哪些日期开始一个班次。
    private var weekdays: [(Int, NSButton)] = []
    /// 是否启用内置中国大陆节假日及调休覆盖。
    private let chinaHoliday = NSButton(checkboxWithTitle: "按中国大陆节假日及调休安排", target: nil, action: nil)
    /// 年度数据覆盖范围及缺失年份回退说明。
    private let chinaHolidayStatus = NSTextField(wrappingLabelWithString: "")
    /// 班次开始时间输入。
    private let start = NSTextField(string: "09:00")
    /// 班次结束时间输入。
    private let end = NSTextField(string: "18:00")
    /// 月薪折算策略选择。
    private let divisorMode = NSPopUpButton()
    /// 固定折算天数输入。
    private let fixedDays = NSTextField()
    /// 月薪特有配置容器。
    private let monthlyOptions = NSStackView()
    /// 手动折算输入行，按选择显示。
    private var fixedRow = NSStackView()
    /// 可增删休息行的容器。
    private let restsStack = NSStackView()
    /// 保留休息区间草稿，保存前不影响生效配置。
    private var restRows: [RestRow] = []
    /// 是否展示鼓励内容。
    private let cheer = NSButton(checkboxWithTitle: "显示鼓励文案", target: nil, action: nil)
    /// 是否在应用运行期间发送工作节点提醒。
    private let workReminders = NSButton(checkboxWithTitle: "提醒上班、休息和下班", target: nil, action: nil)
    /// 面板内三个独立显示开关，保存前只修改草稿。
    private let currentIncomeVisible = NSButton(checkboxWithTitle: "当前已赚", target: nil, action: nil)
    /// 是否在面板中显示本月累计金额。
    private let monthlyIncomeVisible = NSButton(checkboxWithTitle: "本月预估已赚", target: nil, action: nil)
    /// 是否在面板中显示本年累计金额。
    private let yearlyIncomeVisible = NSButton(checkboxWithTitle: "本年预估已赚", target: nil, action: nil)
    /// 菜单栏内容选择，保存后与详情面板使用相同金额。
    private let menuIncome = NSPopUpButton()
    /// 用户明确选择原生液态玻璃，旧系统保留偏好并使用普通背景。
    private let panelGlass = NSButton(checkboxWithTitle: "使用原生液态玻璃", target: nil, action: nil)
    /// 收入面板与设置窗口共同使用的主题选择。
    private let appearanceMode = NSPopUpButton()
    /// 是否启用自定义染色；取消勾选时恢复系统默认底色。
    private let panelTintEnabled = NSButton(checkboxWithTitle: "自定义面板染色", target: nil, action: nil)
    /// 系统原生颜色选择器，保存时转为不透明 sRGB。
    private let panelTint = NSColorWell()
    /// 系统管理的登录启动开关，不写入工资配置。
    private let login = NSButton(checkboxWithTitle: "登录后自动启动（立即生效）", target: nil, action: nil)
    /// 显示自动启动的实际系统状态。
    private let loginState = NSTextField(wrappingLabelWithString: "")
    /// 与主面板相同指标的保存前预览。
    private let preview = NSTextField(wrappingLabelWithString: "填写后可预览当前收入。")
    /// 输入或保存失败的可见原因。
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    /// 立即生效的自动检查偏好。
    private let automaticUpdates = NSButton(checkboxWithTitle: "自动检测更新（立即生效）", target: nil, action: nil)
    /// 当前检查状态，不显示或传输工资信息。
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    /// 手动检查入口，请求期间禁用。
    private let checkUpdate = NSButton(title: "检查更新…", target: nil, action: nil)
    /// 用户明确点击后下载、校验并原位安装新版。
    private let downloadUpdate = NSButton(title: "安装更新", target: nil, action: nil)

    /// 根据已保存工资和外观创建独立草稿，连接实际保存与重置操作。
    init(settings: WorkSettings, dataPath: String, updates: UpdateController,
         onSave: @escaping (WorkSettings) throws -> Void, onReset: @escaping () throws -> Void) {
        original = settings
        self.dataPath = dataPath
        self.onSave = onSave
        self.onReset = onReset
        self.updates = updates
        salary = settings.hideAmounts ? NSSecureTextField() : NSTextField()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 690),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppBuildChannel.current.displayName + " · 工资与作息"
        window.appearance = settings.panelAppearance.mode.nativeAppearance
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildForm()
        window.center()
    }

    /// 设置页仅通过明确的配置创建，不接受归档恢复。
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// 构建工资、面板外观及系统状态表单；外观与工资均在保存后持久化。
    private func buildForm() {
        guard let window else { return }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        // 表单使用传统滚动条，减少系统覆盖滚动条的额外显示资源。
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        window.contentView = scroll
        let document = FormDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        let title = label("工资与作息", size: 22, secondary: false)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(label("只在本机保存，用于估算当前及本年收入。"))
        payMode.addItems(withTitles: ["月薪", "日薪"])
        payMode.selectItem(at: original.payMode == .monthly ? 0 : 1)
        payMode.target = self
        payMode.action = #selector(updatePreview)
        salary.stringValue = original.salary.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        salary.placeholderString = "请输入工资"
        salary.setAccessibilityIdentifier("salaryInput")
        let salaryRow = horizontal([salaryLabel, salary, payMode])
        salary.widthAnchor.constraint(equalToConstant: 145).isActive = true
        stack.addArrangedSubview(salaryRow)
        stack.addArrangedSubview(label("每周上班日", secondary: false))
        let dayRow = NSStackView()
        dayRow.orientation = .horizontal
        dayRow.spacing = 8
        for (weekday, name) in [(2, "一"), (3, "二"), (4, "三"), (5, "四"), (6, "五"), (7, "六"), (1, "日")] {
            let button = NSButton(checkboxWithTitle: name, target: self, action: #selector(updatePreview))
            button.state = original.weekdays.contains(weekday) ? .on : .off
            button.setAccessibilityLabel("周" + name)
            weekdays.append((weekday, button))
            dayRow.addArrangedSubview(button)
        }
        stack.addArrangedSubview(dayRow)
        chinaHoliday.state = original.chinaHolidayEnabled ? .on : .off
        chinaHoliday.target = self
        chinaHoliday.action = #selector(updateHolidayStatus)
        stack.addArrangedSubview(chinaHoliday)
        chinaHolidayStatus.font = .systemFont(ofSize: 11)
        chinaHolidayStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(chinaHolidayStatus)
        updateHolidayStatus()
        start.stringValue = timeText(original.startMinute)
        end.stringValue = timeText(original.endMinute)
        start.setAccessibilityLabel("上班时间")
        end.setAccessibilityLabel("下班时间")
        stack.addArrangedSubview(horizontal([label("上班", secondary: false), start, label("下班", secondary: false), end]))
        stack.addArrangedSubview(label("时间格式 HH:mm；下班早于上班表示次日下班。"))
        stack.addArrangedSubview(label("非计薪休息", secondary: false))
        restsStack.orientation = .vertical
        restsStack.alignment = .leading
        restsStack.spacing = 8
        stack.addArrangedSubview(restsStack)
        for rest in original.rests { restRows.append(makeRest(start: rest.start, end: rest.end)) }
        rebuildRests()
        stack.addArrangedSubview(NSButton(title: "添加休息时段", target: self, action: #selector(addRest)))
        stack.addArrangedSubview(label("带薪休息请删除对应时段；跨夜时段按班次自动归属次日。"))
        divisorMode.addItems(withTitles: ["本月排班天数", "指定折算天数"])
        divisorMode.selectItem(at: original.divisorMode == .schedule ? 0 : 1)
        divisorMode.target = self
        divisorMode.action = #selector(updatePreview)
        fixedDays.stringValue = original.fixedDays.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""
        fixedDays.placeholderString = "折算天数"
        fixedRow = horizontal([label("折算天数", secondary: false), fixedDays])
        monthlyOptions.orientation = .vertical
        monthlyOptions.alignment = .leading
        monthlyOptions.spacing = 8
        monthlyOptions.detachesHiddenViews = true
        monthlyOptions.addArrangedSubview(horizontal([label("月薪折算", secondary: false), divisorMode]))
        monthlyOptions.addArrangedSubview(fixedRow)
        stack.addArrangedSubview(monthlyOptions)
        cheer.state = original.encouragement ? .on : .off
        workReminders.state = original.workReminders ? .on : .off
        menuIncome.addItems(withTitles: MenuBarDisplay.allCases.map { $0.title })
        menuIncome.selectItem(at: MenuBarDisplay.allCases.firstIndex(of: original.menuBarDisplay) ?? 0)
        stack.addArrangedSubview(label("收入面板显示", secondary: false))
        currentIncomeVisible.state = original.showCurrentIncome ? .on : .off
        monthlyIncomeVisible.state = original.showMonthlyIncome ? .on : .off
        yearlyIncomeVisible.state = original.showYearlyIncome ? .on : .off
        currentIncomeVisible.setAccessibilityIdentifier("showCurrentIncome")
        monthlyIncomeVisible.setAccessibilityIdentifier("showMonthlyIncome")
        yearlyIncomeVisible.setAccessibilityIdentifier("showYearlyIncome")
        stack.addArrangedSubview(currentIncomeVisible)
        stack.addArrangedSubview(monthlyIncomeVisible)
        stack.addArrangedSubview(yearlyIncomeVisible)
        stack.addArrangedSubview(cheer)
        stack.addArrangedSubview(workReminders)
        stack.addArrangedSubview(label("首次开启会请求系统通知权限；应用运行期间按当天排班提醒，不包含工资金额。"))
        stack.addArrangedSubview(NSButton(title: "倒计时与菜单栏…", target: self, action: #selector(openCountdowns)))
        stack.addArrangedSubview(horizontal([label("菜单栏显示", secondary: false), menuIncome]))
        stack.addArrangedSubview(label("面板外观", secondary: false))
        panelGlass.state = original.panelAppearance.glassEnabled ? .on : .off
        panelGlass.setAccessibilityIdentifier("panelGlassEnabled")
        if #available(macOS 26.0, *) {} else { panelGlass.isEnabled = false }
        stack.addArrangedSubview(panelGlass)
        stack.addArrangedSubview(label("液态玻璃需要 macOS 26 或更新版本；关闭时使用普通圆角背景。"))
        appearanceMode.addItems(withTitles: AppearanceMode.allCases.map { $0.title })
        appearanceMode.selectItem(at: AppearanceMode.allCases.firstIndex(of: original.panelAppearance.mode) ?? 0)
        appearanceMode.setAccessibilityIdentifier("appearanceMode")
        appearanceMode.target = self
        appearanceMode.action = #selector(updateAppearancePreview)
        stack.addArrangedSubview(horizontal([label("深浅外观", secondary: false), appearanceMode]))
        panelTintEnabled.state = original.panelAppearance.tintHex == nil ? .off : .on
        panelTintEnabled.setAccessibilityIdentifier("panelTintEnabled")
        panelTintEnabled.target = self
        panelTintEnabled.action = #selector(updateAppearancePreview)
        panelTint.color = original.panelAppearance.nativeTintColor ?? .systemGreen
        panelTint.isEnabled = panelTintEnabled.state == .on
        panelTint.setAccessibilityIdentifier("panelTintColor")
        stack.addArrangedSubview(horizontal([panelTintEnabled, panelTint]))
        stack.addArrangedSubview(label("保存后应用面板外观；取消则保留原设置。普通背景使用轻微染色。"))
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        login.target = self
        login.action = #selector(changeLogin)
        login.setAccessibilityIdentifier("loginAtStartup")
        loginState.font = .systemFont(ofSize: 11)
        loginState.textColor = .secondaryLabelColor
        stack.addArrangedSubview(login)
        stack.addArrangedSubview(loginState)
        stack.addArrangedSubview(label("运行环境：" + AppBuildChannel.current.title))
        stack.addArrangedSubview(label("应用更新 · 当前版本 " + updates.currentVersion, size: 13, secondary: false))
        automaticUpdates.target = self
        automaticUpdates.action = #selector(changeAutomaticUpdates)
        checkUpdate.target = self
        checkUpdate.action = #selector(checkUpdates)
        downloadUpdate.target = self
        downloadUpdate.action = #selector(openUpdateDownload)
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateStatus.setAccessibilityIdentifier("updateStatus")
        stack.addArrangedSubview(automaticUpdates)
        stack.addArrangedSubview(horizontal([checkUpdate, downloadUpdate]))
        stack.addArrangedSubview(updateStatus)
        stack.addArrangedSubview(label("启动时检查，此后每24小时最多自动检查一次；仅获取公开版本信息。"))
        updates.onChange = { [weak self] in self?.renderUpdates() }
        renderUpdates()
        preview.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(preview)
        stack.addArrangedSubview(label("保存后会重算本班、本月及本年预估收入，显示金额可能变化。"))
        errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityIdentifier("settingsError")
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        let save = NSButton(title: "保存并返回", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "取消修改", target: self, action: #selector(cancel))
        stack.addArrangedSubview(horizontal([save, cancel]))
        stack.addArrangedSubview(NSButton(title: "清除设置并重置…", target: self, action: #selector(reset)))
        let location = label("配置位置：" + dataPath)
        location.isSelectable = true
        stack.addArrangedSubview(location)
        for field in [salary, start, end, fixedDays] { field.delegate = self }
        for field in [start, end] { field.widthAnchor.constraint(equalToConstant: 92).isActive = true }
        for child in stack.arrangedSubviews {
            child.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        updateLoginState()
        updatePreview()
    }

    /// 创建含业务说明的原生文本标签。
    private func label(_ text: String, size: CGFloat = 11, secondary: Bool = true) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    /// 将同一设置的标签和输入放在一行，保持键盘顺序。
    private func horizontal(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    /// 更新检查状态变化不会覆盖用户正在编辑的工资和作息。
    private func renderUpdates() {
        automaticUpdates.state = updates.automaticEnabled ? .on : .off
        checkUpdate.isEnabled = !updates.isChecking
        downloadUpdate.isHidden = updates.release == nil
        updateStatus.stringValue = updates.status
    }

    /// 自动检查开关立即保存，独立于工资表单的保存与取消。
    @objc private func changeAutomaticUpdates() { updates.setAutomaticEnabled(automaticUpdates.state == .on) }

    /// 手动检查绕过每日自动检查间隔，但不并发重复请求。
    @objc private func checkUpdates() { updates.check(manual: true) }

    /// 交给签名更新器替换当前应用，工资及作息配置不参与安装。
    @objc private func openUpdateDownload() { updates.installUpdate() }

    /// 用 HH:mm 形式展示本地分钟时刻。
    private func timeText(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

    /// 解析严格的 24 小时输入，拒绝自动归一化的无效时刻。
    private func parseTime(_ text: String) throws -> Int {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0].count == 2, pieces[1].count == 2,
              let hour = Int(pieces[0]), let minute = Int(pieces[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { throw SettingsError.invalidTime }
        return hour * 60 + minute
    }

    /// 创建一条休息草稿，所有内容在保存前统一验证。
    private func makeRest(start: Int, end: Int) -> RestRow {
        let a = NSTextField(string: timeText(start))
        let b = NSTextField(string: timeText(end))
        a.delegate = self
        b.delegate = self
        a.setAccessibilityLabel("休息开始")
        b.setAccessibilityLabel("休息结束")
        a.widthAnchor.constraint(equalToConstant: 100).isActive = true
        b.widthAnchor.constraint(equalToConstant: 100).isActive = true
        return RestRow(start: a, end: b)
    }

    /// 重建可增删休息行，不重建其正在编辑的文本框。
    private func rebuildRests() {
        for view in restsStack.arrangedSubviews { restsStack.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, rest) in restRows.enumerated() {
            let remove = NSButton(title: "删除", target: self, action: #selector(removeRest(_:)))
            remove.tag = index
            restsStack.addArrangedSubview(horizontal([rest.start, label("至"), rest.end, remove]))
        }
    }

    /// 读取完整工资和外观草稿，保留未编辑的隐私状态并校验颜色可恢复。
    private func draft() throws -> WorkSettings {
        var settings = original
        settings.payMode = payMode.indexOfSelectedItem == 0 ? .monthly : .daily
        let input = salary.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")) else {
            throw SettingsError.invalidSalary
        }
        settings.salary = value
        settings.weekdays = Set(weekdays.filter { $0.1.state == .on }.map { $0.0 })
        settings.startMinute = try parseTime(start.stringValue)
        settings.endMinute = try parseTime(end.stringValue)
        settings.rests = try restRows.map { try RestPeriod(start: parseTime($0.start.stringValue), end: parseTime($0.end.stringValue)) }
        settings.divisorMode = divisorMode.indexOfSelectedItem == 0 ? .schedule : .fixed
        if settings.payMode == .monthly, settings.divisorMode == .fixed,
           fixedDays.stringValue.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) == nil {
            throw SettingsError.invalidDivisor
        }
        settings.fixedDays = Decimal(string: fixedDays.stringValue, locale: Locale(identifier: "en_US_POSIX"))
        settings.showCurrentIncome = currentIncomeVisible.state == .on
        settings.showMonthlyIncome = monthlyIncomeVisible.state == .on
        settings.showYearlyIncome = yearlyIncomeVisible.state == .on
        settings.encouragement = cheer.state == .on
        settings.workReminders = workReminders.state == .on
        settings.menuBarDisplay = MenuBarDisplay.allCases[menuIncome.indexOfSelectedItem]
        settings.menuBarIncome = settings.menuBarDisplay != .icon
        settings.chinaHolidayEnabled = chinaHoliday.state == .on
        settings.panelAppearance.glassEnabled = panelGlass.state == .on
        settings.panelAppearance.mode = AppearanceMode.allCases[appearanceMode.indexOfSelectedItem]
        if panelTintEnabled.state == .on {
            guard let hex = panelTint.color.panelTintHex else { throw SettingsError.invalidPanelTint }
            settings.panelAppearance.tintHex = hex
        } else { settings.panelAppearance.tintHex = nil }
        try settings.validate()
        return settings
    }

    /// 仅预览当前设置窗口的主题，并控制染色输入可用性；取消时不持久化。
    @objc private func updateAppearancePreview() {
        window?.appearance = AppearanceMode.allCases[appearanceMode.indexOfSelectedItem].nativeAppearance
        panelTint.isEnabled = panelTintEnabled.state == .on
    }

    /// 输入变化后更新同一收入指标的预览，不把草稿写入磁盘。
    @objc private func updatePreview() {
        let monthly = payMode.indexOfSelectedItem == 0
        salaryLabel.stringValue = monthly ? "每月工资（元）" : "每天工资（元）"
        monthlyOptions.isHidden = !monthly
        fixedRow.isHidden = divisorMode.indexOfSelectedItem == 0
        do {
            let settings = try draft()
            let engine = IncomeEngine()
            let snapshot = try engine.evaluate(settings, at: Date())
            let income = settings.hideAmounts ? "••••" : IncomeViewController.money(snapshot.amount)
            let note = monthly && settings.divisorMode == .schedule ? "；本月排班 " + String(engine.workdays(in: Date(), settings: settings)) + " 天" : ""
            preview.stringValue = "当前收入预览：" + income + note
        } catch { preview.stringValue = "填写有效工资和作息后可预览当前收入。" }
    }

    /// 显示内置年度数据覆盖范围，并明确缺失年份的回退规则。
    @objc private func updateHolidayStatus() {
        let year = Calendar.autoupdatingCurrent.component(.year, from: Date())
        chinaHolidayStatus.stringValue = chinaHoliday.state == .on
            ? (ChinaHolidayCalendar.hasData(for: year) ? "已内置 \(year) 年官方安排；未内置年份按每周排班计算。" : "\(year) 年安排缺失，将按每周排班计算。")
            : "已内置 2026 年官方安排；未内置年份按每周排班计算。"
        updatePreview()
    }

    /// 任何文本变更只刷新预览，不打断用户输入。
    func controlTextDidChange(_ notification: Notification) { updatePreview() }

    /// 为新的非计薪区间添加可编辑草稿。
    @objc private func addRest() { restRows.append(makeRest(start: 720, end: 780)); rebuildRests(); updatePreview() }

    /// 移除用户选中的休息区间，空列表表示休息也计薪。
    @objc private func removeRest(_ sender: NSButton) { restRows.remove(at: sender.tag); rebuildRests(); updatePreview() }

    /// 工资和外观校验、保存全部成功后关闭设置，否则保留草稿供修正。
    @objc private func save() {
        do { try onSave(draft()); close() }
        catch { showError(error) }
    }

    /// 放弃工资作息和外观草稿；立即生效的系统登录开关单独说明。
    /// 打开独立倒计时设置，保留未保存的工资草稿。
    @objc private func openCountdowns() { onCountdowns?() }

    @objc private func cancel() { close() }

    /// 非正式包禁用系统登录项入口；正式包展示系统实际注册状态。
    private func updateLoginState() {
        guard AppBuildChannel.current.allowsLoginItemRegistration else {
            login.isEnabled = false
            login.state = .off
            loginState.stringValue = "当前为" + AppBuildChannel.current.title + "，不允许注册登录自启动。"
            return
        }
        let status = SMAppService.mainApp.status
        login.state = status == .enabled ? .on : .off
        switch status {
        case .enabled: loginState.stringValue = "已开启；本次登录内退出后不会自行重启。"
        case .requiresApproval: loginState.stringValue = "等待系统批准，请到系统设置的登录项中确认。"
        case .notRegistered: loginState.stringValue = "未开启。此开关立即生效，不受取消工资修改影响。"
        case .notFound: loginState.stringValue = "系统未找到应用，请先将正式应用安装到应用程序。"
        @unknown default: loginState.stringValue = "无法确定登录启动状态，请检查系统设置。"
        }
    }

    /// 再次校验包环境后调用系统服务，避免非正式包通过动作调用注册自启动。
    @objc private func changeLogin() {
        guard AppBuildChannel.current.allowsLoginItemRegistration else { updateLoginState(); return }
        do {
            if login.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { showError(error) }
        updateLoginState()
    }

    /// 从系统设置返回时重新读取可能已被撤销的登录权限。
    func windowDidBecomeKey(_ notification: Notification) { updateLoginState() }

    /// 关闭当前颜色选择器并释放窗口与草稿，有效配置仍由应用持有。
    func windowWillClose(_ notification: Notification) {
        if panelTint.isActive { panelTint.deactivate(); NSColorPanel.shared.close() }
        onClose?()
    }

    /// 清楚说明清理范围，经确认才交给应用执行真实清理。
    @objc private func reset() {
        let alert = NSAlert()
        alert.messageText = "清除设置并重置？"
        alert.informativeText = "将删除本应用的工资、作息、倒计时、显示及更新检查偏好，并关闭登录自动启动。应用本体和其他文件不会被删除。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清除并重置")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try onReset(); close() }
        catch { showError(error) }
    }

    /// 展示可恢复的错误，不丢弃用户草稿或静默覆盖旧文件。
    private func showError(_ error: Error) { errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false }
}
