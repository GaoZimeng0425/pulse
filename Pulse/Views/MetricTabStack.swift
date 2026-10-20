import SwiftUI
import PulseCore

// MARK: - 每个 tab 的内容栈(主窗口与弹窗共用,2026-10-20 用户拍板:每个 tab 两处一致)

/// 一个 tab 的内容栈:主窗口与弹窗读同一份——卡片组成、顺序、数据出处全在这里,
/// 两处只差排版档(`isCompact`:弹窗 360pt 定宽)。排版差异只有三种,全由宽度决定:
/// 卡用紧凑档;主窗口并排的两卡(内存双环 / 各卷 + 快照)在弹窗里上下排;主窗口的
/// 节标题(此刻 / 开发服务)弹窗不画,卡片各自带标题。排行卡一律卡内标题,不配节标题。
///
/// 组排行卡由宿主经 `ranking` 给:主窗口带搜索过滤与可排序进程表,弹窗是紧凑行与
/// 简版下钻——只差交互深度,出现在哪些 tab、排在哪里由本栈决定。
/// 本栈只出卡片序列,外层 VStack / ScrollView 与间距由宿主给。
struct MetricTabStack<Ranking: View>: View {
    let tab: MetricTab
    let isCompact: Bool
    let monitor: SystemMonitor
    let model: DashboardModel
    /// 当前 tab 的展示内容(内存分段等,DashboardModel.content 折叠)。
    let content: MetricTabContent
    /// 总览卡点击跳转。
    let onSelectTab: (MetricTab) -> Void
    @ViewBuilder let ranking: () -> Ranking

    var body: some View {
        switch tab {
        case .overview:
            overviewGrid
            sectionTitle("此刻")
            pair {
                RingCardView.memoryByType(monitor.memory, isCompact: isCompact)
                memoryByApp
            }
            ranking()
            sectionTitle("开发服务")
            // dev server 卡(工单 p1-history/08):全部停止只上抛请求,确认对话框
            // (KillRequestFlow 关口)把关后才发信号。
            DevServerCardView(servers: monitor.devServers.servers, isCompact: isCompact) {
                model.requestStopAllDevServers(monitor.devServers.servers)
            }
        case .cpu:
            MetricMainCardView(model: model.cpuModel, isCompact: isCompact)
            ranking()
        case .memory:
            MetricMainCardView(model: model.memoryModel, isCompact: isCompact)
            pair {
                RingCardView.memoryByType(monitor.memory, isCompact: isCompact)
                memoryByApp
            }
            ranking()
        case .battery:
            // 电池页(工单 p1-history/02):六项读数主卡 + 能耗影响排行
            // (工单 module-rankings/01,只读);组排行与电池无关,不放。
            MetricMainCardView(model: model.batteryModel, isCompact: isCompact)
            ModuleRankingCardView(
                title: "能耗影响",
                valueLabel: "CPU 时间",
                rows: monitor.rankings.energyRows,
                accent: Metric.battery.accentColor,
                cadenceNote: "5 秒一档",
                isCompact: isCompact
            )
        case .disk:
            // 磁盘页(工单 p1-history/05):主卡 + 各卷对账明细 + 快照列表 + 读写最多排行。
            MetricMainCardView(model: model.diskModel, isCompact: isCompact)
            pair {
                DiskVolumeBreakdownView(capacity: monitor.disk.capacity, isCompact: isCompact)
                DiskSnapshotsCardView(listing: monitor.disk.capacity?.snapshots, isCompact: isCompact)
            }
            ModuleRankingCardView(
                title: "读写最多",
                valueLabel: "读写",
                rows: monitor.rankings.diskRows,
                accent: Metric.disk.accentColor,
                cadenceNote: "30 秒一档",
                isCompact: isCompact
            )
        case .network:
            // 网络页(工单 p1-history/06):主卡 + 流量累计明细 + 每进程流量排行(nettop 归组)。
            MetricMainCardView(model: model.networkModel, isCompact: isCompact)
            NetworkTotalsCardView(totals: monitor.history.networkTotals, isCompact: isCompact)
            ModuleRankingCardView(
                title: "每进程流量",
                valueLabel: "流量",
                rows: monitor.rankings.networkRows,
                accent: Metric.network.accentColor,
                cadenceNote: "5 秒一档",
                isCompact: isCompact
            )
        case .history:
            // 历史页(工单 p1-history/04):指标 × 时间范围走势,查询走引擎 actor。
            HistoryTabView(monitor: monitor, isCompact: isCompact)
        }
    }

    /// 总览模块卡网格(用户拍板 2026-10-17:全部模块一屏可点,点卡跳对应 tab);
    /// 电池卡随有无内建电池。卡间距 full 16 / compact 8(DESIGN.md §Components)。
    private var overviewGrid: some View {
        let spacing: CGFloat = isCompact ? 8 : 16
        let style: MetricCardView.Style = isCompact ? .compact : .full
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: spacing), GridItem(.flexible())],
            spacing: spacing
        ) {
            MetricCardView(model: model.cpuModel, style: style) { onSelectTab(.cpu) }
            MetricCardView(model: model.memoryModel, style: style) { onSelectTab(.memory) }
            MetricCardView(model: model.diskModel, style: style) { onSelectTab(.disk) }
            MetricCardView(model: model.networkModel, style: style) { onSelectTab(.network) }
            if monitor.battery.hasBattery {
                MetricCardView(model: model.batteryModel, style: style) { onSelectTab(.battery) }
            }
        }
    }

    private var memoryByApp: some View {
        RingCardView.memoryByApp(
            segments: content.memorySegments,
            totalBytes: content.memoryTotalBytes,
            isCompact: isCompact
        )
    }

    /// 两卡一组:主窗口并排(顶对齐,卡间距 16),弹窗上下排(卡间距 8)。
    @ViewBuilder
    private func pair<Content: View>(@ViewBuilder _ cards: () -> Content) -> some View {
        if isCompact {
            VStack(spacing: 8) { cards() }
        } else {
            HStack(alignment: .top, spacing: 16) { cards() }
        }
    }

    /// 节标题只在主窗口画(弹窗卡片自带标题,17pt 节标题在 360pt 里喧宾夺主)。
    @ViewBuilder
    private func sectionTitle(_ title: String) -> some View {
        if !isCompact {
            SectionTitle(title: title)
                .padding(.top, 6)
        }
    }
}
