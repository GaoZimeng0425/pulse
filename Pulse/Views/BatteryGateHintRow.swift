import PulseCore
import SwiftUI

// 工单 battery-energy/02:电池页空排行收成紧凑引导行。helper 批准链搁置期间,
// 两张「耗电排行」卡长期停在同一个引导空态——整页读作「一张活卡 + 两张双胞胎
// 死卡」;收到读数前收成一行,数据到了自动还原两张完整卡。

/// 耗电排行的布局形态:数据说了算——任一排行有行出两张完整卡;全空收成一条
/// 紧凑引导行(携带 gate 态,行内文案与出口由 gate 四态决定)。纯判定,单测见
/// PulseTests.BatteryRankingsLayoutTests。
enum BatteryRankingsLayout: Equatable {
    case hint(EnergyHelperGate)
    case cards

    static func resolve(
        gate: EnergyHelperGate,
        allAppsRowCount: Int,
        agentRowCount: Int
    ) -> BatteryRankingsLayout {
        (allAppsRowCount > 0 || agentRowCount > 0) ? .cards : .hint(gate)
    }
}

/// 紧凑引导行:一行高卡壳 + 电池 accent 图标 + 四态文案(title + detail)+
/// 尾部 `.link` 出口;文案与动作 = `MetricTabStack.energyGateEmptyMessage` 同源,
/// 不另写一套(energy-one-tap 一键直达管线照用)。
struct BatteryGateHintRow: View {
    let message: RankingEmptyMessage
    /// 弹窗紧凑档。
    var isCompact = false
    /// 等读数态(btm-lwcr-fix/04):行尾小号转圈,点了开关后有「正在等」的
    /// 反馈,数据到自动被排行替换(与 DESIGN.md「卡头文字按钮」的进行中形态同款)。
    var showsProgress = false

    var body: some View {
        HStack(spacing: RowMetrics.spacing(compact: isCompact)) {
            Image(systemName: "bolt.badge.clock")
                .font(.system(size: IconSize.leading(compact: isCompact), weight: .medium))
                .foregroundStyle(Metric.battery.accentColor)
                .frame(width: RowMetrics.iconSize(compact: isCompact))
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                if let detail = message.detail {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(detail)
                }
            }
            Spacer(minLength: 12)
            if let actionTitle = message.actionTitle, let action = message.action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            } else if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(Metric.battery.accentColor)
            }
        }
        .cardShell(compact: isCompact)
    }
}

#Preview("紧凑引导行") {
    BatteryGateHintRow(
        message: RankingEmptyMessage(
            title: "耗电排行需要特权助手",
            detail: "每分钟采集一次各 App 能耗(活动监视器同口径)。点一下:登记并带你到系统设置允许(仅首次)",
            actionTitle: "开启并去批准",
            action: {}
        )
    )
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
