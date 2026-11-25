import PulseCore
import SwiftUI

// MARK: - 指标 tab 视图族(工单 P0.6-03)

// 内容模型(tab 展示什么)在 MetricTabModel(纯逻辑,单测覆盖);本文件只做
// SwiftUI 外观:面积趋势图(§3-2)、CPU 主卡、Memory by App 环形卡、两种 tab 条
// 与键盘 ←/→ 接线——按 spec 测试决策走预览 + 手动验收。

/// 面积折线图(参考文档 §3-2,详情 tab 主卡):56 点、线 tint 2px、线下
/// 梯度 tint 32%→0、4 条水平网格线(--line 口径)——无轴、无刻度、无标签。
/// 定长 list:数据经 `HistoryCurveHover.edgeWindow` 取最近 56 点,不足前面补 0
/// (0 值画在 2% 底线,与 strip 同口径);第 i 格 = list[i],悬停到哪格显示哪格,
/// 无任何序号换算(chart-hover-partial,2026-11-25 用户拍板)。空序列只剩网格线。自绘 Canvas:与 StripChartView 同理由(省 Charts 轴开销,形态精确)。
struct AreaTrendChartView: View {
    /// 点数 = 参考文档 §3-2 的 56 点形态(缓冲窗口 ~60 点,取最近 56 个)。
    static let pointCount = 56
    /// 零值/垫底比例(§3-1 同款 2%)。
    private static let floorFraction: CGFloat = 0.02
    /// 4 条水平网格线(§3-2:y=8/37/66/96,约 25% 步进)。
    private static let gridLineFractions: [CGFloat] = [0.08, 0.37, 0.66, 0.96]

    /// 时间序采样值(旧 → 新)。
    let values: [Double]
    /// 与 values 对齐的采样时刻(旧 → 新;空或长度不齐 = 不出悬停,不按
    /// 序号猜时刻——心跳 5s/1s 混合,猜会错到分钟级,history-hover/02)。
    var times: [Date] = []
    /// 悬停数值文案(按所在指标格式化,装配点给)。
    var valueText: (Double) -> String = { PulseFormat.cpuPercent($0) }
    /// 线与面积色。
    var tint: Color
    /// 归一化上限(系统负载固定 0–100 语义域;内存 = 物理总量)。
    var domainMax: Double

    init(
        values: [Double],
        times: [Date] = [],
        valueText: @escaping (Double) -> String = { PulseFormat.cpuPercent($0) },
        tint: Color = Metric.cpu.accentColor,
        domainMax: Double = 100
    ) {
        self.values = values
        self.times = times
        self.valueText = valueText
        self.tint = tint
        self.domainMax = max(domainMax, 1)
    }

    /// 悬停所在格(= window 下标);nil = 未悬停。
    @State private var hoverIndex: Int?
    @State private var plotSize: CGSize = .zero
    @State private var tooltipSize: CGSize = .zero

    /// 定长窗口:恰好 pointCount 个点(空输入 = 空)。绘制与悬停读同一份。
    private var window: [HistoryCurveHover.EdgePoint] {
        HistoryCurveHover.edgeWindow(values: values, times: times, count: Self.pointCount)
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .contentShape(.rect)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newValue in
            if abs(newValue.width - plotSize.width) > 0.5
                || abs(newValue.height - plotSize.height) > 0.5 {
                plotSize = newValue
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case let .active(location):
                let index = HistoryCurveHover.edgeIndex(
                    atX: location.x, width: plotSize.width, count: Self.pointCount
                )
                if index != hoverIndex {
                    hoverIndex = index
                }
            case .ended:
                hoverIndex = nil
            }
        }
        .overlay(alignment: .topLeading) {
            let window = window
            if let hoverIndex, window.indices.contains(hoverIndex) {
                hoverOverlay(hoverIndex, point: window[hoverIndex])
            }
        }
        .accessibilityHidden(true) // 数值信息由主卡统计文字承载
    }

    // MARK: - 悬停读数

    /// 第 index 格的坐标(绘制与悬停同一式:x = i/(count-1)·width;0 值落 2% 底线)。
    private func point(at index: Int, value: Double, in size: CGSize) -> CGPoint {
        let normalized = min(max(value / domainMax, 0), 1)
        let fraction = max(Self.floorFraction, CGFloat(normalized))
        return CGPoint(
            x: size.width * CGFloat(index) / CGFloat(Self.pointCount - 1),
            y: size.height * (1 - fraction)
        )
    }

    private func hoverOverlay(_ index: Int, point sample: HistoryCurveHover.EdgePoint) -> some View {
        let center = point(at: index, value: sample.value, in: plotSize)
        let anchor = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
        let origin = ChartHoverGeometry.tooltipOrigin(
            anchor: anchor, size: tooltipSize, bounds: plotSize, gap: 6
        )
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(tint.opacity(0.7))
                .frame(width: 1, height: max(plotSize.height, 0))
                .position(x: center.x, y: plotSize.height / 2)
            AgentChartTooltip(
                // 补位点没有采样时刻:显示「—」,不编时间。
                title: sample.time.map { Self.timeFormatter.string(from: $0) } ?? "—",
                value: valueText(sample.value),
                swatch: tint
            )
            .onGeometryChange(for: CGSize.self) { $0.size } action: { tooltipSize = $0 }
            .opacity(tooltipSize == .zero ? 0 : 1)
            .offset(x: origin.x, y: origin.y)
        }
        .allowsHitTesting(false)
    }

    /// 主卡窗口只有几分钟,时刻到秒(静态缓存:DateFormatter 已知贵)。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for fraction in Self.gridLineFractions {
            let y = size.height * fraction
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        // 网格线:primary 的 8% 不透明度——primary 浅色是黑、深色是白,两种外观同一式子。
        context.stroke(grid, with: .color(Color.primary.opacity(0.08)), lineWidth: 1)

        let window = window
        guard !window.isEmpty else { return }
        let count = window.count
        let points = window.enumerated().map { point(at: $0.offset, value: $0.element.value, in: size) }

        var line = Path()
        line.move(to: points[0])
        for point in points.dropFirst() {
            line.addLine(to: point)
        }

        var area = line
        area.addLine(to: CGPoint(x: points[count - 1].x, y: size.height))
        area.addLine(to: CGPoint(x: points[0].x, y: size.height))
        area.closeSubpath()

        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [tint.opacity(0.32), tint.opacity(0)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        context.stroke(line, with: .color(tint), lineWidth: 2)
    }
}

// MARK: - tab 条 + 键盘接线

/// tab 条键盘接线:←/→ 切 tab(状态机在 MetricTabSelection 纯逻辑层,单测覆盖)。
/// 焦点随出现落在 tab 条上——弹窗打开 / 窗口进场即可用方向键;点击 tab 按钮
/// 或其他区域后焦点转移属正常 SwiftUI 行为,点击仍是主路径。
private struct MetricTabKeyboardModifier: ViewModifier {
    @Binding var selection: MetricTabSelection
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable(true)
            .focused($focused)
            .focusEffectDisabled()
            .onAppear { focused = true }
            .onKeyPress(.leftArrow) {
                selection.moveLeft()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                selection.moveRight()
                return .handled
            }
    }
}

extension View {
    /// 给 tab 条(或其容器)接上 ←/→ 键盘切换。
    func metricTabKeyboard(_ selection: Binding<MetricTabSelection>) -> some View {
        modifier(MetricTabKeyboardModifier(selection: selection))
    }
}

/// 弹窗顶部的图标页签条:每枚只有符号没有文字(13pt medium,槽最小高 26、槽间距
/// 4),提示与无障碍标签用页签标题。选中 = 该页强调色 15% 胶囊底 + 强调色图标,
/// 未选中 = secondary 图标;渲染序 = 展示轴(`MetricTabSelection.axis`,无电池机器
/// 不含电池页)。槽位单行满宽等分:弹窗内容区 332pt 定宽而页签枚数随机器不同,
/// 等分下枚数再多只收窄不溢出,与主窗口工具栏「720 预算优先,不触发溢出菜单」
/// 同一原则。←/→ 切页的键盘接线由 `metricTabKeyboard` 给。
struct MetricIconTabBar: View {
    @Binding var selection: MetricTabSelection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(selection.axis) { tab in
                let isSelected = selection.current == tab
                Button {
                    selection.current = tab
                } label: {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .foregroundStyle(isSelected ? tab.accent.accentColor : Color.secondary)
                        .background(
                            isSelected ? tab.accent.accentColor.opacity(0.15) : Color.clear,
                            in: .capsule
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(tab.title)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .metricTabKeyboard($selection)
    }
}

/// 主窗口药丸 tab:通用 `PillTabBar` 的工具栏用法薄封装(用户拍板 2026-10-22
/// tab 收敛为通用组件)——未选中纯图标、选中图标+文字(P1 验收走查拍板:7 个
/// tab 后工具栏把中间某枚药丸的文字压缩成省略号,压缩只压一处、其余完好的怪象
/// 用"只让选中项带文字"根治,总量恒定不随窗口宽摆动);视觉配方在 PillTabBar
/// 一处(选中 = 强调色 15% 底 + 强调色前景,渲染序同展示轴),本封装只补上
/// ←/→ 键盘切换与工具栏玻璃底的首尾内距。
struct MetricPillTabBar: View {
    @Binding var selection: MetricTabSelection

    var body: some View {
        PillTabBar(
            selection.axis,
            selection: $selection.current,
            textVisibility: .selectedOnly
        ) { tab in
            // 清理 tab 取页内专属 Teal(2026-11-06 拍板:顶部 tab 与页内强调一致;
            // PulseCore 的 Metric 色表是各指标身份色不扩,覆写只在 app 层)。
            PillTabItem(
                title: tab.title,
                symbol: tab.symbolName,
                tint: tab == .cleaner ? Surface.cleanAccent : tab.accent.accentColor
            )
        }
        .metricTabKeyboard($selection)
        // 首尾药丸与系统玻璃底(inner 的胶囊容器)留出内距,不再贴边。
        .padding(.horizontal, 4)
    }
}

// MARK: - 指标 tab 主卡(工单 P0.6-05,参考文档 §2.3 / §2.4)

/// 指标 tab 主卡:左列 "当前" 标签 + 大数字(+ 状态 chip)+ 2×2 小统计;
/// 右列 56 点面积图。弹窗(compact)改竖排:数字行 / 面积图 / 四列统计。
/// 内容复用总览卡的 MetricCardModel——同一指标两处读数同源。
struct MetricMainCardView: View {
    let model: MetricCardModel
    var isCompact = false

    var body: some View {
        Group {
            if isCompact {
                compactBody
            } else {
                regularBody
            }
        }
        .cardShell(compact: isCompact, padded: false)
        .accessibilityElement(children: .combine)
    }

    private var regularBody: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                FigureText(value: model.figureValue, unit: model.figureUnit, size: FigureSize.main)
                if let chip = model.chip {
                    MetricChipView(chip: chip)
                }
                Spacer(minLength: 12)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: model.stats.count, by: 2)), id: \.self) { index in
                        GridRow {
                            statCell(model.stats[index])
                            if index + 1 < model.stats.count {
                                statCell(model.stats[index + 1])
                            }
                        }
                    }
                }
            }
            .frame(width: 200, alignment: .leading)
            AreaTrendChartView(
                values: model.trend,
                times: model.trendTimes,
                valueText: model.trendValueText,
                tint: model.tint,
                domainMax: model.domainMax
            )
            .frame(maxWidth: .infinity)
        }
        .frame(height: 176)
        .padding(16)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    FigureText(value: model.figureValue, unit: model.figureUnit, size: FigureSize.mainCompact)
                }
                Spacer()
                if let chip = model.chip {
                    MetricChipView(chip: chip)
                }
            }
            AreaTrendChartView(
                values: model.trend,
                times: model.trendTimes,
                valueText: model.trendValueText,
                tint: model.tint,
                domainMax: model.domainMax
            )
            .frame(height: 64)
            HStack(alignment: .top, spacing: 6) {
                ForEach(model.stats) { stat in
                    statCell(stat)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
    }

    private func statCell(_ stat: MetricCardStat) -> some View {
        StatValue(label: stat.label, value: stat.value, dot: stat.dot)
    }
}

// MARK: - 预览(spec 测试决策:图表与 tab 外观走预览 + 手动验收)

#Preview("面积图") {
    let series: [Double] = (0 ..< 56).map { i in
        let ramp = Double(i) / 55 * 60
        let wave = Double((i * 7) % 13) * 2.2
        return min(ramp + wave, 100)
    }
    return VStack(spacing: 12) {
        AreaTrendChartView(values: series)
            .frame(height: 84)
        AreaTrendChartView(values: [18])
            .frame(height: 84) // 单点:垫底线 + 一根平线
        AreaTrendChartView(values: [])
            .frame(height: 84) // 空:只剩网格
    }
    .padding(16)
    .frame(width: 340)
}

#Preview("tab 主卡") {
    let host = HostInfo(chipName: "Apple M4 Pro", coreCount: 12, physicalMemoryBytes: 51_539_607_552)
    let loadTrend: [Double] = (0 ..< 56).map { (i: Int) -> Double in
        let ramp = Double(i) / 55 * 50
        let wave = Double((i * 5) % 17) * 2
        return min(ramp + wave, 100)
    }
    let memory = MemoryBreakdown(
        totalBytes: 51_539_607_552, appBytes: 21_000_000_000, wiredBytes: 6_000_000_000,
        compressedBytes: 9_000_000_000, cachedBytes: 8_000_000_000, pressure: .warning
    )
    let cpu = MetricCardModel.cpu(
        breakdown: CPULoadBreakdown(total: 27, user: 19, system: 8),
        load: 27,
        statistics: SeriesStatistics(count: 12, average: 36, peak: 71, minimum: 4),
        trend: loadTrend
    )
    return VStack(spacing: 12) {
        MetricMainCardView(model: cpu)
        MetricMainCardView(model: .memory(memory, trend: [], host: host))
        MetricMainCardView(model: cpu, isCompact: true)
            .frame(width: 332)
    }
    .padding(16)
    .frame(width: 760)
    .background(Surface.window)
}

#Preview("tab 条") {
    @Previewable @State var selection = MetricTabSelection()
    return VStack(spacing: 16) {
        MetricIconTabBar(selection: $selection)
        MetricPillTabBar(selection: $selection)
        Text("当前:\(selection.current.title)")
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 340)
}
