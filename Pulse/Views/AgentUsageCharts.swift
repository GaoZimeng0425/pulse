import Charts
import PulseCore
import SwiftUI

// MARK: - 消耗子页两图:热力墙 + 走势(agent-tab/07)

//
// 两张图的骨架相同——图区 → 日期轴带,并排时靠这份同构等高、左右缘对齐:
// · `AgentHeatWall`:一年 52 列格子墙,Canvas 自绘,随容器宽等比缩放、不滚动;
// · `AgentTrendChart`:近 N 天折线 + 线下渐变面积,官方 Swift Charts,x 轴隐藏;
// · `AgentChartAxis`:两图共用的自绘日期轴带;
// · `AgentChartTooltip`:两图共用的悬停浮层(通用件,规范在 DESIGN.md)。

/// 两图共用的悬停浮层。形态、材质与定位走 DESIGN.md「图表悬停读数与浮层」组件规范
/// (定位算法在 PulseCore `ChartHoverGeometry`);本页特有的只有一处——该时段有分项
/// 时,末尾加一块 2×2 四桶明细(标签层级对齐项目卡 `bucketsRow`)。
struct AgentChartTooltip: View {
    let title: String
    let value: String
    let swatch: Color
    /// 四桶明细;分项缺失(粗粒度回填天)→ nil,浮层照旧两行。
    var breakdown: AgentTokenBreakdown?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(swatch)
                    .frame(width: 8, height: 8)
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            if let breakdown {
                bucketsGrid(breakdown)
                    .padding(.top, 3)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .fixedSize()
        .allowsHitTesting(false)
    }

    /// 2×2 四桶:Grid 保证两列跨行对齐(数值宽度不一,HStack+Spacer 会错列)。
    private func bucketsGrid(_ buckets: AgentTokenBreakdown) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            GridRow {
                bucket("Input", agentTokenText(buckets.input))
                bucket("Output", agentTokenText(buckets.output))
            }
            GridRow {
                bucket("Cache R", agentTokenText(buckets.cacheRead))
                bucket("Cache W", agentTokenText(buckets.cacheWrite))
            }
        }
    }

    private func bucket(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// 浮层日期标题:「今天 · 11月14日」/「11月13日 周四」;跨年补年份。
func agentTooltipDate(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
    let monthDay = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
    if calendar.isDate(date, inSameDayAs: now) {
        return "今天 · \(monthDay)"
    }
    let weekday = weekdays[((parts.weekday ?? 1) - 1) % 7]
    let sameYear = calendar.component(.year, from: now) == parts.year
    return sameYear ? "\(monthDay) 周\(weekday)" : "\(parts.year ?? 0)年\(monthDay) 周\(weekday)"
}

/// 按周浮层标题:「近 7 天 · 11月8日 – 11月14日」/「11月1日 – 11月7日」;跨年补年份。
func agentTooltipWeek(first: Date, last: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    func monthDay(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let text = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        return calendar.component(.year, from: now) == parts.year ? text : "\(parts.year ?? 0)年\(text)"
    }
    let range = "\(monthDay(first)) – \(monthDay(last))"
    return calendar.isDate(last, inSameDayAs: now) ? "近 7 天 · \(range)" : range
}

/// 热力墙粒度。按天 = 一格一天;按周 = 一列连续 7 天同色、悬停读一周合计——列以
/// 今天收尾往前数,是滚动周不是自然周;色阶按周峰值归一,与按天各一套峰值。
enum AgentHeatGranularity: Hashable {
    case day
    case week

    var title: String {
        self == .day ? "天" : "周"
    }
}

// MARK: - 共享日期轴带

/// 两图共用的日期轴带:热力墙与走势都用这一个函数画标签,轴带高与标签到图区底的
/// 距离是同一组常量——两图并排时上下缘与日期标签基线对齐由构造保证,不靠两套
/// 布局碰巧对齐。
enum AgentChartAxis {
    static let height: CGFloat = 18
    /// 标签垂直中线距图区底边的距离。
    static let labelCenterOffset: CGFloat = 11

    static func drawLabel(
        _ text: String,
        x: CGFloat,
        plotBottom: CGFloat,
        anchor: UnitPoint,
        in context: inout GraphicsContext
    ) {
        context.draw(
            Text(text)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.tertiary),
            at: CGPoint(x: x, y: plotBottom + labelCenterOffset),
            anchor: anchor
        )
    }
}

// MARK: - 热力墙

/// 一年 52 列格子墙:随容器宽**等比缩放、不滚动**,每月一个刻度;四档色阶按峰值
/// 归一(量化在 PulseCore `AgentHeatScale`)。悬停 = 命中格描边 + 浮层,浮层锚定
/// 命中格而不是跟随光标(逐格吸附不抖);命中一律坐标反算,不依赖形状
/// hit test(空间地图同款纪律)。
struct AgentHeatWall: View {
    static let weeks = 52
    private static let gap: CGFloat = 3
    /// 墙四周留白(与格间距同源,墙与图区底边缘不贴边)。
    private static let inset: CGFloat = 3
    /// 相邻月签最小间距(「12月」10.5pt ≈ 24 + 呼吸)。
    private static let monthLabelMinGap: CGFloat = 32

    /// 旧 → 新的逐天合计(weeks × 7 条;天数固定,缺天 0)。
    let totals: [AgentDayTotal]
    /// 按天 / 按周,规则见 `AgentHeatGranularity`。
    var granularity: AgentHeatGranularity = .day

    @State private var width: CGFloat = 640
    /// 悬停命中:按天 = 天序号;按周 = 列序号。
    @State private var hoverIndex: Int?
    /// 浮层实测尺寸(钳位用;首帧为 0 时隐藏,免一帧跳位)。
    @State private var tooltipSize: CGSize = .zero

    private var step: CGFloat {
        Self.gap + side
    }

    private var side: CGFloat {
        let horizontal = (width - Self.inset * 2 - Self.gap * CGFloat(Self.weeks - 1)) / CGFloat(Self.weeks)
        return max(horizontal, 1)
    }

    private var gridHeight: CGFloat {
        Self.gridHeight(forWidth: width)
    }

    /// 图区高(格墙 + 上下 inset;不含轴带)。走势图按同宽套同式取绘图区高,
    /// 两图并排 / 上下排时绘图区恒等高(agent-tab/10)。
    static func gridHeight(forWidth width: CGFloat) -> CGFloat {
        let side = max((width - inset * 2 - gap * CGFloat(weeks - 1)) / CGFloat(weeks), 1)
        return inset * 2 + side * 7 + gap * 6
    }

    private var dates: [Date] {
        totals.compactMap { agentDate($0.day) }
    }

    var body: some View {
        let levels = levels
        Canvas { context, _ in
            draw(in: &context, levels: levels)
        }
        .frame(height: gridHeight + AgentChartAxis.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newValue in
            if abs(newValue - width) > 0.5 {
                width = newValue
            }
        }
        .contentShape(.rect)
        // 悬停下标两档含义不同(天序号 / 列序号),切档必须清,否则按旧义错位命中。
        .onChange(of: granularity) { hoverIndex = nil }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                hoverIndex = hitTest(location)
            case .ended:
                hoverIndex = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoverIndex {
                tooltip(for: hoverIndex, levels: levels)
            }
        }
    }

    private func tooltip(for index: Int, levels: [Int]) -> some View {
        let bounds = CGSize(width: width, height: gridHeight)
        // 按周锚点是整列(上下没空间)→ 侧放;按天锚点是单格 → 格上方。
        let origin = granularity == .week
            ? ChartHoverGeometry.sideTooltipOrigin(anchor: hoverRect(index), size: tooltipSize, bounds: bounds, gap: 6)
            : ChartHoverGeometry.tooltipOrigin(anchor: hoverRect(index), size: tooltipSize, bounds: bounds, gap: 6)
        let content: TooltipContent = switch granularity {
        case .day:
            TooltipContent(
                title: index < dates.count ? agentTooltipDate(dates[index]) : totals[index].day,
                total: totals[index].total,
                level: levels[index],
                breakdown: totals[index].breakdown
            )
        case .week:
            weekTooltip(column: index, levels: levels)
        }
        return AgentChartTooltip(
            title: content.title,
            value: "\(agentTokenText(content.total)) tokens",
            swatch: Self.color(level: content.level),
            breakdown: content.breakdown
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
        .opacity(tooltipSize == .zero ? 0 : 1)
        .offset(x: origin.x, y: origin.y)
    }

    /// 悬停内容:标题 / 总数 / 色阶档 / 四桶明细(分项缺失 = nil)。
    private struct TooltipContent {
        let title: String
        let total: Int
        let level: Int
        let breakdown: AgentTokenBreakdown?
    }

    private func weekTooltip(column: Int, levels: [Int]) -> TooltipContent {
        let week = AgentHeatScale.weeks(totals)[column]
        let title = if let first = agentDate(week.firstDay), let last = agentDate(week.lastDay) {
            agentTooltipWeek(first: first, last: last)
        } else {
            "\(week.firstDay) – \(week.lastDay)"
        }
        return TooltipContent(
            title: title, total: week.total, level: levels[column * 7], breakdown: week.breakdown
        )
    }

    /// 悬停描边 / 浮层锚点:按天 = 命中格;按周 = 整列(首格到末格的外包框)。
    private func hoverRect(_ index: Int) -> CGRect {
        switch granularity {
        case .day:
            return cellRect(index)
        case .week:
            let first = index * 7
            let last = min(first + 6, totals.count - 1)
            return cellRect(first).union(cellRect(last))
        }
    }

    private func cellRect(_ index: Int) -> CGRect {
        CGRect(
            x: Self.inset + CGFloat(index / 7) * step,
            y: Self.inset + CGFloat(index % 7) * step,
            width: side,
            height: side
        )
    }

    /// 悬停命中:坐标 → 列/行 → 天序号(旧 → 新,列主序);按周返回列序号。
    private func hitTest(_ point: CGPoint) -> Int? {
        let column = Int((point.x - Self.inset) / step)
        let row = Int((point.y - Self.inset) / step)
        guard point.x >= Self.inset, point.y >= Self.inset,
              column < Self.weeks, row < 7,
              column * 7 + row < totals.count else { return nil }
        return granularity == .week ? column : column * 7 + row
    }

    /// 逐格色阶(0 = 灰档,1…4 = 页 accent 四档;量化式在 PulseCore `AgentHeatScale`)。
    /// 进行中的「今天」先按时刻折算成全天等效量再分档:不折算的话,今天和完整天
    /// 直接比天然吃亏,到下午也可能还落在灰档;折算下限 6h,防凌晨虚高。按周:一列
    /// 7 格取同一档(按周峰值归一),今天那份照样折算。
    private var levels: [Int] {
        let elapsed = dates.last.map { Date().timeIntervalSince(Calendar.current.startOfDay(for: $0)) }
        switch granularity {
        case .day:
            return AgentHeatScale.dayLevels(totals, todayElapsed: elapsed)
        case .week:
            let weekLevels = AgentHeatScale.weekLevels(totals, todayElapsed: elapsed)
            return totals.indices.map { weekLevels[$0 / 7] }
        }
    }

    private static func color(level: Int) -> Color {
        level == 0 ? Surface.cardHigh : agentsAccent.opacity([0, 0.25, 0.5, 0.75, 1][level])
    }

    private func draw(in context: inout GraphicsContext, levels: [Int]) {
        // 图区底(灰 6%,圆角 8)。
        context.fill(
            Path(roundedRect: CGRect(x: 0, y: 0, width: width, height: gridHeight), cornerRadius: 8),
            with: .color(Color.primary.opacity(0.06))
        )
        let corner = min(3, side / 3)
        for index in 0 ..< min(Self.weeks * 7, totals.count) {
            let rect = cellRect(index)
            context.fill(Path(roundedRect: rect, cornerRadius: corner), with: .color(Self.color(level: levels[index])))
        }
        if let hoverIndex {
            context.stroke(
                Path(roundedRect: hoverRect(hoverIndex).insetBy(dx: -1, dy: -1), cornerRadius: corner),
                with: .color(agentsAccent),
                lineWidth: 1.5
            )
        }

        // 月刻度:某列首日的月份与前列不同 → 该列是新月起点,标「N月」。
        // 相邻两签不足 `monthLabelMinGap` 时丢前一个——首列常是残月,只占一两列,
        // 不丢会和下月签挤成「11月12月」。
        var marks: [(x: CGFloat, month: Int)] = []
        var lastMonth = -1
        for column in 0 ..< Self.weeks {
            let dayIndex = column * 7
            guard dayIndex < dates.count else { break }
            let month = Calendar.current.component(.month, from: dates[dayIndex])
            if month != lastMonth {
                lastMonth = month
                marks.append((Self.inset + CGFloat(column) * step, month))
            }
        }
        for (index, mark) in marks.enumerated() {
            if index + 1 < marks.count, marks[index + 1].x - mark.x < Self.monthLabelMinGap {
                continue
            }
            AgentChartAxis.drawLabel(
                "\(mark.month)月",
                x: mark.x,
                plotBottom: gridHeight,
                anchor: .leading,
                in: &context
            )
        }
    }
}

// MARK: - 走势(官方 Swift Charts)

/// 近 N 天合计折线 + 线下渐变面积(与 `AreaTrendChartView` 同配方)。与热力墙
/// **同构**,并排时才等高、左右缘对齐:绘图区高 = 热力墙同宽图区高
/// (`AgentHeatWall.gridHeight(forWidth:)`),图区底同式,下接同一条 `AgentChartAxis`。
/// Charts 自带 x 轴隐藏、y 标签画进图内左上——轴标签一旦占了绘图区以外的宽,
/// 绘图区就比热力墙窄,左右缘对不齐。悬停 = 吸附日竖线 + 高亮点 + 点上方浮层。
struct AgentTrendChart: View {
    let totals: [AgentDayTotal]
    /// nil = 与热力墙等高(按自身宽套同式);弹窗紧凑档传定高。
    var plotHeight: CGFloat?

    private struct Point: Identifiable {
        let date: Date
        let value: Double
        /// 四桶明细;分项缺失的回填天 = nil。
        let breakdown: AgentTokenBreakdown?

        var id: Date {
            date
        }
    }

    /// 单个 MM-DD 标签至少分到的宽(10.5pt 五字符 ≈ 30 + 两侧呼吸)。
    private static let labelMinSpacing: CGFloat = 44
    /// 绘图区高下限(窄宽时热力墙很矮,折线不至于压成一条线)。
    private static let minimumPlotHeight: CGFloat = 60

    @State private var hoverIndex: Int?
    @State private var chartWidth: CGFloat = 0
    @State private var tooltipSize: CGSize = .zero

    var body: some View {
        let points: [Point] = totals.compactMap { total in
            agentDate(total.day).map {
                Point(date: $0, value: Double(total.total), breakdown: total.breakdown)
            }
        }
        if points.isEmpty {
            EmptyView()
        } else {
            let height = plotHeight
                ?? max(AgentHeatWall.gridHeight(forWidth: chartWidth), Self.minimumPlotHeight)
            VStack(spacing: 0) {
                chart(points)
                    .frame(height: height)
                axisStrip(points)
                    .frame(height: AgentChartAxis.height)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
        }
    }

    /// x 位置 = 日期在域内的线性占比 × 宽(绘图区铺满宽,与 Charts 刻度同式)。
    private func xPosition(_ date: Date, first: Date, last: Date, width: CGFloat) -> CGFloat {
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return width / 2 }
        return CGFloat(date.timeIntervalSince(first) / span) * width
    }

    /// 日期标签横排、按宽抽稀,不用斜排:`rotationEffect` 不参与布局,斜字照样互压、
    /// 伸出图外。抽稀从今天倒数、末点恒标;首签左锚、末签右锚,末签才不出界。
    private func axisStrip(_ points: [Point]) -> some View {
        let first = points[0].date
        let last = points[points.count - 1].date
        let stride = ChartHoverGeometry.labelStride(
            count: points.count,
            width: chartWidth,
            minSpacing: Self.labelMinSpacing
        )
        let indices = ChartHoverGeometry.labelIndices(count: points.count, stride: stride)
        return Canvas { context, size in
            for index in indices {
                let date = points[index].date
                let anchor: UnitPoint = index == 0 ? .leading : (index == points.count - 1 ? .trailing : .center)
                AgentChartAxis.drawLabel(
                    agentShortDate(date),
                    x: xPosition(date, first: first, last: last, width: size.width),
                    plotBottom: 0,
                    anchor: anchor,
                    in: &context
                )
            }
        }
    }

    private func chart(_ points: [Point]) -> some View {
        let rawMax = max(points.map(\.value).max() ?? 0, 1)
        let first = points[0].date
        let last = points[points.count - 1].date
        // 域 = 首…末日零点,线贴绘图区左右缘;单点兜底各让半天防零宽域。
        let domain = first < last
            ? first ... last
            : first.addingTimeInterval(-43200) ... last.addingTimeInterval(43200)
        let fill = LinearGradient(
            colors: [agentsAccent.opacity(0.32), agentsAccent.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        let focus = hoverIndex.map { points[$0] } ?? points[points.count - 1]

        // x 值一律不带 `unit:`——带 `.day` 时 Charts 把点画在当天区间中点(+12h),
        // 刻度与悬停吸附却按零点算,点、刻度、吸附三者差半天:线看着漂、吸附不贴点。
        // 遇到竖线不贴点先查这里,不要去挪竖线。
        return Chart {
            ForEach(points) { point in
                AreaMark(x: .value("日期", point.date), y: .value("Token", point.value))
                    .foregroundStyle(fill)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("日期", point.date), y: .value("Token", point.value))
                    .foregroundStyle(agentsAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let hoverIndex {
                RuleMark(x: .value("日期", points[hoverIndex].date))
                    .foregroundStyle(agentsAccent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("日期", points[hoverIndex].date), y: .value("Token", points[hoverIndex].value))
                    .foregroundStyle(agentsAccent.opacity(0.25))
                    .symbolSize(120)
            }
            PointMark(x: .value("日期", focus.date), y: .value("Token", focus.value))
                .foregroundStyle(agentsAccent)
                .symbolSize(36)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0 ... rawMax * 1.15)
        .chartXAxis(.hidden)
        .chartYAxis {
            // 只留网格线;标签在 overlay 里画进图内左侧(绘图区铺满宽)。
            AxisMarks(values: [rawMax / 2, rawMax]) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.primary.opacity(0.08))
            }
        }
        .chartPlotStyle { plot in
            plot.background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    yLabels(rawMax: rawMax, proxy: proxy, plot: plot)
                    Color.clear
                        .contentShape(.rect)
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case let .active(location):
                                // `value(atX:)` 吃绘图区坐标:本地坐标先减 plotFrame
                                // 原点,漏减会整体右偏一个 y 标签区的宽。
                                guard let date: Date = proxy.value(atX: location.x - plot.minX) else { return }
                                hoverIndex = ChartHoverGeometry.nearestIndex(
                                    of: date.timeIntervalSinceReferenceDate,
                                    in: points.map(\.date.timeIntervalSinceReferenceDate)
                                )
                            case .ended:
                                hoverIndex = nil
                            }
                        }
                    if let hoverIndex,
                       let x = proxy.position(forX: points[hoverIndex].date),
                       let y = proxy.position(forY: points[hoverIndex].value) {
                        tooltip(
                            for: points[hoverIndex],
                            anchor: CGRect(x: plot.minX + x - 6, y: plot.minY + y - 6, width: 12, height: 12),
                            bounds: geo.size
                        )
                    }
                }
            }
        }
    }

    /// y 标签(半值 / 峰值)贴各自网格线上方、图内左侧 6pt。
    private func yLabels(rawMax: Double, proxy: ChartProxy, plot: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([rawMax / 2, rawMax], id: \.self) { value in
                if let y = proxy.position(forY: value) {
                    Text(agentTokenText(Int(value)))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .offset(x: plot.minX + 6, y: plot.minY + y - 15)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func tooltip(for point: Point, anchor: CGRect, bounds: CGSize) -> some View {
        let origin = ChartHoverGeometry.tooltipOrigin(anchor: anchor, size: tooltipSize, bounds: bounds, gap: 6)
        return AgentChartTooltip(
            title: agentTooltipDate(point.date),
            value: "\(agentTokenText(Int(point.value))) tokens",
            swatch: agentsAccent,
            breakdown: point.breakdown
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
        .opacity(tooltipSize == .zero ? 0 : 1)
        .offset(x: origin.x, y: origin.y)
    }
}
