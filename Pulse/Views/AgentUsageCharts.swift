import Charts
import PulseCore
import SwiftUI

// MARK: - 消耗页两图:热力墙 + 走势(agent-tab/07)

//
// 两张图的骨架相同——图区 → 日期轴带:
// · `AgentHeatWall`:一年 52 列格子墙,Canvas 自绘,随容器宽等比缩放、不滚动;
// · `AgentTrendChart`:近 N 天按来源分两层的面积 + 两条线,官方 Swift Charts,x 轴隐藏;
// · `AgentChartAxis`:两图共用的自绘日期轴带(轴带高与标签位置只在这里定);
// · `AgentChartTooltip`:多处共用的悬停浮层(通用件,规范在 DESIGN.md;历史页与
//   指标主卡也用)。

/// 浮层明细格里的一项分区:色块 + 名称 + 读数。
struct ChartTooltipPartition: Identifiable {
    let name: String
    let value: String
    let tint: Color

    var id: String {
        name
    }
}

/// 多处共用的悬停浮层。形态、材质与定位走 DESIGN.md「图表悬停读数与浮层」组件规范
/// (定位算法在 PulseCore `ChartHoverGeometry`);读数下可带两列明细格——先按分区列
/// 各项,再列更细一级的分项,哪一级没有数据就不画哪一行。
struct AgentChartTooltip: View {
    let title: String
    let value: String
    /// 读数旁的色块;读数不是单一颜色(多层叠出来的总数)时为 nil。
    var swatch: Color?
    /// 按分区列出的各项(如两层面积各占多少);空 = 不画这一行。
    var partitions: [ChartTooltipPartition] = []
    /// 更细一级的分项;缺失(粗粒度回填天)→ nil。
    var breakdown: AgentTokenBreakdown?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let swatch {
                    swatchView(swatch)
                }
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            if !partitions.isEmpty || breakdown != nil {
                detailGrid
                    .padding(.top, 3)
            }
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .background(.thickMaterial, in: .rect(cornerRadius: 8))
        .fixedSize()
        .allowsHitTesting(false)
    }

    /// 两列明细格:Grid 保证跨行对齐(数值宽度不一,HStack+Spacer 会错列)。
    private var detailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
            if !partitions.isEmpty {
                GridRow {
                    ForEach(partitions) { partition in
                        partitionItem(partition)
                    }
                }
            }
            if let breakdown {
                GridRow {
                    bucket("Input", agentTokenText(breakdown.input))
                    bucket("Output", agentTokenText(breakdown.output))
                }
                GridRow {
                    bucket("Cache R", agentTokenText(breakdown.cacheRead))
                    bucket("Cache W", agentTokenText(breakdown.cacheWrite))
                }
            }
        }
    }

    private func swatchView(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private func partitionItem(_ partition: ChartTooltipPartition) -> some View {
        HStack(spacing: 5) {
            swatchView(partition.tint)
            Text("\(partition.name) \(partition.value)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
/// 距离是同一组常量——同一个页面里两张图的日期标签在图内的高度一致,由构造保证,
/// 不靠两套布局碰巧对齐。
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

// MARK: - 图例色点

/// 图例色点(`{layout.legend-swatch}` 6pt,圆角 2):走势卡图例、项目明细的构成图例共用。
struct AgentLegendSwatch: View {
    let tint: Color

    static let side: CGFloat = 6

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(tint)
            .frame(width: Self.side, height: Self.side)
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
    /// 月签最宽读数(「12月」10.5pt)的估宽:最右一签起点往回收,不出墙右缘被裁。
    private static let monthLabelMaxWidth: CGFloat = 24

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

    /// 图区高(格墙 + 上下 inset;不含轴带),随容器宽等比:格边长 × 7 行 + 行距。
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
        // 从最新的月往回排:与已留下的后一签不足 `monthLabelMinGap` 时丢前一个——首列常是
        // 残月,只占一两列,不丢会和下月签挤成「11月12月」;墙很窄(弹窗)时隔月留签。
        // 最右一签的起点收到墙内,不被右缘裁成「11,」。
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
        let rightmostStart = width - Self.inset - Self.monthLabelMaxWidth
        var nextKeptX = CGFloat.infinity
        for mark in marks.reversed() {
            let x = min(mark.x, rightmostStart)
            guard nextKeptX - x >= Self.monthLabelMinGap else {
                continue
            }
            nextKeptX = x
            AgentChartAxis.drawLabel(
                "\(mark.month)月",
                x: x,
                plotBottom: gridHeight,
                anchor: .leading,
                in: &context
            )
        }
    }
}

// MARK: - 走势(官方 Swift Charts)

/// 近 N 天按来源分两层的面积 + 两条线(ZCode 在下、Claude 在上),各取来源色——
/// 一层是「谁在用」,读得出此消彼长。高度由走势卡给(含日期轴带)。Charts 的轴标签
/// 一旦占了绘图区以外的宽,悬停坐标就得减偏移,所以 x 轴隐藏、y 标签画进图内左上,
/// 下接与热力墙同一条 `AgentChartAxis`。今天画实际值(不折算),悬停标题标「今天」。
/// 悬停 = 吸附日竖线 + 高亮点 + 点上方浮层(日期、总数、两家、四桶)。
struct AgentTrendChart: View {
    let totals: [AgentDayTotal]
    /// 整体高(含日期轴带)。
    let height: CGFloat
    /// 是否在图内左侧画半值 / 峰值刻度字;图很矮的紧凑档不放(数值由读数承载)。
    let showsPeakLabels: Bool

    private struct Point: Identifiable {
        let date: Date
        let claude: Double
        let zcode: Double
        /// 四桶明细;分项缺失的回填天 = nil。
        let breakdown: AgentTokenBreakdown?
        let sources: AgentSourceSplit

        var total: Double {
            claude + zcode
        }

        var id: Date {
            date
        }
    }

    /// 单个 MM-DD 标签至少分到的宽(10.5pt 五字符 ≈ 30 + 两侧呼吸)。
    private static let labelMinSpacing: CGFloat = 44

    @State private var hoverIndex: Int?
    @State private var chartWidth: CGFloat = 0
    @State private var tooltipSize: CGSize = .zero

    var body: some View {
        let points: [Point] = totals.compactMap { total in
            agentDate(total.day).map {
                Point(
                    date: $0,
                    claude: Double(total.claudeTotal),
                    zcode: Double(total.zcodeTotal),
                    breakdown: total.breakdown,
                    sources: total.sourceSplit
                )
            }
        }
        // 没有点也占住高度:卡高不随数据有无跳。
        if points.isEmpty {
            Color.clear.frame(height: height)
        } else {
            VStack(spacing: 0) {
                chart(points)
                    .frame(height: max(height - AgentChartAxis.height, 0))
                    // 浮层翻到点下方时会伸出图区:图层抬到日期轴之上,轴标签不压在浮层上面。
                    .zIndex(1)
                axisStrip(points)
                    .frame(height: AgentChartAxis.height)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
            // 切范围换了点数:悬停着的竖线与浮层不再对应任何点,清掉。只看点数——
            // 后台刷新今天那行时点数不变,不打断正在看的悬停。
            .onChange(of: totals.count) { _, _ in
                hoverIndex = nil
            }
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
        let rawMax = max(points.map(\.total).max() ?? 0, 1)
        let first = points[0].date
        let last = points[points.count - 1].date
        // 域 = 首…末日零点,线贴绘图区左右缘;单点兜底各让半天防零宽域。
        let domain = first < last
            ? first ... last
            : first.addingTimeInterval(-43200) ... last.addingTimeInterval(43200)
        let claude = AgentPartitionTint.source(.claude)
        let zcode = AgentPartitionTint.source(.zcode)
        // 线下填充同 DESIGN.md「面积走势图」:各自来源色 32% → 0 的竖向渐变,不平涂。
        func fill(_ tint: Color) -> LinearGradient {
            LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)], startPoint: .top, endPoint: .bottom)
        }
        let focus = hoverIndex.flatMap { points.indices.contains($0) ? points[$0] : nil }
            ?? points[points.count - 1]

        // x 值一律不带 `unit:`——带 `.day` 时 Charts 把点画在当天区间中点(+12h),
        // 刻度与悬停吸附却按零点算,点、刻度、吸附三者差半天:线看着漂、吸附不贴点。
        // 遇到竖线不贴点先查这里,不要去挪竖线。
        // 两层面积各画成一条带,起点 / 终点由数据显式给出(下:0 → ZCode,上:ZCode → 合计),
        // 不靠堆叠规则;每一层都带自己的 series——同一点上画两笔同类型的标记,不带
        // series 时 Charts 把它们并成一笔,几何与样式都会串(实测只剩一层、颜色还错)。
        return Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    yStart: .value("Token", 0.0),
                    yEnd: .value("Token", point.zcode),
                    series: .value("来源", "ZCode")
                )
                .foregroundStyle(fill(zcode))
                .interpolationMethod(.monotone)
                AreaMark(
                    x: .value("日期", point.date),
                    yStart: .value("Token", point.zcode),
                    yEnd: .value("Token", point.total),
                    series: .value("来源", "Claude")
                )
                .foregroundStyle(fill(claude))
                .interpolationMethod(.monotone)
            }
            ForEach(points) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("Token", point.zcode),
                    series: .value("来源", "ZCode")
                )
                .foregroundStyle(zcode)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("Token", point.total),
                    series: .value("来源", "Claude")
                )
                .foregroundStyle(claude)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }
            if let hoverIndex, points.indices.contains(hoverIndex) {
                let point = points[hoverIndex]
                RuleMark(x: .value("日期", point.date))
                    .foregroundStyle(agentsAccent.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("日期", point.date), y: .value("Token", point.total))
                    .foregroundStyle(claude.opacity(0.25))
                    .symbolSize(120)
            }
            PointMark(x: .value("日期", focus.date), y: .value("Token", focus.total))
                .foregroundStyle(claude)
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
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    if showsPeakLabels {
                        yLabels(rawMax: rawMax, proxy: proxy, plot: plot)
                    }
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
                    if let hoverIndex, points.indices.contains(hoverIndex),
                       let x = proxy.position(forX: points[hoverIndex].date),
                       let y = proxy.position(forY: points[hoverIndex].total) {
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
        // 总数不是单一颜色(两层叠出来的),读数旁不画色块;两层的量各带来源色块列在明细里。
        return AgentChartTooltip(
            title: agentTooltipDate(point.date),
            value: "\(agentTokenText(Int(point.total))) tokens",
            swatch: nil,
            partitions: [
                ChartTooltipPartition(
                    name: "Claude", value: agentTokenText(point.sources.claude),
                    tint: AgentPartitionTint.source(.claude)
                ),
                ChartTooltipPartition(
                    name: "ZCode", value: agentTokenText(point.sources.zcode),
                    tint: AgentPartitionTint.source(.zcode)
                ),
            ],
            breakdown: point.breakdown
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
        .opacity(tooltipSize == .zero ? 0 : 1)
        .offset(x: origin.x, y: origin.y)
    }
}
