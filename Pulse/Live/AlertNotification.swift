import AppKit
import Foundation
import PulseCore
import UserNotifications

// MARK: - 通知发送缝(spec 六缝之「通知发送」)

//
// 薄封装:授权请求 / 授权查询 / 发送三件事直通 UNUserNotificationCenter,
// 缝上无逻辑(纯逻辑在 AlertNotificationContent 的文案拼装与路由解析,可单测;
// 真实授权弹窗与系统投递属真机走查,冒烟即 spec 测试决策)。

extension NotificationAuthorization {
    /// 系统原值 → 三态(枚举本体在 PulseCore 的 AlertNotificationPort;纯映射,单测钉死):provisional 静默送达算可发
    /// (本 app 从不申请 provisional);未知新值按拒绝——不弹窗、不循环请求,
    /// 原值随状态变化日志里的系统侧明细留痕。
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional:
            self = .authorized
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        @unknown default:
            self = .denied
        }
    }
}

/// Darwin 薄适配器(与 LiveDiskCapacitySource 同一角色)。
struct LiveAlertNotificationSender: AlertNotificationSending {
    /// 请求失败(签名 / 系统拒绝登记等)如实记日志——曾被 try? 吞掉,
    /// 授权链路断在哪里无从查起。
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            LogService.info("通知授权请求结果:\(granted ? "已允许" : "未允许")", category: "Alert")
            return granted
        } catch {
            LogService.error("通知授权请求失败:\(error)", category: "Alert")
            return false
        }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        await NotificationAuthorization(UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    func authorizationDiagnostics() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return "status=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue)"
            + " center=\(settings.notificationCenterSetting.rawValue) style=\(settings.alertStyle.rawValue)"
    }

    func send(_ payload: AlertNotificationPayload) async {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default
        content.userInfo = [AlertNotificationContent.routeUserInfoKey: payload.route.rawValue]
        let request = UNNotificationRequest(
            identifier: payload.identifier, content: content, trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // 投递失败如实留痕(已授权却投不出去时,签名 / 注册异常靠它排查)。
            LogService.error("通知投递失败(\(payload.identifier)):\(error)", category: "Alert")
        }
    }

    @MainActor
    func openSystemSettings() {
        SystemNotificationSettings.open()
    }
}

// MARK: - 系统通知设置深链(授权被拒时的恢复入口)

/// 系统设置 → 通知 → 本 app 的深链(macOS 13+ 设置扩展 id,`?id=` 直接选中本 app)。
/// 拒绝后系统不再弹授权窗,用户只能去系统设置里打开——入口必须一键直达,
/// 不让用户自己翻找(2026-10-19 走查用户反馈)。
enum SystemNotificationSettings {
    static func url(bundleIdentifier: String) -> URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)")
    }

    @MainActor
    static func open() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier,
              let url = url(bundleIdentifier: bundleIdentifier),
              NSWorkspace.shared.open(url)
        else {
            LogService.error("打开系统通知设置失败", category: "Alert")
            return
        }
    }
}

// MARK: - 点通知路由(delegate + 主窗口激活)

/// UNUserNotificationCenter delegate:点开通知 → 激活 app → 记下落点 tab →
/// 广播开主窗口。popover 无法程序化打开,深链一律落主窗口(spec 既定)。
/// 激活与落点在这里;开窗动作由常驻视图(MenuBarExtra label,持 openWindow
/// 环境)响应广播完成——两个动作先激活后开窗,与弹窗"在窗口中打开"按钮同序。
@MainActor
final class AlertNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// 落点状态与开窗广播(纯状态,功能层 / 视图层只认它,不认本 delegate)。
    let landing: MainWindowLanding

    init(landing: MainWindowLanding) {
        self.landing = landing
        super.init()
    }

    /// 前台收到通知也横幅提示(菜单栏 app 常驻后台,横幅不打断)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// 点开通知:解析路由 → 激活 app → 记落点 → 广播开窗。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let route = AlertNotificationContent.route(from: response.notification.request.content.userInfo)
        else { return }
        await activate(tab: route.tab)
    }

    /// 激活 + 记落点 + 广播(先激活后开窗,LSUIElement 的 .accessory 策略下
    /// openWindow 只建窗不抢前台,实机沉淀见 DashboardView)。
    func activate(tab: MetricTab) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        landing.land(tab: tab)
    }
}
