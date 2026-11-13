import Foundation

/// 愿望是独立的预估进度，不是资金分配或真实储蓄余额。
public struct CheerWish: Codable, Equatable, Sendable {
    /// 编辑及删除时保持稳定的身份。
    public var id: String = UUID().uuidString
    /// 用户输入的纯文本名称。
    public var name: String
    /// 预估目标金额，最多两位小数。
    public var target: Decimal
    /// 用户手动补入的已有金额。
    public var seed: Decimal
    /// 创建时的全局累计起点，跨年不清零。
    public var baseline: Decimal
    /// 创建愿望时显式记录当前累计起点。
    public init(name: String, target: Decimal, seed: Decimal, baseline: Decimal) {
        self.name = name; self.target = target; self.seed = seed; self.baseline = baseline
    }
}

/// 与工资独立保存的打气配置及配置生效区间累计检查点。
public struct CheerPreferences: Codable, Equatable, Sendable {
    /// 文件格式版本；未知版本保留原文件并报错。
    public var version = 1
    /// 最多三个愿望，各自独立展示相同新增收入。
    public var wishes: [CheerWish] = []
    /// 战报需要用户主动开启。
    public var reportsEnabled = false
    /// 系统通知不包含任何金额或愿望名称。
    public var notificationsEnabled = true
    /// 自动木鱼只在工作中可见时运行，默认关闭。
    public var autoWood = false
    /// 木鱼默认静音。
    public var sound = false
    /// 已结算的累计收入，不依赖本年回算值。
    public var earned: Decimal = 0
    /// 最近一次成功结算时间；重启可从该时刻继续。
    public var checkpoint: Date?
    /// 检查点之后生效的工资规则，不保存所有历史规则。
    public var work: WorkSettings?
    /// 时区变化时放弃无法确定的未结算区间。
    public var timeZone: String?
    /// 首次使用不创建虚构工资、愿望或累计值。
    public init() {}

    /// 只比较影响收入的字段，隐私或面板设置变化不切断累计。
    public static func sameIncomeRules(_ lhs: WorkSettings?, _ rhs: WorkSettings?) -> Bool {
        guard let lhs, let rhs else { return lhs == rhs }
        return lhs.payMode == rhs.payMode && lhs.salary == rhs.salary && lhs.weekdays == rhs.weekdays
            && lhs.startMinute == rhs.startMinute && lhs.endMinute == rhs.endMinute && lhs.rests == rhs.rests
            && lhs.divisorMode == rhs.divisorMode && lhs.fixedDays == rhs.fixedDays && lhs.chinaHolidayEnabled == rhs.chinaHolidayEnabled
    }

    /// 同一配置和时区才回补收入；配置不一致、时钟回拨时只重新建立起点。
    public func settled(at now: Date, work current: WorkSettings?, engine: IncomeEngine) throws -> CheerPreferences {
        var next = self
        if !wishes.isEmpty, let checkpoint, now > checkpoint, let work,
           Self.sameIncomeRules(work, current), timeZone == engine.calendar.timeZone.identifier {
            next.earned += try engine.earned(work, from: checkpoint, to: now)
        }
        next.checkpoint = now; next.work = current; next.timeZone = engine.calendar.timeZone.identifier
        return next
    }

    /// 任一愿望使用同一累计基准，编辑已有金额不会改变其他愿望。
    public func total(for wish: CheerWish) -> Decimal { max(0, wish.seed + earned - wish.baseline) }

    /// 校验存储结构、唯一标识和金额精度，禁止静默吞掉损坏数据。
    public func validate() throws {
        guard version == 1, wishes.count <= 3, Set(wishes.map(\.id)).count == wishes.count,
              !earned.isNaN, earned >= 0 else { throw CheerError.invalid("打气配置格式无效。") }
        for wish in wishes {
            guard !wish.id.isEmpty, !wish.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  wish.name.count <= 20, !wish.name.contains(where: { $0.isNewline }),
                  validMoney(wish.target, positive: true), validMoney(wish.seed, positive: false),
                  !wish.baseline.isNaN, wish.baseline >= 0, wish.baseline <= earned else {
                throw CheerError.invalid("愿望名称须为1–20字；目标须大于0，已有金额不能为负，金额最多两位小数且不超过99,999,999元。")
            }
        }
        if let work { try work.validate() }
    }

    /// 用户输入金额限制在可显示范围，并拒绝非有限值与过多小数。
    private func validMoney(_ amount: Decimal, positive: Bool) -> Bool {
        guard !amount.isNaN, amount >= 0, amount <= 99_999_999, !positive || amount > 0 else { return false }
        var input = amount; var rounded = Decimal(); NSDecimalRound(&rounded, &input, 2, .plain)
        return amount == rounded
    }
}

/// 一次离开期间的收入解释，不会再次计入工资。
public struct BreakReport: Equatable, Sendable {
    /// 离开的绝对起点。
    public let start: Date
    /// 返回的绝对时刻。
    public let end: Date
    /// 该区间的未舍入预估收入。
    public let amount: Decimal
    /// 排除非计薪休息后的秒数。
    public let paidSeconds: TimeInterval
}

/// 锁屏、休眠与屏幕熄灭可交叠，只在所有离开原因结束后生成一条战报。
public struct BreakSession: Sendable {
    /// 活跃原因集合防止重复事件重置起点。
    private var reasons = Set<String>()
    /// 第一次离开起点，重启不保存不补发。
    private var start: Date?
    /// 自动木鱼可复用该状态暂停。
    public var isAway: Bool { !reasons.isEmpty }
    /// 创建不含任何历史离开记录的会话。
    public init() {}
    /// 第一次离开记录起点，重复或交叠事件只添加原因。
    public mutating func leave(reason: String, at now: Date) {
        if reasons.isEmpty { start = now }
        reasons.insert(reason)
    }
    /// 所有原因结束且满两分钟时结算，未知或重复返回不产生副作用。
    public mutating func returned(reason: String, at now: Date, work: WorkSettings?, engine: IncomeEngine) throws -> BreakReport? {
        guard reasons.remove(reason) != nil, reasons.isEmpty else { return nil }
        let beginning = start; start = nil
        guard let beginning, now.timeIntervalSince(beginning) >= 120, let work else { return nil }
        let amount = try engine.earned(work, from: beginning, to: now)
        guard amount >= Decimal(string: "0.005")! else { return nil }
        return BreakReport(start: beginning, end: now, amount: amount,
                           paidSeconds: try engine.paidSeconds(work, from: beginning, to: now))
    }
    /// 规则变化时保留离开原因以继续暂停木鱼，但取消该次战报起点。
    public mutating func invalidate() { start = nil }
    /// 配置、时区或时钟异常后不猜测该次离开区间。
    public mutating func cancel() { reasons.removeAll(); start = nil }
}

/// 自动敲击条件由核心统一表达，界面收起、下班及离开时必须停止。
public enum WoodfishPolicy {
    /// 仅主动开启、工作中、木鱼可见且未离开时允许定时敲击。
    public static func shouldAutoStrike(enabled: Bool, working: Bool, visible: Bool, away: Bool) -> Bool {
        enabled && working && visible && !away
    }
}

/// 可直接展示给用户的打气配置错误。
public enum CheerError: LocalizedError {
    case invalid(String)
    /// 返回具体失败原因，不包含用户金额。
    public var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

/// 打气配置单独原子保存，读取失败保留原文件。
public struct CheerStore {
    /// 测试可注入独立目录，不接触正式数据。
    public let directory: URL
    /// 本功能唯一拥有的配置文件。
    public var fileURL: URL { directory.appendingPathComponent("cheer.json") }
    /// 创建存储对象不提前写盘。
    public init(directory: URL) { self.directory = directory }
    /// 缺失返回空配置；未知版本或损坏数据明确报错。
    public func load() throws -> CheerPreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return CheerPreferences() }
        do {
            let value = try JSONDecoder().decode(CheerPreferences.self, from: Data(contentsOf: fileURL))
            try value.validate(); return value
        } catch { throw CheerError.invalid("打气配置无法读取，原 cheer.json 已保留。") }
    }
    /// 先校验再原子写入，失败不破坏上一份有效配置。
    public func save(_ value: CheerPreferences) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
    }
    /// 只删除本功能拥有的文件，不触碰未知文件。
    public func clear() throws { if FileManager.default.fileExists(atPath: fileURL.path) { try FileManager.default.removeItem(at: fileURL) } }
}
