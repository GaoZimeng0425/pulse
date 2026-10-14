import SwiftUI

// MARK: - strip 微柱走势图(工单 P0.6-01)

/// strip 微柱走势图,参照 vitals-style-reference §3.1 的 44 柱形态:
/// 固定 44 个槽位,**最新采样在最右**,每轮采样柱条整体左移;数据不足的
/// 旧槽位以 2% 垫底(官网 demo 同款),因此刚启动(<2 轮)只剩轨道与垫底柱,
/// 不会出现坏图(工单验收口径)。无轴、无标签——纯"形状即数据"。
///
/// 自绘选 Canvas 而非 Swift Charts:340pt 弹窗内组卡多、每卡一图,
/// Charts 每图都有轴/布局开销,Canvas 一次 draw 最省(参考文档 §5 同推荐)。
/// 采样节奏 1–5s 一轮,无需柱高过渡动画,重绘即最新。
///
/// 工单 P0.6-03 组卡瘦身:补 compact 变体(§3.1 变体条款:紧凑行 26×14、
/// gap-px、无轨道)——13 槽、1px 间距、透明底,给组卡行内的迷你微图用。
///
/// tint 缺省 = CPU 指标强调色(P0.6-02:替换 01 的占位蓝 StripChartPalette;
/// 调用方有更强语境时显式传色——组卡传当前口径的强调色,孤儿橙)。
struct StripChartView: View {
    /// 形态:full = 44 柱 + 9% 轨道;compact = 13 柱 + 1px 间距 + 无轨道。
    enum Style {
        case full
        case compact

        /// 槽位与间距随形态取值(§3.1 主形态 / 变体条款)。
        var slotCount: Int {
            switch self {
            case .full: 44
            case .compact: 13
            }
        }

        var barSpacing: CGFloat {
            switch self {
            case .full: 2
            case .compact: 1 // HTML 变体:gap-px
            }
        }

        var showsTrack: Bool { self == .full }
    }

    /// 零值/空槽的垫底高度(§3.1 "旧值以 2% 垫底")。
    private static let floorFraction: CGFloat = 0.02
    /// 柱条上圆角(§3.1:仅上圆角 2px)。
    private static let barCornerRadius: CGFloat = 2

    /// 时间序采样值(旧 → 新);为空时只剩轨道与垫底柱。
    let values: [Double]
    /// 柱条与轨道色。
    var tint: Color
    /// 归一化上限:有语义域时给定(系统负载固定 0–100),
    /// nil = 按窗口内最大值归一(组 CPU% 可 >100%,无固定域)。
    var domainMax: Double?
    /// 形态(工单 03:组卡行内微图用 .compact;调用方以 frame 约定 26×14)。
    var style: Style = .full

    init(
        values: [Double],
        tint: Color = Metric.cpu.accentColor,
        domainMax: Double? = nil,
        style: Style = .full
    ) {
        self.values = values
        self.tint = tint
        self.domainMax = domainMax
        self.style = style
    }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, size: size)
        }
        // 轨道:tint 9%(§1.1 color-mix 口径),圆角 8;compact 变体无轨道。
        .background(
            style.showsTrack ? AnyShapeStyle(tint.opacity(0.09)) : AnyShapeStyle(.clear),
            in: .rect(cornerRadius: 8)
        )
        .accessibilityHidden(true) // 数值信息由统计行的文字承载
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let slots = style.slotCount
        let spacing = style.barSpacing
        let barWidth = max(1, (size.width - spacing * CGFloat(slots - 1)) / CGFloat(slots))

        // 右对齐取最近 N 个;无语义域时窗口最大值归一(全零序列退化为垫底柱)。
        let window = Array(values.suffix(slots))
        let normalizer: Double = domainMax ?? max(window.max() ?? 0, 1)

        for slot in 0..<slots {
            let dataIndex = slot - (slots - window.count)
            let fraction: CGFloat
            if dataIndex >= 0 {
                let v = window[dataIndex] / normalizer
                fraction = max(Self.floorFraction, CGFloat(min(max(v, 0), 1)))
            } else {
                fraction = Self.floorFraction
            }
            let barHeight = fraction * size.height
            let rect = CGRect(
                x: CGFloat(slot) * (barWidth + spacing),
                y: size.height - barHeight,
                width: barWidth,
                height: barHeight
            )
            let radius = min(Self.barCornerRadius, barWidth / 2, barHeight / 2)
            let bar = UnevenRoundedRectangle(
                topLeadingRadius: radius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: radius
            )
            .path(in: rect)
            context.fill(bar, with: .color(tint))
        }
    }
}

#Preview("44 柱形态") {
    VStack(spacing: 12) {
        // 满窗:形态即数据(最新在右)。手写锯齿序列,预览形态稳定。
        StripChartView(values: (0..<44).map { i in
            let ramp = Double(i) / 43 * 80
            let saw = Double(i % 7) * 6
            return min(ramp + saw, 100)
        })
        .frame(height: 36)
        // 单点:一根柱 + 垫底槽(空窗口不坏图)。
        StripChartView(values: [42])
            .frame(height: 36)
        // 空序列:只剩轨道。
        StripChartView(values: [])
            .frame(height: 36)
        // 系统负载:固定 0–100 语义域。
        StripChartView(
            values: [12, 18, 15, 40, 62, 55, 30, 22],
            domainMax: 100
        )
        .frame(height: 14)
        // compact 变体(工单 03 组卡瘦身):26×14、1px 间距、无轨道。
        let ramp: [Double] = (0..<13).map { index in Double(index) * 6.5 }
        HStack(spacing: 24) {
            StripChartView(values: ramp, style: .compact)
                .frame(width: 26, height: 14)
            StripChartView(values: [42], style: .compact)
                .frame(width: 26, height: 14)
            StripChartView(values: [], style: .compact)
                .frame(width: 26, height: 14)
        }
    }
    .padding(16)
    .frame(width: 308)
}
