import Foundation

/// 当前班次、本月及本年预估收入共同使用的工资输入口径。
public enum PayMode: String, Codable, Sendable {
    case monthly, daily
}

/// 月薪折算依据，手动天数不改变实际排班。
public enum DivisorMode: String, Codable, Sendable {
    case schedule, fixed
}

/// 菜单栏可展示的内容；收入指标与详情面板使用相同快照。
public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable {
    case icon, current, month

    /// 设置选择器和菜单中的统一中文名称。
    public var title: String {
        switch self {
        case .icon: return "仅图标"
        case .current: return "当前班次已赚"
        case .month: return "本月预估已赚"
        }
    }
}

/// 每天的非计薪休息时段，分钟值均为本地钟表时间。
public struct RestPeriod: Codable, Equatable, Sendable {
    /// 休息开始时刻，范围为零点起的 0 至 1439 分钟。
    public var start: Int
    /// 休息结束时刻，跨午夜归属由班次确定。
    public var end: Int

    /// 用本地时刻创建休息区间，保存前统一校验有效性。
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// 可持久化的工资、排班和展示偏好；自动启动状态由系统管理。
public struct WorkSettings: Codable, Equatable, Sendable {
    /// 用户选择的工资口径。
    public var payMode: PayMode = .monthly
    /// 用户填写的人民币工资；首次使用为空，不生成示例收入。
    public var salary: Decimal?
    /// Calendar 的星期编号：周日为 1，周一为 2。
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// 班次开始的本地分钟时刻。
    public var startMinute: Int = 540
    /// 班次结束的本地分钟时刻，较小时表示次日。
    public var endMinute: Int = 1080
    /// 非计薪区间，空数组表示全部班次时间计薪。
    public var rests: [RestPeriod] = [.init(start: 720, end: 780)]
    /// 月薪默认按本月每周排班日期数量折算。
    public var divisorMode: DivisorMode = .schedule
    /// 手动折算天数，仅固定折算模式需要填写。
    public var fixedDays: Decimal?
    /// 是否在收入面板显示鼓励文案。
    public var encouragement = true
    /// 是否在应用运行期间提醒上班、休息和下班节点。
    public var workReminders = false
    /// 兼容旧版的菜单栏金额开关，新版按 menuBarDisplay 选择内容。
    public var menuBarIncome = false
    /// 菜单栏展示指标，默认仅图标，旧版开关在解码时迁移。
    public var menuBarDisplay: MenuBarDisplay = .icon
    /// 收入面板是否展示当前班次整块金额与说明。
    public var showCurrentIncome = true
    /// 收入面板是否展示本月预估已赚。
    public var showMonthlyIncome = true
    /// 收入面板是否展示本年预估已赚及回算说明。
    public var showYearlyIncome = true
    /// 工资及收入的隐私显示偏好。
    public var hideAmounts = false
    /// 是否让内置中国大陆节假日及调休安排覆盖每周排班。
    public var chinaHolidayEnabled = false
    /// 收入面板材质、应用深浅外观及可选背景染色，不参与工资计算。
    public var panelAppearance = PanelAppearanceSettings()

    /// 创建首次使用设置，工资留空等待用户输入。
    public init() {}

    /// 兼容旧配置；保留工资和展示迁移规则，缺少外观字段时使用低开销默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payMode = try container.decodeIfPresent(PayMode.self, forKey: .payMode) ?? .monthly
        salary = try container.decodeIfPresent(Decimal.self, forKey: .salary)
        weekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? [2, 3, 4, 5, 6]
        startMinute = try container.decodeIfPresent(Int.self, forKey: .startMinute) ?? 540
        endMinute = try container.decodeIfPresent(Int.self, forKey: .endMinute) ?? 1080
        rests = try container.decodeIfPresent([RestPeriod].self, forKey: .rests) ?? [.init(start: 720, end: 780)]
        divisorMode = try container.decodeIfPresent(DivisorMode.self, forKey: .divisorMode) ?? .schedule
        fixedDays = try container.decodeIfPresent(Decimal.self, forKey: .fixedDays)
        encouragement = try container.decodeIfPresent(Bool.self, forKey: .encouragement) ?? true
        workReminders = try container.decodeIfPresent(Bool.self, forKey: .workReminders) ?? false
        menuBarIncome = try container.decodeIfPresent(Bool.self, forKey: .menuBarIncome) ?? false
        menuBarDisplay = try container.decodeIfPresent(MenuBarDisplay.self, forKey: .menuBarDisplay) ?? (menuBarIncome ? .current : .icon)
        showCurrentIncome = try container.decodeIfPresent(Bool.self, forKey: .showCurrentIncome) ?? true
        showMonthlyIncome = try container.decodeIfPresent(Bool.self, forKey: .showMonthlyIncome) ?? true
        showYearlyIncome = try container.decodeIfPresent(Bool.self, forKey: .showYearlyIncome) ?? true
        hideAmounts = try container.decodeIfPresent(Bool.self, forKey: .hideAmounts) ?? false
        chinaHolidayEnabled = try container.decodeIfPresent(Bool.self, forKey: .chinaHolidayEnabled) ?? false
        panelAppearance = try container.decodeIfPresent(PanelAppearanceSettings.self, forKey: .panelAppearance) ?? PanelAppearanceSettings()
    }

    /// 按所选指标返回菜单栏金额，隐藏金额或仅图标时不提供金额。
    public func menuBarAmount(in snapshot: IncomeSnapshot) -> Decimal? {
        guard !hideAmounts else { return nil }
        switch menuBarDisplay {
        case .icon: return nil
        case .current: return snapshot.amount
        case .month: return snapshot.monthToDateAmount
        }
    }

    /// 把休息展开到班次时间轴，并拒绝超界、重叠和零计薪时长。
    public func normalizedRests() throws -> [Range<Int>] {
        guard (0..<1440).contains(startMinute), (0..<1440).contains(endMinute),
              startMinute != endMinute else { throw SettingsError.invalidTime }
        let end = endMinute > startMinute ? endMinute : endMinute + 1440
        let ranges = try rests.map { rest -> Range<Int> in
            guard (0..<1440).contains(rest.start), (0..<1440).contains(rest.end),
                  rest.start != rest.end else { throw SettingsError.invalidRest }
            let a = rest.start < startMinute ? rest.start + 1440 : rest.start
            let b = rest.end <= rest.start ? rest.end + (a / 1440 + 1) * 1440 : rest.end + (a / 1440) * 1440
            guard a >= startMinute, b <= end, a < b else { throw SettingsError.invalidRest }
            return a..<b
        }.sorted { $0.lowerBound < $1.lowerBound }
        for pair in zip(ranges, ranges.dropFirst()) where pair.0.upperBound > pair.1.lowerBound {
            throw SettingsError.overlappingRests
        }
        guard ranges.reduce(0, { $0 + $1.count }) < end - startMinute else {
            throw SettingsError.noPaidTime
        }
        return ranges
    }

    /// 验证工资作息和外观值，禁止保存无法估算或无法恢复显示的设置。
    public func validate() throws {
        guard let salary, !salary.isNaN, salary > 0 else { throw SettingsError.invalidSalary }
        var value = salary
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        guard value == rounded else { throw SettingsError.invalidSalary }
        guard !weekdays.isEmpty, weekdays.isSubset(of: Set(1...7)) else { throw SettingsError.noWorkday }
        if payMode == .monthly, divisorMode == .fixed {
            guard let fixedDays, !fixedDays.isNaN, fixedDays > 0 else { throw SettingsError.invalidDivisor }
        }
        _ = try normalizedRests()
        try panelAppearance.validate()
    }
}

/// 可直接展示给用户的配置或时间错误，不包含工资原文。
public enum SettingsError: String, Error, LocalizedError {
    case invalidSalary = "请输入大于 0、最多两位小数的工资。"
    case noWorkday = "请至少选择一个工作日。"
    case invalidTime = "上下班时间必须有效且不能相同。"
    case invalidRest = "休息时段必须位于班次内，且开始与结束不能相同。"
    case overlappingRests = "休息时段不能重叠。"
    case noPaidTime = "扣除休息后，计薪时长必须大于 0。"
    case invalidDivisor = "请输入大于 0 的折算天数。"
    case ambiguousTime = "班次涉及不存在或重复的本地时刻，请调整作息。"
    case invalidStorage = "设置文件无法读取，请检查文件或明确保存新设置后再继续。"
    case invalidPanelTint = "面板染色必须是六位十六进制 RGB 颜色。"

    /// 返回不泄露配置内容的中文错误说明。
    public var errorDescription: String? { rawValue }
}
