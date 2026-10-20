import SwiftUI
import AppKit

// MARK: - 模块排行共用卡(工单 module-rankings/01):电池/磁盘/网络三页各一张只读排行
// 视觉配方对齐 RankingRowView 的 regular 档(图标 22、名称 13 medium、副文
// 10.5、数值 13 semibold monospacedDigit、meter 110 宽榜首归一、行距 1/行内
// 距 6×7),但**无悬停结束按钮、不可展开**——模块排行只读,处置入口不进
// (工单拍板)。卡形态 = Surface.card + {rounded.card} 18 + {spacing.card-padding}
// 16(DESIGN.md 令牌),标题走 {typography.card-title}(12.5 semibold 指标色)。
// 紧凑档(弹窗,2026-10-20 起与主窗口同内容)对齐 RankingRowView 的 compact 档:
// 图标 18、名称/数值 12.5、meter 52、数值列 48、行内距 5;卡 {rounded.card-compact} 12
// + {spacing.card-padding-compact} 12。

struct ModuleRankingCardView: View {
    let title: String
    let rows: [ModuleRankingRow]
    /// meter 与标题强调色:随所在模块页取指标令牌(电池/磁盘/网络)。
    let accent: Color
    /// 节拍注脚("5 秒一档" / "30 秒一档"):数据新鲜度的安静声明。
    let cadenceNote: String
    /// 弹窗紧凑档。
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(accent)
                .padding(.bottom, 6)
            if rows.isEmpty {
                emptyState
            } else {
                ForEach(rows) { row in
                    ModuleRankingRowView(row: row, accent: accent, isCompact: isCompact)
                }
            }
            Text(cadenceNote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(isCompact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: isCompact ? 12 : 18))
    }

    /// 空态安静文案:基线轮(首见不出数)、门控清账、全零空闲都落这里,
    /// 不报警不催促——回到本页等一档即有数。
    private var emptyState: some View {
        Text("暂无数据,本页可见并完成首档采样后出数")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
}

/// 模块排行行(只读):图标 + 名称/副文 | meter + 主值。
/// 与 RankingRowView 同配方但非按钮:无 hover、无 chevron、无结束入口。
private struct ModuleRankingRowView: View {
    let row: ModuleRankingRow
    let accent: Color
    let isCompact: Bool

    var body: some View {
        HStack(spacing: isCompact ? 8 : 10) {
            icon
                .frame(width: iconSize, height: iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: isCompact ? 12.5 : 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            MeterBar(fraction: row.meterFraction, tint: accent)
                .frame(width: isCompact ? 52 : 110)
            Text(row.primaryText)
                .font(.system(size: isCompact ? 12.5 : 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: isCompact ? 48 : 64, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, isCompact ? 5 : 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name),\(row.subtitle),\(row.primaryText)")
    }

    /// 图标解析与 RankingRowView 同款:App 组取真实应用图标,其余取类别瓦片;
    /// "其他进程"桶(无类别)用通用符号瓦片——不冒充任何组类别。
    @ViewBuilder
    private var icon: some View {
        if let bundlePath = row.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            CategoryIconTile(
                symbolName: row.fallbackCategory?.cardStyle.symbolName ?? "app.dashed",
                color: row.fallbackCategory?.cardStyle.tileColor ?? Surface.inkTertiary,
                size: iconSize
            )
        }
    }

    private var iconSize: CGFloat { isCompact ? 18 : 22 }
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
            title: "能耗影响", rows: rows,
            accent: Metric.battery.accentColor, cadenceNote: "5 秒一档"
        )
        ModuleRankingCardView(
            title: "读写最多", rows: [],
            accent: Metric.disk.accentColor, cadenceNote: "30 秒一档"
        )
        ModuleRankingCardView(
            title: "能耗影响(紧凑)", rows: rows,
            accent: Metric.battery.accentColor, cadenceNote: "5 秒一档", isCompact: true
        )
        .frame(width: 332)
    }
    .padding(24)
    .frame(width: 620)
    .background(Surface.window)
}
