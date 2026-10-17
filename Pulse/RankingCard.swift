import SwiftUI
import AppKit

// MARK: - 应用排行卡(工单 P0.6-05,参考文档 §2.3 应用排行卡 / OG "Busiest Right Now")

/// 排行卡:一张卡内的应用榜单——表头 `应用 | CPU`(或内存),
/// 行 = 图标 + 名称 + 进程数副文 | 榜首归一 meter + 数值。
/// 点行展开组内进程(展开内容由调用方给:弹窗 = 下钻列表,主窗口 = 可排序进程表)。
/// 取代原先"每组一张大卡"的形态(用户拍板)。
struct RankingCardView<Expanded: View>: View {
    enum Density {
        /// 主窗口:卡内边距 16、圆角 18、图标 22。
        case regular
        /// 弹窗:卡内边距 12、圆角 12、图标 18、meter 收窄。
        case compact
    }

    var title: String?
    let groups: [ProcessGroup]
    let metric: GroupCardMetric
    let cpuLeader: Double
    let memoryLeaderBytes: UInt64
    let expandedGroupIDs: Set<GroupIdentity>
    var density: Density = .regular
    let onToggle: (GroupIdentity) -> Void
    let onEndGroup: (ProcessGroup) -> Void
    @ViewBuilder let expandedContent: (ProcessGroup) -> Expanded

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
            columnHeader
            ForEach(groups) { group in
                let isExpanded = expandedGroupIDs.contains(group.id)
                VStack(spacing: 4) {
                    RankingRowView(
                        group: group,
                        metric: metric,
                        meterFraction: meterFraction(for: group),
                        isExpanded: isExpanded,
                        isCompact: density == .compact,
                        onToggle: { onToggle(group.id) },
                        onEndGroup: { onEndGroup(group) }
                    )
                    if isExpanded {
                        expandedContent(group)
                            .padding(.bottom, 6)
                    }
                }
            }
        }
        .padding(density == .compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: density == .compact ? 12 : 18))
    }

    private var columnHeader: some View {
        HStack {
            Text("应用")
            Spacer()
            Text(metric == .cpu ? "CPU" : "内存")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.bottom, 2)
    }

    /// meter 榜首归一(工单 02 口径,随口径换指标)。
    private func meterFraction(for group: ProcessGroup) -> Double {
        switch metric {
        case .cpu:
            MeterNormalization.fraction(group.cpuPercent, leader: cpuLeader)
        case .memory:
            MeterNormalization.fraction(Double(group.memoryBytes), leader: Double(memoryLeaderBytes))
        }
    }
}

/// 排行行:图标 + 名称 / 副文 | meter + 数值 + 展开指示。
/// 组 CPU% > 100%(工单 04 徽章语义)在名称行内挂红色 高负载 chip;
/// "结束整组"(工单 08)悬停时出现在行尾,右键菜单同入口;点击只是请求确认。
struct RankingRowView: View {
    let group: ProcessGroup
    let metric: GroupCardMetric
    let meterFraction: Double
    let isExpanded: Bool
    let isCompact: Bool
    let onToggle: () -> Void
    let onEndGroup: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: isCompact ? 8 : 10) {
                icon
                    .frame(width: iconSize, height: iconSize)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(group.name)
                            .font(.system(size: isCompact ? 12.5 : 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let badge = StatusBadgeRules.groupBadge(cpuPercent: group.cpuPercent) {
                            MetricChipView(chip: badge.chip, compact: true)
                                .fixedSize()
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                MeterBar(fraction: meterFraction, tint: accent)
                    .frame(width: isCompact ? 52 : 110)
                Text(valueText)
                    .font(.system(size: isCompact ? 12.5 : 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(minWidth: isCompact ? 48 : 64, alignment: .trailing)
                trailingControls
            }
            .padding(.horizontal, 6)
            .padding(.vertical, isCompact ? 5 : 7)
            .background(
                isHovering || isExpanded ? Color.primary.opacity(0.05) : Color.clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("结束整组…", role: .destructive, action: onEndGroup)
        }
        .accessibilityLabel("\(group.name),\(group.processes.count) 进程,\(valueText)")
        .accessibilityHint(isExpanded ? "收起组内进程列表" : "展开组内进程列表")
    }

    private var iconSize: CGFloat { isCompact ? 18 : 22 }

    /// 结束按钮只在悬停时可见(占位不变,行宽不跳);chevron 常驻指示展开态。
    private var trailingControls: some View {
        HStack(spacing: 2) {
            Button(action: onEndGroup) {
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Surface.negative)
                    .frame(width: 18, height: 18)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .opacity(isHovering ? 1 : 0)
            .help("结束整组(需确认)")
            .accessibilityLabel("结束整组 \(group.name)")
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
        }
    }

    private var valueText: String {
        switch metric {
        case .cpu: PulseFormat.cpuPercent(group.cpuPercent)
        case .memory: PulseFormat.memory(group.memoryBytes)
        }
    }

    /// 副文:进程数 + 另一指标(CPU 口径带内存,内存口径带 CPU%)。
    private var subtitle: String {
        switch metric {
        case .cpu: "\(group.processes.count) 进程 · \(PulseFormat.memory(group.memoryBytes))"
        case .memory: "\(group.processes.count) 进程 · CPU \(PulseFormat.cpuPercent(group.cpuPercent))"
        }
    }

    /// 行内强调色:CPU 口径走类别样式表(孤儿橙);内存口径换内存指标色,孤儿仍橙。
    private var accent: Color {
        if metric == .memory, group.category != .orphan {
            return Metric.memory.accentColor
        }
        return group.category.cardStyle.accentColor
    }

    /// bundle 组用真实应用图标;其余类别用"外壳底色 + 白符号"瓦片(形态对齐 app logo)。
    @ViewBuilder
    private var icon: some View {
        if let bundlePath = group.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            CategoryIconTile(
                symbolName: group.category.cardStyle.symbolName,
                color: group.category.cardStyle.tileColor,
                size: iconSize
            )
        }
    }
}

#Preview("排行卡") {
    let groups = [
        ProcessGroup(
            id: .app(bundlePath: "/Applications/Xcode.app"), name: "Xcode",
            processes: [], cpuPercent: 51.4, memoryBytes: 5_200_000_000
        ),
        ProcessGroup(
            id: .project(root: "/Users/x/work/octok-client", worktreeName: "main"),
            name: "octok-client @ main",
            processes: [], cpuPercent: 18.6, memoryBytes: 2_400_000_000
        ),
        ProcessGroup(
            id: .orphan, name: "孤儿进程",
            processes: [], cpuPercent: 7, memoryBytes: 30_000_000
        ),
    ]
    return VStack(spacing: 16) {
        RankingCardView(
            title: "当前最忙", groups: groups, metric: .cpu, cpuLeader: 51.4, memoryLeaderBytes: 5_200_000_000,
            expandedGroupIDs: [], onToggle: { _ in }, onEndGroup: { _ in }
        ) { _ in EmptyView() }
        RankingCardView(
            groups: groups, metric: .memory, cpuLeader: 51.4, memoryLeaderBytes: 5_200_000_000,
            expandedGroupIDs: [], density: .compact, onToggle: { _ in }, onEndGroup: { _ in }
        ) { _ in EmptyView() }
        .frame(width: 332)
    }
    .padding(24)
    .frame(width: 720)
    .background(Surface.window)
}
