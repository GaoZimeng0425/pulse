import AppKit
import PulseCore
import SwiftUI

// MARK: - 项目榜单(agent-usage-redesign/03)

//
// 项目区是一张排行卡:卡内标题 → 表头 → 每个项目一行 → 截断末行。行建在「排行列表」
// 标准件之上(行尺寸走 RowMetrics 两档、行尾留展开箭头一列、悬停底色、卡内空态、
// 截断末行);与通用排行行只差两处——占比条是分段的(两段 = 两家来源),数值有三列
// (占比 / 消耗 / 环比)。紧凑档的行是两行(上行名称 + 消耗,下行小字:在跑 / 占比 /
// 环比),给名称留出宽度。点一行原地展开明细,展开区把后面的行推下去。
// 排序、占比、环比、五桶、模型与来源份额全在 PulseCore `AgentUsageWindow.projects`。

/// 榜单的列宽(页面专属参数;行尺寸的共享值一律委托 `RowMetrics` / `RankingListMetrics`)。
enum AgentProjectRankingMetrics {
    /// 占比列:整数百分比,取 `{layout.row-value-percent}`(令牌按 12pt 量,随行档放大)。
    static func shareWidth(compact: Bool) -> CGFloat {
        CardRowWidth.scaled(CardRowWidth.percentValue, fontSize: RowMetrics.valueFontSize(compact: compact))
    }

    /// 占比条宽,同 meter 条;紧凑档不画条。
    static func barWidth(compact: Bool) -> CGFloat {
        RowMetrics.meterWidth(compact: compact)
    }

    /// 行尾的展开箭头列,同所有排行。
    static func trailingWidth(compact: Bool) -> CGFloat {
        RankingListMetrics.trailingWidth(compact: compact)
    }

    /// 消耗列:按该列最宽的现实读数以实际绘制字体量宽 + 2。
    static func tokensWidth(compact: Bool) -> CGFloat {
        compact ? compactTokensWidth : regularTokensWidth
    }

    /// 环比列(▲ +N% / ▼ -N% / 持平):两档同为 10.5 常规。
    static let deltaWidth = measured(
        ["▲ +999%", "▼ -999%", "持平"], fontSize: 10.5, weight: .regular
    )

    private static let regularTokensWidth = measured(
        ["999.9B", "999.9M", "999k", "999"], fontSize: RowMetrics.valueFontSize(compact: false), weight: .semibold
    )
    private static let compactTokensWidth = measured(
        ["999.9B", "999.9M", "999k", "999"], fontSize: RowMetrics.valueFontSize(compact: true), weight: .semibold
    )

    private static func measured(_ readings: [String], fontSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: weight)
        let widest = readings.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(widest) + 2
    }
}

/// 项目榜单卡:标题带当前窗口天数;默认列前 N 个,末行展开 / 收起;点行看明细。
struct AgentProjectRankingCard: View {
    /// 窗口内全部项目(已按消耗降序)。
    let projects: [AgentProjectSummary]
    let windowDays: Int
    let isCompact: Bool
    /// 展开明细的项目(按项目名);由子页持有,切范围保持。
    @Binding var expandedProjects: Set<String>
    /// 超过上限后是否列出全部。
    @Binding var showsAll: Bool

    /// 默认展示上限(DESIGN.md `{layout.agent-project-limit}`)。
    private static let limit = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                symbolName: nil, title: "项目 · 近 \(windowDays) 天", tint: agentsAccent
            ) {
                EmptyView()
            }
            if projects.isEmpty {
                CardEmptyState(title: "窗口内没有项目数据", detail: "只有粗粒度回填的日子没有项目维度")
            } else {
                columnHeader
                // 行距 2,同所有排行卡。
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { project in
                        AgentProjectRankingRow(
                            project: project,
                            windowDays: windowDays,
                            peakTotal: projects.first?.total ?? 0,
                            isExpanded: expandedProjects.contains(project.id),
                            isCompact: isCompact
                        ) {
                            toggle(project.id)
                        }
                    }
                    if projects.count > Self.limit {
                        AgentProjectOverflowRow(
                            isExpanded: showsAll,
                            hiddenCount: projects.count - Self.limit
                        ) {
                            showsAll.toggle()
                        }
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    private var shown: [AgentProjectSummary] {
        showsAll ? projects : Array(projects.prefix(Self.limit))
    }

    private func toggle(_ id: String) {
        if expandedProjects.contains(id) {
            expandedProjects.remove(id)
        } else {
            expandedProjects.insert(id)
        }
    }

    /// 表头逐列命名,列宽与行逐列相同;首列留出行首图标的宽,和名称对齐。紧凑档的行是
    /// 两行,占比与环比在第二行的小字里自带口径,表头只剩「项目 | 消耗」。
    private var columnHeader: some View {
        HStack(spacing: RowMetrics.spacing(compact: isCompact)) {
            HStack(spacing: 0) {
                placeholder(width: RowMetrics.iconSize(compact: isCompact))
                Text("项目")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isCompact {
                placeholder(width: AgentProjectRankingMetrics.barWidth(compact: false))
            }
            if !isCompact {
                Text("占比").frame(
                    width: AgentProjectRankingMetrics.shareWidth(compact: isCompact), alignment: .trailing
                )
            }
            Text("消耗").frame(
                width: AgentProjectRankingMetrics.tokensWidth(compact: isCompact), alignment: .trailing
            )
            if !isCompact {
                Text("环比").frame(width: AgentProjectRankingMetrics.deltaWidth, alignment: .trailing)
            }
            placeholder(width: AgentProjectRankingMetrics.trailingWidth(compact: isCompact))
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, RowMetrics.rowInset(compact: isCompact))
        .padding(.bottom, 2)
    }

    /// 表头里给图标 / 占比条 / 箭头列占位的透明块。高度必须定死:只定宽的 `Color.clear`
    /// 高度是弹性的,弹窗把整页当一个量高块,会把整页量成天文数字。
    private func placeholder(width: CGFloat) -> some View {
        Color.clear.frame(width: width, height: 1)
    }
}

/// 榜单的一行。全尺寸一行:图标 + 名称与「在跑」芯片 + 分段占比条 + 占比 / 消耗 / 环比
/// + 箭头;紧凑档两行:上行名称 + 消耗,下行在跑 / 占比 / 环比。整行可点,悬停或展开
/// 时有底色。
struct AgentProjectRankingRow: View {
    let project: AgentProjectSummary
    let windowDays: Int
    /// 榜首的消耗:占比条按它归一。
    let peakTotal: Int
    let isExpanded: Bool
    let isCompact: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                row
                    .padding(.horizontal, RowMetrics.rowInset(compact: isCompact))
                    .padding(.vertical, RowMetrics.rowVerticalPadding(compact: isCompact))
                    .background(
                        isHovering || isExpanded ? Color.primary.opacity(0.05) : Color.clear,
                        in: .rect(cornerRadius: 8)
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(
                "\(project.project),占 \(shareText),近 \(windowDays) 天 \(agentTokenText(project.total))"
            )
            .accessibilityHint(isExpanded ? "收起项目明细" : "展开项目明细")
            if isExpanded {
                // 明细缩进到名称的起点。
                AgentProjectDetail(project: project, windowDays: windowDays, isCompact: isCompact)
                    .padding(
                        .leading,
                        RowMetrics.rowInset(compact: isCompact) + RowMetrics.iconSize(compact: isCompact)
                            + RowMetrics.spacing(compact: isCompact)
                    )
                    .padding(.trailing, RowMetrics.rowInset(compact: isCompact))
                    .padding(.bottom, RowMetrics.rowVerticalPadding(compact: isCompact))
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        if isCompact {
            compactRow
        } else {
            regularRow
        }
    }

    /// 全尺寸一行。
    private var regularRow: some View {
        HStack(spacing: RowMetrics.spacing(compact: false)) {
            icon
            HStack(spacing: 4) {
                name
                liveChip
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AgentSegmentedBar(segments: barSegments)
                .frame(width: AgentProjectRankingMetrics.barWidth(compact: false))
            value(shareText, width: AgentProjectRankingMetrics.shareWidth(compact: false))
            value(
                agentTokenText(project.total),
                width: AgentProjectRankingMetrics.tokensWidth(compact: false)
            )
            AgentDeltaText(label: nil, delta: project.delta)
                .frame(width: AgentProjectRankingMetrics.deltaWidth, alignment: .trailing)
            chevron
        }
    }

    /// 紧凑档两行:上行 = 图标 + 名称 + 消耗 + 箭头,下行(缩进到名称起点)= 在跑芯片、
    /// 占比、环比。一行五列时名称只剩约 61pt,带芯片的名字整个被挤成「…」。
    private var compactRow: some View {
        let iconColumn = RowMetrics.iconSize(compact: true) + RowMetrics.spacing(compact: true)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: RowMetrics.spacing(compact: true)) {
                icon
                name
                    .frame(maxWidth: .infinity, alignment: .leading)
                value(
                    agentTokenText(project.total),
                    width: AgentProjectRankingMetrics.tokensWidth(compact: true)
                )
                chevron
            }
            HStack(spacing: 6) {
                liveChip
                subline("占 \(shareText)")
                AgentDeltaText(label: nil, delta: project.delta)
                Spacer(minLength: 0)
            }
            .padding(.leading, iconColumn)
            // 下行小字不伸到消耗列底下。
            .padding(
                .trailing,
                AgentProjectRankingMetrics.tokensWidth(compact: true) + RowMetrics.spacing(compact: true)
                    + AgentProjectRankingMetrics.trailingWidth(compact: true)
            )
        }
    }

    private var icon: some View {
        Image(systemName: "folder.fill")
            .font(.system(size: IconSize.leading(compact: isCompact), weight: .medium))
            .foregroundStyle(iconTint)
            .frame(width: RowMetrics.iconSize(compact: isCompact))
    }

    private var name: some View {
        Text(project.project)
            .font(.system(size: RowMetrics.nameFontSize(compact: isCompact), weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var liveChip: some View {
        if project.liveSessions > 0 {
            ChipView(
                text: "在跑 \(project.liveSessions)",
                tint: Surface.positive,
                profile: .inline,
                help: "会话快照里该项目正在运行的会话数"
            )
        }
    }

    private func subline(_ text: String) -> some View {
        Text(text)
            .font(.system(size: RowMetrics.subFontSize(compact: true)))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: IconSize.inline, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(
                width: AgentProjectRankingMetrics.trailingWidth(compact: isCompact),
                alignment: .trailing
            )
    }

    private func value(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: RowMetrics.valueFontSize(compact: isCompact), weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    private var shareText: String {
        "\(Int((project.share * 100).rounded()))%"
    }

    /// 占比条:长度 = 本项目 ÷ 榜首,两段按来源分——一眼看出主要来自哪家。
    private var barSegments: [(fraction: Double, tint: Color)] {
        let length = peakTotal > 0 ? Double(project.total) / Double(peakTotal) : 0
        return [
            (length * project.claudeShare, AgentPartitionTint.source(.claude)),
            (length * (1 - project.claudeShare), AgentPartitionTint.source(.zcode)),
        ]
    }

    /// 图标色:今天活跃或在跑 → 该项目的主来源色;否则取「停 / 未连接」的灰。
    private var iconTint: Color {
        guard project.liveSessions > 0 || project.idleDays == 0 else {
            return Surface.inactive
        }
        return AgentPartitionTint.source(project.claudeShare >= 0.5 ? .claude : .zcode)
    }
}

// MARK: - 明细

/// 展开的明细(卡内抬升底):五格读数 → 模型构成 → 来源构成 → 元信息。
/// 紧凑档把五格与图例折成多行,不靠截断。
struct AgentProjectDetail: View {
    let project: AgentProjectSummary
    let windowDays: Int
    let isCompact: Bool

    /// 构成行标签列宽 = `{layout.row-label-short}` 36(两汉字「模型 / 来源」)。
    private static let compositionLabelWidth: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            buckets
            if !project.models.isEmpty {
                compositionRow(
                    label: "模型",
                    entries: project.models.enumerated().map { index, model in
                        (
                            name: AgentUsageWindow.modelDisplayName(model.name),
                            share: model.share,
                            tint: AgentPartitionTint.model(at: index)
                        )
                    }
                )
            }
            compositionRow(
                label: "来源",
                entries: [
                    (name: "Claude", share: project.claudeShare, tint: AgentPartitionTint.source(.claude)),
                    (name: "ZCode", share: 1 - project.claudeShare, tint: AgentPartitionTint.source(.zcode)),
                ]
            )
            meta
        }
        .padding(isCompact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.cardHigh, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: 五格读数

    /// 全尺寸五格**两端对齐、等间距**(末格「Cache×」要靠右,不要排成等宽列);
    /// 紧凑档折成 3 + 2 两行。
    @ViewBuilder
    private var buckets: some View {
        let fontSize = RowMetrics.valueFontSize(compact: isCompact)
        if isCompact {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    bucket("Input", agentTokenText(project.inputTokens), fontSize: fontSize)
                    bucket("Output", agentTokenText(project.outputTokens), fontSize: fontSize)
                    bucket("Cache R", agentTokenText(project.cacheReadTokens), fontSize: fontSize)
                }
                GridRow {
                    bucket("Cache W", agentTokenText(project.cacheWriteTokens), fontSize: fontSize)
                    bucket("Cache×", cacheMultiplier, fontSize: fontSize)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                bucket("Input", agentTokenText(project.inputTokens), fontSize: fontSize)
                Spacer(minLength: 12)
                bucket("Output", agentTokenText(project.outputTokens), fontSize: fontSize)
                Spacer(minLength: 12)
                bucket("Cache R", agentTokenText(project.cacheReadTokens), fontSize: fontSize)
                Spacer(minLength: 12)
                bucket("Cache W", agentTokenText(project.cacheWriteTokens), fontSize: fontSize)
                Spacer(minLength: 12)
                bucket("Cache×", cacheMultiplier, fontSize: fontSize, alignment: .trailing)
            }
        }
    }

    private func bucket(
        _ label: String,
        _ value: String,
        fontSize: CGFloat,
        alignment: HorizontalAlignment = .leading
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: fontSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// 倍率 = 缓存读 ÷ 净(输入 + 输出),衡量缓存吃掉多少重复读取;分母 0 显示「—」。
    private var cacheMultiplier: String {
        project.cacheMultiplier.map { String(format: "%.1fx", $0) } ?? "—"
    }

    // MARK: 构成

    /// 一行构成:左标签列 + 右(分段条 → 色点图例)。份额为 0 的项不进图例。
    private func compositionRow(
        label: String,
        entries: [(name: String, share: Double, tint: Color)]
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: Self.compositionLabelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                AgentSegmentedBar(segments: entries.map { (fraction: $0.share, tint: $0.tint) })
                    .padding(.top, 5) // 条中线对齐标签 11pt 文字中线
                legend(entries)
            }
        }
    }

    @ViewBuilder
    private func legend(_ entries: [(name: String, share: Double, tint: Color)]) -> some View {
        let items = entries.filter { $0.share > 0 }.map { legendItem($0.name, $0.share, $0.tint) }
        if isCompact {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    item
                }
            }
        } else {
            HStack(spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    item
                }
            }
        }
    }

    private func legendItem(_ name: String, _ share: Double, _ tint: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(Int((share * 100).rounded()))%")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
    }

    // MARK: 元信息

    /// 活跃天数 · 现存会话数 · 请求数,符号引导;全尺寸右侧是日粒度活跃态,紧凑档折成 2×2。
    @ViewBuilder
    private var meta: some View {
        let items = [
            metaItem("calendar", "活跃 \(min(project.activeDays, windowDays))/\(windowDays) 天"),
            metaItem("bubble.left.and.bubble.right", "\(project.sessions) 个会话"),
            metaItem("arrow.up.arrow.down", "\(agentCountText(project.requests)) 次请求"),
        ]
        if isCompact {
            // 窄处一行放不下三项:折成 2×2,每格都放得下,不靠截断。
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    items[0]
                    items[1]
                }
                GridRow {
                    items[2]
                    idleText
                }
            }
        } else {
            HStack(spacing: 16) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    item
                }
                Spacer(minLength: 8)
                idleText
            }
        }
    }

    private func metaItem(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: IconSize.inline))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// 日粒度活跃态(今天 / 静了 N 天);在跑已在行内的芯片上。
    private var idleText: some View {
        Text(project.idleDays == 0 ? "今天活跃" : "静了 \(project.idleDays) 天")
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}

// MARK: - 分段条(SwiftUI 原语,agent-tab/05)

/// 占比分段条(高 6 圆角 3,轨道 = 三级墨 14%);段宽按 fraction、>0 才画,
/// 段间留 2pt 缝——相邻段同明度时靠这条缝分得开。
struct AgentSegmentedBar: View {
    let segments: [(fraction: Double, tint: Color)]

    var body: some View {
        GeometryReader { proxy in
            let visible = segments.filter { $0.fraction > 0 }
            let gaps = CGFloat(max(visible.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segment.tint)
                        // 微段保底 2pt 可见(与清理构成条 inuse 段同思路)。
                        .frame(width: max((proxy.size.width - gaps) * segment.fraction, 2))
                }
            }
        }
        .frame(height: 6)
        .background(Surface.inkTertiary.opacity(0.14), in: .rect(cornerRadius: 3))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

// MARK: - 截断末行

/// 项目展开 / 收起末行:排行截断末行(`RankingOverflowRow`)同款视觉配方
/// (11 medium secondary + chevron + 悬停 primary 5% 圆角 8),文案按项目口径
/// (「另 N 个项目」/「只看前 10 个」)。
struct AgentProjectOverflowRow: View {
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
        .help(isExpanded ? "收起,只看前 10 个项目" : "展开全部项目")
    }

    private var label: String {
        isExpanded ? "收起,只看前 10 个" : "显示全部(另 \(hiddenCount) 个项目)"
    }
}
