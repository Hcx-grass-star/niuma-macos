import Foundation
import NiumaCore

/// 通过真实文件保存、重新加载和收入计算验证需求中的业务链路。
@main
struct SalaryFlowIntegrationTests {
    /// 执行真实存储和计算的集成用例，任何失败都返回非零退出码。
    static func main() async {
        let suite = SalaryFlowIntegrationTests()
        if CommandLine.arguments.contains("--month-fixtures") {
            do { try suite.exportMonthFixtures() }
            catch { print("本月样例导出失败"); exit(1) }
            return
        }
        let cases: [(String, () throws -> Void)] = [
            ("月薪及休息边界", suite.testMonthlySavedScheduleAndRestBoundaries),
            ("日薪、折算及带薪休息", suite.testDailyFixedDivisorAndPaidBreak),
            ("跨夜及跨月", suite.testOvernightRestAndMonthOwnership),
            ("休息日和首次使用", suite.testOffDayAndUnconfiguredHaveNoAmount),
            ("无效保存保护旧设置", suite.testInvalidSavePreservesPreviousSettings),
            ("重置及损坏配置", suite.testResetAndCorruptFileRecovery),
            ("多段休息及下次状态边界", suite.testMultipleRestsAndNextBoundary),
            ("夏令时歧义拒绝", suite.testDaylightSavingAmbiguity),
            ("本年预估收入", suite.testYearToDateAmount),
            ("年度回算边界", suite.testYearToDateBoundaries),
            ("中国节假日及调休", suite.testChinaHolidaySchedule),
            ("本月收入与菜单栏选择", suite.testMonthIncome),
            ("收入面板显示偏好", suite.testIncomeVisibility),
            ("面板外观持久化与旧配置兼容", suite.testPanelAppearance),
            ("复用引擎后的配置变更", suite.testReusableEngine),
            ("包环境识别及自启动准入", BuildChannelIntegrationTests.run)
        ]
        var failures = 0
        for (name, run) in cases {
            do { try run(); print("PASS: " + name) }
            catch { failures += 1; print("FAIL: " + name + " — " + error.localizedDescription) }
        }
        do { try await UpdateIntegrationTests.run() }
        catch { failures += 1; print("FAIL: 更新检查 — " + error.localizedDescription) }
        guard failures == 0 else { exit(1) }
        print("全部 " + String(cases.count) + " 组收入集成与更新检查验证通过。")
    }

    /// 向跨运行时验证脚本输出受控时间的统计值，不读取用户配置或系统时钟。
    private func exportMonthFixtures() throws {
        var output: [[String: Any]] = []
        for profile in 0..<4 {
            var settings = monthly()
            if profile == 1 {
                settings.weekdays = Set(1...7)
                settings.salary = 31000
                settings.startMinute = 1320
                settings.endMinute = 360
                settings.rests = []
            }
            if profile == 2 { settings.chinaHolidayEnabled = true }
            if profile == 3 { settings.divisorMode = .fixed; settings.fixedDays = 22 }
            for (index, point) in [(2026, 1, 4, 14), (2026, 2, 1, 2), (2026, 11, 4, 14), (2026, 12, 31, 23), (2027, 1, 1, 2), (2024, 3, 1, 0)].enumerated() {
                let now = date(point.2, point.3, month: point.1, year: point.0)
                let snapshot = try persistedSnapshot(settings, at: now)
                output.append([
                    "id": String(profile) + ":" + String(index),
                    "month": NSDecimalNumber(decimal: snapshot.monthToDateAmount!).doubleValue,
                    "year": NSDecimalNumber(decimal: snapshot.yearToDateAmount!).doubleValue
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    /// 样例固定使用上海时区，避免运行机器时区影响断言。
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return result
    }

    /// 构造验收样例的明确本地日期，绝不修改系统时钟。
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
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

    /// 对本年累计金额使用与当前金额相同的两位小数展示规则。
    private func amount(_ value: Decimal?) -> Decimal? {
        guard var value else { return nil }
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

    /// 本年金额按当前配置回算，包含已完成班次和当前班次的已计薪部分。
    func testYearToDateAmount() throws {
        let working = try persistedSnapshot(monthly(), at: date(4, 14))
        try expectEqual(amount(working.yearToDateAmount), Decimal(212500))
        let offDay = try persistedSnapshot(monthly(), at: date(8, 14))
        try expectEqual(offDay.phase, .off)
        try expectEqual(amount(offDay.yearToDateAmount), Decimal(215000))
        try expectNil(try IncomeEngine(calendar: calendar).evaluate(nil, at: date(4, 14)).yearToDateAmount)
        var changed = monthly()
        changed.salary = 42000
        try expectEqual(amount(try persistedSnapshot(changed, at: date(4, 14)).yearToDateAmount), 425000)
    }

    /// 验证年度截断、闰日、固定折算与休息扣除，不依赖真实系统日期。
    func testYearToDateBoundaries() throws {
        var settings = monthly()
        settings.payMode = .daily
        settings.salary = 800
        for (hour, minute, expected) in [(0, 0, 0), (12, 0, 300), (12, 30, 300), (18, 0, 800)] {
            let result = try persistedSnapshot(settings, at: date(1, hour, minute, month: 1))
            try expectEqual(amount(result.yearToDateAmount), Decimal(expected))
        }
        let yearEnd = try persistedSnapshot(settings, at: date(31, 20, month: 12))
        try expectEqual(yearEnd.nextBoundary, date(1, 0, month: 1, year: 2027))
        settings.weekdays = Set(1...7)
        let leap = try persistedSnapshot(settings, at: date(1, 9, month: 3, year: 2024))
        try expectEqual(amount(leap.yearToDateAmount), 48000)
        settings.payMode = .monthly
        settings.salary = 31000
        let february = try persistedSnapshot(settings, at: date(1, 14, month: 2))
        try expectEqual(amount(february.yearToDateAmount), Decimal(string: "31553.57"))
        settings.startMinute = 1320
        settings.endMinute = 360
        settings.rests = []
        let midnight = try persistedSnapshot(settings, at: date(1, 0, month: 1))
        try expectEqual(amount(midnight.yearToDateAmount), 0)
        let overnight = try persistedSnapshot(settings, at: date(1, 2, month: 1))
        try expectEqual(amount(overnight), 500)
        try expectEqual(amount(overnight.yearToDateAmount), 250)
        settings.rests = [.init(start: 0, end: 60)]
        let resting = try persistedSnapshot(settings, at: date(1, 0, 30, month: 1))
        try expectEqual(amount(resting.yearToDateAmount), 0)
        settings = monthly()
        settings.salary = 22000
        settings.divisorMode = .fixed
        settings.fixedDays = 22
        let fixed = try persistedSnapshot(settings, at: date(2, 14, month: 1))
        try expectEqual(amount(fixed.yearToDateAmount), 1500)
    }

    /// 第一期：2026 官方放假、补班覆盖每周排班，2027 缺失时回退每周排班。
    func testChinaHolidaySchedule() throws {
        var settings = monthly()
        settings.chinaHolidayEnabled = true
        try expectEqual(IncomeEngine(calendar: calendar).workdays(in: date(1, 12, month: 1, year: 2026), settings: settings), 21)
        let holiday = try persistedSnapshot(settings, at: date(1, 14, month: 1, year: 2026))
        try expectEqual(holiday.phase, .off)
        try expectEqual(holiday.scheduleReason, "节假日休息")
        let makeup = try persistedSnapshot(settings, at: date(4, 14, month: 1, year: 2026))
        try expectEqual(makeup.phase, .working)
        try expectEqual(amount(makeup), 500)
        try expectEqual(makeup.scheduleReason, "调休上班")
        let missingYear = try persistedSnapshot(settings, at: date(1, 14, month: 1, year: 2027))
        try expectEqual(missingYear.phase, .working)
        try expectEqual(missingYear.scheduleReason, "2027年安排缺失，按每周排班")
        let longHoliday = try persistedSnapshot(settings, at: date(15, 12, month: 2))
        try expectEqual(longHoliday.nextBoundary, date(24, 9, month: 2))
        settings.chinaHolidayEnabled = false
        try expectEqual(try persistedSnapshot(settings, at: date(1, 14, month: 1, year: 2026)).phase, .working)
    }

    /// 本月金额跨月跨年截断，菜单栏切换保存重载，隐私状态优先于指标选择。
    func testMonthIncome() throws {
        var settings = monthly()
        let snapshot = try persistedSnapshot(settings, at: date(4, 14))
        try expectEqual(amount(snapshot.monthToDateAmount), 2500)
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 12)).monthToDateAmount), 2375)
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 12, 30)).monthToDateAmount), 2375)
        try expectEqual(amount(try persistedSnapshot(settings, at: date(4, 18)).monthToDateAmount), 3000)
        var changed = settings
        changed.salary = 42000
        try expectEqual(amount(try persistedSnapshot(changed, at: date(4, 14)).monthToDateAmount), 5000)
        changed.payMode = .daily
        changed.salary = 800
        try expectEqual(amount(try persistedSnapshot(changed, at: date(4, 14)).monthToDateAmount), 2000)
        changed = settings
        changed.divisorMode = .fixed
        changed.fixedDays = 22
        try expectEqual(amount(try persistedSnapshot(changed, at: date(4, 14)).monthToDateAmount), Decimal(string: "2386.36"))
        settings.menuBarDisplay = .month
        try expectEqual(amount(settings.menuBarAmount(in: snapshot)), 2500)
        settings.menuBarDisplay = .current
        try expectEqual(amount(settings.menuBarAmount(in: snapshot)), 500)
        settings.menuBarDisplay = .icon
        try expectNil(settings.menuBarAmount(in: snapshot))
        settings.menuBarDisplay = .month
        settings.hideAmounts = true
        try expectNil(settings.menuBarAmount(in: snapshot))
        settings.hideAmounts = false
        let off = try persistedSnapshot(settings, at: date(8, 14))
        try expectEqual(amount(settings.menuBarAmount(in: off)), 5000)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-menu-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        try store.save(settings)
        try expectEqual(try SettingsStore(directory: directory).load()?.menuBarDisplay, .month)
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        old.removeValue(forKey: "menuBarDisplay")
        old["menuBarIncome"] = true
        var loaded = try JSONDecoder().decode(WorkSettings.self, from: JSONSerialization.data(withJSONObject: old))
        try expectEqual(loaded.menuBarDisplay, .current)
        old["menuBarIncome"] = false
        loaded = try JSONDecoder().decode(WorkSettings.self, from: JSONSerialization.data(withJSONObject: old))
        try expectEqual(loaded.menuBarDisplay, .icon)
        settings.weekdays = Set(1...7)
        settings.salary = 31000
        settings.startMinute = 1320
        settings.endMinute = 360
        settings.rests = []
        let february = try persistedSnapshot(settings, at: date(1, 2, month: 2))
        try expectEqual(amount(february), 500)
        try expectEqual(amount(february.monthToDateAmount), 250)
        try expectEqual(amount(try persistedSnapshot(settings, at: date(1, 0, month: 2)).monthToDateAmount), 0)
        let january = try persistedSnapshot(settings, at: date(1, 2, month: 1))
        try expectEqual(amount(january.monthToDateAmount), amount(january.yearToDateAmount))
        settings.payMode = .daily
        settings.salary = 800
        settings.startMinute = 540
        settings.endMinute = 1080
        try expectEqual(amount(try persistedSnapshot(settings, at: date(29, 18, month: 2, year: 2024)).monthToDateAmount), 23200)
        try expectNil(try IncomeEngine(calendar: calendar).evaluate(nil, at: date(4, 14)).monthToDateAmount)
    }

    /// 三项显示偏好独立保存重载，旧配置默认全开，显示选择不改变金额或菜单栏指标。
    func testIncomeVisibility() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-display-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        for mask in 0..<8 {
            var settings = monthly()
            settings.showCurrentIncome = mask & 1 != 0
            settings.showMonthlyIncome = mask & 2 != 0
            settings.showYearlyIncome = mask & 4 != 0
            settings.menuBarDisplay = .month
            try store.save(settings)
            let loaded = try SettingsStore(directory: directory).load()!
            try expectEqual(loaded, settings)
            let snapshot = try IncomeEngine(calendar: calendar).evaluate(loaded, at: date(4, 14))
            try expectEqual(amount(snapshot), 500)
            try expectEqual(amount(loaded.menuBarAmount(in: snapshot)), 2500)
        }
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(monthly())) as! [String: Any]
        for key in ["showCurrentIncome", "showMonthlyIncome", "showYearlyIncome"] { old.removeValue(forKey: key) }
        let loaded = try JSONDecoder().decode(WorkSettings.self, from: JSONSerialization.data(withJSONObject: old))
        try expectTrue(loaded.showCurrentIncome && loaded.showMonthlyIncome && loaded.showYearlyIncome)
    }

    /// 从实际 JSON 保存重载外观，验证旧字段缺省及非法颜色不会覆盖已保存设置。
    func testPanelAppearance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-appearance-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(monthly())) as! [String: Any]
        payload["panelAppearance"] = ["glassEnabled": true, "mode": "dark", "tintHex": "3377BB"]
        let settings = try JSONDecoder().decode(WorkSettings.self, from: JSONSerialization.data(withJSONObject: payload))
        try store.save(settings)
        let loaded = try store.load()!
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
        let appearance = encoded["panelAppearance"] as? [String: Any]
        try expectTrue(appearance?["glassEnabled"] as? Bool == true)
        try expectTrue(appearance?["mode"] as? String == "dark")
        try expectTrue(appearance?["tintHex"] as? String == "3377BB")
        try expectEqual(loaded.salary, monthly().salary)
        try expectEqual(amount(try IncomeEngine(calendar: calendar).evaluate(loaded, at: date(4, 14))), 500)

        payload.removeValue(forKey: "panelAppearance")
        let legacy = try JSONDecoder().decode(WorkSettings.self, from: JSONSerialization.data(withJSONObject: payload))
        let migrated = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        let defaults = migrated["panelAppearance"] as? [String: Any]
        try expectTrue(defaults?["glassEnabled"] as? Bool == false)
        try expectTrue(defaults?["mode"] as? String == "system")
        try expectTrue(defaults?["tintHex"] == nil)
        for color in ["#3377BB", "123", "GGHHII", "3377BBFF", "3377BB\n"] {
            payload["panelAppearance"] = ["glassEnabled": false, "mode": "light", "tintHex": color]
            let invalid = try JSONDecoder().decode(WorkSettings.self, from: JSONSerialization.data(withJSONObject: payload))
            try expectThrows { try store.save(invalid) }
            try expectEqual(try store.load(), loaded)
        }
    }

    /// 真实保存、重载后复用同一引擎，工资、排班及月份改变不能沿用错误计数。
    func testReusableEngine() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-cache-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        let engine = IncomeEngine(calendar: calendar)
        var settings = monthly()
        for (salary, weekdays, expected) in [(21000, Set([2, 3, 4, 5, 6]), "500"),
                                              (42000, Set([2, 3, 4, 5, 6]), "1000"),
                                              (21000, Set(1...7), "350")] {
            settings.salary = Decimal(salary)
            settings.weekdays = weekdays
            try store.save(settings)
            let loaded = try store.load()!
            for _ in 0..<3 {
                try expectEqual(amount(try engine.evaluate(loaded, at: date(4, 14))), Decimal(string: expected)!)
            }
        }
        settings = monthly()
        settings.chinaHolidayEnabled = true
        try store.save(settings)
        let loaded = try store.load()!
        try expectEqual(try engine.evaluate(loaded, at: date(4, 14, month: 1)).phase, .working)
        settings.chinaHolidayEnabled = false
        try store.save(settings)
        try expectEqual(try engine.evaluate(store.load(), at: date(4, 14, month: 1)).phase, .off)
        // 换月及缓存容量淘汰后，工作日数量仍按该月实际天数计算。
        settings.weekdays = Set(1...7)
        for year in 2024...2028 {
            for month in 1...12 {
                let now = date(4, 14, month: month, year: year)
                try expectEqual(engine.workdays(in: now, settings: settings), calendar.range(of: .day, in: .month, for: now)!.count)
            }
        }
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
func expectEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) throws {
    guard actual == expected else { throw CheckFailure(message: "实际结果与期望不一致（用例行 \(line)）") }
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
