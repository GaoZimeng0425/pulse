import Charts
import PulseCore
import SwiftUI

// MARK: - 消耗子页两图(agent-tab/07 修正;自 AgentUsageViews.swift 拆出)

//
// 07 根因修正(2026-11-14 用户实报「折线画线漂移、坐标偏、左侧没对齐边缘、
// tooltip 不好看」):
// ① 折线 `LineMark(x: .value(_, date, unit: .day))` 带 unit 时 Charts 把点画在
//    **当天区间中点**(+12h),而轴刻度与悬停吸附按零点算——点、刻度、吸附三者
//    差半天;域又是 first−12h…last+12h,首点离左缘整整一天宽 = 「左侧没对齐」。
//    06g/06h 两次「竖线贴光标」是绕开症状,根因在此。去掉 unit、域 = 首…末日。
// ② 悬停把整张图(含左 y 轴标签区)坐标直接喂 `proxy.value(atX:)`,而它要
//    **绘图区坐标**——多出 y 标签宽(≈40pt)的系统性右偏。改为先减 plotFrame 原点。
// ③ 30 天标签 `rotationEffect(-45°)` 不参与布局:斜字照样互相压、伸出图外;
//    改为按宽度抽稀(从今天倒数,末点恒标)、横排,每天仍有刻度。
// ④ 浮层:两图共用 `AgentChartTooltip`(系统材质 + 两行层级),定位走 PulseCore
//    `ChartHoverGeometry`(锚定命中格 / 数据点正上方,放不下翻下方、实测尺寸钳位)。

/// 两图共用悬停浮层:上行日期(secondary)、下行色点 + 读数(12 semibold)。
/// 底 = 系统材质(DESIGN「弹出的浮层交给系统材质,不自绘阴影」)。
struct AgentChartTooltip: View {
    let title: String
    let value: String
    let swatch: Color

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
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .fixedSize()
        .allowsHitTesting(false)
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

// MARK: - 热力墙

/// 一年 52 列格子墙(2026-11-14 用户拍板:**等比缩放、不滚动、每月一刻度**)。
/// 格子边长 = (容器宽 − 51×间距)÷ 52;四档色阶按一年峰值归一(≤8% 灰档);
/// 悬停 = 命中格描边 + 格上方浮层(07:锚定命中格,不再随光标像素抖动)。
/// 命中一律坐标反算、不依赖形状 hit test(空间地图同款纪律)。
struct AgentHeatWall: View {
    static let weeks = 52
    private static let gap: CGFloat = 3
    /// 墙四周留白(与格间距同源,墙与图区底边缘不贴边)。
    private static let inset: CGFloat = 3
    private static let axisHeight: CGFloat = 18

    /// 旧 → 新的逐天合计(weeks × 7 条;天数固定,缺天 0)。
    let totals: [AgentDayTotal]

    @State private var width: CGFloat = 640
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
        Self.inset * 2 + side * 7 + Self.gap * 6
    }

    private var dates: [Date] {
        totals.compactMap { agentDate($0.day) }
    }

    var body: some View {
        let levels = levels
        Canvas { context, _ in
            draw(in: &context, levels: levels)
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
            case .ended:
                hoverIndex = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let hoverIndex {
                tooltip(for: hoverIndex, level: levels[hoverIndex])
            }
        }
    }

    private func tooltip(for index: Int, level: Int) -> some View {
        let origin = ChartHoverGeometry.tooltipOrigin(
            anchor: cellRect(index),
            size: tooltipSize,
            bounds: CGSize(width: width, height: gridHeight),
            gap: 6
        )
        let date = index < dates.count ? dates[index] : nil
        return AgentChartTooltip(
            title: date.map { agentTooltipDate($0) } ?? totals[index].day,
            value: "\(agentTokenText(totals[index].total)) tokens",
            swatch: Self.color(level: level)
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
        .opacity(tooltipSize == .zero ? 0 : 1)
        .offset(x: origin.x, y: origin.y)
    }

    private func cellRect(_ index: Int) -> CGRect {
        CGRect(
            x: Self.inset + CGFloat(index / 7) * step,
            y: Self.inset + CGFloat(index % 7) * step,
            width: side,
            height: side
        )
    }

    /// 悬停命中:坐标 → 列/行 → 天序号(旧 → 新,列主序)。
    private func hitTest(_ point: CGPoint) -> Int? {
        let column = Int((point.x - Self.inset) / step)
        let row = Int((point.y - Self.inset) / step)
        guard point.x >= Self.inset, point.y >= Self.inset,
              column < Self.weeks, row < 7,
              column * 7 + row < totals.count else { return nil }
        return column * 7 + row
    }

    /// 逐格色阶(0 = 灰档,1…4 = accent 0.25…1)。进行中的「今天」按时刻折算成
    /// 全天等效量再分档(11-14 实报「今天没色」;折算下限 6h 防凌晨虚高)。
    private var levels: [Int] {
        let maxValue = Double(totals.map(\.total).max() ?? 0)
        guard maxValue > 0 else { return totals.map { _ in 0 } }
        var todayElapsed: TimeInterval?
        if let today = dates.last {
            let start = Calendar.current.startOfDay(for: today)
            todayElapsed = max(Date().timeIntervalSince(start), 6 * 3600)
        }
        return totals.indices.map { index in
            var value = Double(totals[index].total)
            if index == totals.count - 1, let elapsed = todayElapsed {
                value = value * 86400 / elapsed
            }
            let normalized = value / maxValue
            return normalized <= 0.08 ? 0 : min(4, Int(ceil(normalized * 4)))
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
            if index == hoverIndex {
                context.stroke(
                    Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: corner),
                    with: .color(agentsAccent),
                    lineWidth: 1.5
                )
            }
        }

        // 月刻度:某列首日的月份与前列不同 → 该列是新月起点,标「N月」。
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

// MARK: - 走势(官方 Swift Charts)

/// 近 N 天合计折线 + 线下渐变面积(07:用户要「带背景、上浓下淡」,同
/// AreaTrendChartView 配方 32%→0,替代 06 的图区 6% 平底)。y 轴在左三档
/// 0/半值/峰值、域顶 15% 头寸;x 轴每天一刻度、MM-DD 标签按宽抽稀;悬停 =
/// 吸附日竖线 + 高亮点 + 点上方浮层(根因修正后吸附即精确,竖线回到数据点上)。
struct AgentTrendChart: View {
    let totals: [AgentDayTotal]
    /// nil = 弹性高(双列时吃满行高);否则定高(单列)。
    var height: CGFloat?

    private struct Point: Identifiable {
        let date: Date
        let value: Double

        var id: Date {
            date
        }
    }

    /// 单个 MM-DD 标签至少分到的宽(10.5pt 五字符 ≈ 30 + 两侧呼吸)。
    private static let labelMinSpacing: CGFloat = 44
    /// 左 y 轴标签区估宽(抽稀步长用,不追求精确)。
    private static let yAxisAllowance: CGFloat = 44

    @State private var hoverIndex: Int?
    @State private var chartWidth: CGFloat = 0
    @State private var tooltipSize: CGSize = .zero

    var body: some View {
        let points: [Point] = totals.compactMap { total in
            agentDate(total.day).map { Point(date: $0, value: Double(total.total)) }
        }
        if points.isEmpty {
            EmptyView()
        } else {
            chart(points)
                .frame(minHeight: height ?? 140, maxHeight: height ?? .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
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
        let stride = ChartHoverGeometry.labelStride(
            count: points.count,
            width: chartWidth - Self.yAxisAllowance,
            minSpacing: Self.labelMinSpacing
        )
        let labelDates = ChartHoverGeometry.labelIndices(count: points.count, stride: stride).map { points[$0].date }
        let fill = LinearGradient(
            colors: [agentsAccent.opacity(0.32), agentsAccent.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )

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
            PointMark(
                x: .value("日期", (hoverIndex.map { points[$0] } ?? points[points.count - 1]).date),
                y: .value("Token", (hoverIndex.map { points[$0] } ?? points[points.count - 1]).value)
            )
            .foregroundStyle(agentsAccent)
            .symbolSize(36)
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0 ... rawMax * 1.15)
        .chartYAxis {
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
            // 每天一刻度(拍板「每天一格」保留);标签另一组按宽抽稀、横排。
            AxisMarks(position: .bottom, values: points.map(\.date)) { _ in
                AxisTick(length: 3)
                    .foregroundStyle(Color.primary.opacity(0.15))
            }
            // 日期轴标签默认左锚在刻度上,末点(今天)伸出绘图区被 Charts 丢弃——
            // 改为居中,首末两枚分别左/右锚收进图内。
            AxisMarks(position: .bottom, values: labelDates) { value in
                let date = value.as(Date.self)
                let anchor: UnitPoint = date == first ? .topLeading : (date == last ? .topTrailing : .top)
                AxisValueLabel(centered: false, anchor: anchor, horizontalSpacing: 0) {
                    if let date = value.as(Date.self) {
                        Text(agentShortDate(date))
                            .font(.system(size: 10.5))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(.rect)
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            switch phase {
                            case let .active(location):
                                // 绘图区坐标 = 本地坐标 − plotFrame 原点(06 漏减 = 系统性右偏)。
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

    private func tooltip(for point: Point, anchor: CGRect, bounds: CGSize) -> some View {
        let origin = ChartHoverGeometry.tooltipOrigin(anchor: anchor, size: tooltipSize, bounds: bounds, gap: 6)
        return AgentChartTooltip(
            title: agentTooltipDate(point.date),
            value: "\(agentTokenText(Int(point.value))) tokens",
            swatch: agentsAccent
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
        .opacity(tooltipSize == .zero ? 0 : 1)
        .offset(x: origin.x, y: origin.y)
    }
}
