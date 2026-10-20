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
    /// 授权请求没走完:抛错 / 未作答收场而系统仍没问过(设置页与横幅给"重新请求")。
    private(set) var authorizationRequestFailed = false
    /// 授权请求在途:连开几条规则只发一次请求(弹窗等作答期间一直持有)。
    private var requestingAuthorization = false
    /// 上次记下的系统授权状态(nil = 本会话尚未查询):变化才记日志。
    private var loggedStatus: NotificationAuthorization?

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

    /// 启动时现查授权:系统还没问过且已有规则开着 → 补一次真请求(只认系统
    /// 三态,不信本地标记——2026-10-19 真机:本地标记与系统现状脱节)。全关时不弹窗。
    func refreshAuthorization() async {
        let status = await recordStatus(resendingExcept: [])
        if status == .notDetermined, store.isAnyEnabled {
            await requestAuthorization()
        }
    }

    // MARK: - 喂食(功能模块钩子调用,见文末 MonitorFeature 扩展)

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

    /// app 回前台时同步授权现状(用户经「打开系统通知设置」改完切回来,降级
    /// 提示即时更新、触发中告警补发)。只读不请求:回前台很频繁,请求失败会刷屏日志。
    func syncAuthorizationStatus() async {
        await recordStatus(resendingExcept: [])
    }

    /// 请求没走完时的手动重试(设置页 / 横幅的"重新请求")。
    func retryAuthorization() {
        Task { [weak self] in
            await self?.requestAuthorization()
        }
    }

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
        let granted = await sender.requestAuthorization()
        let status = await recordStatus(resendingExcept: [])
        // 抛错 / 未作答收场而系统仍没问过:不臆断拒绝,如实标出并给重试入口
        // (真机也见过抛错后系统落定为拒绝的——以现查为准)。
        authorizationRequestFailed = !granted && status == .notDetermined
    }

    /// 现查授权并回写状态。`resendingExcept` 非 nil:非授权 → 授权 时为触发中
    /// 告警补发系统通知(弹窗等作答 / 事后在系统设置里打开期间触发的告警,持续
    /// 性告警不会再次触发,不补发则整段会话都收不到),跳过本批自己要发的标识。
    /// 状态变化记一条日志带系统侧明细——app 日志里得看得出现状(真机排障曾只能
    /// 靠系统日志反推)。回写与补发在日志查询之前完成:并发调用不会双发。
    @discardableResult
    private func recordStatus(resendingExcept skipped: Set<String>?) async -> NotificationAuthorization {
        let status = await sender.authorizationStatus()
        let wasAuthorized = notificationsAuthorized
        notificationsAuthorized = status == .authorized
        authorizationDenied = status == .denied
        if status != .notDetermined {
            authorizationRequestFailed = false
        }
        if let skipped, notificationsAuthorized, !wasAuthorized {
            let backlog = activeAlerts
                .map(AlertNotificationContent.make(for:))
                .filter { !skipped.contains($0.identifier) }
            if !backlog.isEmpty {
                let sender = self.sender
                Task {
                    for payload in backlog { await sender.send(payload) }
                }
            }
        }
        if status != loggedStatus {
            let previous = loggedStatus.map { "\($0)" } ?? "启动"
            loggedStatus = status
            let detail = await sender.authorizationDiagnostics()
            LogService.info("通知授权:\(previous) → \(status)(\(detail))", category: "Alert")
        }
        return status
    }

    /// 改阈值(即时生效并持久,引擎下轮按新阈值评估)。
    func setThreshold(_ threshold: Double, for kind: AlertKind) {
        store.setThreshold(threshold, for: kind)
    }

    // MARK: - 事件出口

    private func handle(_ events: [AlertEvent]) {
        var payloads: [AlertNotificationPayload] = []
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
                payloads.append(AlertNotificationContent.make(for: occurrence))
            case .resolved(let kind, let subjectKey):
                activeAlerts.removeAll {
                    $0.kind == kind && $0.subjectKey == subjectKey
                }
                LogService.info("告警恢复:\(kind.title)(\(subjectKey))", category: "Alert")
            }
        }
        guard !payloads.isEmpty else { return }
        // 一轮一批:发送前现查一次授权(系统设置里打开 / 关闭即时生效,无需重启),
        // 现查顺带补发此前未能送达的触发中告警(本批自己发,不重复);按序逐条发。
        let batch = payloads
        let sender = self.sender
        Task { [weak self] in
            guard let self else { return }
            let status = await self.recordStatus(resendingExcept: Set(batch.map(\.identifier)))
            guard status == .authorized else { return }
            for payload in batch { await sender.send(payload) }
        }
    }
}

// MARK: - 功能模块(ADR-0003 MonitorFeature)

/// 告警模块(工单 p1-history/07):AlertCenter 即薄壳、AlertEngine 即纯内核(其余
/// 功能模块照此样板)。喂食全部经扩展点到达——每轮心跳喂系统负载与全部组;磁盘容量
/// 与 dev server 盘点经其他模块的广播喂进来。引擎只读聚合口径,不持快照。
extension AlertCenter: MonitorFeature {
    func onRound(_ context: RoundContext) {
        ingestSampling(
            systemCPULoad: context.update.systemCPULoad,
            groups: context.groups.map { group in
                AlertGroupSnapshot(
                    id: group.id,
                    name: group.name,
                    cpuPercent: group.cpuPercent,
                    memoryBytes: group.memoryBytes
                )
            }
        )
    }

    /// 磁盘剩余规则吃 Finder「可用」口径(读不到不喂,不伪造);dev server 只喂已
    /// 闲置的(未闲置 = idleSeconds 为 nil)。
    func onEvent(_ event: FeatureEvent) {
        switch event {
        case .diskCapacity(let reading):
            if let available = reading.availableForImportantUsageBytes {
                ingestDisk(availableBytes: available)
            }
        case .devServers(let servers):
            ingestDevServers(servers.compactMap { server in
                server.idleSeconds.map {
                    AlertDevServerSnapshot(pid: server.pid, name: server.displayName, idleSeconds: $0)
                }
            })
        case .diskThroughput:
            break
        }
    }

    /// 通知授权:启动现查;规则开着而系统还没问过则补一次请求。
    func start(_ host: MonitorHost) {
        Task { [weak self] in
            await self?.refreshAuthorization()
        }
    }
}
