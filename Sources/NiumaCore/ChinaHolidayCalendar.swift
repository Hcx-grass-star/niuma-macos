import Foundation

/// 全国节假日安排中的单日覆盖规则。
public struct ChinaHolidayDay: Codable, Sendable {
    /// holiday 表示休息，makeup 表示调休上班。
    public let kind: String
    /// 面向用户的排班依据说明。
    public let label: String
}

/// 从应用内置 JSON 读取的中国大陆年度节假日安排。
public enum ChinaHolidayCalendar {
    /// 当前资源中有完整官方安排的年份。
    public static let supportedYears: Set<Int> = [2026]

    private struct Year: Decodable {
        /// 官方通知标题及编号。
        let source: String
        /// 官方通知页面地址，供数据维护和审计使用。
        let sourceUrl: String
        /// 该年度明确休息日和调休上班日的索引。
        let days: [String: ChinaHolidayDay]
    }

    private static let years: [String: Year] = load()

    /// 返回指定日期的全国覆盖规则，未内置年份或普通日期返回空。
    public static func day(on date: Date, calendar: Calendar) -> ChinaHolidayDay? {
        years[String(calendar.component(.year, from: date))]?.days[key(for: date, calendar: calendar)]
    }

    /// 返回年份是否有官方完整安排，供设置页解释回退行为。
    public static func hasData(for year: Int) -> Bool { years[String(year)] != nil }

    /// 返回开关开启后的日期依据说明。
    public static func reason(on date: Date, settings: WorkSettings, calendar: Calendar) -> String {
        guard settings.chinaHolidayEnabled else { return "按每周排班" }
        if let day = day(on: date, calendar: calendar) { return day.label }
        if !hasData(for: calendar.component(.year, from: date)) {
            return "\(calendar.component(.year, from: date))年安排缺失，按每周排班"
        }
        return "按每周排班"
    }

    /// 以本地日历生成资源使用的 YYYY-MM-DD 键。
    private static func key(for date: Date, calendar: Calendar) -> String {
        String(format: "%04d-%02d-%02d", calendar.component(.year, from: date),
               calendar.component(.month, from: date), calendar.component(.day, from: date))
    }

    /// 读取 SwiftPM 处理后的只读资源；资源损坏时按缺失年份安全回退。
    private static func load() -> [String: Year] {
        guard let url = Bundle.module.url(forResource: "china-holidays", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: Year].self, from: data) else { return [:] }
        return value
    }
}
