import PulseCore
import SwiftUI

// 空间地图配色域(solid-split/02):分区异色取色、地图内局部提饱和、方块 / 旭日两形态的
// 着色工厂。两形态同一套出口,悬停提亮也在这里。
enum SpaceMapPalette {
    /// 分区完全异色(space-map-forms/03):顶层块按序循环十个指标 accent,换分区必须
    /// 换色——不退回同色系深浅,也不靠压低饱和度求柔和(会发灰)。
    static let sectionColors: [Color] = [
        Metric.cpu, .memory, .network, .battery, .gpu,
        .sensors, .sound, .bluetooth, .containers, .disk,
    ].map(\.accentColor)

    /// 地图内局部提饱和:鲜亮只加在地图上,不动全 app 的 accent 令牌。`Color.saturation`
    /// 是 View 修饰符,色域内提饱和要经 NSColor 走 HSB——s ×1.25 封顶 1、亮度不动;灰系
    /// (s≈0)原样返回,所以密封块与「其他」不受影响。必须在**取色点**做(动态色按当前
    /// 外观解析);定义时烤色会把深浅双值固定在一个外观里,外观切换颜色不跟。
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

    // 基色不透明度;外环比父色淡一档(读者靠深浅认父子);悬停提亮量。
    static let sectionBaseOpacity: Double = 0.70
    static let sectionChildStep: Double = 0.13
    static let hoverBoost: Double = 0.08

    struct BlockFill {
        let color: Color
        let opacity: Double
        let textColor: Color
    }

    /// 方块着色。密封块与「其他」合成块不可下钻,走灰系,与可下钻块区分开。
    /// 文字色的判据(底色不透明度 ≥0.5 用白、否则用墨)与视图侧弧内文字同一口径。
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

    /// 旭日着色:内环每支一色,外环用父色淡一档。依赖布局按「父弧在前、其子弧紧随」
    /// 的顺序产出——外环靠上一个内环弧认父色。
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
