import Foundation
import PulseCore

/// 主窗口落点(arch-clean/06 自 AlertNotificationRouter 拆出):「下次开主窗口落到哪个 tab /
/// 展开哪张排行卡」的纯状态 + 开窗广播。点通知(Live 的 AlertNotificationRouter)、弹窗
/// 「查看全部」(DashboardView)、菜单栏控制器都经它记落点;常驻视图监听广播调 openWindow。
/// 不碰 AppKit / UserNotifications——激活 app 由 Live 路由器在调用 `land` 前完成。
@MainActor
final class MainWindowLanding {
    /// 开窗广播名:常驻视图监听它调用 openWindow(id: main)。
    static let openMainWindowNotification = Notification.Name("pulse.alert.openMainWindow")
    static let tabUserInfoKey = "tab"
    /// 落地即展开的排行卡 id(弹窗「查看全部」,ranking-limit/01)。
    static let rankingUserInfoKey = "ranking"

    /// 落点 tab(主窗口出现/存活时消费并清空;消费方同模块)。
    private(set) var pendingTab: MetricTab?
    /// 落点排行卡(主窗口出现时消费并清空;弹窗「查看全部」冷开窗专用)。
    private(set) var pendingRankingID: String?

    init() {}

    /// 主窗口消费落点后清空(避免下次开窗重复跳转)。
    func consumePendingTab() -> MetricTab? {
        defer { pendingTab = nil }
        return pendingTab
    }

    func consumePendingRankingID() -> String? {
        defer { pendingRankingID = nil }
        return pendingRankingID
    }

    /// 记落点但不广播:弹窗侧的跳转(「查看全部」/ 底排开窗)自己广播,菜单栏控制器收到
    /// 广播后经此记落点——窗口未建时(冷开窗)onReceive 收不到,主窗口出现再消费才落对页。
    func stash(tab: MetricTab, rankingID: String?) {
        pendingTab = tab
        pendingRankingID = rankingID
    }

    /// 主窗口存活时已按广播直接落地,清掉落点——否则下次冷开窗会把这次的落点重放一遍。
    func clearPending() {
        pendingTab = nil
        pendingRankingID = nil
    }

    /// 记落点 + 广播开窗(调用方已先激活 app)。
    func land(tab: MetricTab) {
        pendingTab = tab
        NotificationCenter.default.post(
            name: Self.openMainWindowNotification,
            object: nil,
            userInfo: [Self.tabUserInfoKey: tab.rawValue]
        )
    }
}
