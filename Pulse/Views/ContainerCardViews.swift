import PulseCore
import SwiftUI

// MARK: - 容器页卡片(p2-sensors/07;行样式 ui-unify 追改 2026-11-09)

// HTTP 解析与 stats 折算在核心层 ContainerModel(纯逻辑,单测覆盖——含探针⑦
// 四坑);本文件只做 SwiftUI 外观——容器实体行(CardEntityRow:图标 + 名称 + CPU% +
// 内存),弹窗(紧凑)与主窗口共用,走预览 + 手动验收。

/// 容器卡:每台一行,运行中置顶(行序是 `ContainersReading` 的不变量,本视图照序画,
/// p2-review/03);图标亮 = 运行中、灰 = 未运行(代替旧状态圆点)。数值列的"—" =
/// 该容器没有 stats 样本(未运行),是表格的诚实单元格(DESIGN.md 未知值安静原则的
/// 数值列例外)。弹窗截 6 行补「…共 N 台」;引擎缺席(OrbStack 未跑)或无容器安静占位。
struct ContainersCardView: View {
    let reading: ContainersReading?
    var isCompact = false

    private static let compactLimit = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "cube.box.fill",
                title: "容器",
                tint: Metric.containers.accentColor,
                note: note
            )
            if let containers = reading?.containers, !containers.isEmpty {
                VStack(spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                    ForEach(containers.prefix(isCompact ? Self.compactLimit : containers.count)) { container in
                        row(container)
                    }
                    if isCompact, containers.count > Self.compactLimit {
                        Text("…共 \(containers.count) 台")
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }
                }
            } else {
                CardEmptyState(title: emptyTitle)
            }
        }
        .cardShell(compact: isCompact)
        .accessibilityElement(children: .combine)
    }

    private var note: String? {
        guard let reading, !reading.containers.isEmpty else { return nil }
        let running = reading.containers.filter(\.isRunning).count
        return "\(reading.containers.count) 台 · \(running) 运行中"
    }

    private var emptyTitle: String {
        if let reading, reading.engineReachable {
            return "无容器"
        }
        return "Docker / OrbStack 未运行"
    }

    private func row(_ container: ContainerRow) -> some View {
        let running = container.isRunning
        let valueSize = RowMetrics.valueFontSize(compact: isCompact)
        return CardEntityRow(
            systemImage: running ? "cube.box.fill" : "cube.box",
            tint: running ? Metric.containers.accentColor : Surface.inactive,
            name: container.name,
            compact: isCompact
        ) {
            CardRowValue(
                text: container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                minWidth: CardRowWidth.decimalPercentValue,
                style: .primary,
                fontSize: valueSize,
                weight: .semibold
            )
            CardRowValue(
                text: container.memoryBytes.map { PulseFormat.memory($0) } ?? "—",
                minWidth: CardRowWidth.quantityValue,
                style: .secondary,
                fontSize: valueSize
            )
        }
    }
}
