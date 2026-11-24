import Charts
import PulseCore
import SwiftUI

// MARK: - 消耗子页(agent-tab/06)

//
// 子页骨架:四张卡平级、上下排,外面不套统一的大卡(还没有账本数据时整页换成一张
// 空态卡)——
// 1. 数字卡排:一张卡,内含四张等宽小卡(今日消耗 / N 天合计 / 日均 / Claude 用量);
// 2. 日历图(热力墙)与 3. 走势:内容宽够才并排两列,否则上下各一张;
// 4. 项目大卡网格(默认截断,末行展开 / 收起)。
// 数字与派生全在 PulseCore `AgentUsageWindow`(纯值),本文件只描不算。

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
    /// 「重新扫描」动作(日历图卡头按钮的唯一触发源)。
    var onRescan: () -> Void

    /// 项目默认展示上限(超出走末行展开 / 收起)。
    private static let projectLimit = 10

    /// 走势 / 项目的范围切换(数字卡排随档位联动)。
    enum Range: Hashable {
        case week
        case month

        var days: Int {
            self == .week ? 7 : 30
        }

        var title: String {
            self == .week ? "7 天" : "30 天"
        }

        /// 合计卡环比基准的称谓(7 天比上周、30 天比上月)。
        var previousLabel: String {
            self == .week ? "较上周" : "较上月"
        }
    }

    @State private var range: Range = .week
    /// 日历图粒度(天 / 周)。
    @State private var heatGranularity: AgentHeatGranularity = .day
    /// 项目超过上限时的展开态(切 7/30 保持;重进子页回默认收起)。
    @State private var projectsExpanded = false
    /// 日历图 + 走势列数(按子页内容宽 ≥ `chartTwoColumnMinWidth` 判定)。
    @State private var chartColumns = 1

    var body: some View {
        if rows.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 16) {
                numberCard
                chartRow
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

    // MARK: 卡 1:数字卡排(四张一排)

    private var numberCard: some View {
        let figures = AgentUsageWindow.figures(rows: rows, days: range.days)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "消耗总览", tint: agentsAccent) {
                EmptyView()
            }
            HStack(alignment: .top, spacing: 8) {
                numberCell(
                    label: "今日消耗",
                    tokens: figures.todayTotal,
                    valueTint: agentsAccent
                ) {
                    AgentDeltaText(label: "较昨日", delta: figures.todayDelta)
                }
                numberCell(
                    label: "\(figures.windowDays) 天合计",
                    tokens: figures.windowTotal
                ) {
                    AgentDeltaText(label: range.previousLabel, delta: figures.windowDelta)
                }
                numberCell(
                    label: "日均(\(figures.windowDays) 天)",
                    tokens: figures.windowAverage
                ) {
                    Text("峰 \(agentTokenText(figures.windowPeak))/天")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                usageCell
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 一张 lift 数字小卡:标签 → 大数字(figure-stat 28)→ 副行;等宽分布。
    private func numberCell(
        label: String,
        tokens: Int,
        valueTint: Color? = nil,
        @ViewBuilder sub: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            let figure = agentTokenFigure(tokens)
            FigureText(value: figure.value, unit: figure.unit, size: FigureSize.stat)
                .foregroundStyle(valueTint ?? Color.primary)
                .minimumScaleFactor(0.5) // 弹窗紧凑档四等分,超宽读数兜底
            sub()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        .frame(maxHeight: .infinity, alignment: .top) // 同行四卡等高
        .accessibilityElement(children: .combine)
    }

    /// 第 4 张 = Claude 用量(5 小时窗优先,缺失退本周;快照缺失「—」不伪造)。
    private var usageCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Claude 用量")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            if let window = usage?.fiveHour ?? usage?.sevenDay {
                FigureText(value: "\(window.usedPercentage)", unit: "%", size: FigureSize.stat)
                    .foregroundStyle(Color.primary)
                    .minimumScaleFactor(0.5)
                Text(usageSubline)
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            } else {
                FigureText(value: "—", unit: "", size: FigureSize.stat)
                    .foregroundStyle(Color.primary)
                Text("未读到快照")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .combine)
    }

    /// 用量副行:本周占用 + 窗口重置(读得到的才写)。
    private var usageSubline: String {
        var parts: [String] = []
        if let week = usage?.sevenDay {
            parts.append("本周 \(week.usedPercentage)%")
        }
        if let resetsIn = usage?.fiveHour?.resetsAt.map(\.timeIntervalSinceNow),
           resetsIn > 0 {
            parts.append("重置 \(PulseFormat.duration(seconds: resetsIn))后")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 卡 2/3:日历图 + 走势(≥1920 窗宽一排两列,否则一列)

    /// 日历图 + 走势并排的断点:量的是子页内容宽(窗宽减两侧窗口内距),不是窗宽。
    /// 不要改回 `ViewThatFits`——热力墙与 Charts 都是弹性宽、理想宽不可预期,按它
    /// 判定何时切换不可控。弹窗恒一列。
    static let chartTwoColumnMinWidth: CGFloat = 1872
    /// 弹窗紧凑档走势绘图区定高(热力墙在 330 宽下只有 ~45 高,不跟随)。
    private static let compactTrendPlotHeight: CGFloat = 100

    private var chartRow: some View {
        // 断点常量先取局部(非隔离 transform 闭包不得直引 actor 隔离 static)。
        let chartTwoColumnMinWidth = Self.chartTwoColumnMinWidth
        return Group {
            if chartColumns == 2 {
                // 并排时两卡靠**结构同构**等高(卡头 → 图区 → 日期轴带 → 页脚逐段同高),
                // 不靠 fixedSize / frame 拉伸。同构落在哪几处,见 `AgentChartAxis` 与
                // `AgentTrendChart`。
                HStack(alignment: .top, spacing: 16) {
                    heatCard
                    trendCard
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    heatCard
                    trendCard
                }
            }
        }
        .onGeometryChange(for: Int.self) { proxy in
            !isCompact && proxy.size.width >= chartTwoColumnMinWidth ? 2 : 1
        } action: { newValue in
            if newValue != chartColumns {
                chartColumns = newValue
            }
        }
    }

    /// 7/30 时间筛选药丸(走势与项目各一份,同一 state 视觉同步)。
    private var rangePills: some View {
        PillTabBar([Range.week, .month], selection: $range) { item in
            PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
        }
    }

    private var heatCard: some View {
        let totals = AgentUsageWindow.dayTotals(rows: rows, days: AgentHeatWall.weeks * 7)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "Token 消耗", tint: agentsAccent) {
                HStack(spacing: 12) {
                    rescanButton
                    PillTabBar([AgentHeatGranularity.day, .week], selection: $heatGranularity) { item in
                        PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
                    }
                }
            }
            AgentHeatWall(totals: totals, granularity: heatGranularity)
            chartFooter(leading: "Claude 与 ZCode 合计", trailing: heatPeakText(totals))
        }
        .cardShell(compact: isCompact)
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

    /// 两图卡共用页脚(micro tertiary,左说明右峰值;两卡同构等高的一部分)。
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

    /// 重新扫描:全量重扫 Claude 与 ZCode 的本地记录,补齐漏记的日子。按钮样式走
    /// DESIGN.md「卡头文字按钮」组件规范,这里只定本页的状态——扫描中换成转圈 +
    /// 「扫描中」并禁用,防重入。
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
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(isScanning)
        .help("全量重扫 Claude 与 ZCode 的本地记录,补齐漏记的日子")
    }

    private var trendCard: some View {
        let totals = AgentUsageWindow.dayTotals(rows: rows, days: range.days)
        let values = totals.map(\.total)
        let average = values.isEmpty ? 0 : values.reduce(0, +) / values.count
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "走势", tint: agentsAccent) {
                rangePills
            }
            AgentTrendChart(
                totals: totals,
                plotHeight: isCompact ? Self.compactTrendPlotHeight : nil
            )
            chartFooter(
                leading: "近 \(range.days) 天 · 日均 \(agentTokenText(average))",
                trailing: "最多一天 \(agentTokenText(values.max() ?? 0))"
            )
        }
        .cardShell(compact: isCompact)
    }

    // MARK: 卡 4:项目大卡网格

    private var projectCard: some View {
        let projects = AgentUsageWindow.projects(
            projectRows: projectRows,
            modelRows: modelRows,
            days: range.days,
            liveCounts: liveProjectCounts,
            sessionCounts: sessionCounts
        )
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "项目", tint: agentsAccent) {
                rangePills
            }
            if projects.isEmpty {
                CardEmptyState(title: "窗口内没有项目数据", detail: "只有粗粒度回填的日子没有项目维度")
            } else {
                // 列数、行内等高、末行满宽的规则都在 `AgentProjectCardGrid`。
                // 这里只管截断:默认前 `projectLimit` 张,超出走末行展开 / 收起
                // (排行截断同款交互)。
                AgentProjectCardGrid(
                    projects: projectsExpanded ? projects : Array(projects.prefix(Self.projectLimit)),
                    windowDays: range.days
                )
                if projects.count > Self.projectLimit {
                    AgentProjectOverflowRow(
                        isExpanded: projectsExpanded,
                        hiddenCount: projects.count - Self.projectLimit
                    ) {
                        projectsExpanded.toggle()
                    }
                }
            }
        }
        .cardShell(compact: isCompact)
    }
}

// MARK: - 环比文字(数字卡副行与项目卡共用)

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
    func row(_ day: String, source: AgentUsageSource, total: Int) -> AgentDailyUsageRow {
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
        rows.append(row(back(offset), source: .claude, total: total))
        rows.append(row(back(offset), source: .zcode, total: total / 3))
    }
    rows.append(row(back(0), source: .claude, total: 320_000_000))
    rows.append(row(back(0), source: .zcode, total: 64_000_000))

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
