import PulseCore
import SwiftUI

// MARK: - 占比 meter 条(工单 P0.6-02,参考文档 §3-3)

/// 占比 meter 条:6pt 圆头胶囊,轨道 = 强调色 14% 底、填充 = 强调色纯色,
/// 宽度 = 榜首归一占比。强调色(轨道/填充共用)由调用方注入:组卡取类别样式表的
/// accentColor(孤儿橙),进程行取 CPU 指标强调色。
///
/// **宽度不做过渡动画**(2026-10-29 用户拍板,DESIGN.md 排行卡节):条宽变化仅几个
/// 像素、体感为零,而 SwiftUI 每帧动画都要遍历整棵面板视图树——十几根条在 1s 档
/// 读数下几乎每秒都有越线,0.6s 缓动让帧钟持续运转,面板开期实测 36.5% vs 关动画
/// 8.4%(同面板运行时 A/B,popover-layout-loop/01)。读数到即重画一次。
struct MeterBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                Capsule()
                    .fill(tint)
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 6)
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
