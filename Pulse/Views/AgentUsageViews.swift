import PulseCore
import SwiftUI

// MARK: - 消耗子页(agent-tab/06)

//
// 页面规格。子页骨架:卡片平级、外面不套统一的大卡(还没有账本数据时整页换成一张
// 空态卡)——
// 1. 数字卡排(`AgentUsageStatCards`):今日消耗 / N 天合计 / 日均 / Claude 用量四张小卡;
//    主窗口一排四张,弹窗两列两行;
// 2. 走势 | 日历:子页内容宽 ≥ `{layout.agent-chart-two-column-min-width}` 1512(窗宽 1560)
//    时左右两列等高,否则上下一列(半宽的图太小);弹窗恒一列。走势卡头的
//    「7 天 | 30 天」是全页唯一的范围开关;日历卡头是「重新扫描」玻璃按钮 + 天 / 周;
// 3. 项目榜单:一行一个项目,点行看明细;默认前 10 个,末行展开 / 收起;跟着范围走。
// 卡间距:主窗口 16,弹窗 8(`{spacing.gap}`,与别的页一致)。范围(7 / 30 天)只有一个
// 状态,重进子页回默认(7 天、项目收起)。数字与派生全在 PulseCore `AgentUsageWindow`
// (纯值),本文件只描不算。

/// 消耗子页(骨架见文件头)。
struct AgentUsagePaneView: View {
    /// 账本全表(按天升序);空 = 还没扫过。
    let rows: [AgentDailyUsageRow]
    var projectRows: [AgentProjectUsageRow] = []
    var modelRows: [AgentModelUsageRow] = []
    /// 项目现存会话数(agent-tab/06,扫描现数)。
    var sessionCounts: [String: Int] = [:]
    /// Claude 用量快照(数字卡排第 4 张;两窗全缺如实「—」)。
    var usage: ClaudeUsageSnapshot?
    /// 会话快照的项目在跑数(组装时传入)。
    var liveProjectCounts: [String: Int] = [:]
    /// 弹窗紧凑档。
    var isCompact = false
    /// 全量扫描进行中(按钮转圈与禁用重入)。
    var isScanning = false
    /// 「重新扫描」动作(日历卡头按钮的唯一触发源)。
    var onRescan: () -> Void

    /// 走势与日历并排的断点(`{layout.agent-chart-two-column-min-width}`):量的是子页
    /// 内容宽,不是窗宽——1512 = 窗宽 1560 减两侧 `{spacing.window-padding}` 24。
    /// 不足就上下排,两张图各占整行。
    static let chartTwoColumnMinWidth: CGFloat = 1512
    /// 走势整体高(含日期轴带):主窗口同大卡正文高,弹窗同旧走势卡的紧凑档。
    private static let trendHeight: CGFloat = 184
    private static let compactTrendHeight: CGFloat = 100
    /// 并排时走势高的下限:走势跟日历同高(两卡同构、不留空),但日历在半宽下很矮,
    /// 走势不低于这个高度;多出来的高度让日历在卡里上下居中。
    private static let pairedTrendMinHeight: CGFloat = 140

    /// 范围:数字卡、走势、项目榜单共用。
    @State private var range: AgentUsageRange = .week
    /// 日历图粒度(天 / 周)。
    @State private var heatGranularity: AgentHeatGranularity = .day
    /// 榜单里展开着明细的项目(切 7/30 保持;重进子页回默认全部收起)。
    @State private var expandedProjects: Set<String> = []
    /// 项目超过上限时是否列出全部(切 7/30 保持;重进子页回默认收起)。
    @State private var projectsExpanded = false
    /// 走势 | 日历的列数(按内容宽 ≥ 断点判定;弹窗恒 1)。
    @State private var chartColumns = 1
    /// 走势 | 日历这一行的内容宽(并排时据此算日历高,走势跟它同高)。
    @State private var chartRowWidth: CGFloat = 0

    private var cardSpacing: CGFloat {
        isCompact ? 8 : 16
    }

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: cardSpacing) {
                AgentUsageStatCards(
                    figures: AgentUsageWindow.figures(rows: rows, days: range.days),
                    usage: usage,
                    range: range,
                    isCompact: isCompact
                )
                // 图表浮层可能伸出卡外(日历在半宽下比浮层还矮):图表行压在后面的榜单之上,
                // 浮层才盖得住后面的内容(材质底才模糊得到它们),而不是被它们压住。
                chartRow
                    .zIndex(1)
                projectCard
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isScanning {
            CardEmptyState(
                title: "正在扫描本地记录",
                detail: "正在从 Claude 与 ZCode 的会话记录回填每日消耗"
            )
            .cardShell(compact: isCompact)
        } else {
            CardEmptyState(
                title: "还没有每日数据",
                detail: "点「重新扫描」,从 Claude 与 ZCode 的本地记录回填历史"
            )
            .cardShell(compact: isCompact)
        }
    }

    // MARK: 卡 2 / 3:走势 | 日历

    private var chartRow: some View {
        // 断点先取局部(非隔离的几何闭包不得直引 actor 隔离的 static)。
        let minWidth = Self.chartTwoColumnMinWidth
        let compact = isCompact
        return Group {
            if chartColumns == 2 {
                // 等高靠 `EqualHeightRow`(行高 = 两卡自然高的较大者,卡底铺到行底);
                // 只在并排时让卡撑高——弹窗量高是「高度无上限」,弹性高会被量成天文数字。
                EqualHeightRow(spacing: cardSpacing) {
                    trendCard(fillsHeight: true)
                    calendarCard(fillsHeight: true)
                }
            } else {
                VStack(alignment: .leading, spacing: cardSpacing) {
                    trendCard(fillsHeight: false)
                        .zIndex(1)
                    calendarCard(fillsHeight: false)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let columns = !compact && width >= minWidth ? 2 : 1
            if columns != chartColumns {
                chartColumns = columns
            }
            if abs(width - chartRowWidth) > 0.5 {
                chartRowWidth = width
            }
        }
    }

    /// 走势整体高:弹窗 / 上下排取定高;并排时取日历在半宽下的高(格墙 + 月份轴带),
    /// 不低于下限。
    private var trendHeightForLayout: CGFloat {
        if isCompact {
            return Self.compactTrendHeight
        }
        guard chartColumns == 2 else {
            return Self.trendHeight
        }
        let padding = CardMetrics.padding(compact: false)
        let wallWidth = (chartRowWidth - cardSpacing) / 2 - padding * 2
        let calendarHeight = AgentHeatWall.gridHeight(forWidth: wallWidth) + AgentChartAxis.height
        return max(calendarHeight, Self.pairedTrendMinHeight)
    }

    /// 走势卡:卡头(标题 + 全页唯一的范围开关)→ 按来源分层的走势 → 图例。
    private func trendCard(fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "走势 · 近 \(range.days) 天", tint: agentsAccent) {
                PillTabBar([AgentUsageRange.week, .month], selection: $range, isGlassContainer: true) { item in
                    PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
                }
            }
            AgentTrendChart(
                totals: AgentUsageWindow.dayTotals(rows: rows, days: range.days),
                height: trendHeightForLayout,
                showsPeakLabels: !isCompact
            )
            .accessibilityHidden(true)
            .frame(maxHeight: fillsHeight ? .infinity : nil)
            .zIndex(1)
            HStack(spacing: 12) {
                ForEach([("Claude", AgentUsageSource.claude), ("ZCode", .zcode)], id: \.0) { name, source in
                    HStack(spacing: 4) {
                        AgentLegendSwatch(tint: AgentPartitionTint.source(source))
                        Text(name)
                    }
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
        }
        .chartCardShell(compact: isCompact, fillsHeight: fillsHeight)
    }

    /// 日历卡:卡头(标题 + 重新扫描 + 天 / 周)→ 一年热力墙 → 页脚。
    private func calendarCard(fillsHeight: Bool) -> some View {
        let totals = AgentUsageWindow.dayTotals(rows: rows, days: AgentHeatWall.weeks * 7)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "日历", tint: agentsAccent) {
                HStack(spacing: 8) {
                    rescanButton
                    PillTabBar(
                        [AgentHeatGranularity.day, .week], selection: $heatGranularity, isGlassContainer: true
                    ) { item in
                        PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
                    }
                }
            }
            // 并排时卡高跟着走势;日历比它矮的部分上下均分,不挤在卡头下面。
            AgentHeatWall(totals: totals, granularity: heatGranularity)
                .frame(maxHeight: fillsHeight ? .infinity : nil)
                .zIndex(1)
            chartFooter(leading: "Claude 与 ZCode 合计", trailing: heatPeakText(totals))
        }
        .chartCardShell(compact: isCompact, fillsHeight: fillsHeight)
    }

    /// 日历图页脚峰值:按天「最多一天」/ 按周「最多一周」。
    private func heatPeakText(_ totals: [AgentDayTotal]) -> String {
        switch heatGranularity {
        case .day:
            "最多一天 \(agentTokenText(totals.map(\.total).max() ?? 0))"
        case .week:
            "最多一周 \(agentTokenText(AgentHeatScale.weeks(totals).map(\.total).max() ?? 0))"
        }
    }

    /// 页脚(micro tertiary,左说明右峰值)。
    private func chartFooter(leading: String, trailing: String) -> some View {
        HStack {
            Text(leading)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Text(trailing)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// 重新扫描:全量重扫 Claude 与 ZCode 的本地记录,补齐漏记的日子。样式走 DESIGN.md
    /// 「卡头玻璃按钮」(`HeaderGlassButtonStyle`);这里只定本页的状态——扫描中换成
    /// 转圈 + 「扫描中」并禁用,防重入。
    private var rescanButton: some View {
        Button {
            onRescan()
        } label: {
            HStack(spacing: 4) {
                if isScanning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: IconSize.inline, weight: .semibold))
                }
                Text(isScanning ? "扫描中" : "重新扫描")
            }
        }
        .buttonStyle(HeaderGlassButtonStyle())
        .disabled(isScanning)
        .help("全量重扫 Claude 与 ZCode 的本地记录,补齐漏记的日子")
    }

    // MARK: 卡 3:项目榜单

    private var projectCard: some View {
        // 范围开关在走势卡头;榜单标题写明当前窗口,读数跟着同一个范围走。
        // 截断、展开明细与卡内空态都在榜单卡里。
        AgentProjectRankingCard(
            projects: AgentUsageWindow.projects(
                projectRows: projectRows,
                modelRows: modelRows,
                days: range.days,
                liveCounts: liveProjectCounts,
                sessionCounts: sessionCounts
            ),
            windowDays: range.days,
            isCompact: isCompact,
            expandedProjects: $expandedProjects,
            showsAll: $projectsExpanded
        )
    }
}

// MARK: - 环比文字(数字卡与项目榜单共用)

/// ▲ +12% / ▼ -8% / 持平 / —(无基准):▲ 绿 ▼ 红,零与无基准灰。
struct AgentDeltaText: View {
    var label: String?
    let delta: Double?

    var body: some View {
        let text: String
        let style: AnyShapeStyle
        if let delta {
            let percent = Int((abs(delta) * 100).rounded())
            if delta > 0 {
                text = arrowLabel("▲", "+\(percent)%")
                style = AnyShapeStyle(Surface.positive)
            } else if delta < 0 {
                text = arrowLabel("▼", "-\(percent)%")
                style = AnyShapeStyle(Surface.negative)
            } else {
                text = "\(label.map { "\($0) " } ?? "")持平"
                style = AnyShapeStyle(.tertiary)
            }
        } else {
            // 前窗无基准:如实「—」,不出 0% 假读数。
            text = "\(label.map { "\($0) " } ?? "")—"
            style = AnyShapeStyle(.tertiary)
        }
        return Text(text)
            .font(.system(size: 10.5))
            .monospacedDigit()
            .foregroundStyle(style)
    }

    private func arrowLabel(_ arrow: String, _ value: String) -> String {
        if let label {
            "\(arrow) \(label) \(value)"
        } else {
            "\(arrow) \(value)"
        }
    }
}

#Preview("消耗子页") {
    func row(_ day: String, _ source: AgentUsageSource, _ total: Int) -> AgentDailyUsageRow {
        AgentDailyUsageRow(day: day, source: source, origin: .jsonl, totalTokens: total)
    }

    let calendar = Calendar.current
    let now = Date()
    func back(_ days: Int) -> String {
        let date = calendar.date(byAdding: .day, value: -days, to: now)!
        return String(
            format: "%04d-%02d-%02d",
            calendar.component(.year, from: date),
            calendar.component(.month, from: date),
            calendar.component(.day, from: date)
        )
    }

    var rows: [AgentDailyUsageRow] = []
    for offset in 0 ..< 364 {
        let base = Double(364 - offset) / 364
        let wave = 0.4 + 0.6 * abs(sin(Double(offset) / 5))
        let total = Int(base * wave * 800_000_000)
        rows.append(row(back(offset), .claude, total))
        rows.append(row(back(offset), .zcode, total / 3))
    }
    rows.append(row(back(0), .claude, 320_000_000))
    rows.append(row(back(0), .zcode, 64_000_000))

    var projectRows: [AgentProjectUsageRow] = []
    var modelRows: [AgentModelUsageRow] = []
    let projects: [(String, Int, [String: Int])] = [
        ("pulse", 600, ["claude-opus-5-5": 6, "GLM-5.3": 3, "claude-sonnet-5": 1]),
        ("octok-client", 200, ["claude-opus-5-5": 7, "GLM-5.3": 3]),
        ("NemoNotch", 90, ["claude-sonnet-5": 9]),
        ("sage", 30, ["GLM-5.3": 10]),
    ]
    for (name, weight, models) in projects {
        for offset in 0 ..< 30 where offset % (name == "sage" ? 4 : 2) == 0 {
            let total = weight * 1_000_000 * (offset < 7 ? 1 : 2)
            projectRows.append(
                AgentProjectUsageRow(
                    day: back(offset), source: .claude, project: name,
                    inputTokens: total / 5, outputTokens: total / 10,
                    cacheReadTokens: total / 2, cacheWriteTokens: total / 20,
                    totalTokens: total / 2, requestCount: 40
                )
            )
            projectRows.append(
                AgentProjectUsageRow(
                    day: back(offset), source: .zcode, project: name,
                    inputTokens: total / 10, outputTokens: total / 20,
                    totalTokens: total / 2, requestCount: 20
                )
            )
            for (model, share) in models {
                modelRows.append(
                    AgentModelUsageRow(
                        day: back(offset), source: .claude, project: name, model: model,
                        totalTokens: total / 2 * share / 10
                    )
                )
            }
        }
    }

    return AgentUsagePaneView(
        rows: rows,
        projectRows: projectRows,
        modelRows: modelRows,
        sessionCounts: ["pulse": 291, "octok-client": 142],
        usage: ClaudeUsageSnapshot(
            fiveHour: .init(usedPercentage: 17, resetsAt: now.addingTimeInterval(3600)),
            sevenDay: .init(usedPercentage: 42, resetsAt: nil)
        ),
        liveProjectCounts: ["pulse": 2],
        isScanning: false,
        onRescan: {}
    )
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}

// MARK: - 图表卡外壳

private extension View {
    /// 走势 / 日历卡的外壳:同 `cardShell`,并排时多一层弹性高(在底色里面),让
    /// `EqualHeightRow` 提进来的行高铺满矮卡的底色。上下排时不撑高(弹窗量高无上限)。
    func chartCardShell(compact: Bool, fillsHeight: Bool) -> some View {
        padding(CardMetrics.padding(compact: compact))
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
            .background(Surface.card, in: .rect(cornerRadius: CardMetrics.cornerRadius(compact: compact)))
    }
}
