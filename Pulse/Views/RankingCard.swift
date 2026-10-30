import AppKit
import PulseCore
import SwiftUI

// MARK: - 应用排行卡(工单 P0.6-05,参考文档 §2.3 应用排行卡 / OG "Busiest Right Now")

/// 组排行卡("当前最忙"):排行列表通用组件(RankingListCard / RankingListRow)上的
/// 组排行——行可点开组内进程(展开内容由调用方给:弹窗 = 下钻列表,主窗口 = 可排序
/// 进程表),悬停出「结束整组」。标题色随口径(CPU / 内存指标色)。
/// 取代原先"每组一张大卡"的形态(用户拍板)。
struct RankingCardView<Expanded: View>: View {
    enum Density {
        /// 主窗口:卡内边距 16、圆角 18、图标 22。
        case regular
        /// 弹窗:卡内边距 12、圆角 12、图标 18、meter 收窄。
        case compact
    }

    var title = "当前最忙"
    let groups: [ProcessGroup]
    let metric: GroupCardMetric
    let cpuLeader: Double
    let memoryLeaderBytes: UInt64
    let expandedGroupIDs: Set<GroupIdentity>
    var density: Density = .regular
    /// 组列表为空时的卡内空态(首轮前 / 搜索无命中,由调用方给文案)。
    var emptyMessage = RankingEmptyMessage(title: "暂无活动组", detail: "首轮采样尚未完成,或系统极端空闲")
    let onToggle: (GroupIdentity) -> Void
    let onEndGroup: (ProcessGroup) -> Void
    @ViewBuilder let expandedContent: (ProcessGroup) -> Expanded

    var body: some View {
        RankingListCard(
            title: title,
            accent: metric == .cpu ? Metric.cpu.accentColor : Metric.memory.accentColor,
            valueLabel: metric == .cpu ? "CPU" : "内存",
            isCompact: density == .compact,
            isEmpty: groups.isEmpty,
            emptyMessage: emptyMessage
        ) {
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
    }

    /// meter 榜首归一(工单 p0.6-ui-alignment/02 口径,随口径换指标)。
    private func meterFraction(for group: ProcessGroup) -> Double {
        switch metric {
        case .cpu:
            MeterNormalization.fraction(group.cpuPercent, leader: cpuLeader)
        case .memory:
            MeterNormalization.fraction(Double(group.memoryBytes), leader: Double(memoryLeaderBytes))
        }
    }
}

/// 组排行行:通用行配方 + 交互——点行展开、悬停底色与「结束整组」、右键同入口。
/// 组 CPU% > 100%(StatusBadgeRules 同一阈值)时行尾 CPU 数值标红,名称后挂红色
/// chip 写组内最忙进程名——一眼看出是谁在吃(2026-10-30 用户拍板 B;此前的
/// "高负载"文字 chip 与数值圈红均已撤)。仅 CPU 口径(内存值不背 CPU 警示)。
/// 点击结束只是请求确认。
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
            RankingListRow(
                name: group.name,
                subtitle: subtitle,
                bundlePath: group.bundlePath,
                tileSymbol: group.category.cardStyle.symbolName,
                tileColor: group.category.cardStyle.tileColor,
                meterFraction: meterFraction,
                tint: accent,
                valueText: valueText,
                alertsHighLoad: metric == .cpu
                    && StatusBadgeRules.groupBadge(cpuPercent: group.cpuPercent) != nil,
                valueColumn: .standard,
                isCompact: isCompact
            ) {
                if let hotProcessName {
                    HotProcessChip(name: hotProcessName, compact: isCompact)
                }
            } trailing: {
                trailingControls
            }
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
        .accessibilityLabel(
            "\(group.name),\(group.processes.count) 进程,\(valueText)"
                + (StatusBadgeRules.groupBadge(cpuPercent: group.cpuPercent) != nil ? ",高负载" : "")
                + (hotProcessName.map { ",最忙进程 \($0)" } ?? "")
        )
        .accessibilityHint(isExpanded ? "收起组内进程列表" : "展开组内进程列表")
    }

    /// 结束按钮只在悬停时可见(占位不变,行宽不跳);chevron 常驻指示展开态。
    private var trailingControls: some View {
        HStack(spacing: RankingListMetrics.trailingControlSpacing(compact: isCompact)) {
            Button(action: onEndGroup) {
                let side = RankingListMetrics.endButtonSize(compact: isCompact)
                Image(systemName: "xmark.octagon")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Surface.negative)
                    .frame(width: side, height: side)
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

    /// 最忙进程名:仅 CPU 口径行,阈值与数值标红同源(StatusBadgeRules)。
    private var hotProcessName: String? {
        metric == .cpu ? StatusBadgeRules.groupHotProcessName(group) : nil
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
}

/// 组行最忙进程 chip:状态 chip 配方(胶囊、state-negative 14% 底 + 同色字),只写进程名
/// 不带图标省行宽;长名中间截断,上限宽度防把组名挤没。
struct HotProcessChip: View {
    let name: String
    let compact: Bool

    var body: some View {
        Text(name)
            .font(.system(size: compact ? 10 : 10.5, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(Surface.negative)
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, 1)
            .background(Surface.negative.opacity(0.14), in: .capsule)
            .frame(maxWidth: compact ? 150 : 200, alignment: .leading)
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
            groups: groups, metric: .cpu, cpuLeader: 51.4, memoryLeaderBytes: 5_200_000_000,
            expandedGroupIDs: [], onToggle: { _ in }, onEndGroup: { _ in }
        ) { _ in EmptyView() }
        RankingCardView(
            groups: groups, metric: .memory, cpuLeader: 51.4, memoryLeaderBytes: 5_200_000_000,
            expandedGroupIDs: [], density: .compact, onToggle: { _ in }, onEndGroup: { _ in }
        ) { _ in EmptyView() }
            .frame(width: 332)
        RankingCardView(
            groups: [], metric: .cpu, cpuLeader: 0, memoryLeaderBytes: 0,
            expandedGroupIDs: [], onToggle: { _ in }, onEndGroup: { _ in }
        ) { _ in EmptyView() }
    }
    .padding(24)
    .frame(width: 720)
    .background(Surface.window)
}
