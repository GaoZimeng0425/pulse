import Foundation

// MARK: - 空间地图布局(p4-cleaner/07 v2:Canvas 扇形替换为分层条形图)

//
// 用户拍板(2026-11-03):「不要扇形了,非常的卡顿」。
// 替换方案:分层水平条形图——单个 Canvas 一次 draw call(GPU 加速,零卡顿),
// 命中测试是 y 坐标线性反算(不依赖 SwiftUI 形状 hit test)。
// 布局纯值在 PulseCore:当前根的直接子项按字节比例分层,每层一行。

/// 条形图的一行(归一化 0-1 y 坐标 + 高度占比;渲染时乘实际尺寸)。
public struct SpaceMapBar: Sendable, Equatable {
    public var node: SpaceMapNode
    /// 归一化 y 起点(0 = 顶部)。
    public var y: Double
    /// 归一化高度占比。
    public var height: Double

    public init(node: SpaceMapNode, y: Double, height: Double) {
        self.node = node
        self.y = y
        self.height = height
    }
}

/// 分层水平条形图:当前根的直接子项从大到小、每项一行、高度按字节比例。
/// 最小行高护栏(默认 5%):太矮的尾部并入「其他」,保证可读可点。
public enum SpaceMapBarLayout {
    public static func layout(
        root: SpaceMapNode,
        maxChildren: Int = 14,
        minBarFraction: Double = 0.04
    ) -> [SpaceMapBar] {
        let sorted = root.children.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path
        }
        let total = sorted.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0, !sorted.isEmpty else { return [] }

        var kept: [SpaceMapNode] = []
        var otherBytes: Int64 = 0
        var otherCount = 0
        for (index, node) in sorted.enumerated() {
            let fraction = Double(node.bytes) / Double(total)
            if index < maxChildren, fraction >= minBarFraction {
                kept.append(node)
            } else {
                otherBytes += node.bytes
                otherCount += 1
            }
        }
        if otherCount > 0, otherBytes > 0 {
            kept.append(SpaceMapNode(
                name: "其他",
                path: "",
                bytes: otherBytes,
                isAggregate: true,
                mergedCount: otherCount
            ))
        }

        let keptTotal = kept.reduce(Int64(0)) { $0 + $1.bytes }
        guard keptTotal > 0 else { return [] }

        var bars: [SpaceMapBar] = []
        var y: Double = 0
        for node in kept {
            let fraction = Double(node.bytes) / Double(keptTotal)
            bars.append(SpaceMapBar(node: node, y: y, height: fraction))
            y += fraction
        }
        return bars
    }
}
