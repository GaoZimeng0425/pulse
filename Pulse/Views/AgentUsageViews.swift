import Charts
import PulseCore
import SwiftUI

// MARK: - 消耗子页(agent-tab/06,定稿骨架 wireframe-agents-page.html)

//
// 「每日消耗」外壳拆掉、四块平级成卡(用户拍板):数字卡排(四张一排,含
// Claude 用量)→ 日历图 + 走势一排两列(容器不够宽上下排)→ 项目宽卡
// (媒体查询列数)。range(7/30)子页内共享,数字卡排随档位联动;「重新扫描」
// 在日历图卡头(全量档手动触发,补漏天)。项目卡对齐 tokscale 参数:四桶 +
// 缓存倍率 + 会话数(Cost / 精确 Last Active 用户点名不做)。数据派生全走
// PulseCore `AgentUsageWindow`(纯值,UI 只描不算)。

/// 消耗子页(智能体页三子 tab 之一)。
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

    /// 日历图「年」占位单选项(时间筛选位置恒定;档位切换是未来功能)。
    enum HeatSpan: Hashable {
        case year
    }

    @State private var range: Range = .week

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
        .frame(maxHeight: .infinity, alignment: .top) // 同行四卡等高(2026-11-13 用户拍板)
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

    // MARK: 卡 2/3:日历图 + 走势(一排两列,不够宽上下排)

    /// 媒体查询语义:横排放得下(两卡理想宽合计 ≤ 容器)则并排,否则竖排;
    /// 并排时两卡等高(用户拍板 2026-11-13)——走势图高度弹性,吃掉行内多余。
    private var chartRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                heatCard
                    .frame(maxHeight: .infinity, alignment: .top)
                trendCard
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            VStack(alignment: .leading, spacing: 16) {
                heatCard
                trendCard
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
                HStack(spacing: 8) {
                    PillTabBar([HeatSpan.year], selection: .constant(HeatSpan.year)) { span in
                        PillTabItem(title: span == .year ? "年" : "", symbol: nil, tint: agentsAccent)
                    }
                    rescanButton
                }
            }
            AgentHeatWall(totals: totals)
            HStack {
                Text("Claude 与 ZCode 合计")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("最多一天 \(agentTokenText(totals.map(\.total).max() ?? 0))")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .cardShell(compact: isCompact)
    }

    /// 重新扫描按钮:扫描中转圈禁用(全量档后台跑,完成即刷新账本)。
    private var rescanButton: some View {
        Button {
            onRescan()
        } label: {
            if isScanning {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text("扫描中")
                }
            } else {
                Text("重新扫描")
            }
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .disabled(isScanning)
    }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "走势", tint: agentsAccent) {
                rangePills
            }
            AgentTrendChart(
                totals: AgentUsageWindow.dayTotals(rows: rows, days: range.days)
            )
        }
        .cardShell(compact: isCompact)
    }

    // MARK: 卡 4:项目(宽卡,媒体查询列数)

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
                // 响应式多列(2026-11-13 三度修正,用户拍板「同行等高 + 宽了出多列」):
                // 列数按容器实宽容纳的最多列(单卡保底 520、上限 3 列),逐行 HStack
                // 排布——行内卡 .frame(maxHeight:.infinity) 等高、末行不满自动满宽;
                // 不用 LazyVGrid(行内不拉齐高度)也不用 GridItem minimum(硬下限,
                // 窄容器溢出裁剪,前案实锤),容器多窄单列都 100% 宽。
                AgentProjectCardGrid(projects: projects, windowDays: range.days)
            }
        }
        .cardShell(compact: isCompact)
    }
}

// MARK: - 环比文字(数字卡副行与项目卡共用)

/// ▲ +12% / ▼ -8% / 持平 / —(无基准):▲ 绿 ▼ 红,零与无基准灰。
private struct AgentDeltaText: View {
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

// MARK: - 热力墙(自封装小组件,agent-tab/05)

/// 一年 52 列贡献图式格子墙(正方格边 14、间距 4、内容宽 932 超宽横向滚动、
/// 开卡锚到最右「今」)。四档色阶按窗口峰值归一(≤8% 灰档),底部每 8 周刻度
/// +「今」;坐标数学直译自定稿原型 drawHeat()。
struct AgentHeatWall: View {
    static let weeks = 52
    private static let side: CGFloat = 14
    private static let gap: CGFloat = 4

    /// 旧 → 新的逐天合计(weeks × 7 条;天数固定,缺天 0)。
    let totals: [AgentDayTotal]

    var body: some View {
        let step = Self.side + Self.gap
        let contentWidth = CGFloat(Self.weeks) * step - Self.gap
        ScrollView(.horizontal, showsIndicators: true) {
            Canvas { context, _ in
                draw(in: &context, step: step)
            }
            .frame(width: contentWidth, height: Self.axisHeight(step: step))
        }
        .defaultScrollAnchor(.trailing) // 开卡锚「今」(最新在右)
        .accessibilityHidden(true) // 数值由下方注记行承载
    }

    /// 图高 = 7 行格子 + 12 刻度行(原型 axisY = gridH + 12)。
    private static func axisHeight(step: CGFloat) -> CGFloat {
        7 * step - gap + 12 + 4
    }

    private func draw(in context: inout GraphicsContext, step: CGFloat) {
        let gridHeight = 7 * step - Self.gap
        let contentWidth = CGFloat(Self.weeks) * step - Self.gap

        // 图区底(灰 6%,圆角 8,原型同款)。
        context.fill(
            Path(roundedRect: CGRect(x: 0, y: 0, width: contentWidth, height: gridHeight), cornerRadius: 8),
            with: .color(Color.primary.opacity(0.06))
        )

        let cells = Self.weeks * 7
        let maxValue = totals.map(\.total).max() ?? 0
        for index in 0 ..< min(cells, totals.count) {
            let column = index / 7
            let row = index % 7
            let value = Double(totals[totals.count - cells + index].total)
            let rect = CGRect(
                x: CGFloat(column) * step,
                y: CGFloat(row) * step,
                width: Self.side,
                height: Self.side
            )
            // 四档:值/峰值 ×4 向上取整;≤8% 与零值归灰档。
            let normalized = maxValue > 0 ? value / Double(maxValue) : 0
            let level = normalized <= 0.08 ? 0 : min(4, Int(ceil(normalized * 4)))
            let color: Color = level == 0
                ? Surface.cardHigh
                : agentsAccent.opacity([0, 0.25, 0.5, 0.75, 1][level])
            context.fill(
                Path(roundedRect: rect, cornerRadius: 3),
                with: .color(color)
            )
        }

        // 底部周数刻度:每 8 周一标(51周/43周/…/3周)+ 最右「今」。
        let axisFont = Font.system(size: 10.5)
        for column in stride(from: 0, to: Self.weeks, by: 8) {
            let weeksAgo = Self.weeks - 1 - column
            let label = weeksAgo == 0 ? "今" : "\(weeksAgo)周"
            drawAxis(label, at: CGFloat(column) * step + Self.side / 2, in: &context, font: axisFont)
        }
        drawAxis(
            "今",
            at: CGFloat(Self.weeks - 1) * step + Self.side / 2,
            in: &context,
            font: axisFont
        )
    }

    private func drawAxis(_ label: String, at x: CGFloat, in context: inout GraphicsContext, font: Font) {
        let step = Self.side + Self.gap
        let y = 7 * step - Self.gap + 12
        context.draw(
            Text(label)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(.tertiary),
            at: CGPoint(x: x, y: y),
            anchor: .center
        )
    }
}

// MARK: - 走势(官方 Swift Charts,agent-tab/05 首次引入)

/// 近 N 天合计折线 + xy 坐标轴:y 三档(0/半值/峰值)网格线、x 每 3/6 天
/// (「今天」在右);域顶留 15% 头寸、线 2pt 圆头、末点圆点、缺天画 0、图区
/// 6% accent 底。缺天画 0 = 账本无行即当日无记录,不猜。
struct AgentTrendChart: View {
    let totals: [AgentDayTotal]

    private struct Point: Identifiable {
        let index: Int
        let value: Double
        var id: Int {
            index
        }
    }

    var body: some View {
        let points = totals.enumerated().map { Point(index: $0.offset, value: Double($0.element.total)) }
        let rawMax = max(points.map(\.value).max() ?? 0, 1)
        let domainMax = rawMax * 1.15 // 域顶头寸,峰不顶格(原型 ×1.15 同款)
        let stepDays = points.count <= 7 ? 3 : 6
        let xMarks = stride(from: points.count - 1, through: 0, by: -stepDays).map(Double.init)

        Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("天", Double(point.index)),
                    y: .value("Token", point.value)
                )
                .foregroundStyle(agentsAccent)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let last = points.last {
                PointMark(
                    x: .value("天", Double(last.index)),
                    y: .value("Token", last.value)
                )
                .foregroundStyle(agentsAccent)
                .symbolSize(30)
            }
        }
        .chartXScale(domain: -0.5 ... Double(max(points.count - 1, 1)) + 0.5)
        .chartYScale(domain: 0 ... domainMax)
        .chartYAxis {
            // y 三档:0 / 半值 / 峰值(峰值不顶格,域顶有头寸)。
            AxisMarks(values: [0.0, rawMax / 2, rawMax]) { value in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.08))
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(agentTokenText(Int(amount)))
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xMarks) { value in
                AxisValueLabel {
                    if let index = value.as(Double.self).map(Int.init) {
                        let ago = points.count - 1 - index
                        Text(ago == 0 ? "今天" : "\(ago) 天前")
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(agentsAccent.opacity(0.06), in: .rect(cornerRadius: 8))
        }
        .frame(minHeight: 96, maxHeight: .infinity) // 双列等高时吃满行内剩余
        .accessibilityHidden(true) // 数值由数字卡排承载
    }
}

// MARK: - 项目卡响应式网格(agent-tab/06 三度修正)

/// 项目大卡响应式网格:列数 = 容器实宽容纳的最多列(单卡保底 520,上限 3),
/// 逐行 HStack——**行内等高**、末行不满自动满宽;容器多窄都单列 100%(不走
/// GridItem minimum,规避 flexible 硬下限在窄容器溢出裁剪的前案)。
private struct AgentProjectCardGrid: View {
    /// 单卡保底宽(低于此宁可少一列——呼吸感是 06 追补的实报教训)。
    private static let minimumCardWidth: CGFloat = 520
    private static let spacing: CGFloat = 12
    private static let maximumColumns = 3

    let projects: [AgentProjectSummary]
    let windowDays: Int

    /// 初值 1:窄窗/弹窗首帧即正确,宽度变化后纠正。
    @State private var columnCount = 1

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row) { project in
                        AgentProjectCardView(project: project, windowDays: windowDays)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }
        }
        .onGeometryChange(for: Int.self) { proxy in
            let perColumn = Self.minimumCardWidth + Self.spacing
            return min(Self.maximumColumns, max(1, Int((proxy.size.width + Self.spacing) / perColumn)))
        } action: { newValue in
            if newValue != columnCount {
                columnCount = newValue
            }
        }
    }

    /// 按列数分行(不足列的末行自动满宽——HStack 内卡 maxWidth ∞)。
    private var rows: [[AgentProjectSummary]] {
        guard columnCount > 1 else { return projects.map { [$0] } }
        return stride(from: 0, to: projects.count, by: columnCount).map {
            Array(projects[$0 ..< min($0 + columnCount, projects.count)])
        }
    }
}

// MARK: - 项目大卡(agent-tab/06 加宽 + tokscale 参数对齐)

/// 项目一张宽卡(cardHigh 底、圆角 10、内距 12):头(名/占比)→ 主数值 +
/// 环比 → 四桶 + 缓存倍率行 → 模型分段条 + 色点图例 → harness 分段条 +
/// 底行(在跑/静了)→ 活跃行(活跃/会话数/请求数)。
struct AgentProjectCardView: View {
    let project: AgentProjectSummary
    let windowDays: Int

    var body: some View {
        // 呼吸感令牌档(2026-11-13 用户实报过密追补):内距 = {spacing.card-padding}
        // 16、层间距 = {spacing.group-gap} 12(两列 410 时代收编的 12/8 作废)。
        VStack(alignment: .leading, spacing: 12) {
            header
            valueRow
            Divider().padding(.horizontal, -16)
            bucketsRow
            if !project.models.isEmpty {
                Divider().padding(.horizontal, -16)
                modelBlock
            }
            Divider().padding(.horizontal, -16)
            harnessBlock
            Divider().padding(.horizontal, -16)
            activityRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.cardHigh, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    /// 层 1:项目名 + 占窗口份额。
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(project.project)
                .font(.system(size: 14.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("占 \(Int((project.share * 100).rounded()))%")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// 层 2:主数值(figure-card 24)+ 环比。
    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let figure = agentTokenFigure(project.total)
            FigureText(value: figure.value, unit: figure.unit, size: FigureSize.card)
            AgentDeltaText(label: nil, delta: project.delta)
        }
    }

    /// 层 3:四桶 + 缓存倍率一行(tokscale 对齐,agent-tab/06;账本五桶现成)。
    /// 倍率 = 缓存读 ÷ 净(输入+输出),衡量缓存吃掉多少重复读取。
    private var bucketsRow: some View {
        HStack(alignment: .top, spacing: 16) {
            bucket("Input", agentTokenText(project.inputTokens))
            bucket("Output", agentTokenText(project.outputTokens))
            bucket("Cache R", agentTokenText(project.cacheReadTokens))
            bucket("Cache W", agentTokenText(project.cacheWriteTokens))
            bucket("Cache×", project.cacheMultiplier.map { String(format: "%.1fx", $0) } ?? "—")
        }
    }

    private func bucket(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 层 4:模型分段条(top3 已并「其他」)+ 色点图例。
    private var modelBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentSegmentedBar(
                segments: project.models.enumerated().map { index, model in
                    (fraction: model.share, tint: AgentModelTint.tint(at: index))
                }
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 76), spacing: 12, alignment: .leading)],
                alignment: .leading,
                spacing: 4
            ) {
                ForEach(Array(project.models.enumerated()), id: \.offset) { index, model in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AgentModelTint.tint(at: index))
                            .frame(width: 6, height: 6)
                        Text(
                            "\(AgentUsageWindow.modelDisplayName(model.name)) \(Int((model.share * 100).rounded()))%"
                        )
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// 层 5:harness(= source)分段条 + 底行(claude/zcode 占比 · 在跑/静了)。
    private var harnessBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            AgentSegmentedBar(
                segments: [
                    (fraction: project.claudeShare, tint: AgentModelTint.harness(.claude)),
                    (fraction: 1 - project.claudeShare, tint: AgentModelTint.harness(.zcode)),
                ]
            )
            HStack {
                Text(
                    "claude \(Int((project.claudeShare * 100).rounded()))% · zcode \(Int(((1 - project.claudeShare) * 100).rounded()))%"
                )
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                liveState
            }
        }
    }

    /// 在跑(会话快照实时)> 今天活跃 > 静了 N 天(日粒度,派不出小时)。
    @ViewBuilder
    private var liveState: some View {
        if project.liveSessions > 0 {
            Text("● 在跑 \(project.liveSessions)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Surface.positive)
        } else if project.idleDays == 0 {
            Text("今天活跃")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        } else {
            Text("静了 \(project.idleDays) 天")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// 尾行:活跃天数 · 现存会话数 / 请求数。
    private var activityRow: some View {
        HStack {
            Text("活跃 \(project.activeDays)/\(windowDays) 天")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Text("· 会话 \(project.sessions)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text("\(agentCountText(project.requests)) 次")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 分段条(SwiftUI 原语,agent-tab/05)

/// 占比分段条(高 4 圆角 2,轨道 = 三级墨 14%);段宽按 fraction、>0 才画。
struct AgentSegmentedBar: View {
    let segments: [(fraction: Double, tint: Color)]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.fraction > 0 {
                        Rectangle()
                            .fill(segment.tint)
                            // 微段保底 2pt 可见(与清理构成条 inuse 段同思路)。
                            .frame(width: max(proxy.size.width * segment.fraction, 2))
                    }
                }
            }
        }
        .frame(height: 4)
        .background(Surface.inkTertiary.opacity(0.14), in: .rect(cornerRadius: 2))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .accessibilityHidden(true)
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
