import Foundation

/// 固定目标和按现有排班寻找下一次下班的两类规则。
public enum CountdownType: String, Codable, Sendable { case fixed, nextWorkEnd }
/// 用户选择的菜单栏内容，空值兼容旧版收入开关。
public enum MenuBarMode: String, Codable, Sendable { case icon, income, countdown, both }
/// 独立的倒计时事件，不持久化逐秒剩余值。
public struct CountdownEvent: Codable, Equatable, Sendable {
    /// 跨编辑和排序保持稳定的事件标识。
    public var id: String
    /// 用户输入的纯文本标题。
    public var title: String
    /// 目标日期的解析规则。
    public var type: CountdownType
    /// 固定事件的绝对目标时刻；排班事件不使用此值。
    public var targetAt: Date?
    /// 暂时关闭时保留用户原始内容。
    public var enabled: Bool
    /// 用明确的标题和目标创建事件。
    public init(id: String = UUID().uuidString, title: String, type: CountdownType = .fixed, targetAt: Date? = nil, enabled: Bool = true) {
        self.id = id; self.title = title; self.type = type; self.targetAt = targetAt; self.enabled = enabled
    }
}
/// 与工资格式独立保存，首次加载不改变旧设置。
public struct CountdownPreferences: Codable, Equatable, Sendable {
    /// 最多二十条事件，避免界面和配置无限增长。
    public var events: [CountdownEvent] = []
    /// 空值沿用旧版菜单栏收入设置。
    public var menuMode: MenuBarMode?
    /// 用户选中的主倒计时；删除或关闭后回退到最近的可用事件。
    public var menuCountdownID: String?
    /// 菜单栏总宽度，包含图标；空值使用系统自动宽度。
    public var menuWidth: Double?
    /// 初始保留旧菜单行为，不创建虚构倒计时。
    public init() {}
    /// 校验事件、唯一标识与布局范围，保存失败不覆盖旧配置。
    public func validate() throws {
        guard events.count <= 20, Set(events.map(\.id)).count == events.count else { throw CountdownError.invalid("最多添加 20 条倒计时，且标识不能重复。") }
        if let width = menuWidth, !width.isFinite || !(60...240).contains(width) { throw CountdownError.invalid("菜单栏宽度须为 60–240 pt。") }
        for event in events {
            guard !event.id.isEmpty, !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.title.count <= 32, !event.title.contains(where: { $0.isNewline }) else { throw CountdownError.invalid("倒计时标题须为 1–32 个字符，且不能换行。") }
            if event.type == .fixed {
                guard let target = event.targetAt, target.timeIntervalSince1970.isFinite,
                      (0...253402214400).contains(target.timeIntervalSince1970) else { throw CountdownError.invalid("请选择有效的目标时间（1970–9999 年）。") }
            }
        }
    }
}
/// 可直接展示给用户的校验或存储错误。
public enum CountdownError: Error, LocalizedError {
    case invalid(String)
    /// 不包含配置原文的错误说明。
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}
/// 已到达事件不再安排周期刷新，缺少作息时明确显示待配置。
public enum CountdownPhase: String, Sendable { case pending, arrived, unavailable }
/// UI 与菜单栏共享同一个时刻的计算结果。
public struct CountdownSnapshot: Sendable {
    /// 原始事件，便于用户编辑并保持稳定标识。
    public let event: CountdownEvent
    /// 事件当前可见状态。
    public let phase: CountdownPhase
    /// 本次解析的目标时刻。
    public let targetAt: Date?
    /// 单个排班事件的失败原因，不阻断其他固定事件和收入。
    public let unavailableReason: String?
    /// 非负的剩余秒数，由目标减去当前时间得到。
    public let remainingSeconds: Int
    /// 详情使用天、时、分展示，临近一天时增加秒。
    public var detailText: String {
        guard phase == .pending else { return phase == .arrived ? "已到达" : (unavailableReason ?? "请先设置作息") }
        return remainingSeconds >= 86400 ? "\(remainingSeconds / 86400)天 " + Self.clock(remainingSeconds % 86400, seconds: false) : Self.clock(remainingSeconds, seconds: true)
    }
    /// 菜单栏长目标按天取整向上，短目标显示时分秒。
    public var menuText: String {
        event.title + " " + (phase == .pending && remainingSeconds >= 86400 ? "\(Int(ceil(Double(remainingSeconds) / 86400)))天" : detailText)
    }
    /// 使用固定数字宽度的时间格式，避免布局随秒跳动。
    private static func clock(_ value: Int, seconds: Bool) -> String {
        let prefix = String(format: "%02d:%02d", value / 3600, value % 3600 / 60)
        return seconds ? prefix + String(format: ":%02d", value % 60) : prefix
    }
}
/// 无状态地计算目标与刷新计划，休眠恢复不补跑历史 tick。
public struct CountdownEngine: Sendable {
    /// 每周排班按当前本地时区解释，测试时注入固定时区。
    public let calendar: Calendar
    /// 明确日历依赖，不读取任何工资或历史文件。
    public init(calendar: Calendar = .autoupdatingCurrent) { self.calendar = calendar }
    /// 计算启用事件并按有效目标排序，固定事件可脱离工资设置使用。
    public func evaluate(_ events: [CountdownEvent], work: WorkSettings?, at now: Date) throws -> [CountdownSnapshot] {
        var nextEnd: Date?
        var scheduleError: String?
        if events.contains(where: { $0.enabled && $0.type == .nextWorkEnd }) {
            do { nextEnd = try nextWorkEnd(work, at: now) }
            catch { scheduleError = error.localizedDescription }
        }
        return events.filter(\.enabled).map { event in
            let target = event.type == .fixed ? event.targetAt : nextEnd
            let remaining = target.map { max(0, Int(ceil($0.timeIntervalSince(now)))) } ?? 0
            return CountdownSnapshot(event: event, phase: target == nil ? .unavailable : (remaining > 0 ? .pending : .arrived), targetAt: target, unavailableReason: event.type == .nextWorkEnd ? scheduleError : nil, remainingSeconds: remaining)
        }.sorted { ($0.phase == .pending ? 0 : 1, $0.targetAt ?? .distantFuture, $0.event.id) < ($1.phase == .pending ? 0 : 1, $1.targetAt ?? .distantFuture, $1.event.id) }
    }
    /// 最多安排一个任务，只有可见且变化的输出参与调度。
    public func refreshDelay(_ snapshots: [CountdownSnapshot], panelVisible: Bool, menuID: String?, incomeActive: Bool) -> TimeInterval? {
        if incomeActive { return 1 }
        let visible = snapshots.filter { $0.phase == .pending && (panelVisible || $0.event.id == menuID) }
        return visible.map { $0.remainingSeconds <= 86400 ? 1.0 : min(60, Double($0.remainingSeconds - 86400)) }.min()
    }
    /// 从昨日到未来一年枚举有界班次，支持长假覆盖，包含尚未开始和跨夜班次。
    private func nextWorkEnd(_ work: WorkSettings?, at now: Date) throws -> Date? {
        guard let work else { return nil }
        let today = calendar.startOfDay(for: now)
        for offset in -1...366 {
            let day = calendar.date(byAdding: .day, value: offset, to: today)!
            let holiday = work.chinaHolidayEnabled ? ChinaHolidayCalendar.day(on: day, calendar: calendar) : nil
            let scheduled = holiday.map { $0.kind == "makeup" } ?? work.weekdays.contains(calendar.component(.weekday, from: day))
            guard scheduled else { continue }
            let endMinute = work.endMinute + (work.endMinute < work.startMinute ? 1440 : 0)
            let targetDay = calendar.date(byAdding: .day, value: endMinute / 1440, to: day)!
            let a = calendar.date(bySettingHour: endMinute % 1440 / 60, minute: endMinute % 60, second: 0, of: targetDay, matchingPolicy: .strict, repeatedTimePolicy: .first)
            let b = calendar.date(bySettingHour: endMinute % 1440 / 60, minute: endMinute % 60, second: 0, of: targetDay, matchingPolicy: .strict, repeatedTimePolicy: .last)
            guard let end = a, a == b, calendar.isDate(end, inSameDayAs: targetDay) else { throw SettingsError.ambiguousTime }
            if end > now { return end }
        }
        return nil
    }
}
/// 原子保存倒计时，不更改旧工资文件或未知文件。
public struct CountdownStore {
    /// 与工资设置共用应用目录，但使用独立文件格式。
    public let directory: URL
    /// 独立的倒计时配置路径。
    public var fileURL: URL { directory.appendingPathComponent("countdowns.json") }
    /// 测试可传入隔离目录。
    public init(directory: URL) { self.directory = directory }
    /// 文件缺失使用默认值；损坏时保留原文件并报告错误。
    public func load() throws -> CountdownPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return CountdownPreferences() }
        do {
            let preferences = try JSONDecoder().decode(CountdownPreferences.self, from: Data(contentsOf: fileURL))
            try preferences.validate()
            return preferences
        } catch { throw CountdownError.invalid("倒计时配置无法读取；原文件已保留，请检查 countdowns.json。") }
    }
    /// 验证成功后一次写入，不逐秒写盘。
    public func save(_ preferences: CountdownPreferences) throws {
        try preferences.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(preferences).write(to: fileURL, options: .atomic)
    }
    /// 重置时只移除本功能的配置文件。
    public func clear() throws { if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) } }
}
