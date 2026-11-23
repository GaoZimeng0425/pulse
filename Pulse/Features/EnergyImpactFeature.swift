import Foundation
import Observation
import PulseCore
import ServiceManagement

/// 特权助手功能模块(p3-root-mcp/03):60s 档拉取 helper 的 per-process
/// Energy Impact,按进程名聚合 top 与全机合计;合计经 `FeatureEvent.gauges`
/// 广播进历史窄表(GaugeKey.energyImpact,助手缺席不产行 = 空段诚实)。
/// **归组口径 v1 = 进程名聚合**(记档理由):pid→组映射依赖采样轮时序,
/// 60s 档与 5s 心跳不同拍有 pid 复用错配风险;名字聚合对"哪个 App 耗电"
/// 够用,精细归组留 04 Agents 用量卡按需再进。不做可见性门控:60s 单档
/// 一次 XPC 短调用,开销可忽略,数据以落库为目的(与容器/蓝牙的可见门控
/// 动机不同——它们一轮成本高)。
@Observable
@MainActor
final class EnergyImpactFeature: MonitorFeature {
    /// 一轮聚合结果:top 进程(名聚合,impact 降序)+ 全机合计 + 采样时刻。
    private(set) var reading: EnergyImpactReading?

    /// 拉取缝:Live = XPC client;预览/测试注入合成闭包(60s 循环不设缝,
    /// 真机验收,探针 09 同族)。
    typealias Fetch = @Sendable () async throws
        -> (samples: [(pid: Int, name: String, impact: Double)], collectedAt: Date)

    private let fetch: Fetch
    private var host: MonitorHost?
    private var pollTask: Task<Void, Never>?

    /// 特权助手安装三态(battery-energy/01:电池页两卡共用引导空态的判据)。
    /// start 即读、每轮 poll 前刷新(用户在设置里开关/批准后,最长 60s 内跟上)。
    /// **注意 status 会说谎**(energy-gate-fix,2026-11-22 用户实案):Pulse 更新
    /// 换 bundle 后,BTM 里残留旧条目的 enabled 判定,而新 helper 从未批准/从未
    /// 跑起——卡片据此显示「运行中」骗人干等。物理真值在 `helperGate`(融合
    /// 拉取健康度),视图一律读它。
    private(set) var helperStatus: PrivilegedHelperStatus = .notRegistered

    /// 融合判定:系统说开了 + 一分钟一跳的拉取持续失败 = 助手实际没在运行
    /// (换 bundle 未重登/BTM 旧代残留)——如实给「重新登记」出口,不假称运行中。
    var helperGate: EnergyHelperGate {
        EnergyHelperGate.resolve(status: helperStatus, fetchFailing: lastFetchFailed)
    }

    init(fetch: @escaping Fetch = { try await EnergyHelperClient().fetchLatest() }) {
        self.fetch = fetch
    }

    /// btm-lwcr-fix/04(11-23 用户实案「点了没反应」):用户拨开关/点登记动作后,
    /// 引导行最长 60s 不动。动作侧(PrivilegedHelperStatus)post 此通知,拉取
    /// 循环监听并立即跑一轮——状态与文案即时翻转,不等下一跳。
    static let helperStateChanged = Notification.Name("pulse.energyHelperStateChanged")

    private var observerTask: Task<Void, Never>?

    func start(_ host: MonitorHost) {
        self.host = host
        helperStatus = PrivilegedHelperStatus.current()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await self?.pollOnce() ?? .seconds(60)
                try? await Task.sleep(for: interval)
            }
        }
        observerTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: Self.helperStateChanged) {
                guard let self else { return }
                _ = await pollOnce()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        observerTask?.cancel()
        observerTask = nil
    }

    private(set) var lastFetchFailed = false

    /// 等待期加密轮询(btm-lwcr-fix/04):拉取失败且已登记(等系统批准/已批准
    /// 助手未跑起)时 5s 一档——用户在系统设置点完允许后 5s 内跟上,数据尽快
    /// 出现;拉取成功或未登记(没人等,不空转)回落常规 60s。纯判定,单测钉口径。
    static func pollInterval(
        fetchFailed: Bool,
        status: PrivilegedHelperStatus
    ) -> Duration {
        (fetchFailed && status != .notRegistered) ? .seconds(5) : .seconds(60)
    }

    /// 下一跳间隔在轮末按最新健康度决定(见 pollInterval)。
    private var nextPollInterval: Duration {
        Self.pollInterval(fetchFailed: lastFetchFailed, status: helperStatus)
    }

    @discardableResult
    private func pollOnce() async -> Duration {
        helperStatus = PrivilegedHelperStatus.current()
        let result: (samples: [(pid: Int, name: String, impact: Double)], collectedAt: Date)?
        do {
            result = try await fetch()
        } catch {
            // 翻转才记(读路径健康状态沿):未装期间每分钟一条 error 会刷屏。
            if !lastFetchFailed {
                LogService.error("特权助手拉取失败(未装/未批准/超时):\(error.localizedDescription)", category: "Energy")
                lastFetchFailed = true
            }
            return nextPollInterval
        }
        if lastFetchFailed {
            LogService.info("特权助手拉取恢复", category: "Energy")
        }
        lastFetchFailed = false
        guard let result else { return nextPollInterval } // 编译器收窄(catch 路径已 return)
        let aggregated = Self.aggregate(result.samples)
        guard !aggregated.isEmpty else { return nextPollInterval }
        let total = aggregated.reduce(0) { $0 + $1.impact }
        reading = EnergyImpactReading(
            top: aggregated.sorted { $0.impact > $1.impact }.prefix(10)
                .map { EnergyImpactReading.Row(name: $0.name, impact: $0.impact) },
            totalImpact: total,
            agents: AgentEnergyTable.group(aggregated.map { ($0.name, $0.impact) }),
            collectedAt: result.collectedAt
        )
        host?.broadcast(.gauges([.energyImpact: total]))
        return nextPollInterval
    }

    /// 同名进程求和(纯函数,单测钉口径)。**pid < 0 的伪行不进聚合**
    /// (powermetrics 尾部 ALL_TASKS/DEAD_TASKS 是全系统汇总行,与逐进程行
    /// 相加等于双重计数;真机首日 2026-10-27 实测总值虚高约 2.4 倍)。
    nonisolated static func aggregate(_ samples: [(pid: Int, name: String, impact: Double)]) -> [(
        name: String,
        impact: Double
    )] {
        var byName: [String: Double] = [:]
        for sample in samples where sample.pid >= 0 && sample.impact > 0 {
            byName[sample.name, default: 0] += sample.impact
        }
        return byName.map { (name: $0.key, impact: $0.value) }
    }
}

/// 能耗影响读数(top 名聚合行 + 全机合计 + 助手聚合行)。
struct EnergyImpactReading: Sendable, Equatable {
    struct Row: Sendable, Equatable, Identifiable {
        let name: String
        let impact: Double
        var id: String {
            name
        }
    }

    let top: [Row]
    let totalImpact: Double
    /// 按内置助手表聚合的行(p3-root-mcp/04 电池页「AI 助手」卡数据源)。
    let agents: [AgentEnergyEntry]
    let collectedAt: Date
}

// MARK: - 设置页状态桥(特权助手三态)

/// SMAppService daemon 状态的 UI 桥:设置页开关直接驱动 register/unregister
/// (探针 09 结论:register() 报 Code=1 是等用户批准的中间态,status 才是
/// 判据;批准动作在系统设置,app 侧只如实显示三态)。
@MainActor
enum PrivilegedHelperStatus {
    case notRegistered
    case requiresApproval
    case enabled

    /// btm-lwcr-fix(11-23 定谳):helper2 的 BTM 条目沉积成疾——disposition 停在
    /// enabled,但 Launch Constraint 的 cdhash 放行名单是空数组,用户侧任何关-
    /// 开循环都只是「重提交 job → 15ms 拒杀」,永远补不进名单。修法 = 换全新
    /// 身份号 helper3 走干净批准链;helper2 死条目在此注销(plist 保留在 bundle,
    /// SMAppService 按 bundle 内路径解析)。幂等,失败不阻塞(条目可能已被清)。
    private static func unregisterLegacyHelper2() {
        let legacy = SMAppService.daemon(plistName: "com.gaozimeng.pulse.helper2.plist")
        if legacy.status != .notRegistered {
            try? legacy.unregister()
        }
    }

    static func current(plistName: String = "com.gaozimeng.pulse.helper3.plist") -> PrivilegedHelperStatus {
        switch SMAppService.daemon(plistName: plistName).status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .notRegistered
        }
    }

    static func setInstalled(_ installed: Bool) {
        unregisterLegacyHelper2()
        let service = SMAppService.daemon(plistName: "com.gaozimeng.pulse.helper3.plist")
        if installed {
            try? service.register()
            // energy-one-tap:开开关不止登记——系统确要批准时直接带用户去批准页
            // (类方法会高亮待批准项),不再停在自家开关让用户猜下一步。
            if current() == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        } else {
            try? service.unregister()
        }
        // btm-lwcr-fix/04:动作后立即通知拉取循环刷新状态,引导行即时反馈。
        NotificationCenter.default.post(name: EnergyImpactFeature.helperStateChanged, object: nil)
    }

    /// 一键直达批准页(energy-one-tap):未登记 → 登记;已登记(换 bundle 旧代
    /// 残留等)→ 注销重登(plist 运维口径「bootout → 重开 → 重批」);随后打开
    /// 系统设置的登录项批准页。批准仍是用户自点(TCC 原则),app 只带路。
    static func reRegisterAndOpenApproval() {
        unregisterLegacyHelper2()
        let service = SMAppService.daemon(plistName: "com.gaozimeng.pulse.helper3.plist")
        if current() != .notRegistered {
            try? service.unregister()
        }
        try? service.register()
        SMAppService.openSystemSettingsLoginItems()
        // btm-lwcr-fix/04:动作后立即通知拉取循环刷新状态,引导行即时反馈。
        NotificationCenter.default.post(name: EnergyImpactFeature.helperStateChanged, object: nil)
    }

    /// 已提交注册、只差用户点头:直接打开批准页(比通用深链好,会高亮条目)。
    static func openApprovalPane() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
