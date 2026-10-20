import SwiftUI

// MARK: - 占比 meter 条(工单 P0.6-02,参考文档 §3-3)

/// meter 归一化(纯逻辑):占比条"按当前榜单榜首归一"的取值口径。
/// 榜首(最大值)= 满条;榜首 ≤ 0(空载/空榜/首轮采样前)一律 0,
/// 不画填充也不除零;越界值夹紧到 0…1。单测见 MeterBarTests。
enum MeterNormalization {
    static func fraction(_ value: Double, leader: Double) -> Double {
        guard leader > 0 else { return 0 }
        return min(max(value / leader, 0), 1)
    }
}

/// 占比 meter 条:6pt 圆头胶囊,轨道 = 强调色 14% 底、填充 = 强调色纯色,
/// 宽度 = 榜首归一占比;宽度过渡用 Vitals 同款缓动
/// (0.6s cubic-bezier(.2,.7,.2,1),参考文档 §3-3)。
/// 强调色(轨道/填充共用)由调用方注入:组卡取类别样式表的 accentColor
/// (孤儿橙),进程行取 CPU 指标强调色。
struct MeterBar: View {
    let fraction: Double
    let tint: Color

    /// Vitals 同款缓动:0.6s cubic-bezier(.2,.7,.2,1)。
    private static let widthAnimation: Animation = .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.6)

    /// 实际绘制的占比:跟随 fraction,但在**独立的**动画事务里追平。
    /// 不能在 fraction 变化的那一轮直接挂动画(`.animation(_:value:)` /
    /// 作用域动画都不行):榜单换序与 fraction 变化同轮发生,那一轮的
    /// 动画事务会连带条的位置变化——条从旧行位置滑到新行,卡片其余部分
    /// 却瞬移(实机 bug)。onChange 晚于本轮更新触发,换序已无动画落定,
    /// 此时再 withAnimation 只动宽度。
    @State private var displayedFraction: Double

    init(fraction: Double, tint: Color) {
        self.fraction = fraction
        self.tint = tint
        _displayedFraction = State(initialValue: fraction)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * displayedFraction)
            }
        }
        .frame(height: 6)
        .onChange(of: fraction) { _, newValue in
            withAnimation(Self.widthAnimation) {
                displayedFraction = newValue
            }
        }
        // 占比信息已由行内数字文本承载(无障碍读数不重复),条本身按装饰处理。
        .accessibilityHidden(true)
    }
}

#Preview("meter 条(榜首归一)") {
    let tint = Metric.cpu.accentColor
    return VStack(alignment: .leading, spacing: 10) {
        MeterBar(fraction: MeterNormalization.fraction(445, leader: 445), tint: tint)
        MeterBar(fraction: MeterNormalization.fraction(89, leader: 445), tint: tint)
        MeterBar(fraction: MeterNormalization.fraction(12, leader: 445), tint: tint)
        MeterBar(fraction: MeterNormalization.fraction(0, leader: 445), tint: tint)
        MeterBar(fraction: MeterNormalization.fraction(30, leader: 0), tint: Surface.warning)
    }
    .padding(16)
    .frame(width: 280)
}
