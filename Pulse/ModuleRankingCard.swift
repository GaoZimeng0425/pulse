import SwiftUI
import AppKit

// MARK: - 模块排行共用卡(工单 01):电池/磁盘/网络三页各一张只读排行
// 视觉配方对齐 RankingRowView 的 regular 档(图标 22、名称 13 medium、副文
// 10.5、数值 13 semibold monospacedDigit、meter 110 宽榜首归一、行距 1/行内
// 距 6×7),但**无悬停结束按钮、不可展开**——模块排行只读,处置入口不进
// (工单拍板)。卡形态 = Surface.card + {rounded.card} 18 + {spacing.card-padding}
// 16(DESIGN.md 令牌),标题走 {typography.card-title}(12.5 semibold 指标色)。

struct ModuleRankingCardView: View {
    let title: String
    let rows: [ModuleRankingRow]
    /// meter 与标题强调色:随所在模块页取指标令牌(电池/磁盘/网络)。
    let accent: Color
    /// 节拍注脚("5 秒一档" / "30 秒一档"):数据新鲜度的安静声明。
    let cadenceNote: String

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
                    ModuleRankingRowView(row: row, accent: accent)
                }
            }
            Text(cadenceNote)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: 18))
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

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            MeterBar(fraction: row.meterFraction, tint: accent)
                .frame(width: 110)
            Text(row.primaryText)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
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
                size: 22
            )
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
            title: "能耗影响", rows: rows,
            accent: Metric.battery.accentColor, cadenceNote: "5 秒一档"
        )
        ModuleRankingCardView(
            title: "读写最多", rows: [],
            accent: Metric.disk.accentColor, cadenceNote: "30 秒一档"
        )
    }
    .padding(24)
    .frame(width: 620)
    .background(Surface.window)
}
