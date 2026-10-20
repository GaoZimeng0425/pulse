import Foundation
import Darwin
import PulseCore

// MARK: - 惰性源(预览与单测共用)
//
// 每条 OS 接缝的「什么都不做」实现:读数恒缺(nil / 空)、不起子进程、不发信号、
// 不请求通知授权、不碰用户偏好与生产历史库。SystemMonitor 不再带 Live 默认参数
// (默认 `HistoryEngine.openDefault()` 曾让测试 / 预览误连生产库,见 0c892c1),
// 预览与单测经这里显式装配;真实装配只在 `SystemMonitor.live(projectRoots:)`。

/// 出生扫描:没有 pid,也就没有出生(登记只来自采样轮兜底)。
struct InertBirthScanSource: BirthScanSource {
    func pids() -> [pid_t] { [] }
    func birthInfo(for pid: pid_t) -> LineageRegistry.Entry? { nil }
}

/// 结束进程:绝不发信号;如实回报「进程已退出」(合成进程本就不存在)。
struct InertKillService: KillService {
    func send(signal: Int32, to pid: pid_t) -> KillSignalResult {
        .failed(.noSuchProcess)
    }
}

/// 电池:无内建电池(电池页整页隐藏,与台式机同口径)。
struct InertBatterySource: BatterySource {
    func read() -> BatteryRawReading? { nil }
}

/// 磁盘容量:读不到(容量卡整卡占位)。
struct InertDiskCapacitySource: DiskCapacitySource {
    func read() -> DiskCapacityRawReading? { nil }
}

/// 磁盘吞吐:读不到(速率列占位);节奏取低频档,调度器空转成本最低。
struct InertDiskThroughputSource: DiskThroughputSource {
    func readCounters() -> DiskIOCounters? { nil }
    var cadenceSeconds: TimeInterval { 30 }
}

/// nettop:不起子进程,读数恒缺(网络每进程排行占位)。
struct InertNettopCSVSource: NettopCSVSource {
    func read() async -> String? { nil }
}

/// dev server 端口扫描:不扫,无监听端口。
struct InertDevServerPortScanner: DevServerPortScanning {
    func listeningPorts(pid: pid_t) -> [UInt16] { [] }
}

/// 每核 tick:空样本(系统负载按 0 计,CoreTickDiffer 的退化口径)。
struct InertCoreTickSource: CoreTickSource {
    func sample() -> CoreTickSample {
        CoreTickSample(busyTicks: [], totalTicks: [], takenAt: Date())
    }
}

/// 内存构成:读不到(内存卡占位)。
struct InertMemoryStatsSource: MemoryStatsSource {
    func sample() -> MemoryBreakdown? { nil }
}

/// 网络计数:读缺失(网络页占位,历史增量 0)。
struct InertNetworkCountersSource: NetworkCountersSource {
    func sample() -> NetworkCounters? { nil }
}

/// 通知发送:系统「还没问过」、从不请求、从不投递。
struct InertAlertNotificationSender: AlertNotificationSending {
    func requestAuthorization() async -> Bool { false }
    func authorizationStatus() async -> NotificationAuthorization { .notDetermined }
    func authorizationDiagnostics() async -> String { "inert" }
    func send(_ payload: AlertNotificationPayload) async {}
}

extension AlertCenter {
    /// 惰性告警编排:规则全关(预设阈值)、配置不落盘、不碰 UserDefaults、不请求授权。
    static func inert() -> AlertCenter {
        AlertCenter(
            store: AlertSettingsStore(load: { [:] }, persist: { _ in }),
            sender: InertAlertNotificationSender()
        )
    }
}

// MARK: - 预览装配

extension SystemMonitor {
    /// SwiftUI 预览装配:进程来自调用方的合成源;每核 tick / 内存 / 网络计数取
    /// 只读 Live 源(不写任何东西,总览卡与改造前一样有真读数);其余 OS 接缝全
    /// 惰性(不起 nettop、不扫端口、不发信号、不请求通知授权、不碰用户偏好);
    /// 历史默认内存库(零磁盘副作用,落库与累计读回照常走一遍),绝不开生产库。
    static func preview(
        source: any ProcessSource = SyntheticProcessSource(processes: []),
        projectRoots: [String] = [],
        historyEngine: HistoryEngine? = HistoryEngine(database: try? HistoryDatabase.openInMemory())
    ) -> SystemMonitor {
        SystemMonitor(
            sources: MonitorSources(
                process: source,
                coreTicks: LiveCoreTickSource(),
                memoryStats: LiveMemoryStatsSource(),
                networkCounters: LiveNetworkCountersSource(),
                heartbeatRelay: HeartbeatRusageRelay(),
                birthScan: InertBirthScanSource(),
                killService: InertKillService()
            ),
            projectRoots: projectRoots,
            features: MonitorFeatures(
                network: NetworkFeature(),
                alerts: .inert(),
                devServers: DevServerFeature(portScanner: InertDevServerPortScanner()),
                rankings: RankingsFeature(nettopSource: InertNettopCSVSource()),
                history: HistoryFeature(engine: historyEngine),
                disk: DiskFeature(
                    capacitySource: InertDiskCapacitySource(),
                    throughputSource: InertDiskThroughputSource()
                ),
                battery: BatteryFeature(source: InertBatterySource())
            )
        )
    }
}
