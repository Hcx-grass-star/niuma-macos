import Foundation
import NiumaCore

/// 通过真实文件保存、重新加载和收入计算验证需求中的业务链路。
@main
struct SalaryFlowIntegrationTests {
    /// 执行真实存储和计算的集成用例，任何失败都返回非零退出码。
    static func main() {
        let suite = SalaryFlowIntegrationTests()
        let cases: [(String, () throws -> Void)] = [
            ("月薪及休息边界", suite.testMonthlySavedScheduleAndRestBoundaries),
            ("日薪、折算及带薪休息", suite.testDailyFixedDivisorAndPaidBreak),
            ("跨夜及跨月", suite.testOvernightRestAndMonthOwnership),
            ("休息日和首次使用", suite.testOffDayAndUnconfiguredHaveNoAmount),
            ("无效保存保护旧设置", suite.testInvalidSavePreservesPreviousSettings),
            ("重置及损坏配置", suite.testResetAndCorruptFileRecovery),
            ("多段休息及下次状态边界", suite.testMultipleRestsAndNextBoundary),
            ("夏令时歧义拒绝", suite.testDaylightSavingAmbiguity)
        ]
        var failures = 0
        for (name, run) in cases {
            do { try run(); print("PASS: " + name) }
            catch { failures += 1; print("FAIL: " + name + " — " + error.localizedDescription) }
        }
        guard failures == 0 else { exit(1) }
        print("全部 " + String(cases.count) + " 组集成验证通过。")
    }

    /// 样例固定使用上海时区，避免运行机器时区影响断言。
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    /// 构造验收样例的明确本地日期，绝不修改系统时钟。
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 使用独立临时目录模拟保存后重启，再按指定时刻计算收入。
    private func persistedSnapshot(_ settings: WorkSettings, at now: Date) throws -> IncomeSnapshot {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.save(settings)
        return try IncomeEngine(calendar: calendar).evaluate(SettingsStore(directory: directory).load(), at: now)
    }

    /// 构造需求 A01 的月薪和默认工作作息。
    private func monthly() -> WorkSettings {
        var settings = WorkSettings()
        settings.salary = 21000
        return settings
    }

    /// 对内部未舍入金额仅在断言显示结果时取两位小数。
    private func amount(_ snapshot: IncomeSnapshot) -> Decimal? {
        guard var value = snapshot.amount else { return nil }
        var result = Decimal()
        NSDecimalRound(&result, &value, 2, .plain)
        return result
    }

    /// A02/A03/A04：保存重载后的午休、下午和下班收入一致。
    func testMonthlySavedScheduleAndRestBoundaries() throws {
        for (hour, minute, expected, phase) in [
            (8, 0, Decimal(0), WorkPhase.before),
            (12, 0, Decimal(375), .resting),
            (12, 30, Decimal(375), .resting),
            (14, 0, Decimal(500), .working),
            (18, 0, Decimal(1000), .finished),
            (20, 0, Decimal(1000), .finished)
        ] {
            let snapshot = try persistedSnapshot(monthly(), at: date(4, hour, minute))
            try expectEqual(amount(snapshot), expected)
            try expectEqual(snapshot.phase, phase)
        }
    }

    /// A05/A11/A23：日薪、手动折算和带薪休息均按保存后的配置计算。
    func testDailyFixedDivisorAndPaidBreak() throws {
        var settings = monthly()
        settings.payMode = .daily
        settings.salary = 800
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 11, 30))), 250)
        settings.divisorMode = .fixed
        settings.fixedDays = nil
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 11, 30))), 250)
        settings = monthly()
        settings.divisorMode = .fixed
        settings.fixedDays = 22
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 14))), Decimal(string: "477.27"))
        settings = monthly()
        settings.rests = []
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 14))), Decimal(string: "555.56"))
    }

    /// A09/A10/A24：跨午夜及跨月时仍使用班次开始日期和月份。
    func testOvernightRestAndMonthOwnership() throws {
        var settings = monthly()
        settings.payMode = .daily
        settings.salary = 800
        settings.startMinute = 1320
        settings.endMinute = 360
        settings.rests = []
        try expectEqual(amount(try persistedSnapshot(settings, at: date(3, 2))), 400)
        settings.rests = [.init(start: 120, end: 150)]
        for minute in [15, 30] {
            try expectEqual(amount(try persistedSnapshot(settings, at: date(3, 2, minute))), Decimal(string: "426.67"))
        }
        try expectEqual(amount(try persistedSnapshot(settings, at: date(3, 3))), 480)
        settings.payMode = .monthly
        settings.salary = 21000
        settings.rests = []
        try expectEqual(amount(try persistedSnapshot(settings, at: date(1, 2, month: 12))), 500)
    }

    /// A06：休息日无当前班次时不沿用上一班收入。
    func testOffDayAndUnconfiguredHaveNoAmount() throws {
        let snapshot = try persistedSnapshot(monthly(), at: date(7, 14))
        try expectEqual(snapshot.phase, .off)
        try expectNil(snapshot.amount)
        try expectNil(try IncomeEngine(calendar: calendar).evaluate(nil, at: date(4, 14)).amount)
    }

    /// A12/A16：不合法修改无法覆盖磁盘中原有的有效设置。
    func testInvalidSavePreservesPreviousSettings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let original = monthly()
        try store.save(original)
        var invalid = original
        invalid.salary = -1
        try expectThrows { try store.save(invalid) }
        try expectEqual(try store.load(), original)
        invalid = original
        invalid.rests.append(.init(start: 750, end: 800))
        try expectThrows { try store.save(invalid) }
        try expectEqual(try store.load(), original)
    }

    /// A30：重置仅删除配置，不影响目录中的未知文件。
    func testResetAndCorruptFileRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.save(monthly())
        let unrelated = directory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        try Data("broken".utf8).write(to: store.fileURL)
        try expectThrows { try store.load() }
        try expectEqual(try String(contentsOf: store.fileURL, encoding: .utf8), "broken")
        try store.clear()
        try expectNil(try store.load())
        try expectTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// 多段不计薪休息正确扣除，并给出停止轮询后的实际恢复时刻。
    func testMultipleRestsAndNextBoundary() throws {
        var settings = monthly()
        settings.rests.append(.init(start: 900, end: 915))
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 16))), Decimal(string: "741.94"))
        let resting = try persistedSnapshot(settings, at: date(4, 12, 30))
        try expectEqual(resting.nextBoundary, date(4, 13))
        let ended = try persistedSnapshot(settings, at: date(4, 18))
        try expectEqual(ended.nextBoundary, date(5, 9))
    }

    /// 非上海时区遇到重复或不存在的钟表时间时必须明确拒绝。
    func testDaylightSavingAmbiguity() throws {
        var clock = Calendar(identifier: .gregorian)
        clock.timeZone = TimeZone(identifier: "America/New_York")!
        var settings = monthly()
        settings.weekdays = Set(1...7)
        settings.rests = []
        settings.startMinute = 90
        settings.endMinute = 240
        let autumn = clock.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 3))!
        try expectThrows { try IncomeEngine(calendar: clock).evaluate(settings, at: autumn) }
        settings.startMinute = 150
        let spring = clock.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 4))!
        try expectThrows { try IncomeEngine(calendar: clock).evaluate(settings, at: spring) }
    }
}

/// 只携带断言说明，不记录工资配置或文件内容。
struct CheckFailure: Error, LocalizedError {
    /// 失败的验证条件。
    let message: String
    /// 供命令行显示的错误原因。
    var errorDescription: String? { message }
}

/// 比较集成链路的实际结果和明确的需求期望。
func expectEqual<T: Equatable>(_ actual: T, _ expected: T) throws {
    guard actual == expected else { throw CheckFailure(message: "实际结果与期望不一致") }
}

/// 验证没有收入或配置时，结果确实为空。
func expectNil<T>(_ value: T?) throws {
    guard value == nil else { throw CheckFailure(message: "期望为空") }
}

/// 验证文件等外部可观察条件成立。
func expectTrue(_ value: Bool) throws {
    guard value else { throw CheckFailure(message: "外部条件不成立") }
}

/// 验证无效操作明确失败，而非悄悄修改已保存结果。
func expectThrows<T>(_ operation: () throws -> T) throws {
    do { _ = try operation() }
    catch { return }
    throw CheckFailure(message: "无效操作没有被拒绝")
}
