import SwiftUI

// MARK: - 网络卡明细视图(工单 06):Today/7 天累计的分方向明细
// 数据形状(差分/接口选择/累计聚合)在 NetworkSensor 与 HistoryEngine(纯逻辑,
// 单测覆盖);本文件只做 SwiftUI 外观,与磁盘各卷明细卡同层——tab 主卡之下的
// 补充卡,走预览 + 手动验收(spec 测试决策)。

/// 流量累计明细(工单 06):Today / 7 天各两行(下行 rx / 上行 tx),合计取
/// 历史库 SQL 聚合(system_min/system_hour),UI 不重算。读数缺失(库缺席/
/// 首轮前)给安静文案而不是坏 UI。
struct NetworkTotalsCardView: View {
    let totals: NetworkTotalsReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let totals {
                row("今日下行", bytes: totals.todayDownBytes, prominent: true)
                row("今日上行", bytes: totals.todayUpBytes)
                row("7 天下行", bytes: totals.weekDownBytes)
                row("7 天上行", bytes: totals.weekUpBytes)
            } else {
                CardEmptyState(title: "累计暂不可用")
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        CardSubHeader(
            symbolName: "network",
            title: "流量累计",
            tint: Metric.network.accentColor,
            note: totals.map { "7 天合计 \(PulseFormat.networkTotal($0.weekDownBytes + $0.weekUpBytes))" }
        )
    }

    private func row(_ label: String, bytes: UInt64, prominent: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(prominent ? .primary : .secondary)
            Spacer()
            Text(PulseFormat.networkTotal(bytes))
                .font(.system(size: 12, weight: prominent ? .semibold : .regular))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

#Preview("流量累计") {
    VStack(spacing: 12) {
        NetworkTotalsCardView(
            totals: NetworkTotalsReading(
                todayDownBytes: 2_530_000_000,
                todayUpBytes: 412_000_000,
                weekDownBytes: 18_940_000_000,
                weekUpBytes: 3_110_000_000
            )
        )
        NetworkTotalsCardView(totals: nil, isCompact: true)
    }
    .padding(16)
    .frame(width: 340)
    .background(Surface.window)
}
