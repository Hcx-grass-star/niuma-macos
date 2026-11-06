import Foundation
import NiumaCore

/// 通过真实文件重载验证自定义倒计时、排班目标与按需刷新。
enum CountdownIntegrationTests {
    /// 使用独立目录，不读取或覆盖用户的正式配置。
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let engine = CountdownEngine(calendar: calendar)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 17))!
        var work = WorkSettings()
        work.salary = 21000
        var preferences = CountdownPreferences()
        preferences.events = [CountdownEvent(title: "离职", targetAt: now.addingTimeInterval(180000)), CountdownEvent(title: "下班", type: .nextWorkEnd)]
        preferences.menuMode = .both
        preferences.menuCountdownID = preferences.events[0].id
        preferences.menuWidth = 120
        let store = CountdownStore(directory: directory)
        try store.save(preferences)
        let loaded = try store.load()
        try expectEqual(loaded, preferences)
        let results = try engine.evaluate(loaded.events, work: work, at: now)
        try expectEqual(results[0].remainingSeconds, 3600)
        try expectEqual(results[0].menuText, "下班 01:00:00")
        try expectNil(engine.refreshDelay(results, panelVisible: false, menuID: nil, incomeActive: false))
        try expectEqual(engine.refreshDelay(results, panelVisible: false, menuID: preferences.events[0].id, incomeActive: false), 60)
        let mondayEnd = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 18))!
        let next = try engine.evaluate([preferences.events[1]], work: work, at: now.addingTimeInterval(3600))
        try expectEqual(next[0].targetAt, mondayEnd)
        work.startMinute = 1320
        work.endMinute = 360
        let night = try engine.evaluate([preferences.events[1]], work: work, at: now.addingTimeInterval(9 * 3600))
        try expectEqual(night[0].remainingSeconds, 4 * 3600)
        let arrived = try engine.evaluate([preferences.events[0]], work: nil, at: now.addingTimeInterval(180000))
        try expectEqual(arrived[0].phase, .arrived)
        try expectNil(engine.refreshDelay(arrived, panelVisible: true, menuID: nil, incomeActive: false))
        preferences.events[0].title = " "
        try expectThrows { try store.save(preferences) }
        try expectEqual(try store.load(), loaded)
        work = WorkSettings(); work.salary = 21000; work.chinaHolidayEnabled = true
        let holidayNow = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10))!
        let makeupEnd = calendar.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 18))!
        let holiday = try engine.evaluate([loaded.events[1]], work: work, at: holidayNow)
        try expectEqual(holiday[0].targetAt, makeupEnd)
        var dst = Calendar(identifier: .gregorian)
        dst.timeZone = TimeZone(identifier: "America/New_York")!
        work.startMinute = 30; work.endMinute = 90; work.weekdays = Set(1...7)
        let repeatedTime = dst.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0))!
        let isolated = try CountdownEngine(calendar: dst).evaluate(loaded.events, work: work, at: repeatedTime)
        try expectEqual(isolated.first { $0.event.type == .nextWorkEnd }?.phase, .unavailable)
        try expectTrue(isolated.first { $0.event.type == .fixed }?.phase == .pending)
        preferences = loaded
        preferences.menuWidth = 241
        try expectThrows { try store.save(preferences) }
        try expectEqual(try store.load(), loaded)
        try store.clear()
        try expectTrue(try store.load().events.isEmpty)
        print("PASS: 倒计时保存重载、跨夜周末、到达和按需调度")
    }
}
