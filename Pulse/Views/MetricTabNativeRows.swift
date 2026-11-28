import PulseCore
import SwiftUI

// MARK: - 卡片序列 → 原生列表行(弹窗与主窗口共用)

//
// main-window-native-list(2026-11-28 用户拍板「两窗一个列表组件」):原生列表 NativeList
// 原先只接在弹窗,主窗口还是 ScrollView + 普通 VStack——排行展开到上百行时全部行常驻,
// 滚一帧整页重出绘制、重算命中与跟踪区(真机滚动 ~37%,离屏 120 行 ~47%)。拼装逻辑
// 从 DashboardView 搬到这里,两窗读同一份:卡片一卡一行,排行拆成卡头 / 每行 /
// 「显示全部」/ 卡尾。两窗只差下面这几个参数,不再各拼一套。

/// 组排行(当前最忙)的行数据:宿主给——弹窗是全部组 + 简版下钻,主窗口叠了搜索过滤
/// 与可排序进程表;截断动作同一套 RankingOverflow(弹窗跳主窗口 / 主窗口原地展开)。
struct GroupRankingRowsSpec {
    let groups: [ProcessGroup]
    let metric: GroupCardMetric
    let cpuLeader: Double
    let memoryLeaderBytes: UInt64
    let expandedGroupIDs: Set<GroupIdentity>
    let emptyMessage: RankingEmptyMessage
    /// nil = 不截(主窗口搜索命中:过滤本身已经收窄)。
    let overflow: RankingOverflow.Action?
    let onToggle: (GroupIdentity) -> Void
    let onEndGroup: (ProcessGroup) -> Void
    let expandedContent: (ProcessGroup) -> AnyView
}

@MainActor
struct MetricTabNativeRows {
    let blocks: [MetricTabBlock]
    let isCompact: Bool
    let groupRanking: GroupRankingRowsSpec
    /// 模块排行卡的截断动作(按卡 id;规则同 MetricTabStack.body)。
    let moduleOverflow: (_ cardID: String) -> RankingOverflow.Action?
    /// 卡外间距的一半:原生列表没有行间距,卡间距 = 上下各留这么多透明边
    /// (弹窗卡间距 8 → 4;主窗口 16 → 8)。
    let halfGap: CGFloat
    /// 行内容的水平外边距(主窗口页边 24;弹窗 0)。
    var horizontalInset: CGFloat = 0
    /// 最后一块不留下半间距(主窗口:原 VStack 末卡贴底,页底留白由外层 24 给)。
    var trimsTrailingGap = false

    var rows: [NativeListRow] {
        blocks.enumerated().flatMap { index, block -> [NativeListRow] in
            let bottomGap = trimsTrailingGap && index == blocks.count - 1 ? 0 : halfGap
            switch block.kind {
            case let .card(view):
                let gap = halfGap
                return [row(kind: block.id, height: .measured(key: block.id)) {
                    view.padding(.top, gap).padding(.bottom, bottomGap)
                }]
            case .groupRanking:
                return groupRankingRows(id: block.id, bottomGap: bottomGap)
            case let .moduleRanking(spec):
                return moduleRankingRows(id: block.id, spec: spec, bottomGap: bottomGap)
            }
        }
    }

    // MARK: 排行逐行

    /// 组排行:组行同高(按 kind 量一次),展开的组连同下钻按组自量。
    private func groupRankingRows(id: String, bottomGap: CGFloat) -> [NativeListRow] {
        let spec = groupRanking
        let header = RankingListHeader(
            title: GroupRankingStyle.title,
            accent: GroupRankingStyle.accent(spec.metric),
            valueLabel: GroupRankingStyle.valueLabel(spec.metric),
            isCompact: isCompact,
            isEmpty: spec.groups.isEmpty,
            emptyMessage: spec.emptyMessage
        )
        var rows = [headerRow(id: id, header: header)]
        let shown = spec.overflow.map { RankingOverflow.split(spec.groups, isExpanded: $0.isExpanded).shown }
            ?? spec.groups[...]
        for group in shown {
            let isExpanded = spec.expandedGroupIDs.contains(group.id)
            let cell = RankingGroupCell(
                group: group,
                metric: spec.metric,
                meterFraction: GroupRankingStyle.meterFraction(
                    group, metric: spec.metric,
                    cpuLeader: spec.cpuLeader, memoryLeaderBytes: spec.memoryLeaderBytes
                ),
                isExpanded: isExpanded,
                isCompact: isCompact,
                onToggle: { spec.onToggle(group.id) },
                onEndGroup: { spec.onEndGroup(group) },
                expandedContent: { spec.expandedContent(group) }
            )
            let compact = isCompact
            rows.append(isExpanded
                ? row(kind: "\(id)-row-expanded", height: .measured(key: "\(id)-x-\(group.id)")) {
                    cell.rankingRowSlice(compact: compact)
                }
                : row(kind: "\(id)-row", height: .uniform) {
                    cell.rankingRowSlice(compact: compact)
                })
        }
        rows += showAllRows(id: id, total: spec.groups.count, action: spec.overflow)
        rows.append(footerRow(id: id, footnote: nil, bottomGap: bottomGap))
        return rows
    }

    /// 模块排行(只读,行同高)。
    private func moduleRankingRows(id: String, spec: ModuleRankingSpec, bottomGap: CGFloat) -> [NativeListRow] {
        let header = RankingListHeader(
            title: spec.title, accent: spec.accent, valueLabel: spec.valueLabel,
            isCompact: isCompact, isEmpty: spec.rows.isEmpty, emptyMessage: spec.resolvedEmptyMessage
        )
        let overflow = moduleOverflow(id)
        let shown = overflow.map { RankingOverflow.split(spec.rows, isExpanded: $0.isExpanded).shown }
            ?? spec.rows[...]
        let compact = isCompact
        var rows = [headerRow(id: id, header: header)]
        rows += shown.map { item in
            row(kind: "\(id)-row", height: .uniform) {
                ModuleRankingRowView(row: item, accent: spec.accent, isCompact: compact)
                    .rankingRowSlice(compact: compact)
            }
        }
        rows += showAllRows(id: id, total: spec.rows.count, action: overflow)
        rows.append(footerRow(id: id, footnote: spec.cadenceNote, bottomGap: bottomGap))
        return rows
    }

    private func headerRow(id: String, header: RankingListHeader) -> NativeListRow {
        let compact = isCompact
        let gap = halfGap
        return row(kind: "\(id)-header", height: .measured(key: "\(id)-header-\(header.isEmpty)")) {
            RankingListSlices.Header(content: header, isCompact: compact, outerGap: gap)
        }
    }

    private func footerRow(id: String, footnote: String?, bottomGap: CGFloat) -> NativeListRow {
        let compact = isCompact
        return row(kind: "\(id)-footer", height: .measured(key: "\(id)-footer-\(bottomGap)")) {
            RankingListSlices.Footer(footnote: footnote, isCompact: compact, outerGap: bottomGap)
        }
    }

    /// 超出前 20 名时补一行「显示全部 / 收起」(整卡形态由 RankingListCard 自画)。
    private func showAllRows(id: String, total: Int, action: RankingOverflow.Action?) -> [NativeListRow] {
        guard let action, let rowModel = RankingOverflow.rowModel(total: total, action: action) else { return [] }
        let compact = isCompact
        return [row(kind: "\(id)-show-all", height: .uniform) {
            RankingOverflowRow(model: rowModel, isCompact: compact).rankingRowSlice(compact: compact)
        }]
    }

    /// 一行:内容统一加水平外边距(主窗口页边),装进 AnyView。
    private func row(
        kind: String,
        height: NativeListRow.Height,
        @ViewBuilder content: @escaping () -> some View
    ) -> NativeListRow {
        let inset = horizontalInset
        // 撑满行宽、内容靠左:表格行会把窄内容(节标题、子页条)居中(DESIGN.md 药丸条注)。
        return NativeListRow(kind: kind, height: height) {
            AnyView(InsetRowContent(inset: inset, content: content))
        }
    }
}

/// 行内容外壳:撑满行宽、内容靠左(表格行会把窄内容——节标题、子页条——居中,
/// DESIGN.md 药丸条注),加水平页边,并把「行宽 − 两侧页边」作为内容宽传给卡片。
private struct InsetRowContent<Content: View>: View {
    let inset: CGFloat
    @ViewBuilder let content: () -> Content
    @Environment(\.nativeListRowWidth) private var rowWidth

    var body: some View {
        content()
            .environment(\.listContentWidth, rowWidth.map { max(0, $0 - inset * 2) })
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
    }
}
