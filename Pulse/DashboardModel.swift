import Foundation
import Observation
import PulseCore

// MARK: - 弹窗与主窗口共用呈现模型(工单 P0.6-05,评审 F4 去重)

/// 两窗共用的呈现模型:弹窗(DashboardView)与主窗口(MainWindowView)对同一份
/// SystemMonitor 数据做完全相同的折叠——指标卡模型、tab 内容、
/// 展开/下钻会话状态与处置请求。原先散在两个视图里的重复实现收敛到这里,
/// 视图只保留各自的外形(弹窗紧凑 / 窗口常规)与 tab 选中态(两窗独立)。
@Observable
@MainActor
final class DashboardModel {
    let monitor: SystemMonitor

    /// 展开中的组(按类型化组身份):跨采样轮次保持,组消失时残留身份无害。
    var expandedGroupIDs: Set<GroupIdentity> = []
    /// 展开详情的进程(跨组唯一):下钻期间进程退出时详情安静收起。
    var selectedProcessID: pid_t?
    /// 处置结果汇总(工单 08):**有失败才弹**;全成功保持安静。
    var killFailureReport: KillReport?

    init(monitor: SystemMonitor) {
        self.monitor = monitor
    }

    // MARK: tab 内容折叠(纯逻辑在 MetricTabContent)

    /// 当前 tab 的展示内容:榜单序、组行口径、内存分段与两个 meter 榜首。
    func content(tab: MetricTab) -> MetricTabContent {
        MetricTabContent.build(groups: monitor.allGroups, tab: tab)
    }

    // MARK: 指标卡模型(总览小卡与 tab 主卡同源)

    var cpuModel: MetricCardModel {
        .cpu(
            breakdown: monitor.cpuBreakdown,
            load: monitor.systemCPULoad,
            statistics: monitor.sampleHistory.systemCPULoad.statistics,
            trend: monitor.sampleHistory.systemCPULoad.values
        )
    }

    var memoryModel: MetricCardModel {
        .memory(monitor.memory, trend: monitor.sampleHistory.memoryUsed.values, host: .current)
    }

    /// 电池卡(工单 02):六项读数读 monitor.battery(lastGood 语义——读失败
    /// 不回退为 nil);未首读/无电池机器的占位模型只在轴内不会出现,仍给全占位兜底。
    var batteryModel: MetricCardModel {
        .battery(monitor.battery.reading)
    }

    /// 磁盘卡(工单 05):容量对账 + 可清除 + 各卷 + 快照读容量 provider,
    /// 读写速率与走势读吞吐 provider——两个 provider 两条节奏,卡模型在此合流;
    /// 容量未首读时全占位(MetricCardModel.disk 兜底)。
    var diskModel: MetricCardModel {
        .disk(capacity: monitor.disk.capacity, throughput: monitor.disk.throughput)
    }

    /// 网络卡(工单 06):实时速率读心跳差分(monitor.network.reading,LastGood),
    /// Today/7 天累计读历史库聚合(monitor.history.networkTotals),走势 = 速率环;
    /// 未首读时全占位(MetricCardModel.network 兜底)。
    var networkModel: MetricCardModel {
        .network(
            reading: monitor.network.reading,
            trend: monitor.network.trend.totalBytesPerSecond,
            totals: monitor.history.networkTotals
        )
    }

    // MARK: 会话状态与处置请求(工单 08;确认 + 执行在 KillRequestFlow)

    /// 点行展开 / 收起组内进程。
    func toggleExpansion(of groupID: GroupIdentity) {
        if !expandedGroupIDs.insert(groupID).inserted {
            expandedGroupIDs.remove(groupID)
        }
    }

    /// 进程详情"结束进程":确认(点名 name+pid)→ SIGTERM;有失败才弹汇总。
    func requestEndProcess(_ target: KillTarget) {
        killFailureReport = KillRequestFlow.endProcess(target, monitor: monitor)
    }

    /// 排行行"结束整组":确认(列进程数)→ 对最新一轮采样的组员逐个 SIGTERM。
    func requestEndGroup(_ group: ProcessGroup) {
        killFailureReport = KillRequestFlow.endGroup(group, monitor: monitor)
    }

    /// dev server 卡"全部停止"(工单 08):一次确认列全部目标 → 逐个 SIGTERM。
    /// 取点击瞬间的盘点名单;确认对话框打开期间采样照跑,消失的进程 SIGTERM
    /// 报"进程已退出"进失败汇总,不会误伤。
    func requestStopAllDevServers(_ servers: [DevServerStatus]) {
        let targets = servers.map { KillTarget(pid: $0.pid, name: $0.displayName) }
        killFailureReport = KillRequestFlow.stopAll(targets, monitor: monitor)
    }
}
