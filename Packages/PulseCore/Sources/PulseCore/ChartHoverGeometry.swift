import CoreGraphics
import Foundation

/// 图表悬停几何(agent-tab/07):浮层定位、轴标签抽稀、最近点吸附。纯值,视图层
/// 只喂坐标与尺寸——热力墙与走势共用一套,避免两处各写一份估算钳位(06 时代
/// 浮层宽硬编码 132 估算、翻面靠魔数,是「别扭」的来源之一)。
public enum ChartHoverGeometry {
    /// 浮层左上角原点:默认在锚点(命中格 / 数据点)**正上方居中**、间隔 `gap`;
    /// 上方放不下翻到锚点下方;水平钳进 `[0, bounds.width − size.width]`,
    /// 比容器还宽时贴左缘。
    public static func tooltipOrigin(
        anchor: CGRect,
        size: CGSize,
        bounds: CGSize,
        gap: CGFloat
    ) -> CGPoint {
        let above = anchor.minY - gap - size.height
        let y = above >= 0 ? above : anchor.maxY + gap
        let maxX = max(bounds.width - size.width, 0)
        let x = min(max(anchor.midX - size.width / 2, 0), maxX)
        return CGPoint(x: x, y: y)
    }

    /// 轴标签抽稀步长:每个标签至少分到 `minSpacing` 宽;放得下全标则 1。
    /// 宽度退化(≤0)时只标一个(步长 = count)。
    public static func labelStride(count: Int, width: CGFloat, minSpacing: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        guard width > 0, minSpacing > 0 else { return count }
        let perLabel = width / CGFloat(count)
        return max(1, Int((minSpacing / perLabel).rounded(.up)))
    }

    /// 从末尾倒数按步长取标签下标(升序返回;末点 = 今天恒标)。
    public static func labelIndices(count: Int, stride step: Int) -> [Int] {
        guard count > 0 else { return [] }
        let safeStep = max(step, 1)
        return Swift.stride(from: count - 1, through: 0, by: -safeStep).reversed()
    }

    /// `xs` 中离 `target` 最近的下标(并列取靠前);空序列 nil。
    public static func nearestIndex(of target: Double, in xs: [Double]) -> Int? {
        xs.indices.min { abs(xs[$0] - target) < abs(xs[$1] - target) }
    }
}
