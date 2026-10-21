import AppKit
import PulseCore
import SwiftUI

// MARK: - 模块排行卡(工单 module-rankings/01):电池/磁盘/网络三页各一张只读排行

// 排行列表通用组件(RankingListCard / RankingListRow)上的只读排行:无悬停、不可展开、
// 无结束入口(工单拍板),行尾列留空占位——与组排行的 meter / 数值同一竖线。

struct ModuleRankingCardView: View {
    let title: String
    /// 表头右列指标名("CPU 时间" / "读写" / "流量")。
    let valueLabel: String
    let rows: [ModuleRankingRow]
    /// meter 与标题强调色:随所在模块页取指标令牌(电池/磁盘/网络)。
    let accent: Color
    /// 节拍注脚("5 秒一档" / "30 秒一档"):数据新鲜度的安静声明。
    let cadenceNote: String
    /// 弹窗紧凑档。
    var isCompact = false

    var body: some View {
        RankingListCard(
            title: title,
            accent: accent,
            valueLabel: valueLabel,
            isCompact: isCompact,
            isEmpty: rows.isEmpty,
            // 基线轮(首见不出数)、门控清账、全零空闲都落这里,不报警不催促。
            emptyMessage: RankingEmptyMessage(title: "暂无数据", detail: "本页可见并完成首档采样后出数"),
            footnote: cadenceNote
        ) {
            ForEach(rows) { row in
                RankingListRow(
                    name: row.name,
                    subtitle: row.subtitle,
                    bundlePath: row.bundlePath,
                    // "其他进程"桶(无类别)用通用符号瓦片,不冒充任何组类别。
                    tileSymbol: row.fallbackCategory?.cardStyle.symbolName ?? "app.dashed",
                    tileColor: row.fallbackCategory?.cardStyle.tileColor ?? Surface.inkTertiary,
                    meterFraction: row.meterFraction,
                    tint: accent,
                    valueText: row.primaryText,
                    isCompact: isCompact
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.name),\(row.subtitle),\(row.primaryText)")
            }
        }
    }
}

// MARK: - 预览(spec 测试决策:排行卡外观走预览 + 手动验收)

#Preview("模块排行卡") {
    let rows: [ModuleRankingRow] = [
        ModuleRankingRow(
            id: "bundle:/Applications/Xcode.app", name: "Xcode",
            bundlePath: "/Applications/Xcode.app", fallbackCategory: nil,
            primary: 4.2, primaryText: "4.2 秒", subtitle: "唤醒 3.6 次/秒",
            meterFraction: 1
        ),
        ModuleRankingRow(
            id: "project:/Users/x/work/demo@main", name: "demo @ main",
            bundlePath: nil, fallbackCategory: .project,
            primary: 1.8, primaryText: "1.8 秒", subtitle: "唤醒 1.2 次/秒",
            meterFraction: MeterNormalization.fraction(1.8, leader: 4.2)
        ),
        ModuleRankingRow(
            id: "system", name: "系统",
            bundlePath: nil, fallbackCategory: .system,
            primary: 0.6, primaryText: "0.6 秒", subtitle: "唤醒 0.4 次/秒",
            meterFraction: MeterNormalization.fraction(0.6, leader: 4.2)
        ),
        ModuleRankingRow(
            id: ModuleRankingAggregator.otherProcessesKey, name: "其他进程",
            bundlePath: nil, fallbackCategory: nil,
            primary: 0.2, primaryText: "0.2 秒", subtitle: "唤醒 0.1 次/秒",
            meterFraction: MeterNormalization.fraction(0.2, leader: 4.2)
        ),
    ]
    VStack(spacing: 16) {
        ModuleRankingCardView(
            title: "能耗影响", valueLabel: "CPU 时间", rows: rows,
            accent: Metric.battery.accentColor, cadenceNote: "5 秒一档"
        )
        ModuleRankingCardView(
            title: "读写最多", valueLabel: "读写", rows: [],
            accent: Metric.disk.accentColor, cadenceNote: "30 秒一档"
        )
        ModuleRankingCardView(
            title: "能耗影响(紧凑)", valueLabel: "CPU 时间", rows: rows,
            accent: Metric.battery.accentColor, cadenceNote: "5 秒一档", isCompact: true
        )
        .frame(width: 332)
    }
    .padding(24)
    .frame(width: 620)
    .background(Surface.window)
}
