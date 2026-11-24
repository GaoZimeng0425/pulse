import PulseCore
import SwiftUI

// MARK: - 应用内告警提示(工单 P1-07)

//
// 两个角色:①通知授权被拒时的降级出口(spec:拒绝后规则照常判定、降级为
// 应用内提示);②常态的"触发中"状态展示(授权正常时也如实显示,不打扰)。
// 数据源 = AlertCenter.activeAlerts(@Observable,每轮引擎评估驱动)。UI 层
// 不单测,spec 测试决策(P0 既定:预览 + 真机走查)。

/// 紧凑告警横幅:弹窗(footer 上方)专用。主窗口 2026-11-16 起改走页头小条
/// `AlertHeaderIndicator`(用户实报:横幅在页头下方铺开,出现/消失把内容推下移),
/// 大字号形态随之收编,只留弹窗紧凑档。
/// 无触发中告警时整体不渲染(零占用)。
struct AlertBannerView: View {
    /// 告警编排(读 activeAlerts 与授权状态)。
    let center: AlertCenter

    var body: some View {
        if !center.activeAlerts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(center.activeAlerts, id: \.self) { occurrence in
                    row(occurrence)
                }
                if center.authorizationDenied {
                    HStack(spacing: 6) {
                        Text("系统通知已被拒绝,告警仅在应用内提示。")
                            .foregroundStyle(.secondary)
                        // 拒绝后系统不再弹授权窗:一键直达 系统设置 → 通知 → Pulse。
                        Button("打开系统通知设置") {
                            SystemNotificationSettings.open()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                }
                if center.authorizationRequestFailed {
                    HStack(spacing: 6) {
                        Text("系统通知授权未完成,告警仅在应用内提示。")
                            .foregroundStyle(.secondary)
                        Button("重新请求") {
                            center.retryAuthorization()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 语义警示色淡底({colors.state-warning}),{rounded.inner} 10;无描边(DESIGN.md)。
            .background(Surface.warning.opacity(0.12), in: .rect(cornerRadius: 10))
        }
    }

    /// 单条触发中告警:铃铛 + 标题 + 读数副文。副文与系统通知共用同一拼装
    /// 函数(alert-offender-outlets),归因行(fired 时按触发当轮算好存在
    /// center.offenders)自动同口径——应用内提示也点名「谁在吃」。
    private func row(_ occurrence: AlertOccurrence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: IconSize.inline, weight: .semibold))
                .foregroundStyle(Surface.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(AlertNotificationContent.title(for: occurrence))
                    .font(.system(size: 11, weight: .semibold))
                Text(AlertNotificationContent.body(
                    for: occurrence,
                    offender: center.offenders[occurrence.offenderKey] ?? .none
                ))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// 页头告警小条(2026-11-16 用户拍板):主窗口页头右侧配件槽的单行提示——
/// 铃铛 + 首条标题(多条「系统负载过高 等 N 项」),告警出没不再推内容下移;
/// 每条的读数与归因「谁在吃」进悬停提示(副文与系统通知同源
/// `AlertNotificationContent.body`,弹窗横幅同口径)。授权异常只在悬停里注明,
/// 深链入口随弹窗横幅与设置页。无触发中告警时整体不渲染(零占用)。
struct AlertHeaderIndicator: View {
    /// 告警编排(读 activeAlerts 与授权状态)。
    let center: AlertCenter

    var body: some View {
        if !center.activeAlerts.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: IconSize.inline, weight: .semibold))
                    .foregroundStyle(Surface.warning)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            // 与弹窗横幅同配方:{colors.state-warning} 淡底 + {rounded.inner} 10,无描边。
            .background(Surface.warning.opacity(0.12), in: .rect(cornerRadius: 10))
            .help(tooltip)
        }
    }

    /// 一条 = 标题;多条 = 首条 + 计数,恒一行。
    private var headline: String {
        let alerts = center.activeAlerts
        guard alerts.count > 1 else { return AlertNotificationContent.title(for: alerts[0]) }
        return "\(AlertNotificationContent.title(for: alerts[0])) 等 \(alerts.count) 项"
    }

    /// 悬停列全部:每条「标题 · 归因」一行;授权异常加尾行(主窗口无深链按钮,指路弹窗/设置)。
    private var tooltip: String {
        var lines = center.activeAlerts.map { occurrence in
            let body = AlertNotificationContent.body(
                for: occurrence,
                offender: center.offenders[occurrence.offenderKey] ?? .none
            )
            return "\(AlertNotificationContent.title(for: occurrence)) · \(body)"
        }
        if center.authorizationDenied {
            lines.append("系统通知已被拒绝,告警仅在应用内提示(可在设置中打开)。")
        }
        if center.authorizationRequestFailed {
            lines.append("系统通知授权未完成,告警仅在应用内提示。")
        }
        return lines.joined(separator: "\n")
    }
}

#Preview("横幅:触发中 1 条") {
    let center = AlertCenter(
        store: AlertSettingsStore(
            load: {
                [AlertKind.diskAvailable: AlertRuleConfig(isEnabled: true, threshold: 20 * 1_073_741_824)]
            },
            persist: { _ in }
        ),
        sender: PreviewDeniedAlertSender(),
        toastSender: InertNemoNotchToastSender(),
        clock: { Date() }
    )
    center.activeAlerts = [
        AlertOccurrence(
            kind: .diskAvailable,
            subjectKey: "disk",
            subjectName: nil,
            value: 18.2 * 1_073_741_824,
            firedAt: Date()
        ),
    ]
    return VStack(alignment: .leading, spacing: 16) {
        AlertHeaderIndicator(center: center)
        Divider()
        AlertBannerView(center: center)
    }
    .padding(24)
}

/// 预览用假 sender(拒绝授权,呈现降级提示)。
private struct PreviewDeniedAlertSender: AlertNotificationSending {
    func requestAuthorization() async -> Bool {
        false
    }

    func authorizationStatus() async -> NotificationAuthorization {
        .denied
    }

    func authorizationDiagnostics() async -> String {
        "preview"
    }

    func send(_ payload: AlertNotificationPayload) async {}
}
