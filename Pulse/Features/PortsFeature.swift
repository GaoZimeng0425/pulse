import Foundation
import Observation
import PulseCore

/// 全局端口功能模块(工单 port-view/01;ADR-0003 MonitorFeature /
/// ADR-0004 传感器):薄壳 + 纯值内核 PortInventoryFinder。
/// 传感器 = 全机 fd 扫描(LiveGlobalPortScanner,批量缝),10s 档 +
/// `.ports` 家族可见性闸(服务页可见才扫;实测一轮 ≈2.9ms,票面探针记档);
/// pid 列表由心跳快照喂入(与快照同源,名字归并口径一致;不走 proc_listallpids
/// ——darwin 27.2 上只回 232 pid,已记票面);dev server 标注吃 DevServerFeature
/// 的广播,不直读别的模块。视图直读 `inventory`(LastGood:扫描失败保留上次)。
@Observable
@MainActor
final class PortsFeature: MonitorFeature {
    /// 最近一次合成的盘点;nil = 从未扫到(服务页不可见期间保持)。
    private(set) var inventory: PortInventory?

    @ObservationIgnored private let provider: PortScanProvider
    @ObservationIgnored private let finder = PortInventoryFinder()
    @ObservationIgnored private let rowLimit: Int
    @ObservationIgnored private var latestSnapshot: ProcessSnapshot?
    @ObservationIgnored private var latestDevServers: [DevServerStatus] = []

    init(scanner: any GlobalPortScanning, rowLimit: Int = PortsCardMetrics.rowLimit) {
        provider = PortScanProvider(scanner: scanner)
        self.rowLimit = rowLimit
    }

    func onRound(_ context: RoundContext) {
        latestSnapshot = context.update.snapshot
        provider.storePIDs(context.update.snapshot.processes.map(\.pid))
    }

    func onEvent(_ event: FeatureEvent) {
        if case let .devServers(servers) = event {
            latestDevServers = servers
        }
    }

    /// 端口扫描闸:任一在场窗口停在服务页(`.ports` 家族)才扫。
    func visibilityChanged(_ visibility: MonitorVisibility) {
        provider.setVisible(visibility.shows(.ports))
    }

    func sensorDrivers() -> [SensorDriver] {
        [
            provider.markedDriver { [weak self] delivery in
                guard let self else { return }
                Task { @MainActor in
                    // 只认 fresh(不可见轮的 stale 重投与读失败都不动显示)。
                    guard case let .fresh(scan) = delivery, let snapshot = self.latestSnapshot
                    else { return }
                    self.inventory = self.finder.inventory(
                        scan: scan,
                        snapshot: snapshot,
                        devServers: self.latestDevServers,
                        limit: self.rowLimit
                    )
                }
            },
        ]
    }
}

/// 全机端口扫描传感器 provider(ADR-0004 薄缝):10s 档,可见性闸门内——
/// 服务页不可见时 tick 空转不扫描;pid 列表由 feature 的心跳轮喂入
/// (SensorLastGoodBox 同款锁盒,协议要求非隔离读取)。
private struct PortScanProvider: SensorProvider {
    let cadence: SensorCadence = .every(seconds: 10)

    private let scanner: any GlobalPortScanning
    private let gate = SensorVisibilityGate()
    private let pidBox = SensorLastGoodBox<[pid_t]>()
    private let lastGoodBox = SensorLastGoodBox<[pid_t: [UInt16]]>()

    init(scanner: any GlobalPortScanning) {
        self.scanner = scanner
    }

    var lastGood: [pid_t: [UInt16]]? {
        lastGoodBox.current
    }

    func setVisible(_ visible: Bool) {
        gate.setVisible(visible)
    }

    func storePIDs(_ pids: [pid_t]) {
        pidBox.store(pids)
    }

    func snapshot() async -> [pid_t: [UInt16]]? {
        guard gate.isVisible, let pids = pidBox.current, !pids.isEmpty else {
            return nil
        }
        // 同步扫描(≈2.9ms/轮,票面探针)在调度器 actor 里做——与容器
        // docker 轮询同模式,不值得再起任务。
        let scan = scanner.listeningPorts(pids: pids)
        lastGoodBox.store(scan)
        return scan
    }
}
