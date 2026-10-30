import AppKit
import PulseCore

// MARK: - 每个 tab 的卡片序列(popover-appkit;以 MetricTabStack 紧凑分支为准)

/// 页面构造所需的共享上下文。
@MainActor
struct PopoverPageContext {
    let monitor: SystemMonitor
    let model: DashboardModel
    /// 总览卡点击跳页。
    let selectTab: (MetricTab) -> Void
}

/// 一个 tab 的卡片序列:组成与顺序照抄 `MetricTabStack` 的 `isCompact == true` 分支
/// (含传感器页只放派生卡的拍板例外,p2-review/04 A)。新增卡片两处一起改:
/// 主窗口改 MetricTabStack,弹窗改这里。
@MainActor
enum PopoverPages {
    static func cards(for tab: MetricTab, context: PopoverPageContext) -> [NSView] {
        let model = context.model
        switch tab {
        case .overview:
            return [overviewGrid(context), groupRanking(.overview, context)]
        case .cpu:
            return [MetricMainCardNSView { model.cpuModel }, groupRanking(.cpu, context)]
        case .memory:
            return [MetricMainCardNSView { model.memoryModel }, groupRanking(.memory, context)]
        case .gpu:
            return [MetricMainCardNSView { model.gpuModel }, MetricMainCardNSView { model.aneModel }]
        case .battery:
            return [MetricMainCardNSView { model.batteryModel }] + batteryRankings(context)
        case .disk:
            return [MetricMainCardNSView { model.diskModel }, diskRanking(context)]
        case .network:
            return [MetricMainCardNSView { model.networkModel }, networkRanking(context)]
        default:
            return [placeholder(tab)]
        }
    }

    /// 「当前最忙」组排行卡(DashboardView.rankingCard 同义:榜单序 / 口径随 tab)。
    private static func groupRanking(_ tab: MetricTab, _ context: PopoverPageContext) -> NSView {
        GroupRankingCardNSView(tab: tab, monitor: context.monitor, model: context.model)
    }

    /// 电池页:能耗影响(CPU 时间估算,5s)+ AI 助手能耗(root Energy Impact,60s)。
    private static func batteryRankings(_ context: PopoverPageContext) -> [NSView] {
        let monitor = context.monitor
        return [
            ModuleRankingCardNSView(
                title: "能耗影响",
                valueLabel: "CPU 时间",
                accent: Metric.battery.accentColor,
                cadenceNote: "5 秒一档"
            ) { monitor.rankings.energyRows },
            ModuleRankingCardNSView(
                title: "AI 助手",
                valueLabel: "能耗",
                accent: Metric.battery.accentColor,
                cadenceNote: "60 秒一档",
                emptyMessage: RankingEmptyMessage(title: "暂无数据", detail: "开启 设置 → 通用 → 特权助手 后出数")
            ) { AgentEnergyTable.rankingRows(monitor.energyImpact.reading?.agents ?? []) },
        ]
    }

    /// 磁盘页:读写最多(30s 一档)。
    private static func diskRanking(_ context: PopoverPageContext) -> NSView {
        let monitor = context.monitor
        return ModuleRankingCardNSView(
            title: "读写最多",
            valueLabel: "读写",
            accent: Metric.disk.accentColor,
            cadenceNote: "30 秒一档"
        ) { monitor.rankings.diskRows }
    }

    /// 网络页:每进程流量(nettop 归组,5s 一档)。
    private static func networkRanking(_ context: PopoverPageContext) -> NSView {
        let monitor = context.monitor
        return ModuleRankingCardNSView(
            title: "每进程流量",
            valueLabel: "流量",
            accent: Metric.network.accentColor,
            cadenceNote: "5 秒一档"
        ) { monitor.rankings.networkRows }
    }

    /// 总览模块卡网格:弹窗定宽固定 2 列、卡间距 8;电池卡随有无内建电池。
    private static func overviewGrid(_ context: PopoverPageContext) -> NSView {
        let model = context.model
        let select = context.selectTab
        var cards: [NSView] = [
            OverviewMetricCardNSView(model: { model.cpuModel }, onOpen: { select(.cpu) }),
            OverviewMetricCardNSView(model: { model.memoryModel }, onOpen: { select(.memory) }),
            OverviewMetricCardNSView(model: { model.gpuModel }, onOpen: { select(.gpu) }),
            OverviewMetricCardNSView(model: { model.diskModel }, onOpen: { select(.disk) }),
            OverviewMetricCardNSView(model: { model.networkModel }, onOpen: { select(.network) }),
        ]
        if context.monitor.battery.hasBattery {
            cards.append(OverviewMetricCardNSView(model: { model.batteryModel }, onOpen: { select(.battery) }))
        }
        return grid(cards, columns: 2, spacing: 8)
    }

    /// 等宽多列网格(LazyVGrid flexible 列同义):末行不满时以空位补齐,保持列宽一致。
    static func grid(_ views: [NSView], columns: Int, spacing: CGFloat) -> NSView {
        var rows: [NSView] = []
        var index = 0
        while index < views.count {
            var cells = Array(views[index ..< min(index + columns, views.count)])
            while cells.count < columns {
                let filler = NSView()
                filler.translatesAutoresizingMaskIntoConstraints = false
                cells.append(filler)
            }
            let row = hstack(cells, spacing: spacing, alignment: .top)
            row.distribution = .fillEqually
            rows.append(row)
            index += columns
        }
        let stack = vstack(rows, spacing: spacing)
        for row in rows {
            row.fillWidth(of: stack)
        }
        return stack
    }

    /// 尚未迁移的页(实施期过渡;09 票前必须清零)。
    private static func placeholder(_ tab: MetricTab) -> NSView {
        let empty = EmptyStateView()
        empty.set(title: "\(tab.title) 页迁移中", detail: "popover-appkit")
        return CardView(content: empty)
    }
}
