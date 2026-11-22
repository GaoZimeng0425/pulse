import PulseCore
import SwiftUI

// 空间地图配色域(solid-split/02 步骤 1,自 CleanerSpaceMapView 的 SpaceMapSection
// 抽出;纯搬运零逻辑):分区异色取色、局部提饱和、两形态块/弧着色工厂。
// 悬停提亮的 hoverBoost 旭日绘制侧也在用,一并住这里(单一出处)。
enum SpaceMapPalette {
    /// 分区完全异色·鲜亮版(space-map-forms/03 三轮拍板:01 高饱和 0.75 被嫌「闹」,
    /// 02 同色系被毙,03 柔和 0.60 上线一天用户实报「发灰、想要鲜艳」——2026-11-11
    /// 折中 = 0.70 + 地图内局部提饱和 ×1.25,不动全 app 的 accent 令牌):顶层块按序
    /// 循环十个 accent 令牌,基色不透明度 0.70;旭日外环 = 父色 −0.13;hover +0.08
    /// 封顶 0.95;文字色 ≥0.5 白、其余墨。密封 = inkTertiary 0.5、「其他」= cardHigh
    /// 0.75 不变(灰系不提饱和,saturation 对其无效果)。
    static let sectionColors: [Color] = [
        Metric.cpu, .memory, .network, .battery, .gpu,
        .sensors, .sound, .bluetooth, .containers, .disk,
    ].map(\.accentColor)

    /// 地图内局部提饱和(三轮拍板 2026-11-11):`Color.saturation` 是 View 修饰符,
    /// 色域内提饱和要经 NSColor 走 HSB——s ×1.25 封顶 1、亮度不动;灰系(s≈0)
    /// 原样返回。必须在**取色点**做(动态色按当前外观解析);定义时烤色会把深浅
    /// 双值固定在一个外观里,外观切换颜色不跟。
    static func vivid(_ color: Color) -> Color {
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // NSColor.getHue 不回传成败(iOS 的 UIColor 版才回 Bool);上面已强转
        // deviceRGB,HSB 换算恒可,出参必被写。
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(
            hue: Double(h),
            saturation: Double(min(s * 1.25, 1)),
            brightness: Double(b),
            opacity: Double(a)
        )
    }

    static let sectionBaseOpacity: Double = 0.70
    static let sectionChildStep: Double = 0.13
    static let hoverBoost: Double = 0.08

    struct BlockFill {
        let color: Color
        let opacity: Double
        let textColor: Color
    }

    static func blockFill(
        node: SpaceMapNode,
        rank: Int,
        isHovered: Bool
    ) -> BlockFill {
        let base = if node.isSealed {
            BlockFill(color: Surface.inkTertiary, opacity: 0.5, textColor: .primary)
        } else if node.isAggregate {
            BlockFill(color: Surface.cardHigh, opacity: 0.75, textColor: .primary)
        } else {
            BlockFill(
                color: vivid(sectionColors[rank % sectionColors.count]),
                opacity: sectionBaseOpacity,
                textColor: sectionBaseOpacity >= 0.5 ? .white : .primary
            )
        }
        guard isHovered else { return base }
        return BlockFill(
            color: base.color,
            opacity: min(base.opacity + hoverBoost, 0.95),
            textColor: base.textColor
        )
    }

    struct ColoredArc {
        let arc: SunburstArc
        let color: Color
        let opacity: Double
    }

    static func coloredArcs(_ arcs: [SunburstArc]) -> [ColoredArc] {
        var result: [ColoredArc] = []
        var ring1Rank = 0
        var parentColor = vivid(sectionColors[0])
        for arc in arcs {
            if arc.node.isSealed {
                result.append(ColoredArc(arc: arc, color: Surface.inkTertiary, opacity: 0.5))
                continue
            }
            if arc.node.isAggregate {
                result.append(ColoredArc(arc: arc, color: Surface.cardHigh, opacity: 0.75))
                continue
            }
            if arc.ring == 1 {
                parentColor = vivid(sectionColors[ring1Rank % sectionColors.count])
                ring1Rank += 1
                result.append(ColoredArc(arc: arc, color: parentColor, opacity: sectionBaseOpacity))
            } else {
                result.append(ColoredArc(
                    arc: arc,
                    color: parentColor,
                    opacity: max(sectionBaseOpacity - sectionChildStep, 0.2)
                ))
            }
        }
        return result
    }
}
