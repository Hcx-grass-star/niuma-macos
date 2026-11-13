import Foundation
import NiumaCore

/// 使用真实计薪、文件保存和会话状态验证三个打气功能的共同规则。
struct CheerIntegrationTests {
    /// 固定上海日历，跨年样例不依赖运行机器时间。
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    /// 构造精确的业务时间。
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, year: Int = 2026, month: Int = 11) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
    /// 日薪500元，含一小时非计薪午休。
    private func work() -> WorkSettings {
        var value = WorkSettings(); value.payMode = .daily; value.salary = 500
        value.weekdays = Set(1...7)
        return value
    }
    /// 只在显示边界舍入，与真实面板口径一致。
    private func rounded(_ amount: Decimal) -> Decimal {
        var input = amount; var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain); return output
    }
    /// 覆盖计薪交集、重复事件、跨年调薪、文件重载和非法配置。
    static func run() throws {
        let suite = CheerIntegrationTests(); let work = suite.work()
        let engine = IncomeEngine(calendar: suite.calendar)
        try expectEqual(suite.rounded(try engine.earned(work, from: suite.date(12, 10), to: suite.date(12, 10, 15))), Decimal(string: "15.63")!)
        try expectEqual(suite.rounded(try engine.earned(work, from: suite.date(12, 11, 50), to: suite.date(12, 12, 10))), Decimal(string: "10.42")!)
        try expectEqual(try engine.earned(work, from: suite.date(12, 18), to: suite.date(12, 23)), 0)
        try expectEqual(try engine.paidSeconds(work, from: suite.date(12, 11, 50), to: suite.date(12, 12, 10)), 600)
        var night = work; night.startMinute = 1320; night.endMinute = 360; night.rests = []
        try expectEqual(try engine.earned(night, from: suite.date(31, 23, year: 2026, month: 12), to: suite.date(1, 1, year: 2027, month: 1)), 125)
        var month = night; month.payMode = .monthly; month.salary = 31000; month.divisorMode = .schedule
        try expectEqual(try engine.earned(month, from: suite.date(31, 23, month: 10), to: suite.date(1, 1)), 250)
        var session = BreakSession()
        session.leave(reason: "lock", at: suite.date(12, 10))
        session.leave(reason: "sleep", at: suite.date(12, 10, 1))
        try expectNil(try session.returned(reason: "sleep", at: suite.date(12, 10, 10), work: work, engine: engine))
        let report = try session.returned(reason: "lock", at: suite.date(12, 10, 15), work: work, engine: engine)
        try expectEqual(suite.rounded(report!.amount), Decimal(string: "15.63")!)
        try expectNil(try session.returned(reason: "lock", at: suite.date(12, 10, 16), work: work, engine: engine))
        session.leave(reason: "lock", at: suite.date(12, 10))
        try expectNil(try session.returned(reason: "lock", at: suite.date(12, 10, 1), work: work, engine: engine))
        session.leave(reason: "lock", at: suite.date(12, 18))
        try expectNil(try session.returned(reason: "lock", at: suite.date(12, 19), work: work, engine: engine))
        session.leave(reason: "lock", at: suite.date(12, 10)); session.cancel()
        try expectNil(try session.returned(reason: "lock", at: suite.date(12, 11), work: work, engine: engine))

        var preferences = CheerPreferences()
        preferences = try preferences.settled(at: suite.date(31, 17, year: 2026, month: 12), work: work, engine: engine)
        let wish = CheerWish(name: "去海边", target: 1000, seed: 100, baseline: preferences.earned)
        preferences.wishes = [wish]
        preferences = try preferences.settled(at: suite.date(1, 10, year: 2027, month: 1), work: work, engine: engine)
        try expectEqual(suite.rounded(preferences.total(for: wish)), 225)
        var nextWork = work; nextWork.salary = 1000
        preferences.work = nextWork
        preferences = try preferences.settled(at: suite.date(1, 11, year: 2027, month: 1), work: nextWork, engine: engine)
        try expectEqual(suite.rounded(preferences.total(for: wish)), 350)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niuma-cheer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CheerStore(directory: directory)
        try store.save(preferences)
        let reloaded = try store.load()
        try expectEqual(reloaded, preferences)
        var invalid = preferences; invalid.wishes[0].target = 0
        try expectThrows { try store.save(invalid) }
        try expectEqual(try store.load(), preferences)
        var privacyWork = nextWork; privacyWork.hideAmounts = true
        let continued = try preferences.settled(at: suite.date(1, 12, year: 2027, month: 1), work: privacyWork, engine: engine)
        try expectEqual(suite.rounded(continued.total(for: wish)), 475)
        var changed = nextWork; changed.salary = 2000
        let uncertain = try preferences.settled(at: suite.date(1, 12, year: 2027, month: 1), work: changed, engine: engine)
        try expectEqual(uncertain.earned, preferences.earned)
        try expectTrue(WoodfishPolicy.shouldAutoStrike(enabled: true, working: true, visible: true, away: false))
        try expectTrue(!WoodfishPolicy.shouldAutoStrike(enabled: true, working: true, visible: false, away: false))
        try expectTrue(!WoodfishPolicy.shouldAutoStrike(enabled: true, working: false, visible: true, away: false))
        try expectTrue(!WoodfishPolicy.shouldAutoStrike(enabled: true, working: true, visible: true, away: true))
        let backward = try preferences.settled(at: suite.date(1, 9, year: 2027, month: 1), work: nextWork, engine: engine)
        try expectEqual(backward.earned, preferences.earned)
        var otherZone = suite.calendar; otherZone.timeZone = TimeZone(identifier: "Europe/London")!
        let moved = try preferences.settled(at: suite.date(1, 12, year: 2027, month: 1), work: nextWork, engine: IncomeEngine(calendar: otherZone))
        try expectEqual(moved.earned, preferences.earned)
        let originalData = try Data(contentsOf: store.fileURL)
        try Data("corrupt".utf8).write(to: store.fileURL)
        try expectThrows { try store.load() }
        try expectEqual(try Data(contentsOf: store.fileURL), Data("corrupt".utf8))
        try originalData.write(to: store.fileURL)
        try store.clear(); try expectEqual(try store.load(), CheerPreferences())
    }
}
