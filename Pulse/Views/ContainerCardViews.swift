import PulseCore
import SwiftUI

// MARK: - 容器页卡片(p2-sensors/07)

// HTTP 解析与 stats 折算在核心层 ContainerModel(纯逻辑,单测覆盖——含探针⑦
// 四坑);本文件只做 SwiftUI 外观——容器表行(名称/状态/CPU/内存),弹窗
// (紧凑)与主窗口共用,走预览 + 手动验收。

/// 容器卡:每台一行(名称 + 状态点 + CPU% + 内存),运行中置顶;引擎缺席
/// (OrbStack 未跑)或无容器安静占位。
struct ContainersCardView: View {
    let reading: ContainersReading?
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardSubHeader(
                symbolName: "cube.box.fill",
                title: "容器",
                tint: Metric.containers.accentColor,
                note: note
            )
            if let containers = reading?.containers, !containers.isEmpty {
                VStack(spacing: 6) {
                    ForEach(containers.prefix(isCompact ? 6 : containers.count)) { container in
                        row(container)
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
        let running = reading.containers.filter { $0.state == "running" }.count
        return "\(reading.containers.count) 台 · \(running) 运行中"
    }

    private var emptyTitle: String {
        if let reading, reading.engineReachable {
            return "无容器"
        }
        return "Docker / OrbStack 未运行"
    }

    private func row(_ container: ContainerRow) -> some View {
        let running = container.state == "running"
        return HStack(spacing: 8) {
            Circle()
                .fill(running ? Metric.containers.accentColor : Surface.inactive)
                .frame(width: 6, height: 6)
            Text(container.name)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 8)
            CardRowValue(
                text: container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                minWidth: CardRowWidth.decimalPercentValue
            )
            CardRowValue(
                text: container.memoryBytes.map { PulseFormat.memory($0) } ?? "—",
                minWidth: CardRowWidth.quantityValue,
                style: .tertiary
            )
        }
    }
}
