import Foundation
import PulseCore

// MARK: - 装配(SystemMonitor 的构造入参与真实装配工厂)

//
// SystemMonitor.init 只收两样东西:主干的采集源(MonitorSources)与功能模块注册列表
// (MonitorFeatures)。各模块在工厂里只用自己的采集源构造,对主干 / 心跳 / 其他模块的
// 影响走 start 时拿到的宿主接口(MonitorHost)——装配不在 init 里两段式接线
// (arch-review-2026-10-18/01 高1)。
// 真实装配 = `SystemMonitor.live`(本文件);预览 = `SystemMonitor.preview`(InertSources)。

/// 主干的 OS 接缝:心跳(进程 / 每核 tick / 内存 / 网络计数)、出生扫描、结束进程。
/// 功能模块自有的源(电池、磁盘、nettop、端口扫描、历史库、通知)随模块在工厂里构造。
struct MonitorSources {
    var process: any ProcessSource
    var coreTicks: any CoreTickSource
    var memoryStats: any MemoryStatsSource
    var networkCounters: any NetworkCountersSource
    /// 心跳中继:Sampler 每轮发布快照,磁盘求和回退源经它取同一趟 rusage
    /// (arch-review-2026-10-18/01 高2)。工厂把同一个中继交给磁盘模块的吞吐源。
    var heartbeatRelay: HeartbeatRusageRelay
    var birthScan: any BirthScanSource
    var killService: any KillService

    /// 全部 Live 源(PulseApp 经 `SystemMonitor.live` 唯一取用)。
    static func live(heartbeatRelay: HeartbeatRusageRelay) -> MonitorSources {
        MonitorSources(
            process: LiveProcessSource(),
            coreTicks: LiveCoreTickSource(),
            memoryStats: LiveMemoryStatsSource(),
            networkCounters: LiveNetworkCountersSource(),
            heartbeatRelay: heartbeatRelay,
            birthScan: LiveBirthScanSource(),
            killService: LiveKillService()
        )
    }
}

/// 功能模块注册列表(ADR-0003 扩展点):视图要直读的模块以具名字段持有,派发一律
/// 按 `registry` 顺序。顺序有意义:网络先落地(徽标与历史同轮);告警先喂本轮采样、
/// dev server 再盘点并广播(与迁移前的喂食次序一致);排行与历史随后。launchd 服务
/// 清单模块没有 onRound,放末尾、顺序无意义。
@MainActor
struct MonitorFeatures {
    let network: NetworkFeature
    let alerts: AlertCenter
    let devServers: DevServerFeature
    let rankings: RankingsFeature
    let history: HistoryFeature
    let disk: DiskFeature
    let battery: BatteryFeature
    let gpu: GpuFeature
    let power: PowerFeature
    let launchdManifest: LaunchdManifestFeature

    /// 派发顺序:onRound / 广播 / 可见性 / 传感器登记 / 启停都按它走。
    var registry: [any MonitorFeature] {
        [network, alerts, devServers, rankings, history, disk, battery, gpu, power, launchdManifest]
    }
}

extension SystemMonitor {
    /// 真实装配(PulseApp 唯一入口):全部 Live 源 + 应用历史库(打开失败降级为
    /// 无历史,已记日志)+ 标准偏好里的告警设置。
    static func live(projectRoots: [String]) -> SystemMonitor {
        let relay = HeartbeatRusageRelay()
        return SystemMonitor(
            sources: .live(heartbeatRelay: relay),
            projectRoots: projectRoots,
            features: MonitorFeatures(
                network: NetworkFeature(),
                alerts: AlertCenter(
                    store: AlertSettingsStore(),
                    sender: LiveAlertNotificationSender()
                ),
                devServers: DevServerFeature(portScanner: LiveDevServerPortScanner()),
                rankings: RankingsFeature(nettopSource: LiveNettopCSVSource()),
                history: HistoryFeature(engine: HistoryEngine.openDefault()),
                disk: DiskFeature(
                    capacitySource: LiveDiskCapacitySource(),
                    throughputSource: LiveDiskThroughputSource.adoptingBestPath(fallbackHeartbeat: relay)
                ),
                battery: BatteryFeature(source: LiveBatterySource()),
                gpu: GpuFeature(source: LiveGpuSource()),
                power: PowerFeature(source: LiveEnergyModelSource(), chipName: HostInfo.current.chipName ?? ""),
                launchdManifest: LaunchdManifestFeature(provider: LaunchdManifestProvider())
            )
        )
    }
}
