import SwiftUI

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
    /// 归一化上限(系统负载固定 0–100 语义域;内存 = 物理总量)。
    var domainMax: Double

    init(
        values: [Double],
        tint: Color = Metric.cpu.accentColor,
        domainMax: Double = 100
    ) {
        self.values = values
        self.tint = tint
        self.domainMax = max(domainMax, 1)
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
/// 渲染序 = 选中态的展示轴(工单 02:无电池机器不含电池页)。
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
/// 选中态与图标 tab 同配方(强调色 15% 底 + 强调色前景);渲染序同展示轴。
struct MetricPillTabBar: View {
    @Binding var selection: MetricTabSelection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(selection.axis) { tab in
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
                    // P1 起 tab 到 6-7 个:水平内距 12→9,保 720 最小窗宽不裁切。
                    .padding(.horizontal, 9)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: isCompact ? 12 : 18))
        .accessibilityElement(children: .combine)
    }

    private var regularBody: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                FigureText(value: model.figureValue, unit: model.figureUnit, size: 44)
                if let chip = model.chip {
                    MetricChipView(chip: chip)
                }
                Spacer(minLength: 12)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
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
            AreaTrendChartView(values: model.trend, tint: model.tint, domainMax: model.domainMax)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 176)
        .padding(20)
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    FigureText(value: model.figureValue, unit: model.figureUnit, size: 30)
                }
                Spacer()
                if let chip = model.chip {
                    MetricChipView(chip: chip)
                }
            }
            AreaTrendChartView(values: model.trend, tint: model.tint, domainMax: model.domainMax)
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let dot = stat.dot {
                    Circle().fill(dot).frame(width: 6, height: 6)
                }
                Text(stat.label)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            Text(stat.value)
                .font(.system(size: isCompact ? 12 : 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
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

#Preview("tab 主卡") {
    let host = HostInfo(chipName: "Apple M4 Pro", coreCount: 12, physicalMemoryBytes: 51_539_607_552)
    let loadTrend: [Double] = (0..<56).map { (i: Int) -> Double in
        let ramp: Double = Double(i) / 55 * 50
        let wave: Double = Double((i * 5) % 17) * 2
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
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    .padding(16)
    .frame(width: 340)
}
