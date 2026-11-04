import Foundation

/// 当前班次的可见工作状态。
public enum WorkPhase: String, Sendable {
    case unconfigured, before, working, resting, finished, off
}

/// 由时间直接计算的显示快照，不依赖后台逐秒累加。
public struct IncomeSnapshot: Sendable {
    /// 当前时间对应的工作状态。
    public let phase: WorkPhase
    /// 本班已赚金额，休息日或未设置时为空。
    public let amount: Decimal?
    /// 内部鼓励节点依据，不向用户展示比例。
    public let progress: Double
    /// 下一次需要改变状态的时间，供停止秒级刷新时使用。
    public let nextBoundary: Date?
}

/// 组合排班、工资和当前时间的收入计算服务。
public struct IncomeEngine: Sendable {
    /// 计算班次归属与月份的日历，测试时固定时区。
    public let calendar: Calendar

    /// 使用明确的日历解释用户输入的本地作息。
    public init(calendar: Calendar = .autoupdatingCurrent) { self.calendar = calendar }

    /// 根据当前时刻生成收入快照，不保存计时器进度。
    public func evaluate(_ settings: WorkSettings?, at now: Date) throws -> IncomeSnapshot {
        guard let settings else {
            return IncomeSnapshot(phase: .unconfigured, amount: nil, progress: 0, nextBoundary: nil)
        }
        try settings.validate()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let previous = try shift(on: yesterday, settings: settings)
        let current = try shift(on: today, settings: settings)
        let active = previous.flatMap { now >= $0.start && now < $0.end ? $0 : nil } ?? current
        var boundaries: [Date] = []
        if let active { boundaries += [active.start, active.end] + active.rests.flatMap { [$0.start, $0.end] } }
        for offset in 0...7 {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            if settings.weekdays.contains(calendar.component(.weekday, from: day)) {
                let start = try localDate(on: day, minute: settings.startMinute)
                if start > now { boundaries.append(start); break }
            }
        }
        let next = boundaries.filter { $0 > now }.min()
        guard let active else { return IncomeSnapshot(phase: .off, amount: nil, progress: 0, nextBoundary: next) }
        let phase: WorkPhase
        if now < active.start { phase = .before }
        else if now >= active.end { phase = .finished }
        else if active.rests.contains(where: { now >= $0.start && now < $0.end }) { phase = .resting }
        else { phase = .working }
        let duration = active.end.timeIntervalSince(active.start) - active.rests.reduce(0) { $0 + $1.duration }
        let stop = min(max(now, active.start), active.end)
        let restElapsed = active.rests.reduce(0.0) { total, rest in
            total + max(0, min(stop, rest.end).timeIntervalSince(rest.start))
        }
        let elapsed = max(0, stop.timeIntervalSince(active.start) - restElapsed)
        let daily: Decimal
        if settings.payMode == .daily { daily = settings.salary! }
        else {
            let divisor = settings.divisorMode == .fixed ? settings.fixedDays! : Decimal(workdays(in: active.start, settings: settings))
            daily = settings.salary! / divisor
        }
        guard !daily.isNaN else { throw SettingsError.invalidDivisor }
        let fraction = Decimal(elapsed) / Decimal(duration)
        return IncomeSnapshot(phase: phase, amount: daily * fraction, progress: elapsed / duration, nextBoundary: next)
    }

    /// 统计班次开始月份的排班日期数量，不推测节假日。
    public func workdays(in date: Date, settings: WorkSettings) -> Int {
        let month = calendar.dateInterval(of: .month, for: date)!
        let count = calendar.range(of: .day, in: .month, for: date)!.count
        return (0..<count).reduce(0) { result, offset in
            let day = calendar.date(byAdding: .day, value: offset, to: month.start)!
            return result + (settings.weekdays.contains(calendar.component(.weekday, from: day)) ? 1 : 0)
        }
    }

    /// 班次使用实际经过的时间，防止夏令时按固定秒数偏移。
    private struct Shift {
        /// 本地班次开始时刻，同时决定月薪归属月份。
        let start: Date
        /// 本地班次结束时刻。
        let end: Date
        /// 当班内已验证的不计薪区间。
        let rests: [DateInterval]
    }

    /// 将一个排班日期转换为实际班次，非工作日不创建班次。
    private func shift(on day: Date, settings: WorkSettings) throws -> Shift? {
        guard settings.weekdays.contains(calendar.component(.weekday, from: day)) else { return nil }
        let endMinute = settings.endMinute > settings.startMinute ? settings.endMinute : settings.endMinute + 1440
        let intervals = try settings.normalizedRests().map {
            try DateInterval(start: localDate(on: day, minute: $0.lowerBound), end: localDate(on: day, minute: $0.upperBound))
        }
        return try Shift(start: localDate(on: day, minute: settings.startMinute),
                         end: localDate(on: day, minute: endMinute), rests: intervals)
    }

    /// 严格解析本地时刻，拒绝夏令时造成的不存在或重复时间。
    private func localDate(on day: Date, minute: Int) throws -> Date {
        let targetDay = calendar.date(byAdding: .day, value: minute / 1440, to: day)!
        let hour = minute % 1440 / 60
        let minuteOfHour = minute % 60
        guard let first = calendar.date(bySettingHour: hour, minute: minuteOfHour, second: 0, of: targetDay,
                                        matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
              let last = calendar.date(bySettingHour: hour, minute: minuteOfHour, second: 0, of: targetDay,
                                       matchingPolicy: .strict, repeatedTimePolicy: .last, direction: .forward),
              calendar.isDate(first, inSameDayAs: targetDay), first == last else {
            throw SettingsError.ambiguousTime
        }
        return first
    }
}
