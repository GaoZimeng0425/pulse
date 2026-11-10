import Foundation

// MARK: - 矩形树图布局(p4-cleaner/07 v3:用户拍板 treemap)

//
// 空间地图从旭日图(卡顿+命中不可靠)→ 分层条形图(过渡)→ treemap(用户选定)。
// 布局纯值在 PulseCore:当前根的直接子项按字节比例铺满归一化矩形,
/// squarify 算法(Bruls et al. 2000)追求接近正方形的宽高比。
// app:单个 Canvas 一次 draw call 渲染全部矩形;命中 = rect.contains(点)。

/// treemap 的一个矩形(归一化 0-1 坐标;渲染时乘实际尺寸)。
public struct TreemapRect: Sendable, Equatable {
    public var node: SpaceMapNode
    public var rect: CGRect

    public init(node: SpaceMapNode, rect: CGRect) {
        self.node = node
        self.rect = rect
    }
}

/// squarify treemap:子项按字节比例铺满一个矩形,追求最佳宽高比。
/// 只布一层(当前根的直接子项);下钻后以选中项为新根重新布局。
public enum TreemapLayout {
    /// - Parameters:
    ///   - root: 当前钻入根。
    ///   - maxChildren: 超出的尾部并入「其他」合成块。
    ///   - minFraction: 低于此占比的尾部并入「其他」。默认 1% = 最小可见块
    ///     (space-map-forms/02 用户拍板:画出来的块都要够看清)。
    public static func layout(
        root: SpaceMapNode,
        maxChildren: Int = 16,
        minFraction: Double = 0.01
    ) -> [TreemapRect] {
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
            if index < maxChildren, fraction >= minFraction {
                kept.append(node)
            } else {
                otherBytes += node.bytes
                otherCount += 1
            }
        }
        if otherCount > 0, otherBytes > 0 {
            kept.append(SpaceMapNode(
                name: "其他", path: "", bytes: otherBytes,
                isAggregate: true, mergedCount: otherCount
            ))
        }

        let keptTotal = kept.reduce(Int64(0)) { $0 + $1.bytes }
        guard keptTotal > 0 else { return [] }

        let fractions = kept.map { Double($0.bytes) / Double(keptTotal) }
        let rects = squarify(items: kept, fractions: fractions)

        return zip(kept, rects).map { TreemapRect(node: $0.0, rect: $0.1) }
    }

    // MARK: - squarify 内核

    /// 返回每个 item 的归一化矩形,面积严格按 fraction 分配。
    private static func squarify(items: [SpaceMapNode], fractions: [Double]) -> [CGRect] {
        var result: [CGRect] = []
        var remainingStart = 0
        var remainingFraction = fractions.reduce(0, +)
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)

        while remainingStart < items.count, remainingFraction > 0 {
            let isWide = rect.width >= rect.height
            let shorter = isWide ? rect.height : rect.width
            let longer = isWide ? rect.width : rect.height
            guard shorter > 0.001, longer > 0.001 else { break }

            // 单条带:沿短边铺,逐个加直到最差宽高比恶化即停
            var stripCount = 0
            var stripFrac = 0.0 // strip 占总量的份额(非占剩余的)
            var bestWorst = Double.infinity

            for i in remainingStart ..< items.count {
                let candidateFrac = stripFrac + fractions[i]
                let candidateThickness = (candidateFrac / remainingFraction) * longer
                guard candidateThickness > 0.0001 else { continue }

                var worst = 0.0
                for j in remainingStart ... i {
                    let itemFrac = fractions[j] / candidateFrac
                    let extent = itemFrac * shorter
                    let ratio = max(
                        candidateThickness / max(extent, 0.0001),
                        max(extent, 0.0001) / candidateThickness
                    )
                    worst = max(worst, ratio)
                }

                if stripCount == 0 || worst <= bestWorst {
                    stripCount += 1
                    stripFrac = candidateFrac
                    bestWorst = worst
                } else {
                    break
                }
            }

            guard stripCount > 0 else { break }

            // 铺条带:厚度沿长边、逐项沿短边
            let thickness = (stripFrac / remainingFraction) * longer
            var offset: Double = 0
            for i in remainingStart ..< remainingStart + stripCount {
                let itemExtent = (fractions[i] / stripFrac) * shorter
                let itemRect = if isWide {
                    CGRect(x: rect.minX, y: rect.minY + offset, width: thickness, height: itemExtent)
                } else {
                    CGRect(x: rect.minX + offset, y: rect.minY, width: itemExtent, height: thickness)
                }
                result.append(itemRect)
                offset += itemExtent
            }

            // 剩余矩形收缩
            if isWide {
                rect = CGRect(
                    x: rect.minX + thickness,
                    y: rect.minY,
                    width: max(rect.width - thickness, 0),
                    height: rect.height
                )
            } else {
                rect = CGRect(
                    x: rect.minX,
                    y: rect.minY + thickness,
                    width: rect.width,
                    height: max(rect.height - thickness, 0)
                )
            }

            remainingStart += stripCount
            remainingFraction -= stripFrac
        }

        // 兜底:没铺到的项给零矩形(不该发生,防越界)
        while result.count < items.count {
            result.append(.zero)
        }
        return result
    }
}
