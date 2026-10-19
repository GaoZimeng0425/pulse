import XCTest
import UserNotifications
@testable import Pulse

/// 接缝:通知发送薄封装(spec 测试决策:OS 边界只冒烟,不深测——文案拼装与
/// 路由解析是纯逻辑在此钉死;真实授权弹窗、系统投递与点开横幅属真机走查,
/// 工单验收"通知授权时序正确(首开才请求)"由真机点击验证)。
final class AlertNotificationSmokeTests: XCTestCase {

    // MARK: - 文案拼装(纯逻辑)

    func testContentBuilderProducesTitleBodyAndRoute() {
        let occurrence = AlertOccurrence(
            kind: .groupCPU,
            subjectKey: "bundle:/Applications/X.app",
            subjectName: "Xcode",
            value: 350,
            firedAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let payload = AlertNotificationContent.make(for: occurrence)
        XCTAssertFalse(payload.title.isEmpty)
        XCTAssertFalse(payload.body.isEmpty)
        XCTAssertTrue(payload.title.contains("Xcode"), "组告警标题带组名")
        XCTAssertTrue(payload.body.contains("350"), "正文带触发读数")
        XCTAssertEqual(payload.route, .cpu)
        XCTAssertEqual(payload.identifier, "groupCPU|bundle:/Applications/X.app", "标识 = 种类|主体(重发替换)")
    }

    func testRouteParsingRoundTripAndFallback() {
        let route = AlertNotificationContent.route(
            from: [AlertNotificationContent.routeUserInfoKey: AlertRoute.disk.rawValue]
        )
        XCTAssertEqual(route, .disk)

        XCTAssertNil(AlertNotificationContent.route(from: [:]), "缺路由 = nil(只开窗不切页)")
        XCTAssertNil(
            AlertNotificationContent.route(from: [AlertNotificationContent.routeUserInfoKey: "bogus"]),
            "未知路由 = nil"
        )
    }

    func testSystemNotificationSettingsDeepLinkSelectsThisApp() {
        // 授权被拒后的恢复入口:直达 系统设置 → 通知 → 本 app(?id= 选中 bundle)。
        XCTAssertEqual(
            SystemNotificationSettings.url(bundleIdentifier: "com.gaozimeng.pulse")?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.gaozimeng.pulse"
        )
    }

    // MARK: - Live 冒烟

    func testLiveSenderAuthorizationQueryRuns() async {
        // 只读查询(getNotificationSettings),不弹授权窗;返回值本身即真机现状。
        let status = await LiveAlertNotificationSender().authorizationStatus()
        print("[smoke] 通知授权现状: \(status)")
        // 请求授权动作会弹窗,不在冒烟内(真机走查覆盖,工单验收项)。
    }

    func testRouterActivationRecordsPendingTab() {
        // 路由 delegate 的可测切片:激活 → 记落点 → 广播。真实 openWindow 接线
        // 在常驻视图(真机走查),这里钉状态与广播载荷。
        MainActor.assumeIsolated {
            let router = AlertNotificationRouter()
            var received: MetricTab?
            let token = NotificationCenter.default.addObserver(
                forName: AlertNotificationRouter.openMainWindowNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let raw = notification.userInfo?[AlertNotificationRouter.tabUserInfoKey] as? String {
                    received = MetricTab(rawValue: raw)
                }
            }
            defer { NotificationCenter.default.removeObserver(token) }

            router.activate(tab: .disk)

            XCTAssertEqual(router.pendingTab, .disk, "主窗口出现时消费落点")
            XCTAssertEqual(received, .disk, "广播载荷带 tab")
        }
    }
}
