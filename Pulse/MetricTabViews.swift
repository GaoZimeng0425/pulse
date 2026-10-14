import SwiftUI
import Charts

// MARK: - 指标 tab 视图族(工单 P0.6-03)
// 内容模型(tab 展示什么)在 MetricTabModel(纯逻辑,单测覆盖);本文件只做
// SwiftUI 外观:面积趋势图(§3-2)、CPU 主卡、Memory by App 环形卡、两种 tab 条
// 与键盘 ←/→ 接线——按 spec 测试决策走预览 + 手动验收。

/// 面积折线图(参考文档 §3-2,详情 tab 主卡):56 点、线 tint 2px、线下
/// 梯度 tint 32%→0、4 条水平网格线(--line 口径)——无轴、无刻度、无标签。
/// 数据不足 56 点时左侧以 2% 垫底(与 strip 同口径),空序列只剩网格线,
/// 不出坏图。自绘 Canvas:与 StripChartView 同理由(省 Charts 轴开销,形态精确)。
struct AreaTrendChartView: View {
    /// 点数 = 参考文档 §3-2 的 56 点形态(缓冲窗口 ~60 点,取最近 56 个)。
    static let pointCount = 56
    /// 零值/垫底比例(§3-1 同款 2%)。
    private static let floorFraction: CGFloat = 0.02
    /// 4 条水平网格线(§3-2:y=8/37/66/96,约 25% 步进)。
    private static let gridLineFractions: [CGFloat] = [0.08, 0.37, 0.66, 0.96]

    /// 时间序采样值(旧 → 新)。
    let values: [Double]
    /// 线与面积色。
    var tint: Color
    /// 归一化上限(系统负载固定 0–100 语义域)。
    var domainMax: Double

    init(
        values: [Double],
        tint: Color = Metric.cpu.accentColor,
        domainMax: Double = 100
    ) {
        self.values = values
        self.tint = tint
        self.domainMax = domainMax
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        .accessibilityHidden(true) // 数值信息由主卡统计文字承载
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for fraction in Self.gridLineFractions {
            let y = size.height * fraction
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        // 网格线:--line 口径(浅色黑 8% / 深色白 10%),Color.primary.opacity 自适应。
        context.stroke(grid, with: .color(Color.primary.opacity(0.08)), lineWidth: 1)

        let count = Self.pointCount
        let window = Array(values.suffix(count))
        guard !window.isEmpty else { return }

        // 左垫底右对齐:不足 56 点时旧槽位 2% 垫底——刚启动只见网格与底线。
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let dataIndex = index - (count - window.count)
            let normalized: Double = dataIndex >= 0
                ? min(max(window[dataIndex] / domainMax, 0), 1)
                : 0
            let fraction = max(Self.floorFraction, CGFloat(normalized))
            let x = size.width * CGFloat(index) / CGFloat(count - 1)
            points.append(CGPoint(x: x, y: size.height * (1 - fraction)))
        }

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

/// 弹窗顶部图标 tab(工单 03,参考文档 §2.1:无文字、title 提示):
/// 选中态 = 该指标强调色 15% 胶囊 + 强调色图标(§1.1 选中 tab 配方)。
struct MetricIconTabBar: View {
    @Binding var selection: MetricTabSelection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MetricTab.allCases) { tab in
                let isSelected = selection.current == tab
                Button {
                    selection.current = tab
                } label: {
                    Image(systemName: tab.symbolName)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 32, height: 26)
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

/// 主窗口药丸文字 tab(工单 03,参考文档 §2.1 主窗口:图标+文字全圆药丸):
/// 选中态与图标 tab 同配方(强调色 15% 底 + 强调色前景)。
struct MetricPillTabBar: View {
    @Binding var selection: MetricTabSelection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MetricTab.allCases) { tab in
                let isSelected = selection.current == tab
                Button {
                    selection.current = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 11, weight: .medium))
                        Text(tab.title)
                    }
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .foregroundStyle(isSelected ? tab.accent.accentColor : Color.secondary)
                    .background(
                        isSelected ? tab.accent.accentColor.opacity(0.15) : Color.clear,
                        in: .capsule
                    )
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .metricTabKeyboard($selection)
    }
}

// MARK: - CPU tab 主卡(全尺寸走势图的归位处,工单 03 纠偏)

/// CPU tab 主卡(参考文档 §2.3 布局):左列"当前"标签 + 大数字 + 窗口均值/峰值
/// 统计对(01 从组卡收回的口径归位至此);右列 56 点面积图(系统 CPU 负载序列)。
/// <2 轮时面积图只剩网格与垫底线、统计对不显示——不出坏图。
struct CPULoadMainCardView: View {
    /// 当轮系统 CPU 负载(0–100)。
    let currentLoad: Double
    /// 窗口统计(nil = 首轮采样前);≥2 轮才显示均值/峰值对。
    let statistics: SeriesStatistics?
    /// 面积图数据(时间序,旧 → 新)。
    let trendValues: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("当前")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                loadFigure
                if let stats = statistics, stats.count >= 2 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("均值 \(PulseFormat.cpuPercent(stats.average))")
                        Text("峰值 \(PulseFormat.cpuPercent(stats.peak))")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 12)
            AreaTrendChartView(values: trendValues, tint: Metric.cpu.accentColor, domainMax: 100)
                .frame(height: 84)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前系统 CPU 负载 \(PulseFormat.cpuPercent(currentLoad))")
    }

    /// 大数字(§1.2 figure 规格):圆体加粗 + tabular + 负字距,单位小字基线对齐。
    private var loadFigure: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(PulseFormat.cpuPercentNumber(currentLoad))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .kerning(-0.7)
            Text("%")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Memory by App 环形卡(内存 tab,工单 03)

/// Memory by App 环形卡(参考文档 §2.2):单色梯度环形(内存强调色 100/83/66/49/32%,
/// "其他"段用中性抬升底)+ 环心全部组内存合计大数字 + 图例(应用图标 + 名称 + 数值 + 占比)。
/// 分段数据由 MetricTabContent 折叠(纯逻辑,单测覆盖);空组/全零内存走安静空态。
struct MemoryRingCardView: View {
    let segments: [MemoryRingSegment]
    /// 全部组内存合计(环心大数字)。
    let totalBytes: UInt64

    /// 单色梯度档位(§2.2 Memory by App:tint 与 card 按 100/83/66/49% 混,
    /// 本表扩到第五档覆盖 top-5;"其他"段单独配色)。
    private static let segmentOpacities: [Double] = [1.0, 0.83, 0.66, 0.49, 0.32]

    private var tint: Color { Metric.memory.accentColor }

    var body: some View {
        if segments.isEmpty {
            Text("暂无内存数据")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(.quaternary, in: .rect(cornerRadius: 12))
        } else {
            HStack(spacing: 14) {
                ring
                legend
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: 12))
        }
    }

    /// 环形主体 + 环心大数字(§2.2:环心 = 总量 + 两字说明)。
    private var ring: some View {
        Chart(segments) { segment in
            SectorMark(
                angle: .value("内存", segment.bytes),
                innerRadius: .ratio(0.72),
                angularInset: 1.2
            )
            .cornerRadius(2.5)
            .foregroundStyle(fill(for: segment))
        }
        .frame(width: 116, height: 116)
        .overlay {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    let figure = PulseFormat.memoryFigure(totalBytes)
                    Text(figure.value)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .kerning(-0.3)
                    Text(figure.unit)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text("全部组")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityHidden(true) // 数值与名称由图例文字承载
    }

    /// 图例:图标 + 名称 + 内存值 + 占比(§2.2 每段图例带应用小图标)。
    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                HStack(spacing: 6) {
                    segmentIcon(segment)
                        .frame(width: 16, height: 16)
                    Text(segment.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(PulseFormat.memory(segment.bytes))
                        .monospacedDigit()
                    Text("\(Int((segment.fraction * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .layoutPriority(-1)
                }
                .font(.caption)
            }
        }
    }

    /// 段填充色:top-5 单色梯度;"其他"= 中性抬升底(card-hi 的本地近似)。
    private func fill(for segment: MemoryRingSegment) -> Color {
        guard !segment.isOther,
              let index = segments.firstIndex(where: { $0.id == segment.id }),
              index < Self.segmentOpacities.count
        else { return Color.primary.opacity(0.12) }
        return tint.opacity(Self.segmentOpacities[index])
    }

    /// 图例小图标:App 组用真实应用图标;其余类别用 SF Symbol;"其他"用省略号。
    @ViewBuilder
    private func segmentIcon(_ segment: MemoryRingSegment) -> some View {
        if let bundlePath = segment.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundlePath))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if segment.isOther {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: segment.category?.cardStyle.symbolName ?? "shippingbox")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 预览(spec 测试决策:图表与 tab 外观走预览 + 手动验收)

#Preview("面积图") {
    let series: [Double] = (0..<56).map { i in
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

#Preview("CPU 主卡 + 内存环形卡") {
    let groups = [
        ProcessGroup(
            id: "bundle:code", name: "Code", category: .app,
            bundlePath: "/Applications/Xcode.app", processes: [], cpuPercent: 88, memoryBytes: 5_200_000_000
        ),
        ProcessGroup(
            id: "bundle:browser", name: "浏览器", category: .app,
            bundlePath: "/Applications/Safari.app", processes: [], cpuPercent: 40, memoryBytes: 3_100_000_000
        ),
        ProcessGroup(id: "p", name: "proj @ wt", category: .project, bundlePath: nil, processes: [], cpuPercent: 445, memoryBytes: 2_400_000_000),
        ProcessGroup(id: "o", name: "孤儿进程", category: .orphan, bundlePath: nil, processes: [], cpuPercent: 7, memoryBytes: 30_000_000),
    ]
    let memoryContent = MetricTabContent.build(groups: groups, tab: .memory)
    let loadTrend: [Double] = (0..<56).map { i in
        let ramp = Double(i) / 55 * 50
        let wave = Double((i * 5) % 17) * 2
        return min(ramp + wave, 100)
    }

    return VStack(spacing: 12) {
        CPULoadMainCardView(
            currentLoad: 27,
            statistics: SeriesStatistics(count: 12, average: 36, peak: 71, minimum: 4),
            trendValues: loadTrend
        )
        MemoryRingCardView(segments: memoryContent.memorySegments, totalBytes: memoryContent.memoryTotalBytes)
        MemoryRingCardView(segments: [], totalBytes: 0) // 空态
    }
    .padding(16)
    .frame(width: 340)
}

#Preview("tab 条") {
    @Previewable @State var selection = MetricTabSelection()
    return VStack(spacing: 16) {
        MetricIconTabBar(selection: $selection)
        MetricPillTabBar(selection: $selection)
        Text("当前:\(selection.current.title)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 340)
}
