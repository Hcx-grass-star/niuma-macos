import Foundation

/// 可提醒的工作边界，不包含收入金额或工资信息。
public enum WorkBoundaryKind: String, Sendable {
    case shiftStart
    case restStart
    case restEnd
    case shiftEnd

    /// 通知标题，使用用户能直接理解的动作描述。
    public var notificationTitle: String {
        switch self {
        case .shiftStart: return "该开始上班了"
        case .restStart: return "休息一下"
        case .restEnd: return "休息结束"
        case .shiftEnd: return "今天辛苦了"
        }
    }

    /// 通知正文，避免泄露工资金额并说明下一步。
    public var notificationBody: String {
        switch self {
        case .shiftStart: return "新的一班开始了，按自己的节奏来。"
        case .restStart: return "非计薪休息开始，先离开屏幕放松一下。"
        case .restEnd: return "休息结束，回来继续完成今天的安排。"
        case .shiftEnd: return "今天的班结束了，可以安心收工。"
        }
    }
}
