import PulseCore
import SwiftUI

// MARK: - 每个 tab 的内容栈(主窗口与弹窗共用,2026-10-20 用户拍板:每个 tab 两处一致)

// 唯一拍板例外:传感器 tab 弹窗只放派生卡(p2-review/04 A,2026-10-24;spec Story 17),
// 见 `.sensors` 分支——不要按"两处一致"把风扇卡 / 明细卡加回弹窗。

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
        case .sensors:
            // 传感器页(p2-sensors/04):主窗口 = 派生读数 + 风扇 pair,温度明细折叠其下。
            // 弹窗是"两处一致"的**拍板例外**(p2-review/04 A,2026-10-24;spec Story 17
            // 「弹窗温度组只放派生值」):只画派生卡(Average/Hottest + 最快风扇),
            // 逐核明细会把 360pt 弹窗撑得不可用的高;风扇信息由派生卡的最快风扇行承载。
            if isCompact {
                SmcDerivedCardView(reading: monitor.smc.reading, isCompact: true)
            } else {
                pair {
                    SmcDerivedCardView(reading: monitor.smc.reading, isCompact: false)
                    SmcFansCardView(reading: monitor.smc.reading, isCompact: false)
                }
                SmcTempsDetailCardView(reading: monitor.smc.reading, isCompact: false)
            }
        case .peripherals:
            // 外设页(p2-sensors/05/06):蓝牙设备表(三源电量合并,可见 30s 扫描;
            // 默认关,卡片按钮 / 设置开关是唯一触发源——权限原则)+ 声音区(纯展示,
            // 事件驱动零轮询)。
            BluetoothDevicesCardView(
                reading: monitor.bluetooth.reading,
                accessState: monitor.bluetooth.accessState,
                isCompact: isCompact,
                onEnable: { monitor.bluetooth.setEnabled(true) },
                onAuthorize: { monitor.bluetooth.requestAuthorization() }
            )
            SoundCardView(reading: monitor.sound.reading, isCompact: isCompact)
        case .gpu:
            // GPU 页(p2-sensors/02/03):利用率主卡 + ANE 卡与五路功率区
            // (同一 Energy Model 订阅,一鱼五吃);每 App GPU 归因是 P3(root
            // helper)的事,本页不设排行。
            MetricMainCardView(model: model.gpuModel, isCompact: isCompact)
            pair {
                MetricMainCardView(model: model.aneModel, isCompact: isCompact)
                PowerDomainsCardView(reading: monitor.power.reading, isCompact: isCompact)
            }
        case .containers:
            // 容器页(p2-sensors/07):docker.sock 单发快照表;数据卷占用行
            // 刻意不做(未拍板,spec Out of Scope)。
            ContainersCardView(reading: monitor.containers.reading, isCompact: isCompact)
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
    /// 主窗口列数**自适应 1–4**(用户拍板 2026-10-24):列数 = 内容宽容纳的最多列,
    /// 单卡最小宽 340(DESIGN.md `layout.overview-card-min-width`)——720 最小窗宽
    /// 下 1 列、744 起两列、约 1104 三列、约 1456 四列,再宽也不超过 4 列;
    /// 弹窗定宽 360 固定 2 列。
    @ViewBuilder
    private var overviewGrid: some View {
        let style: MetricCardView.Style = isCompact ? .compact : .full
        if isCompact {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                overviewCards(style: style)
            }
        } else {
            AdaptiveCardGrid {
                overviewCards(style: style)
            }
        }
    }

    @ViewBuilder
    private func overviewCards(style: MetricCardView.Style) -> some View {
        MetricCardView(model: model.cpuModel, style: style) { onSelectTab(.cpu) }
        MetricCardView(model: model.memoryModel, style: style) { onSelectTab(.memory) }
        MetricCardView(model: model.gpuModel, style: style) { onSelectTab(.gpu) }
        MetricCardView(model: model.diskModel, style: style) { onSelectTab(.disk) }
        MetricCardView(model: model.networkModel, style: style) { onSelectTab(.network) }
        if monitor.battery.hasBattery {
            MetricCardView(model: model.batteryModel, style: style) { onSelectTab(.battery) }
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
    private func pair(@ViewBuilder _ cards: () -> some View) -> some View {
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

/// 自适应网格的常量(泛型 struct 不支持 static 存储属性,独立枚举承载)。
private enum AdaptiveCardGridMetrics {
    /// 单卡最小宽(DESIGN.md `layout.overview-card-min-width`)。
    static let minimumCardWidth: CGFloat = 340
    static let spacing: CGFloat = 16
    static let maximumColumns = 4
}

/// 自适应列数的卡片网格(总览用,用户拍板 2026-10-24:列数 1–4 随窗宽):
/// 列数 = 内容宽容纳的最多列(单卡最小宽 340 + 列距 16),夹在 1…4——
/// 比系统的 `.adaptive` 多一个**上限**(ultrawide 不出第 5 列)。宽度经
/// `onGeometryChange` 读取,只在跨档时改状态,拖拽缩放不逐帧重排。
private struct AdaptiveCardGrid<Card: View>: View {
    /// 初值取默认窗宽(880)的档位,首帧即正确;onGeometryChange 随后按实测纠正。
    @State private var columnCount = 2
    @ViewBuilder let cards: () -> Card

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: AdaptiveCardGridMetrics.spacing),
                count: columnCount
            ),
            spacing: AdaptiveCardGridMetrics.spacing
        ) {
            cards()
        }
        .onGeometryChange(for: Int.self) { proxy in
            let perColumn = AdaptiveCardGridMetrics.minimumCardWidth + AdaptiveCardGridMetrics.spacing
            let fitted = Int((proxy.size.width + AdaptiveCardGridMetrics.spacing) / perColumn)
            return min(AdaptiveCardGridMetrics.maximumColumns, max(1, fitted))
        } action: { newValue in
            if newValue != columnCount {
                columnCount = newValue
            }
        }
    }
}
