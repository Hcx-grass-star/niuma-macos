import Foundation
import NiumaCore

/// 验证工作边界类型可被收入快照复用，保证提醒不重新实现排班规则。
struct WorkReminderIntegrationTests {
    /// 使用上海时区构造稳定的边界样例。
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    /// 构造固定本地时间，避免测试依赖运行机器当前日期。
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// 创建默认月薪班次并显式打开提醒偏好。
    private func settings() -> WorkSettings {
        var value = WorkSettings()
        value.salary = 21000
        value.workReminders = true
        return value
    }

    /// 验证上班、休息结束和下班边界按现有收入计算统一生成。
    static func run() throws {
        let suite = WorkReminderIntegrationTests()
        let engine = IncomeEngine(calendar: suite.calendar)
        let value = suite.settings()
        let before = try engine.evaluate(value, at: suite.date(9, 8, 59))
        try expect(before.nextBoundaryKind == .shiftStart, "上班前应识别上班开始提醒")
        try expect(before.nextBoundary == suite.date(9, 9, 0), "上班前边界应为 09:00")

        let resting = try engine.evaluate(value, at: suite.date(9, 12, 30))
        try expect(resting.phase == .resting, "午休时应保持休息状态")
        try expect(resting.nextBoundaryKind == .restEnd, "午休时应识别休息结束提醒")

        let finished = try engine.evaluate(value, at: suite.date(9, 18, 0))
        try expect(finished.phase == .finished, "18:00 应识别为本班结束")
        try expect(finished.nextBoundaryKind == .shiftStart, "下班后应等待下一次上班开始")

        let oldConfiguration = try JSONDecoder().decode(WorkSettings.self, from: Data(#"{"salary":21000}"#.utf8))
        try expect(!oldConfiguration.workReminders, "旧配置缺少提醒字段时应保持关闭")

        let encoded = try JSONEncoder().encode(value)
        let reloaded = try JSONDecoder().decode(WorkSettings.self, from: encoded)
        try expect(reloaded.workReminders, "提醒开关保存后应能恢复")
    }

    /// 使用明确失败信息终止当前集成验证。
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw NSError(domain: "WorkReminderIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
