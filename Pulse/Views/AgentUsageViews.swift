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

    /// 项目默认展示上限(超出走展开/收起;用户拍板 2026-11-14)。
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

    /// 日历图「年」占位单选项(时间筛选位置恒定;档位切换是未来功能)。
    enum HeatSpan: Hashable {
        case year
    }

    @State private var range: Range = .week
    /// 项目超过上限时的展开态(切 7/30 保持;重进子页回默认收起)。
    @State private var projectsExpanded = false

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
                // 默认前 10 张 + 末行展开/收起(用户拍板 2026-11-14,排行截断同款
                // 交互;上限 = {layout.agent-project-limit})。
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

// MARK: - 热力墙(自封装小组件;agent-tab/05 起,06f 按用户拍板改等比)

/// 一年 52 列格子墙(2026-11-14 用户拍板:**等比缩放、不滚动、每月一刻度**,
/// 推翻 05 时代「固定边 14 + 横向滚动 + 每 8 周刻度」)。格子边长 =
/// (容器宽 − 51×间距)÷ 52,随窗口等比缩放;四档色阶按一年峰值归一
/// (≤8% 灰档);悬停 = 命中格高亮描边 + 左上浮层胶囊(日期 · 当日用量),
/// 命中一律坐标反算、不依赖形状 hit test(空间地图同款纪律)。
struct AgentHeatWall: View {
    static let weeks = 52
    private static let gap: CGFloat = 3
    /// 墙四周留白(2026-11-14 用户实报「块间有间距、和外层没有」)——与格间
    /// 距同源,墙与图区底边缘之间不贴边。
    private static let inset: CGFloat = 3
    private static let axisHeight: CGFloat = 18

    /// 旧 → 新的逐天合计(weeks × 7 条;天数固定,缺天 0)。
    let totals: [AgentDayTotal]

    @State private var width: CGFloat = 640
    @State private var hoverIndex: Int?
    /// 悬停光标位置(浮层跟随鼠标,2026-11-14 用户拍板;Charts 不内置
    /// tooltip,自绘浮层定位自由在手里)。
    @State private var hoverLocation: CGPoint?

    private var step: CGFloat {
        Self.gap + side
    }

    /// 等比格子边长(容器宽容纳 52 列;窄到弹窗也只是格小,不滚动)。宽和高
    /// 两个方向都先扣掉两端 inset,墙四周与外层之间留同间距。
    private var side: CGFloat {
        let horizontal = (width - Self.inset * 2 - Self.gap * CGFloat(Self.weeks - 1)) / CGFloat(Self.weeks)
        return max(horizontal, 1)
    }

    private var gridHeight: CGFloat {
        Self.inset * 2 + side * 7 + Self.gap * 6
    }

    /// 逐天日期(与 totals 同序;轻量解析,每次 body 重算可忽略)。
    private var dates: [Date] {
        totals.compactMap { agentDate($0.day) }
    }

    var body: some View {
        Canvas { context, _ in
            draw(in: &context)
        }
        .frame(height: gridHeight + Self.axisHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newValue in
            if abs(newValue - width) > 0.5 {
                width = newValue
            }
        }
        .contentShape(.rect)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                hoverIndex = hitTest(location)
                hoverLocation = location
            case .ended:
                hoverIndex = nil
                hoverLocation = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoverIndex, let hoverLocation {
                hoverLabel(for: hoverIndex)
                    // 跟随光标:右下偏移(不压格子),贴右/下缘翻到另一侧。
                    .offset(
                        x: hoverLocation.x + (flipX ? -labelWidth - 12 : 12),
                        y: hoverLocation.y + (flipY ? -34 : 12)
                    )
                    .allowsHitTesting(false)
            }
        }
    }

    /// 浮层翻面:光标靠右/靠下时翻到左/上,不裁出墙外。
    private var flipX: Bool {
        guard let hoverLocation else { return false }
        return hoverLocation.x > width - labelWidth - 12
    }

    private var flipY: Bool {
        guard let hoverLocation else { return false }
        return hoverLocation.y > gridHeight - 34
    }

    /// 浮层估算宽("yyyy-MM-dd · 999.9B" ≈ 132;翻面钳位用,不追求精确)。
    private var labelWidth: CGFloat {
        132
    }

    /// 悬停命中:坐标 → 列/行 → 天序号(旧 → 新,列主序同 05 版映射)。
    private func hitTest(_ point: CGPoint) -> Int? {
        let column = Int((point.x - Self.inset) / step)
        let row = Int((point.y - Self.inset) / step)
        guard column >= 0, column < Self.weeks,
              row >= 0, row < 7,
              point.y - Self.inset <= side * 7 + Self.gap * 6,
              column * 7 + row < totals.count else { return nil }
        return column * 7 + row
    }

    /// 左上浮层胶囊:日期 · 当日用量(空间地图悬停读数位同款配方)。
    private func hoverLabel(for index: Int) -> some View {
        Text("\(totals[index].day) · \(agentTokenText(totals[index].total))")
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            .background(Surface.cardHigh.opacity(0.9), in: .rect(cornerRadius: 8))
    }

    private func draw(in context: inout GraphicsContext) {
        let gridHeight = gridHeight
        let step = step

        // 图区底(灰 6%,圆角 8,原型同款)。
        context.fill(
            Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: gridHeight), cornerRadius: 8),
            with: .color(Color.primary.opacity(0.06))
        )

        let cells = Self.weeks * 7
        let maxValue = totals.map(\.total).max() ?? 0
        for index in 0 ..< min(cells, totals.count) {
            let column = index / 7
            let row = index % 7
            let value = Double(totals[index].total)
            let rect = CGRect(
                x: Self.inset + CGFloat(column) * step,
                y: Self.inset + CGFloat(row) * step,
                width: side,
                height: side
            )
            // 四档:值/峰值 ×4 向上取整;≤8% 与零值归灰档。
            let normalized = maxValue > 0 ? value / Double(maxValue) : 0
            let level = normalized <= 0.08 ? 0 : min(4, Int(ceil(normalized * 4)))
            let color: Color = level == 0
                ? Surface.cardHigh
                : agentsAccent.opacity([0, 0.25, 0.5, 0.75, 1][level])
            context.fill(
                Path(roundedRect: rect, cornerRadius: min(3, side / 3)),
                with: .color(color)
            )
            if index == hoverIndex {
                // 悬停高亮:描边圈出命中格(不遮色)。
                context.stroke(
                    Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: min(3, side / 3)),
                    with: .color(agentsAccent),
                    lineWidth: 1.5
                )
            }
        }

        // 月刻度(2026-11-14 用户拍板,替代每 8 周刻度):某列首日的月份与前列
        // 不同 → 该列是新月起点,标「N 月」;首列恒标。
        let axisY = gridHeight + Self.axisHeight / 2 + 2
        var lastMonth = -1
        for column in 0 ..< Self.weeks {
            let dayIndex = column * 7
            guard dayIndex < dates.count else { break }
            let month = Calendar.current.component(.month, from: dates[dayIndex])
            if month != lastMonth {
                lastMonth = month
                context.draw(
                    Text("\(month)月")
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary),
                    at: CGPoint(x: Self.inset + CGFloat(column) * step, y: axisY),
                    anchor: .leading
                )
            }
        }
    }
}

// MARK: - 走势(官方 Swift Charts,agent-tab/05 引入;06f 日期轴 + 左 y 轴 + 悬停)

/// 近 N 天合计折线(2026-11-14 用户拍板:y 轴在**左**、x 轴 **MM-DD 每天一格**
/// ——30 天图标签 -45° 斜排防重叠,替代「N 天前」抽样刻度;悬停 = 最近日竖线 +
/// 顶部浮层「日期 · 用量」)。y 三档 0/半值/峰值、域顶 15% 头寸、线 2pt 圆头、
/// 末点圆点、缺天画 0(账本无行即当日无记录,不猜)、图区 6% accent 底。
struct AgentTrendChart: View {
    let totals: [AgentDayTotal]

    private struct Point: Identifiable {
        let date: Date
        let value: Double

        var id: Date {
            date
        }
    }

    @State private var hoverIndex: Int?
    /// 悬停光标 y(浮层跟随鼠标;Charts 不内置 tooltip,自绘定位)。
    @State private var hoverY: CGFloat?

    var body: some View {
        let points: [Point] = totals.compactMap { total in
            agentDate(total.day).map { Point(date: $0, value: Double(total.total)) }
        }
        guard let first = points.first, let last = points.last else {
            return AnyView(EmptyView())
        }
        let rawMax = max(points.map(\.value).max() ?? 0, 1)
        let domainMax = rawMax * 1.15 // 域顶头寸,峰不顶格
        // 首末点内缩半天,贴边不裁(原型 -0.5 档同义)。
        let calendar = Calendar.current
        let xLow = calendar.date(byAdding: .hour, value: -12, to: first.date) ?? first.date
        let xHigh = calendar.date(byAdding: .hour, value: 12, to: last.date) ?? last.date
        let rotateLabels = points.count > 7

        return AnyView(Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("日期", point.date, unit: .day),
                    y: .value("Token", point.value)
                )
                .foregroundStyle(agentsAccent)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            PointMark(
                x: .value("日期", last.date, unit: .day),
                y: .value("Token", last.value)
            )
            .foregroundStyle(agentsAccent)
            .symbolSize(30)
            if let hoverIndex {
                RuleMark(x: .value("日期", points[hoverIndex].date, unit: .day))
                    .foregroundStyle(agentsAccent.opacity(0.4))
            }
        }
        .chartXScale(domain: xLow ... xHigh)
        .chartYScale(domain: 0 ... domainMax)
        .chartYAxis {
            // y 轴在左(2026-11-14 用户拍板;三档 0/半值/峰值)。
            AxisMarks(position: .leading, values: [0.0, rawMax / 2, rawMax]) { value in
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
            // 每天一格 MM-DD;30 天标签斜排防重叠(标签 view 上 rotationEffect,
            // Charts 无 rotation modifier)。
            AxisMarks(position: .bottom, values: points.map(\.date)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(agentShortDate(date))
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(rotateLabels ? -45 : 0))
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(agentsAccent.opacity(0.06), in: .rect(cornerRadius: 8))
        }
        .frame(minHeight: 96, maxHeight: .infinity) // 双列等高时吃满行内剩余
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let hoverIndex, let x = proxy.position(forX: points[hoverIndex].date) {
                    // 浮层跟随光标(右上偏移,贴右缘翻左);悬停竖线只留 Chart 内
                    // 的 RuleMark(数据层,天然钳在图区)——此前叠加浮层全高
                    // Rectangle 造成双线且伸出图区,已删(2026-11-14 用户实报)。
                    hoverLabel(for: points[hoverIndex])
                        .offset(
                            x: x > geo.size.width - 140 ? x - 132 : x + 8,
                            y: (hoverY ?? 0) - 24
                        )
                }
                Color.clear
                    .contentShape(.rect)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        switch phase {
                        case let .active(location):
                            hoverIndex = nearestIndex(
                                atX: location.x, proxy: proxy, points: points
                            )
                            hoverY = location.y
                        case .ended:
                            hoverIndex = nil
                            hoverY = nil
                        }
                    }
            }
        })
    }

    /// 光标 x → 最近数据日(整列悬停,y 不参与)。
    private func nearestIndex(
        atX x: CGFloat,
        proxy: ChartProxy,
        points: [Point]
    ) -> Int? {
        guard let date = proxy.value(atX: x, as: Date.self), !points.isEmpty else { return nil }
        var best = 0
        var bestGap = TimeInterval.greatestFiniteMagnitude
        for (index, point) in points.enumerated() {
            let gap = abs(point.date.timeIntervalSince(date))
            if gap < bestGap {
                bestGap = gap
                best = index
            }
        }
        return best
    }

    /// 悬停浮层胶囊(热力墙 hoverLabel 同款配方)。
    private func hoverLabel(for point: Point) -> some View {
        Text("\(agentShortDate(point.date)) · \(agentTokenText(Int(point.value)))")
            .font(.system(size: 10.5, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
            .background(Surface.cardHigh.opacity(0.9), in: .rect(cornerRadius: 8))
    }
}

// MARK: - 项目展开/收起(agent-tab/06;排行截断同款)

/// 项目展开/收起末行:排行截断末行(`RankingOverflowRow`)同款视觉配方
/// (11 medium secondary + chevron + 悬停 primary 5% 圆角 8),文案按项目口径
/// (「另 N 个项目」/「只看前 10 个」)。
private struct AgentProjectOverflowRow: View {
    let isExpanded: Bool
    let hiddenCount: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
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
