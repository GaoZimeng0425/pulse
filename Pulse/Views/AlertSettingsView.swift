import PulseCore
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
                    Text("系统通知已被拒绝——规则照常判定,告警降级为应用内提示。在系统设置里打开 Pulse 的通知即可恢复,无需重启。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    // 拒绝后系统不再弹授权窗:一键直达 系统设置 → 通知 → Pulse。
                    Button("打开系统通知设置…") {
                        SystemNotificationSettings.open()
                    }
                }
            }
            if center.authorizationRequestFailed {
                Section {
                    Text("系统通知授权请求没有完成(弹窗可能被勿扰模式收起,或系统报错)——告警暂时仅在应用内提示。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("重新请求授权") {
                        center.retryAuthorization()
                    }
                }
            }
            ForEach(AlertKind.allCases.filter(\.isDataSourceWired)) { kind in
                ruleSection(kind)
            }
            Section("投递渠道") {
                Toggle(isOn: toastDeliveryBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NemoNotch 卡片")
                        Text("资源类告警经本机 NemoNotch 在刘海下弹卡片,点名最耗资源的进程;NemoNotch 未运行时静默跳过。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: systemDeliveryBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("系统通知")
                        Text("macOS 通知横幅。未手动改过时与 NemoNotch 卡片互斥:开了卡片就不发横幅,一条告警只弹一处;两个都想要就都打开。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("说明") {
                Text("触发条件:读数连续 3 次越阈(带持续时长的规则还要跨越该时长);恢复需连续 6 次回到阈值 ∓20% 之外(迟滞防抖,避免阈值附近抖动连环轰炸);同类告警触发后进入 10 分钟冷却期。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
        .padding()
    }

    /// 单规则一节:开关行 + 阈值行。
    private func ruleSection(_ kind: AlertKind) -> some View {
        Section {
            Toggle(isOn: enabledBinding(kind)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                    Text(subtitle(kind))
                        .font(.system(size: 11))
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

    /// NemoNotch 投递开关绑定(无授权时序,直写 store)。
    private var toastDeliveryBinding: Binding<Bool> {
        Binding(
            get: { center.store.toastDeliveryEnabled },
            set: { center.store.setToastDeliveryEnabled($0) }
        )
    }

    /// 系统通知投递开关绑定(显式写死独立键;授权状态展示照旧,开关本身不触发请求)。
    private var systemDeliveryBinding: Binding<Bool> {
        Binding(
            get: { center.store.systemDeliveryEnabled },
            set: { center.store.setSystemDeliveryEnabled($0) }
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
                    format: .number.precision(.fractionLength(0 ... 1))
                )
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 80)
                Text("%")
            }
        case .newGroupMemory, .diskAvailable, .devServerIdle:
            LabeledContent("阈值") {
                TextField(
                    "阈值",
                    value: gigabyteBinding(kind),
                    format: .number.precision(.fractionLength(0 ... 1))
                )
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
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
            persist: { _ in }
        ),
        sender: SettingsPreviewDeniedSender(),
        toastSender: InertNemoNotchToastSender()
    )
    return AlertSettingsView(center: center).frame(width: 480, height: 520)
}

/// 预览用假 sender(拒绝授权,呈现降级提示;文件内私有,与其他预览替身互不相干)。
private struct SettingsPreviewDeniedSender: AlertNotificationSending {
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
