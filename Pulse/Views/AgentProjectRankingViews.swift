import AppKit
import PulseCore
import SwiftUI

// MARK: - 项目榜单(agent-usage-redesign/03)

//
// 项目区是一张排行卡:卡内标题 → 表头 → 每个项目一行 → 截断末行。行建在「排行列表」
// 标准件之上(行尺寸走 RowMetrics 两档、行尾留展开箭头一列、悬停底色、卡内空态、
// 截断末行);与通用排行行只差两处——占比条是分段的(两段 = 两家来源),数值有三列
// (占比 / 消耗 / 环比)。紧凑档的行是两行(上行名称 + 消耗,下行小字:在跑 / 占比 /
// 环比),给名称留出宽度。点一行原地展开:展开后行与明细是同一张卡(一块抬升底,
// 行是卡头、明细在卡里),把后面的行推下去;收起只剩那一行。
// 排序、占比、环比、五桶、模型与来源份额全在 PulseCore `AgentUsageWindow.projects`。

/// 榜单的列宽(页面专属参数;行尺寸的共享值一律委托 `RowMetrics` / `RankingListMetrics`)。
enum AgentProjectRankingMetrics {
    /// 占比列:整数百分比,取 `{layout.row-value-percent}`(令牌按 12pt 量,随行档放大)。
    /// 只有全尺寸行有这一列——紧凑档的占比在副文行里,不定宽。
    static let shareWidth = CardRowWidth.scaled(
        CardRowWidth.percentValue, fontSize: RowMetrics.valueFontSize(compact: false)
    )

    /// 占比条宽,同 meter 条;只有全尺寸行画条。
    static let barWidth = RowMetrics.meterWidth(compact: false)

    /// 行尾的展开箭头列,同所有排行。
    static func trailingWidth(compact: Bool) -> CGFloat {
        RankingListMetrics.trailingWidth(compact: compact)
    }

    /// 消耗列:按该列最宽的现实读数以实际绘制字体量宽 + 2。
    static func tokensWidth(compact: Bool) -> CGFloat {
        compact ? compactTokensWidth : regularTokensWidth
    }

    /// 环比列(▲ +N% / ▼ -N% / 持平):两档同为 10.5 常规;只有全尺寸行有这一列。
    /// 量到三位数为止——涨跌没有上限,过千的读数缩字号放进这一列,不撑列、不折行。
    static let deltaWidth = measuredReadingsWidth(
        ["▲ +999%", "▼ -999%", "持平"], fontSize: 10.5, weight: .regular
    )

    private static let regularTokensWidth = measuredReadingsWidth(
        ["999.9B", "999.9M", "999k", "999"], fontSize: RowMetrics.valueFontSize(compact: false), weight: .semibold
    )
    private static let compactTokensWidth = measuredReadingsWidth(
        ["999.9B", "999.9M", "999k", "999"], fontSize: RowMetrics.valueFontSize(compact: true), weight: .semibold
    )
}

/// 份额 → 整数百分比文字(0…1 → "42%")。
private func percentText(_ fraction: Double) -> String {
    "\(Int((fraction * 100).rounded()))%"
}

/// 项目榜单卡:卡头 = 标题(带当前窗口天数)+ 本卡自己的「7 天 | 30 天」;默认列前
/// N 个,末行展开 / 收起;点行看明细。
struct AgentProjectRankingCard: View {
    /// 窗口内全部项目(已按消耗降序;由子页按 `range` 算好传入)。
    let projects: [AgentProjectSummary]
    /// 榜单自己的范围(与走势卡头的范围互相独立;状态由子页持有)。
    @Binding var range: AgentUsageRange
    let isCompact: Bool
    /// 展开明细的项目(按项目名);由子页持有,切范围保持。
    @Binding var expandedProjects: Set<String>
    /// 超过上限后是否列出全部。
    @Binding var showsAll: Bool

    /// 默认展示上限(DESIGN.md `{layout.agent-project-limit}`)。
    private static let limit = 10

    private var windowDays: Int {
        range.days
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(
                symbolName: nil, title: "项目 · 近 \(windowDays) 天", tint: agentsAccent
            ) {
                PillTabBar(
                    [AgentUsageRange.week, .month], selection: $range,
                    isGlassContainer: true, size: isCompact ? .compact : .regular
                ) { item in
                    PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
                }
            }
            if projects.isEmpty {
                CardEmptyState(title: "窗口内没有项目数据", detail: "只有粗粒度回填的日子没有项目维度")
            } else {
                columnHeader
                // 行距 2,同所有排行卡。行容器用普通堆叠、不用惰性的:弹窗把整页按内容
                // 量高(高无上限),惰性容器在这种量法下报不准——实测展开一行明细时
                // 报 1545、实排 759,弹窗底部会空出一大截;本榜默认 10 行,也不需要惰性。
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
                        RankingOverflowRow(model: overflowModel, isCompact: isCompact)
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 截断末行的数据面:上限是本榜的 10(不是通用排行的 20),量词按项目口径。
    private var overflowModel: RankingOverflowRowModel {
        RankingOverflowRowModel(
            hiddenCount: showsAll ? 0 : projects.count - Self.limit,
            action: .expand(isExpanded: showsAll) { showsAll.toggle() },
            limit: Self.limit,
            noun: "个项目",
            rankNoun: "个"
        )
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

    /// 表头逐列命名,列宽与行逐列相同;首列留出行首图标的宽和图标到名称的间距,
    /// 「项目」与各行的名称起点对齐。紧凑档的行是两行,占比与环比在第二行的小字里
    /// 自带口径,表头只剩「项目 | 消耗」。
    private var columnHeader: some View {
        HStack(spacing: RowMetrics.spacing(compact: isCompact)) {
            HStack(spacing: RowMetrics.spacing(compact: isCompact)) {
                placeholder(width: RowMetrics.iconSize(compact: isCompact))
                Text("项目")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isCompact {
                placeholder(width: AgentProjectRankingMetrics.barWidth)
            }
            if !isCompact {
                Text("占比").frame(
                    width: AgentProjectRankingMetrics.shareWidth, alignment: .trailing
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
/// + 箭头;紧凑档两行:上行名称 + 消耗,下行在跑 / 占比 / 环比。整行可点:收起时悬停
/// 有底色;展开后行与明细合成一张卡(`Surface.cardHigh`、`{rounded.inner}` 10)。
struct AgentProjectRankingRow: View {
    let project: AgentProjectSummary
    let windowDays: Int
    /// 榜首的消耗:占比条按它归一。
    let peakTotal: Int
    let isExpanded: Bool
    let isCompact: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    /// 展开卡的圆角(`{rounded.inner}`)与收起行悬停底的圆角(同所有排行行)。
    private static let expandedRadius: CGFloat = 10
    private static let hoverRadius: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                row
                    .padding(.horizontal, RowMetrics.rowInset(compact: isCompact))
                    .padding(.vertical, RowMetrics.rowVerticalPadding(compact: isCompact))
                    .background(
                        isHovering && !isExpanded ? Color.primary.opacity(0.05) : Color.clear,
                        in: .rect(cornerRadius: Self.hoverRadius)
                    )
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(
                "\(project.project),占 \(percentText(project.share)),近 \(windowDays) 天 \(agentTokenText(project.total))"
            )
            .accessibilityHint(isExpanded ? "收起项目明细" : "展开项目明细")
            if isExpanded {
                // 明细与行同在一张卡里:左缘对齐名称起点,右缘对齐行尾,底边留卡内距。
                AgentProjectDetail(project: project, windowDays: windowDays, isCompact: isCompact)
                    .padding(
                        .leading,
                        RowMetrics.rowInset(compact: isCompact) + RowMetrics.iconSize(compact: isCompact)
                            + RowMetrics.spacing(compact: isCompact)
                    )
                    .padding(.trailing, RowMetrics.rowInset(compact: isCompact))
                    .padding(.top, 4)
                    .padding(.bottom, CardMetrics.padding(compact: isCompact))
            }
        }
        .background(
            isExpanded ? Surface.cardHigh : Color.clear,
            in: .rect(cornerRadius: Self.expandedRadius)
        )
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
                .frame(width: AgentProjectRankingMetrics.barWidth)
            value(percentText(project.share), width: AgentProjectRankingMetrics.shareWidth)
            value(
                agentTokenText(project.total),
                width: AgentProjectRankingMetrics.tokensWidth(compact: false)
            )
            delta.frame(width: AgentProjectRankingMetrics.deltaWidth, alignment: .trailing)
            chevron
        }
    }

    /// 环比读数。全尺寸行里定宽:过千的涨跌缩字号放进列里(同排行数值列),不折行。
    private var delta: some View {
        AgentDeltaText(label: nil, delta: project.delta)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
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
                subline("占 \(percentText(project.share))")
                delta
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

    /// 名称吃剩余宽度、尾部省略(开头是项目名,最该留;同通用排行行)。
    private var name: some View {
        Text(project.project)
            .font(.system(size: RowMetrics.nameFontSize(compact: isCompact), weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
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

/// 展开的明细:五格读数 → 模型构成 → 来源构成 → 元信息。自己不带底——底色与圆角在
/// 行上(行与明细是同一张卡)。紧凑档把五格与图例折成多行,不靠截断。
struct AgentProjectDetail: View {
    let project: AgentProjectSummary
    let windowDays: Int
    let isCompact: Bool

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
        .frame(maxWidth: .infinity, alignment: .leading)
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
                // 标签列定宽取 `{layout.row-label-short}`(两汉字「模型 / 来源」)。
                .frame(width: CardRowWidth.shortLabel, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                AgentSegmentedBar(segments: entries.map { (fraction: $0.share, tint: $0.tint) })
                    // 条顶留一格 `{spacing.unit}`,条中线贴标签 11pt 文字的中线。
                    .padding(.top, 4)
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
            AgentLegendSwatch(tint: tint)
            Text(name)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(percentText(share))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 10.5))
    }

    // MARK: 元信息

    /// 活跃天数 · 现存会话数 · 请求数,符号引导;全尺寸右侧是日粒度活跃态,紧凑档折成 2×2。
    @ViewBuilder
    private var meta: some View {
        if isCompact {
            // 窄处一行放不下三项:折成 2×2,每格都放得下,不靠截断。
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    activeDaysItem
                    sessionsItem
                }
                GridRow {
                    requestsItem
                    idleText
                }
            }
        } else {
            HStack(spacing: 16) {
                activeDaysItem
                sessionsItem
                requestsItem
                Spacer(minLength: 8)
                idleText
            }
        }
    }

    private var activeDaysItem: some View {
        metaItem("calendar", "活跃 \(min(project.activeDays, windowDays))/\(windowDays) 天")
    }

    private var sessionsItem: some View {
        metaItem("bubble.left.and.bubble.right", "\(project.sessions) 个会话")
    }

    private var requestsItem: some View {
        metaItem("arrow.up.arrow.down", "\(agentCountText(project.requests)) 次请求")
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
