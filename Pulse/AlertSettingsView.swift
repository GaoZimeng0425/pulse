import SwiftUI

/// 告警设置页(工单 P1-07):五条预设规则逐条开关、阈值可改,改动即时生效
/// 并持久(AlertSettingsStore 直写;引擎下轮喂食即按新配置评估)。授权时序
/// 由 AlertCenter 接管(首开任一规则才请求);此处展示授权现状与降级提示。
/// 仅展示数据源已接线的规则(dev server 闲置随工单 08 接入后再入列)。
struct AlertSettingsView: View {
    /// 告警编排:开关/阈值动作与授权状态都走它。
    let center: AlertCenter

    var body: some View {
        Form {
            if center.authorizationDenied {
                Section {
                    Text("系统通知未授权——规则照常判定,告警降级为应用内提示。关闭再重新开启任一规则可重新走授权(系统不再弹窗时,请到 系统设置 → 通知 → Pulse 打开)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(AlertKind.allCases.filter(\.isDataSourceWired)) { kind in
                ruleSection(kind)
            }
            Section("说明") {
                Text("触发条件:读数连续 3 次越阈(带持续时长的规则还要跨越该时长);恢复需连续 6 次回到阈值 ∓20% 之外(迟滞防抖,避免阈值附近抖动连环轰炸);同类告警触发后进入 10 分钟冷却期。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// 单规则一节:开关行 + 阈值行。
    @ViewBuilder
    private func ruleSection(_ kind: AlertKind) -> some View {
        Section {
            Toggle(isOn: enabledBinding(kind)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(subtitle(kind))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if center.store.config(for: kind).isEnabled {
                thresholdField(kind)
            }
        }
    }

    /// 开关绑定:经 AlertCenter(授权时序挂在这里,不能直写 store)。
    private func enabledBinding(_ kind: AlertKind) -> Binding<Bool> {
        Binding(
            get: { center.store.config(for: kind).isEnabled },
            set: { center.setEnabled($0, for: kind) }
        )
    }

    /// 阈值输入:百分比规则填 %,字节规则填 GB;提交即生效即持久。
    @ViewBuilder
    private func thresholdField(_ kind: AlertKind) -> some View {
        switch kind {
        case .systemLoad, .groupCPU:
            LabeledContent("阈值") {
                TextField(
                    "阈值",
                    value: percentBinding(kind),
                    format: .number.precision(.fractionLength(0...1))
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                Text("%")
            }
        case .newGroupMemory, .diskAvailable, .devServerIdle:
            LabeledContent("阈值") {
                TextField(
                    "阈值",
                    value: gigabyteBinding(kind),
                    format: .number.precision(.fractionLength(0...1))
                )
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                Text(kind == .devServerIdle ? "小时" : "GB")
            }
        }
    }

    /// 百分比阈值绑定(store 存原生单位 %)。
    private func percentBinding(_ kind: AlertKind) -> Binding<Double> {
        Binding(
            get: { center.store.config(for: kind).threshold },
            set: { center.setThreshold($0, for: kind) }
        )
    }

    /// 字节/秒阈值绑定:UI 以 GB(或小时)编辑,store 存原生单位。
    private func gigabyteBinding(_ kind: AlertKind) -> Binding<Double> {
        Binding(
            get: {
                switch kind {
                case .devServerIdle: center.store.config(for: kind).threshold / 3600
                default: center.store.config(for: kind).threshold / 1_073_741_824
                }
            },
            set: { value in
                switch kind {
                case .devServerIdle: center.setThreshold(value * 3600, for: kind)
                default: center.setThreshold(value * 1_073_741_824, for: kind)
                }
            }
        )
    }

    /// 开关下的说明行(与 spec 预设一致)。
    private func subtitle(_ kind: AlertKind) -> String {
        switch kind {
        case .systemLoad: "系统 CPU 负载持续高于阈值 5 分钟时提醒"
        case .groupCPU: "任一组 CPU 持续高于阈值 10 分钟时提醒(逐组判定)"
        case .newGroupMemory: "新出现的组出生即占用超过阈值内存且稳住三轮时提醒"
        case .diskAvailable: "磁盘可用空间低于阈值时提醒(Finder「可用」口径)"
        case .devServerIdle: "dev server 闲置超过阈值时提醒(argv 识别;最近 10 分钟 CPU≈0 记闲置)"
        }
    }
}

#Preview("告警设置") {
    let center = AlertCenter(
        store: AlertSettingsStore(
            load: {
                [
                    AlertKind.systemLoad: AlertRuleConfig(isEnabled: true, threshold: 70),
                    AlertKind.diskAvailable: AlertRuleConfig(isEnabled: true, threshold: 20 * 1_073_741_824),
                ]
            },
            persist: { _ in },
            loadAuthorizationFlag: { true },
            persistAuthorizationFlag: { _ in }
        ),
        sender: SettingsPreviewDeniedSender()
    )
    return AlertSettingsView(center: center).frame(width: 480, height: 520)
}

/// 预览用假 sender(拒绝授权,呈现降级提示;文件内私有,与其他预览替身互不相干)。
private struct SettingsPreviewDeniedSender: AlertNotificationSending {
    func requestAuthorization() async -> Bool { false }
    func isAuthorized() async -> Bool { false }
    func send(_ payload: AlertNotificationPayload) async {}
}
