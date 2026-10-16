import Foundation
import Observation

/// 告警编排(工单 P1-07,MainActor 粘合层):喂食 → 引擎评估 → 三路出口——
/// ①系统通知(已授权才发);②应用内提示(activeAlerts,授权被拒时的降级出口,
/// 主窗口与弹窗常显);③日志(告警触发/恢复,spec"过渡非轮询"惯例)。
///
/// 授权时序(spec):用户**首次开启任一规则**才请求授权;拒绝后规则照常判定,
/// 只是不发系统通知(activeAlerts 照常更新 = 应用内提示)。
/// UI 不单测,此处粘合逻辑经注入 sender/时钟的 AlertCenterTests 覆盖。
@Observable
@MainActor
final class AlertCenter {
    /// 配置存储(设置页与引擎共用;改动即时生效)。
    let store: AlertSettingsStore

    /// 触发中未解除的告警(新在前;应用内提示的唯一数据源)。
    /// 引擎事件出口写入(handle);预览注入直写同模块可用。
    var activeAlerts: [AlertOccurrence] = []
    /// 系统通知授权状态(启动时查询一次;请求授权后更新)。
    private(set) var notificationsAuthorized = false
    /// 用户明确拒绝过授权(设置页提示"仅应用内提示")。
    private(set) var authorizationDenied = false

    private let sender: any AlertNotificationSending
    private let clock: @Sendable () -> Date
    private var engine = AlertEngine()

    init(
        store: AlertSettingsStore = AlertSettingsStore(),
        sender: any AlertNotificationSending = LiveAlertNotificationSender(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.sender = sender
        self.clock = clock
    }

    /// 启动时查询授权现状(app 曾被授权过 → 直接可发,无需再请求)。
    func refreshAuthorization() async {
        notificationsAuthorized = await sender.isAuthorized()
        authorizationDenied = !notificationsAuthorized && store.hasRequestedAuthorization
    }

    // MARK: - 喂食(SystemMonitor 每轮调用)

    func ingestSampling(systemCPULoad: Double, groups: [AlertGroupSnapshot]) {
        let events = engine.record(
            .sampling(systemCPULoad: systemCPULoad, groups: groups),
            now: clock(),
            settings: store.evaluationSettings
        )
        handle(events)
    }

    func ingestDisk(availableBytes: Int64) {
        let events = engine.record(
            .disk(availableBytes: availableBytes),
            now: clock(),
            settings: store.evaluationSettings
        )
        handle(events)
    }

    // MARK: - 设置动作(设置页调用)

    /// 开关规则:写存储(即时生效并持久);首次从全关变为有开启时请求授权。
    func setEnabled(_ enabled: Bool, for kind: AlertKind) {
        let wasAnyEnabled = store.isAnyEnabled
        store.setEnabled(enabled, for: kind)
        guard enabled, !wasAnyEnabled, !store.hasRequestedAuthorization else { return }
        store.markAuthorizationRequested()
        let sender = self.sender
        Task { [weak self] in
            let granted = await sender.requestAuthorization()
            guard let self else { return }
            self.notificationsAuthorized = granted
            self.authorizationDenied = !granted
        }
    }

    /// 改阈值(即时生效并持久,引擎下轮按新阈值评估)。
    func setThreshold(_ threshold: Double, for kind: AlertKind) {
        store.setThreshold(threshold, for: kind)
    }

    // MARK: - 事件出口

    private func handle(_ events: [AlertEvent]) {
        for event in events {
            switch event {
            case .fired(let occurrence):
                activeAlerts.removeAll {
                    $0.kind == occurrence.kind && $0.subjectKey == occurrence.subjectKey
                }
                activeAlerts.insert(occurrence, at: 0)
                LogService.info(
                    "告警触发:\(occurrence.kind.title)"
                        + (occurrence.subjectName.map { "(\($0))" } ?? "")
                        + " 读数=\(occurrence.value)",
                    category: "Alert"
                )
                if notificationsAuthorized {
                    let payload = AlertNotificationContent.make(for: occurrence)
                    let sender = self.sender
                    Task { await sender.send(payload) }
                }
            case .resolved(let kind, let subjectKey):
                activeAlerts.removeAll {
                    $0.kind == kind && $0.subjectKey == subjectKey
                }
                LogService.info("告警恢复:\(kind.title)(\(subjectKey))", category: "Alert")
            }
        }
    }
}
