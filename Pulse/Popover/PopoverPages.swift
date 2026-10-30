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
            // 网格 → 内存双环(上下排)→ [排行卡] → dev server(全部停止经 KillRequestFlow 关口)。
            return [
                overviewGrid(context),
                RingCardNSView.memoryByType(context.monitor),
                RingCardNSView.memoryByApp(model),
                DevServerCardNSView(monitor: context.monitor, model: model),
            ]
        case .cpu:
            return [MetricMainCardNSView { model.cpuModel }]
        case .memory:
            return [
                MetricMainCardNSView { model.memoryModel },
                RingCardNSView.memoryByType(context.monitor),
                RingCardNSView.memoryByApp(model),
            ]
        case .gpu:
            return [MetricMainCardNSView { model.gpuModel }, MetricMainCardNSView { model.aneModel }]
        case .battery:
            return [MetricMainCardNSView { model.batteryModel }]
        case .disk:
            return [MetricMainCardNSView { model.diskModel }]
        case .network:
            return [MetricMainCardNSView { model.networkModel }]
        case .history:
            return [HistoryPageNSView(monitor: context.monitor)]
        default:
            return [placeholder(tab)]
        }
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
