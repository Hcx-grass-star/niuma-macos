import Foundation
import UserNotifications
import NiumaCore

/// 在应用运行期间把收入引擎的下一个工作边界转换为一次系统提醒。
@MainActor
final class WorkReminderCoordinator {
    /// 系统通知中心；权限由系统统一管理，应用不保存账号或工资数据。
    private let center = UNUserNotificationCenter.current()
    /// 上一轮刷新已经等待的边界，重启后不会从过去的节点补发。
    private var armed: (date: Date, kind: WorkBoundaryKind)?
    /// 已经发送过的边界标识，防止同一事件因刷新重复发送。
    private var delivered = Set<String>()

    /// 请求提醒权限；用户拒绝时不影响收入计算和面板显示。
    func requestAuthorization() {
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    /// 清除当前等待的边界，设置变化后由下一次收入刷新重新建立。
    func reset() { armed = nil; delivered.removeAll(keepingCapacity: true) }

    /// 在边界被正常经过时发送提醒；错过较长时间的边界只重新等待下一项。
    func process(settings: WorkSettings?, snapshot: IncomeSnapshot, now: Date) {
        guard settings?.workReminders == true else {
            armed = nil
            return
        }

        if let armed, now >= armed.date {
            if now.timeIntervalSince(armed.date) <= 90 {
                deliver(kind: armed.kind, date: armed.date)
            }
            self.armed = nil
        }

        guard self.armed == nil,
              let date = snapshot.nextBoundary,
              let kind = snapshot.nextBoundaryKind,
              date > now else { return }
        self.armed = (date, kind)
    }

    /// 发送一次不含金额的本地通知，并用边界时间组成稳定标识。
    private func deliver(kind: WorkBoundaryKind, date: Date) {
        let identifier = String(Int(date.timeIntervalSince1970)) + ":" + kind.rawValue
        guard delivered.insert(identifier).inserted else { return }
        let content = UNMutableNotificationContent()
        content.title = kind.notificationTitle
        content.body = kind.notificationBody
        content.sound = .default
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}
