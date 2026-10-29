import Foundation

// meter 条显示迟滞(popover-layout-loop/01):占比条宽的幅值死区判定。
// 与徽标显示迟滞(BadgeDisplayHysteresis)同一口径,见 GLOSSARY「显示迟滞」;
// 区别在防的东西:徽标防数字翻动,这里防 0.6s 宽度缓动被 1s 档读数抖动
// 背靠背重启——排行卡 ~15 根条几乎总有动画在跑,帧钟不落,SwiftUI 逐帧
// 刷事务,面板开期 ~45% 单核 churn(sample 定谳 + debug.noAnimations
// 对照 A/B:开动画 44.9% / 关动画 ~10%)。死区滤掉抖动后,缓动只在
// 肉眼可见的跳变时跑一次,条上的 Vitals 同款缓动样式不回退。

/// 纯值判定:占比变化是否值得追平(值得才触发一次宽度缓动)。
/// 锚在**已显示值**上,显示误差上限恒为阈值、不随轮数累积。
public enum MeterDisplayHysteresis {
    /// 死区阈值(归一占比,0–1):3pp 条宽肉眼不可辨,又能滤掉 1s 档
    /// 读数的抖动。慢漂移不会被卡死——真实值离开已显示值 ≥ 该值即追。
    public static let deadbandFraction = 0.03

    public static func shouldRetarget(displayed: Double, incoming: Double) -> Bool {
        abs(incoming - displayed) >= deadbandFraction
    }
}
