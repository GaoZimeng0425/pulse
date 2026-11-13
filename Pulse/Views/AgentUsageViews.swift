import Charts
import PulseCore
import SwiftUI

// MARK: - 每日消耗卡(agent-tab/02;05 按定稿原型整体重排)

//
// 定稿原型 `.scratch/agent-tab/prototype-daily-usage.html`(唯一视觉真相,JS
// 坐标数学直译):卡头无徽章(用户拍板:只留标题 + 右「重新扫描」)→ 数字卡排
// (三张同规格 lift 小卡,figure-stat 28)→「Token 消耗」热力墙(52 列一年,
// 正方格边 14 间距 4,超宽横向滚动)→「走势」(官方 Swift Charts,本 app 首次
// 引入:单图低频重绘,不是 StripChartView 避开的高频多卡场景)→「项目」大卡
// (自适应网格 min 240 / max 340,模型 / harness 分段条分区异色)。
// 数据派生全部走 PulseCore `AgentUsageWindow`(纯值,UI 只描不算);数字 /
// 环比 / 活跃天数 / 请求数 / 在跑数都由现有账本与会话快照派生,零新增采集。

/// 每日消耗卡。
struct AgentUsageCardView: View {
    /// 账本全表(按天升序);空 = 还没扫过。
    let rows: [AgentDailyUsageRow]
    /// 项目轨全表(agent-tab/04);窗口内聚合出项目大卡。
    var projectRows: [AgentProjectUsageRow] = []
    /// 模型轨全表(agent-tab/05);项目大卡模型分段条。
    var modelRows: [AgentModelUsageRow] = []
    /// 会话快照的项目在跑数(项目名 → N;MetricTabStack 组装时传入)。
    var liveProjectCounts: [String: Int] = [:]
    /// 弹窗紧凑档。
    var isCompact = false
    /// 全量扫描进行中(按钮转圈与禁用重入)。
    var isScanning = false
    /// 「重新扫描」动作(UI 按钮的唯一触发源)。
    var onRescan: () -> Void

    /// 折线 / 项目的范围切换(数字卡排随档位联动)。
    private enum Range: Hashable {
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

    /// 热力墙「年」占位单选项(时间筛选位置恒定;档位切换是未来功能)。
    private enum HeatSpan: Hashable {
        case year
    }

    @State private var range: Range = .week

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbolName: nil, title: "每日消耗", tint: agentsAccent) {
                rescanButton
            }
            if rows.isEmpty {
                emptyState
            } else {
                numberRow
                heatSection
                trendSection
                projectSection
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

    @ViewBuilder
    private var emptyState: some View {
        if isScanning {
            CardEmptyState(
                title: "正在扫描本地记录",
                detail: "正在从 Claude 与 ZCode 的会话记录回填每日消耗"
            )
        } else {
            CardEmptyState(
                title: "还没有每日数据",
                detail: "点「重新扫描」,从 Claude 与 ZCode 的本地记录回填历史"
            )
        }
    }

    // MARK: 数字卡排(三卡同规格,随档位联动)

    private var numberRow: some View {
        let figures = AgentUsageWindow.figures(rows: rows, days: range.days)
        return HStack(spacing: 8) {
            numberCard(
                label: "今日消耗",
                tokens: figures.todayTotal,
                valueTint: agentsAccent
            ) {
                AgentDeltaText(label: "较昨日", delta: figures.todayDelta)
            }
            numberCard(
                label: "\(figures.windowDays) 天合计",
                tokens: figures.windowTotal
            ) {
                AgentDeltaText(label: range.previousLabel, delta: figures.windowDelta)
            }
            numberCard(
                label: "日均(\(figures.windowDays) 天)",
                tokens: figures.windowAverage
            ) {
                Text("峰 \(agentTokenText(figures.windowPeak))/天")
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 一张 lift 数字小卡:标签 → 大数字(figure-stat 28)→ 副行;等宽分布。
    private func numberCard(
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
                .minimumScaleFactor(0.5) // 弹窗 312 档三等分 ≈ 91pt,超宽读数兜底
            sub()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    // MARK: 图表区统一外包装(lift + 标题行 + 图表)

    /// 7/30 时间筛选药丸(走势与项目各一份,同一 state 视觉同步)。
    private var rangePills: some View {
        PillTabBar([Range.week, .month], selection: $range) { item in
            PillTabItem(title: item.title, symbol: nil, tint: agentsAccent)
        }
    }

    private func chartSection(
        title: String,
        @ViewBuilder pills: () -> some View,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                pills()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.cardHigh, in: .rect(cornerRadius: 12))
    }

    // MARK: Token 消耗(热力墙)

    private var heatSection: some View {
        chartSection(title: "Token 消耗") {
            PillTabBar([HeatSpan.year], selection: .constant(HeatSpan.year)) { span in
                PillTabItem(title: span == .year ? "年" : "", symbol: nil, tint: agentsAccent)
            }
        } content: {
            let totals = AgentUsageWindow.dayTotals(rows: rows, days: AgentHeatWall.weeks * 7)
            VStack(alignment: .leading, spacing: 8) {
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
        }
    }

    // MARK: 走势(Swift Charts)

    private var trendSection: some View {
        chartSection(title: "走势", pills: { rangePills }) {
            AgentTrendChart(
                totals: AgentUsageWindow.dayTotals(rows: rows, days: range.days)
            )
        }
    }

    // MARK: 项目(大卡网格)

    /// 窗口内有项目数据才出节(只有 cache 回填日子的窗口整节不画,04 票先例)。
    @ViewBuilder
    private var projectSection: some View {
        let projects = AgentUsageWindow.projects(
            projectRows: projectRows,
            modelRows: modelRows,
            days: range.days,
            liveCounts: liveProjectCounts
        )
        if !projects.isEmpty {
            chartSection(title: "项目", pills: { rangePills }) {
                AdaptiveCardGrid(
                    minimumCardWidth: 240,
                    spacing: 12,
                    maximumColumns: 4,
                    maximumCardWidth: 340
                ) {
                    ForEach(projects) { project in
                        AgentProjectCardView(project: project, windowDays: range.days)
                    }
                }
            }
        }
    }
}

// MARK: - 环比文字(数字卡副行与项目卡共用)

/// ▲ +12% / ▼ -8% / 持平 / —(无基准):▲ 绿 ▼ 红,零与无基准灰。
/// 颜色是方向语义(DESIGN.md state-positive/negative),箭头已载方向信息。
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
private struct AgentHeatWall: View {
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
private struct AgentTrendChart: View {
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
        .frame(height: 96)
        .accessibilityHidden(true) // 数值由数字卡排承载
    }
}

// MARK: - 项目大卡

/// 项目一张大卡(cardHigh 底、圆角 10、内距 12):头(名/占比)→ 主数值 +
/// 环比 → 模型分段条 + 色点图例 → harness 分段条 + 底行(在跑/静了)→ 活跃行。
private struct AgentProjectCardView: View {
    let project: AgentProjectSummary
    let windowDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            valueRow
            if !project.models.isEmpty {
                Divider().padding(.horizontal, -12).padding(.top, 0)
                modelBlock
            }
            Divider().padding(.horizontal, -12).padding(.top, 0)
            harnessBlock
            Divider().padding(.horizontal, -12).padding(.top, 0)
            activityRow
        }
        .padding(12)
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

    /// 层 3:模型分段条(top3 已并「其他」)+ 色点图例。
    private var modelBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    /// 层 4:harness(= source)分段条 + 底行(claude/zcode 占比 · 在跑/静了)。
    private var harnessBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
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

    /// 尾行:活跃天数 / 请求数。
    private var activityRow: some View {
        HStack {
            Text("活跃 \(project.activeDays)/\(windowDays) 天")
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
private struct AgentSegmentedBar: View {
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

#Preview("每日消耗") {
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
                    totalTokens: total / 2, requestCount: 40
                )
            )
            projectRows.append(
                AgentProjectUsageRow(
                    day: back(offset), source: .zcode, project: name,
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

    return VStack(spacing: 16) {
        AgentUsageCardView(
            rows: rows,
            projectRows: projectRows,
            modelRows: modelRows,
            liveProjectCounts: ["pulse": 2],
            isScanning: false,
            onRescan: {}
        )
        AgentUsageCardView(rows: [], isScanning: true, onRescan: {})
        AgentUsageCardView(rows: [], isScanning: false, onRescan: {})
    }
    .padding(24)
    .frame(width: 680)
    .background(Surface.window)
}
