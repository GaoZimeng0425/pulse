import Foundation

// MARK: - 装配(SystemMonitor 的构造入参与真实装配工厂)
//
// SystemMonitor.init 只收三样东西:主干与既有传感器的采集源(MonitorSources)、
// 告警编排、功能模块注册列表(MonitorFeatures)。各模块在工厂里只用自己的采集源
// 构造,对主干 / 心跳的影响走 start 时拿到的宿主接口(MonitorHost)——装配不在 init
// 里两段式接线(arch-review-2026-10-18/01 高1 的审查必修项)。
// 真实装配 = `SystemMonitor.live`(本文件);预览 = `SystemMonitor.preview`(InertSources)。

/// 主干与既有传感器的 OS 接缝(心跳 / 出生扫描 / 电池 / 磁盘 / dev server / 结束进程)。
/// 功能模块自有的源(nettop、历史库)不在这里,随模块在工厂里构造。
struct MonitorSources {
    var process: any ProcessSource
    var coreTicks: any CoreTickSource
    var memoryStats: any MemoryStatsSource
    var networkCounters: any NetworkCountersSource
    var birthScan: any BirthScanSource
    var battery: any BatterySource
    var diskCapacity: any DiskCapacitySource
    /// 收 SystemMonitor 的心跳中继:磁盘求和回退源经它取心跳那一趟 rusage
    /// (arch-review-2026-10-18/01 高2),中继与 Sampler 同一个,由 init 构造保证。
    var diskThroughput: (HeartbeatRusageRelay) -> any DiskThroughputSource
    var devServerPortScanner: any DevServerPortScanning
    var killService: any KillService

    /// 全部 Live 源(PulseApp 经 `SystemMonitor.live` 唯一取用)。
    static func live() -> MonitorSources {
        MonitorSources(
            process: LiveProcessSource(),
            coreTicks: LiveCoreTickSource(),
            memoryStats: LiveMemoryStatsSource(),
            networkCounters: LiveNetworkCountersSource(),
            birthScan: LiveBirthScanSource(),
            battery: LiveBatterySource(),
            diskCapacity: LiveDiskCapacitySource(),
            diskThroughput: { relay in
                LiveDiskThroughputSource.adoptingBestPath(fallbackHeartbeat: relay)
            },
            devServerPortScanner: LiveDevServerPortScanner(),
            killService: LiveKillService()
        )
    }
}

/// 功能模块注册列表(ADR-0003 扩展点):视图要直读的模块以具名字段持有,派发
/// 一律按 `registry` 顺序(排行在前、历史在后——与迁移前的扇出次序一致)。
@MainActor
struct MonitorFeatures {
    let rankings: RankingsFeature
    let history: HistoryFeature

    /// 派发顺序:onRound / 可见性 / 磁盘读数 / 传感器登记 / 启停都按它走。
    var registry: [any MonitorFeature] { [rankings, history] }
}

extension SystemMonitor {
    /// 真实装配(PulseApp 唯一入口):全部 Live 源 + 应用历史库(打开失败降级为
    /// 无历史,已记日志)+ 标准偏好里的告警设置。
    static func live(projectRoots: [String]) -> SystemMonitor {
        SystemMonitor(
            sources: .live(),
            projectRoots: projectRoots,
            alerts: AlertCenter(
                store: AlertSettingsStore(),
                sender: LiveAlertNotificationSender()
            ),
            features: MonitorFeatures(
                rankings: RankingsFeature(nettopSource: LiveNettopCSVSource()),
                history: HistoryFeature(engine: HistoryEngine.openDefault())
            )
        )
    }
}
