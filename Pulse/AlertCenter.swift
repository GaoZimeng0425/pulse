import Foundation
import Observation

/// 告警编排(工单 P1-07,MainActor 粘合层):喂食 → 引擎评估 → 三路出口——
/// ①系统通知(已授权才发);②应用内提示(activeAlerts,授权被拒时的降级出口,
/// 主窗口与弹窗常显);③日志(告警触发/恢复,spec"过渡非轮询"惯例)。
///
/// 授权时序(spec):有规则开着才请求授权(开规则时;启动时若系统还没问过也补
/// 一次);以系统三态为准,不信本地标记。拒绝后规则照常判定,只是不发系统通知
/// (activeAlerts 照常更新 = 应用内提示);发送前现查授权,系统设置里改即生效。
/// UI 不单测,此处粘合逻辑经注入 sender/时钟的 AlertCenterTests 覆盖。
@Observable
@MainActor
final class AlertCenter {
    /// 配置存储(设置页与引擎共用;改动即时生效)。
    let store: AlertSettingsStore

    /// 触发中未解除的告警(新在前;应用内提示的唯一数据源)。
    /// 引擎事件出口写入(handle);预览注入直写同模块可用。
    var activeAlerts: [AlertOccurrence] = []
    /// 系统通知已授权(启动时现查;请求后、每次发送前更新)。
    private(set) var notificationsAuthorized = false
    /// 系统侧已拒绝(设置页 / 横幅提示"仅应用内提示")。没问过不算拒绝。
    private(set) var authorizationDenied = false
    /// 授权请求在途:连开几条规则只发一次请求。
    private var requestingAuthorization = false

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

    /// 启动时现查授权:系统还没问过且已有规则开着 → 补一次真请求。本地"请求过"
    /// 标记曾与系统现状脱节(2026-10-19 真机:系统从未登记 Pulse,app 却据标记
    /// 判为拒绝、永不再问,告警只剩应用内提示),故只认系统三态。全关时不弹窗。
    func refreshAuthorization() async {
        let status = await sender.authorizationStatus()
        apply(status)
        if status == .notDetermined, store.isAnyEnabled {
            await requestAuthorization()
        }
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

    /// dev server 闲置喂食(工单 08):每轮盘点交付,引擎按闲置秒数评估。
    func ingestDevServers(_ servers: [AlertDevServerSnapshot]) {
        let events = engine.record(
            .devServers(servers),
            now: clock(),
            settings: store.evaluationSettings
        )
        handle(events)
    }

    // MARK: - 设置动作(设置页调用)

    /// 开关规则:写存储(即时生效并持久);开规则而授权未落定时请求授权
    /// (系统侧幂等:已落定不弹窗,只回现状)。
    func setEnabled(_ enabled: Bool, for kind: AlertKind) {
        store.setEnabled(enabled, for: kind)
        guard enabled, !notificationsAuthorized, !authorizationDenied else { return }
        Task { [weak self] in
            await self?.requestAuthorization()
        }
    }

    private func requestAuthorization() async {
        guard !requestingAuthorization else { return }
        requestingAuthorization = true
        defer { requestingAuthorization = false }
        _ = await sender.requestAuthorization()
        // 请求失败(抛错)时系统仍是没问过:以现查为准,不臆断拒绝。
        apply(await sender.authorizationStatus())
    }

    private func apply(_ status: NotificationAuthorization) {
        notificationsAuthorized = status == .authorized
        authorizationDenied = status == .denied
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
                // 发送前现查授权:用户在系统设置里打开 / 关闭通知即时生效,无需重启;
                // 现查结果回写状态,降级提示随之更新。
                let payload = AlertNotificationContent.make(for: occurrence)
                let sender = self.sender
                Task { [weak self] in
                    let status = await sender.authorizationStatus()
                    self?.apply(status)
                    if status == .authorized {
                        await sender.send(payload)
                    }
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
