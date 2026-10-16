import SwiftUI

// MARK: - 应用内告警提示(工单 P1-07)
//
// 两个角色:①通知授权被拒时的降级出口(spec:拒绝后规则照常判定、降级为
// 应用内提示);②常态的"触发中"状态展示(授权正常时也如实显示,不打扰)。
// 数据源 = AlertCenter.activeAlerts(@Observable,每轮引擎评估驱动)。UI 层
// 不单测,spec 测试决策(P0 既定:预览 + 真机走查)。

/// 紧凑告警横幅:弹窗(footer 上方)与主窗口(内容头下方)共用。
/// 无触发中告警时整体不渲染(零占用)。
struct AlertBannerView: View {
    /// 告警编排(读 activeAlerts 与授权状态)。
    let center: AlertCenter
    /// 紧凑形态(弹窗):字号更小。
    var isCompact = false

    var body: some View {
        if !center.activeAlerts.isEmpty {
            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                ForEach(center.activeAlerts, id: \.self) { occurrence in
                    row(occurrence)
                }
                if center.authorizationDenied {
                    Text("系统通知未授权,告警仅在应用内提示(可在设置 → 告警中重新开启授权)。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, isCompact ? 10 : 12)
            .padding(.vertical, isCompact ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5)
            )
        }
    }

    /// 单条触发中告警:铃铛 + 标题 + 读数副文。
    private func row(_ occurrence: AlertOccurrence) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(AlertNotificationContent.title(for: occurrence))
                    .font(.system(size: isCompact ? 11 : 12.5, weight: .semibold))
                Text(AlertNotificationContent.body(for: occurrence))
                    .font(.system(size: isCompact ? 10 : 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

#Preview("横幅:触发中 1 条") {
    let center = AlertCenter(
        store: AlertSettingsStore(
            load: {
                [AlertKind.diskAvailable: AlertRuleConfig(isEnabled: true, threshold: 20 * 1_073_741_824)]
            },
            persist: { _ in },
            loadAuthorizationFlag: { true },
            persistAuthorizationFlag: { _ in }
        ),
        sender: PreviewDeniedAlertSender(),
        clock: { Date() }
    )
    center.activeAlerts = [
        AlertOccurrence(
            kind: .diskAvailable,
            subjectKey: "disk",
            subjectName: nil,
            value: 18.2 * 1_073_741_824,
            firedAt: Date()
        )
    ]
    return VStack(spacing: 16) {
        AlertBannerView(center: center)
        AlertBannerView(center: center, isCompact: true)
    }
    .padding(24)
}

/// 预览用假 sender(拒绝授权,呈现降级提示)。
private struct PreviewDeniedAlertSender: AlertNotificationSending {
    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func send(_ payload: AlertNotificationPayload) async {}
}
