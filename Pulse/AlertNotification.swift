import Foundation
import UserNotifications
import AppKit

// MARK: - 通知发送缝(spec 六缝之「通知发送」)
//
// 薄封装:授权请求 / 授权查询 / 发送三件事直通 UNUserNotificationCenter,
// 缝上无逻辑(纯逻辑在 AlertNotificationContent 的文案拼装与路由解析,可单测;
// 真实授权弹窗与系统投递属真机走查,冒烟即 spec 测试决策)。

/// 系统通知授权三态。"没问过"与"已拒绝"必须分开:前者还能弹窗请求,后者
/// 系统不再弹窗、只能去 系统设置 → 通知 打开(2026-10-19 真机:二者合成一个
/// false 后,从未登记的 app 被误判为拒绝、永不再问)。
enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized

    /// 系统原值 → 三态(纯映射,单测钉死):provisional 静默送达算可发
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

/// 发送缝:AlertCenter 只认此协议;单测注入假 sender 记录调用。
protocol AlertNotificationSending: Sendable {
    /// 请求授权(true = 已授权)。系统侧幂等:已授权/已拒绝时不再弹窗。
    func requestAuthorization() async -> Bool
    /// 当前授权状态(只读查询,永不弹窗)。
    func authorizationStatus() async -> NotificationAuthorization
    /// 系统侧授权明细(状态原值 / 横幅开关 / 通知中心开关 / 提醒样式),只在
    /// 状态变化时取一次写日志——"已授权但横幅样式为无"这类看不见的情形靠它排查。
    func authorizationDiagnostics() async -> String
    /// 发一条告警通知。
    func send(_ payload: AlertNotificationPayload) async
}

/// 跨缝载荷:文案 + 点开路由。UNUserNotificationCenter 的类型不出缝。
struct AlertNotificationPayload: Equatable, Sendable {
    /// 通知标识(同类同主体重发时系统侧替换旧条,不堆叠)。
    let identifier: String
    let title: String
    let body: String
    let route: AlertRoute
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
        NotificationAuthorization(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
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

// MARK: - 文案拼装与路由解析(纯逻辑,冒烟/单测钉死)

enum AlertNotificationContent {
    /// userInfo 里携带路由的键(点开通知 → 直达视图)。
    static let routeUserInfoKey = "pulse.alertRoute"

    /// 告警 → 通知载荷。identifier 稳定(种类+主体):同类同主体重发即替换。
    static func make(for occurrence: AlertOccurrence) -> AlertNotificationPayload {
        AlertNotificationPayload(
            identifier: "\(occurrence.kind.rawValue)|\(occurrence.subjectKey)",
            title: title(for: occurrence),
            body: body(for: occurrence),
            route: occurrence.kind.route
        )
    }

    static func title(for occurrence: AlertOccurrence) -> String {
        let subject = occurrence.subjectName
        switch occurrence.kind {
        case .systemLoad: return "系统负载过高"
        case .groupCPU: return "\(subject ?? "组") CPU 过高"
        case .newGroupMemory: return "新组「\(subject ?? "未知")」占用大量内存"
        case .diskAvailable: return "磁盘空间不足"
        case .devServerIdle: return "dev server 长时间闲置"
        }
    }

    static func body(for occurrence: AlertOccurrence) -> String {
        switch occurrence.kind {
        case .systemLoad:
            "系统 CPU 负载 \(PulseFormat.cpuPercent(occurrence.value)),持续过高。"
        case .groupCPU:
            "CPU \(PulseFormat.cpuPercent(occurrence.value)),持续过高。"
        case .newGroupMemory:
            "内存 \(PulseFormat.memory(UInt64(max(0, occurrence.value))))。"
        case .diskAvailable:
            "可用 \(PulseFormat.diskCapacity(UInt64(max(0, occurrence.value)))),剩余空间紧张。"
        case .devServerIdle:
            "「\(occurrence.subjectName ?? "dev server")」已闲置 \(PulseFormat.duration(seconds: occurrence.value)),确认一下是否还需要。"
        }
    }

    /// userInfo → 路由(缺失/未知值 = nil,调用方回落"只开窗不切页")。
    static func route(from userInfo: [AnyHashable: Any]) -> AlertRoute? {
        guard let raw = userInfo[routeUserInfoKey] as? String else { return nil }
        return AlertRoute(rawValue: raw)
    }
}

// MARK: - 点通知路由(delegate + 主窗口激活)

/// UNUserNotificationCenter delegate:点开通知 → 激活 app → 记下落点 tab →
/// 广播开主窗口。popover 无法程序化打开,深链一律落主窗口(spec 既定)。
/// 激活与落点在这里;开窗动作由常驻视图(MenuBarExtra label,持 openWindow
/// 环境)响应广播完成——两个动作先激活后开窗,与弹窗"在窗口中打开"按钮同序。
@MainActor
final class AlertNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    /// 开窗广播名:常驻视图监听它调用 openWindow(id: main)。
    static let openMainWindowNotification = Notification.Name("pulse.alert.openMainWindow")
    static let tabUserInfoKey = "tab"

    /// 落点 tab(主窗口出现/存活时消费并清空;消费方同模块)。
    private(set) var pendingTab: MetricTab?

    /// 主窗口消费落点后清空(避免下次开窗重复跳转)。
    func consumePendingTab() -> MetricTab? {
        defer { pendingTab = nil }
        return pendingTab
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
        pendingTab = tab
        NotificationCenter.default.post(
            name: Self.openMainWindowNotification,
            object: nil,
            userInfo: [Self.tabUserInfoKey: tab.rawValue]
        )
    }
}
