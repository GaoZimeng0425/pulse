import Foundation

// MARK: - 告警通知缝(arch-clean/06 自 app target 的 Live 层迁入)

//
// 只有纯值与端口:授权三态、发送协议、跨缝载荷、文案与路由。UNUserNotificationCenter
// 的类型不出 Live 适配器(LiveAlertNotificationSender / AlertNotificationRouter)。

/// 系统通知授权三态。"没问过"与"已拒绝"必须分开:前者还能弹窗请求,后者
/// 系统不再弹窗、只能去 系统设置 → 通知 打开(2026-10-19 真机:二者合成一个
/// false 后,从未登记的 app 被误判为拒绝、永不再问)。
public enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
}

/// 发送缝:AlertCenter 只认此协议;单测注入假 sender 记录调用。
public protocol AlertNotificationSending: Sendable {
    /// 请求授权(true = 已授权)。系统侧幂等:已授权/已拒绝时不再弹窗。
    func requestAuthorization() async -> Bool
    /// 当前授权状态(只读查询,永不弹窗)。
    func authorizationStatus() async -> NotificationAuthorization
    /// 系统侧授权明细(状态原值 / 横幅开关 / 通知中心开关 / 提醒样式),只在
    /// 状态变化时取一次写日志——"已授权但横幅样式为无"这类看不见的情形靠它排查。
    func authorizationDiagnostics() async -> String
    /// 发一条告警通知。
    func send(_ payload: AlertNotificationPayload) async
    /// 打开 系统设置 → 通知 → 本 app(授权被拒后的唯一恢复入口;系统不再弹授权窗)。
    @MainActor func openSystemSettings()
}

/// 跨缝载荷:文案 + 点开路由。UNUserNotificationCenter 的类型不出缝。
public struct AlertNotificationPayload: Equatable, Sendable {
    /// 通知标识(同类同主体重发时系统侧替换旧条,不堆叠)。
    public let identifier: String
    public let title: String
    public let body: String
    public let route: AlertRoute

    public init(identifier: String, title: String, body: String, route: AlertRoute) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.route = route
    }
}

/// 告警通知的文案拼装与路由解析(纯逻辑,单测钉死;系统投递在 Live 的发送缝)。
public enum AlertNotificationContent {
    /// userInfo 里携带路由的键(点开通知 → 直达视图)。
    public static let routeUserInfoKey = "pulse.alertRoute"

    /// 通知 identifier(种类+主体):同类同主体重发即替换;AlertCenter 的
    /// 已送达去重集合同用此键(alert-toast-flake/01)。单一出处,勿手拼。
    public static func identifier(kind: AlertKind, subjectKey: String) -> String {
        "\(kind.rawValue)|\(subjectKey)"
    }

    /// 告警 → 通知载荷。identifier 稳定(种类+主体):同类同主体重发即替换。
    /// alert-offender-outlets:body 追加归因(有 entries 才追加),系统通知与
    /// 应用内提示行共用本函数——两出口「谁在吃」口径一致。
    public static func make(
        for occurrence: AlertOccurrence,
        offender: AlertOffenderSummary = .none
    ) -> AlertNotificationPayload {
        AlertNotificationPayload(
            identifier: identifier(kind: occurrence.kind, subjectKey: occurrence.subjectKey),
            title: title(for: occurrence),
            body: body(for: occurrence, offender: offender),
            route: occurrence.kind.route
        )
    }

    public static func title(for occurrence: AlertOccurrence) -> String {
        let subject = occurrence.subjectName
        switch occurrence.kind {
        case .systemLoad: return "系统负载过高"
        case .groupCPU: return "\(subject ?? "组") CPU 过高"
        case .newGroupMemory: return "新组「\(subject ?? "未知")」占用大量内存"
        case .diskAvailable: return "磁盘空间不足"
        case .devServerIdle: return "dev server 长时间闲置"
        }
    }

    public static func body(
        for occurrence: AlertOccurrence,
        offender: AlertOffenderSummary = .none
    ) -> String {
        let base: String
        switch occurrence.kind {
        case .systemLoad:
            base = "系统 CPU 负载 \(PulseFormat.cpuPercent(occurrence.value)),持续过高。"
        case .groupCPU:
            base = "CPU \(PulseFormat.cpuPercent(occurrence.value)),持续过高。"
        case .newGroupMemory:
            base = "内存 \(PulseFormat.memory(UInt64(max(0, occurrence.value))))。"
        case .diskAvailable:
            return "可用 \(PulseFormat.diskCapacity(UInt64(max(0, occurrence.value)))),剩余空间紧张。"
        case .devServerIdle:
            return "「\(occurrence.subjectName ?? "dev server")」已闲置 \(PulseFormat.duration(seconds: occurrence.value)),确认一下是否还需要。"
        }
        // 磁盘/dev server 无归因不硬造(上方已 return);CPU/内存类有归因进程才
        // 追加——正文两行内点名「谁在吃」,组名随引导语带出(系统级告警组名
        // 不在 title,组级告警 title 已有,引导语统一带括号保持口径)。
        guard !offender.entries.isEmpty else { return base }
        let lead: String = switch occurrence.kind {
        case .newGroupMemory:
            offender.groupName.map { "占内存最多(\($0))" } ?? "占内存最多"
        default:
            offender.groupName.map { "最耗 CPU(\($0))" } ?? "最耗 CPU"
        }
        let metric: (AlertOffenderEntry) -> String? = occurrence.kind == .newGroupMemory
            ? { entry in PulseFormat.memory(entry.memoryBytes) }
            : { entry in entry.cpuPercent.map { PulseFormat.cpuPercent($0) } }
        return base + AlertOffenderAttribution.bodyText(lead: lead, entries: offender.entries, metric: metric)
    }

    /// userInfo → 路由(缺失/未知值 = nil,调用方回落"只开窗不切页")。
    public static func route(from userInfo: [AnyHashable: Any]) -> AlertRoute? {
        guard let raw = userInfo[routeUserInfoKey] as? String else { return nil }
        return AlertRoute(rawValue: raw)
    }
}
