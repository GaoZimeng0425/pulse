import Foundation
import Observation

/// dev server 功能模块(工单 p1-history/08;ADR-0003 MonitorFeature):薄壳 + 纯值
/// 内核 DevServerFinder(argv 分类 + 闲置环 + 端口扫描走缝,单测见
/// DevServerFinderTests)。每轮盘点后广播给其他模块(闲置告警由告警模块评估);
/// 主窗口总览页卡片直读 `servers`。
@Observable
@MainActor
final class DevServerFeature: MonitorFeature {
    /// 每轮对 argv 命中的候选进程合成的状态(闲置时长 / 内存 / 监听端口);无候选为空。
    private(set) var servers: [DevServerStatus] = []

    @ObservationIgnored private var finder: DevServerFinder
    @ObservationIgnored private var host: MonitorHost?

    init(portScanner: any DevServerPortScanning) {
        self.finder = DevServerFinder(portScanner: portScanner)
    }

    func start(_ host: MonitorHost) {
        self.host = host
    }

    /// 盘点时刻与快照同一时间轴(不另取钟)。
    func onRound(_ context: RoundContext) {
        let inventory = finder.update(
            snapshot: context.update.snapshot,
            processCPU: context.update.diff.processCPU.cpuPercentByPID,
            now: context.takenAt
        )
        if inventory != servers {
            servers = inventory
        }
        host?.broadcast(.devServers(inventory))
    }
}
