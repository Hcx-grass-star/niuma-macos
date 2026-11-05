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
    /// 从本年一月一日到当前时刻按现行配置回算的预估收入。
    public let yearToDateAmount: Decimal?
    /// 从本月一日零点截至当前的计薪收入，跨月班仅计本月区间。
    public let monthToDateAmount: Decimal?
    /// 内部鼓励节点依据，不向用户展示比例。
    public let progress: Double
    /// 下一次需要改变状态的时间，供停止秒级刷新时使用。
    public let nextBoundary: Date?
    /// 当前班次或当天采用的排班依据，不包含工资信息。
    public let scheduleReason: String?
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
            return IncomeSnapshot(phase: .unconfigured, amount: nil, yearToDateAmount: nil, monthToDateAmount: nil, progress: 0, nextBoundary: nil, scheduleReason: nil)
        }
        try settings.validate()
        let yearToDate = try accruedAmount(for: settings, from: calendar.dateInterval(of: .year, for: now)!.start, through: now)
        let monthToDate = try accruedAmount(for: settings, from: calendar.dateInterval(of: .month, for: now)!.start, through: now)
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let previous = try shift(on: yesterday, settings: settings)
        let current = try shift(on: today, settings: settings)
        let active = previous.flatMap { now >= $0.start && now < $0.end ? $0 : nil } ?? current
        // 年度金额需要在元旦零点刷新，即使下一班尚未开始。
        var boundaries: [Date] = [calendar.dateInterval(of: .month, for: now)!.end]
        if let active { boundaries += [active.start, active.end] + active.rests.flatMap { [$0.start, $0.end] } }
        var nextDay = today
        let monthEnd = calendar.dateInterval(of: .month, for: now)!.end
        while nextDay < monthEnd {
            let day = nextDay
            nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            if isScheduledDate(on: day, settings: settings) {
                let start = try localDate(on: day, minute: settings.startMinute)
                if start > now { boundaries.append(start); break }
            }
        }
        let next = boundaries.filter { $0 > now }.min()
        guard let active else {
            return IncomeSnapshot(phase: .off, amount: nil, yearToDateAmount: yearToDate, monthToDateAmount: monthToDate, progress: 0, nextBoundary: next,
                                  scheduleReason: ChinaHolidayCalendar.reason(on: today, settings: settings, calendar: calendar))
        }
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
        let daily = try dailyIncome(for: active.start, settings: settings)
        guard !daily.isNaN else { throw SettingsError.invalidDivisor }
        let fraction = Decimal(elapsed) / Decimal(duration)
        let scheduleDate = calendar.startOfDay(for: active.start)
        return IncomeSnapshot(phase: phase, amount: daily * fraction, yearToDateAmount: yearToDate, monthToDateAmount: monthToDate,
                              progress: elapsed / duration, nextBoundary: next,
                              scheduleReason: ChinaHolidayCalendar.reason(on: scheduleDate, settings: settings, calendar: calendar))
    }

    /// 按月汇总完整班次，区间起点之前的跨夜班和最近两天按实际计薪部分截断。
    private func accruedAmount(for settings: WorkSettings, from yearStart: Date, through now: Date) throws -> Decimal {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        var total = Decimal.zero
        var monthStart = yearStart
        while monthStart < yesterday {
            let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart)!
            let end = min(monthEnd, yesterday)
            let days = calendar.dateComponents([.day], from: monthStart, to: end).day!
            let count = scheduledDays(from: monthStart, count: days, settings: settings)
            if count > 0 { total += try dailyIncome(for: monthStart, settings: settings) * Decimal(count) }
            monthStart = monthEnd
        }
        let priorYearDay = calendar.date(byAdding: .day, value: -1, to: yearStart)!
        for day in Set([priorYearDay, yesterday, today]) {
            if let shift = try shift(on: day, settings: settings) {
                let lower = max(shift.start, yearStart)
                let upper = min(shift.end, now)
                let duration = shift.end.timeIntervalSince(shift.start) - shift.rests.reduce(0) { $0 + $1.duration }
                let paid = paidDuration(in: shift, from: lower, to: upper)
                if paid > 0, duration > 0 {
                    total += try dailyIncome(for: shift.start, settings: settings) * Decimal(paid) / Decimal(duration)
                }
            }
        }
        return total
    }

    /// 计算一个班次在指定时间区间内扣除非计薪休息后的实际计薪秒数。
    private func paidDuration(in shift: Shift, from lower: Date, to upper: Date) -> TimeInterval {
        guard upper > lower else { return 0 }
        let gross = upper.timeIntervalSince(lower)
        let unpaid = shift.rests.reduce(0.0) { total, rest in
            total + max(0, min(upper, rest.end).timeIntervalSince(max(lower, rest.start)))
        }
        return max(0, gross - unpaid)
    }

    /// 根据班次归属月份计算该班完整预估收入。
    private func dailyIncome(for date: Date, settings: WorkSettings) throws -> Decimal {
        if settings.payMode == .daily { return settings.salary! }
        let divisor = settings.divisorMode == .fixed ? settings.fixedDays! : Decimal(workdays(in: date, settings: settings))
        guard !divisor.isZero else { throw SettingsError.invalidDivisor }
        return settings.salary! / divisor
    }

    /// 统计班次开始月份的排班日期数量，应用已开启的年度安排覆盖。
    public func workdays(in date: Date, settings: WorkSettings) -> Int {
        let month = calendar.dateInterval(of: .month, for: date)!
        let count = calendar.range(of: .day, in: .month, for: date)!.count
        return scheduledDays(from: month.start, count: count, settings: settings)
    }

    /// 按日期统计月份中的有效班次，使全国安排覆盖和缺失年份回退保持一致。
    private func scheduledDays(from start: Date, count: Int, settings: WorkSettings) -> Int {
        var total = 0
        for offset in 0..<count {
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            if isScheduledDate(on: day, settings: settings) { total += 1 }
        }
        return total
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
        guard isScheduledDate(on: day, settings: settings) else { return nil }
        let endMinute = settings.endMinute > settings.startMinute ? settings.endMinute : settings.endMinute + 1440
        let intervals = try settings.normalizedRests().map {
            try DateInterval(start: localDate(on: day, minute: $0.lowerBound), end: localDate(on: day, minute: $0.upperBound))
        }
        return try Shift(start: localDate(on: day, minute: settings.startMinute),
                         end: localDate(on: day, minute: endMinute), rests: intervals)
    }

    /// 判断日期是否创建班次；全国安排覆盖每周排班，缺失年份回退每周排班。
    private func isScheduledDate(on day: Date, settings: WorkSettings) -> Bool {
        if settings.chinaHolidayEnabled, let holiday = ChinaHolidayCalendar.day(on: day, calendar: calendar) {
            return holiday.kind == "makeup"
        }
        return settings.weekdays.contains(calendar.component(.weekday, from: day))
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
