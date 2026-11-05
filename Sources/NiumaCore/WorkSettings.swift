import Foundation

/// 工资输入口径，不改变面板只展示当前收入的规则。
public enum PayMode: String, Codable, Sendable {
    case monthly, daily
}

/// 月薪折算依据，手动天数不改变实际排班。
public enum DivisorMode: String, Codable, Sendable {
    case schedule, fixed
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
    /// 是否直接在菜单栏显示当前收入。
    public var menuBarIncome = false
    /// 工资及收入的隐私显示偏好。
    public var hideAmounts = false

    /// 创建首次使用设置，工资留空等待用户输入。
    public init() {}

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

    /// 验证用户输入的业务条件，禁止保存不完整或无法估算的设置。
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

    /// 返回不泄露配置内容的中文错误说明。
    public var errorDescription: String? { rawValue }
}
