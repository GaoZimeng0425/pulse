import PulseCore
import SwiftUI

// MARK: - 监听端口卡(工单 port-view/01,服务页)

/// 服务页「监听端口」卡:全机监听 TCP 端口 + 占用进程;行级「结束」上抛该端口
/// 全部占用进程(确认流在 KillRequestFlow 同一关口,绝不自动杀)。
/// dev server 占用行带种类 + 闲置标注(文案与 dev server 卡同口径);root 进程端口
/// 系统读不到,卡脚一行小字如实注明。空态安静——不制造焦虑。
struct PortsCardView: View {
    let inventory: PortInventory?
    /// 弹窗紧凑档(卡 {rounded.card-compact} 12 + {spacing.card-padding-compact} 12)。
    var isCompact = false
    let onEndHolders: ([KillTarget]) -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                symbolName: "network",
                title: "监听端口",
                tint: Metric.network.accentColor
            ) {
                if let count = inventory?.totalCount, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            if let inventory, !inventory.entries.isEmpty {
                VStack(alignment: .leading, spacing: RowMetrics.cardRowSpacing(compact: isCompact)) {
                    ForEach(shownEntries) { entry in
                        row(entry)
                    }
                }
                if inventory.isTruncated {
                    PortOverflowRow(
                        isExpanded: expanded,
                        hiddenCount: inventory.totalCount - shownEntries.count
                    ) {
                        expanded.toggle()
                    }
                }
                Text("系统进程(root)的端口可能不在此列")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            } else {
                CardEmptyState(
                    title: "没有监听中的端口",
                    detail: "程序开始监听 TCP 端口时会出现在这里;系统进程(root)的端口可能读不到"
                )
            }
        }
        .cardShell(compact: isCompact)
    }

    private var shownEntries: [PortEntry] {
        expanded ? Array(inventory?.entries ?? []) : Array((inventory?.entries ?? []).prefix(PortsCardMetrics.rowLimit))
    }

    /// 一行端口(实体行):端口号主名 + 占用者副文;尾部 = dev server 标注 + 「结束」。
    private func row(_ entry: PortEntry) -> some View {
        let valueSize = RowMetrics.valueFontSize(compact: isCompact)
        let first = entry.holders[0]
        return CardEntityRow(
            systemImage: first.devServerKind == nil ? "globe" : "terminal",
            tint: Metric.network.accentColor,
            name: ":\(entry.port)",
            sub: holderSummary(entry),
            compact: isCompact
        ) {
            if let label = devServerLabel(entry) {
                label
                    .font(.system(size: valueSize, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button {
                onEndHolders(entry.holders.map(\.killTarget))
            } label: {
                Text("结束")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Surface.negative)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Surface.negative.opacity(0.1), in: .capsule)
            }
            .buttonStyle(.plain)
            .help("经确认后向占用该端口的进程发送结束信号,绝不自动执行")
        }
        .accessibilityElement(children: .combine)
    }

    /// 占用者副文:第一持有者 + pid;多进程如实「等 N 个进程」。
    private func holderSummary(_ entry: PortEntry) -> String {
        let first = entry.holders[0]
        let base = "\(first.name) · pid \(first.pid)"
        guard entry.holders.count > 1 else { return base }
        return "\(base) 等 \(entry.holders.count) 个进程"
    }

    /// dev server 标注:种类 + 闲置时长,文案与 dev server 卡同口径;颜色不随闲置
    /// 转琥珀。整行都不是 dev server 时不占这一列。
    private func devServerLabel(_ entry: PortEntry) -> Text? {
        guard let holder = entry.holders.first(where: { $0.devServerKind != nil }) else {
            return nil
        }
        let kind = holder.devServerKind?.displayName ?? ""
        let idle = switch holder.idleSeconds {
        case nil: "未闲置"
        case let seconds?: "闲置 \(PulseFormat.duration(seconds: seconds))"
        }
        return Text("\(kind) · \(idle)")
    }
}

/// 端口卡截断末行:与项目卡展开行(`AgentProjectOverflowRow`)同款交互与视觉,
/// 文案按端口口径改写(不复用排行的「前 20 名」字样)。
private struct PortOverflowRow: View {
    let isExpanded: Bool
    let hiddenCount: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(isHovering ? Color.primary.opacity(0.05) : Color.clear, in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isExpanded ? "收起,只看前 \(PortsCardMetrics.rowLimit) 个端口" : "展开全部端口")
    }

    private var label: String {
        isExpanded
            ? "收起,只看前 \(PortsCardMetrics.rowLimit) 个"
            : "显示全部(另 \(hiddenCount) 个端口)"
    }
}

#Preview("监听端口卡:空态 / 常态 / 截断") {
    let plain = PortHolder(pid: 55, name: "node")
    let devServer = PortHolder(pid: 9001, name: "next dev", devServerKind: .nextDev, idleSeconds: 25 * 3600 + 300)
    let sample = PortInventory(
        allEntries: (1 ... 26).map { index in
            PortEntry(port: UInt16(5000 + index), holders: index == 3 ? [devServer] : [plain])
        },
        limit: PortsCardMetrics.rowLimit
    )
    return VStack(spacing: 16) {
        PortsCardView(inventory: nil) { _ in }
        PortsCardView(inventory: sample) { _ in }
    }
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
