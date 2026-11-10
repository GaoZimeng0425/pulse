import Foundation

// MARK: - 空间地图(p4-cleaner/07):扫描树 → 显示树 → 两环旭日几何(纯值)

//
// 地图层三件事,全部无 IO、可合成夹具测试(spec「旭日图两环几何为纯值计算」):
//
// 1. firmlink 提升(真机探针 2026-11-01):根目录原始枚举序里 System 排在
//    Users/Applications/private/opt 之前,深度优先先在 /System/Volumes/Data/*
//    抢占 (dev, fileID),顶层 firmlink 全被记 double-visit 跳过——扫描树里
//    用户数据整棵埋在 System 之下。显示树把 Data 的直接子目录拼回顶层、路径
//    改写为规范名(/System/Volumes/Data/Users → /Users),System 余量
//    (SSV 文件 + Preboot/VM/Update 等其他系统卷)折叠为单个密封块。
//    只动展示路径,不动扫描语义与去重账(那属于 02 票的引擎)。
// 2. 密封折叠(/usr/share/firmlinks + mount 探针):/System(余量)、/bin、/sbin
//    都在只读密封系统卷上——不可删、不可下钻,地图上折成单块;点击解释交给视图。
// 3. 弧几何:内环 = 当前根的子辈、外环 = 孙辈;叶子(无目录子辈)与密封块延伸
//    占满外环;份额过小的尾部并入「其他」;百分比分母 = 整卷树(悬浮口径与环内
//    归一化是两个数,不混用)。

/// 空间地图显示树节点(由 `SpaceNode` 变换而来:目录粒度、路径规范化、密封折叠)。
public struct SpaceMapNode: Sendable, Equatable, Identifiable {
    public var id: String {
        path.isEmpty ? name : path
    }

    /// 展示名;根为 "/" 时显示「整卷」。
    public var name: String
    /// 规范展示路径(提升后的顶层 + 全部子孙;「其他」合成块为空串)。
    public var path: String
    /// 实际占用(GLOSSARY「实际占用」;= SpaceNode.accountedBytes)。
    public var bytes: Int64
    /// 子树有目录没扫到(部分扫描,如实上屏)。
    public var isPartial: Bool
    /// 系统密封区(只读,不可下钻、不可删)。
    public var isSealed: Bool
    /// 「其他」合成块(小于阈值的尾部合并;不可下钻,悬浮展示合并项数)。
    public var isAggregate: Bool
    /// isAggregate 时被合并的目录数。
    public var mergedCount: Int
    public var children: [SpaceMapNode]

    public init(
        name: String,
        path: String,
        bytes: Int64,
        isPartial: Bool = false,
        isSealed: Bool = false,
        isAggregate: Bool = false,
        mergedCount: Int = 0,
        children: [SpaceMapNode] = []
    ) {
        self.name = name
        self.path = path
        self.bytes = bytes
        self.isPartial = isPartial
        self.isSealed = isSealed
        self.isAggregate = isAggregate
        self.mergedCount = mergedCount
        self.children = children
    }
}

public extension SpaceMapNode {
    /// 可下钻 = 有目录子辈,且既非密封块也非「其他」合成块。
    var isDrillable: Bool {
        !isSealed && !isAggregate && !children.isEmpty
    }

    /// 按路径分量下钻(与 SpaceNode.descendant(atPath:) 同算法:逐层按名精确匹配)。
    func descendant(atPath path: String) -> SpaceMapNode? {
        let target = PathNormalization.normalize(path)
        let base = PathNormalization.normalize(self.path)
        if target == base {
            return self
        }
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        var node = self
        for component in target.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = node.children.first(where: { $0.name == component }) else { return nil }
            node = next
        }
        return node
    }

    /// 面包屑链:根 → … → 目标节点;路径不在树内返回 nil(不猜)。
    static func breadcrumb(to path: String, in root: SpaceMapNode) -> [SpaceMapNode]? {
        guard let target = root.descendant(atPath: path) else { return nil }
        var chain = [root]
        var node = root
        let targetPath = PathNormalization.normalize(path)
        let base = PathNormalization.normalize(root.path)
        let prefix = base == "/" ? "/" : base + "/"
        guard targetPath.hasPrefix(prefix) else { return chain }
        for component in targetPath.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = node.children.first(where: { $0.name == component }) else { break }
            chain.append(next)
            node = next
        }
        return chain.last == target || chain.contains(target) ? chain : nil
    }
}

/// 一个非数据系统卷的卷级口径摘要(方案 A:只读卷不再逐文件走,statfs 一个数)。
public struct SpaceMapVolumeSummary: Sendable, Equatable {
    public var label: String
    /// (f_blocks − f_bfree) × f_bsize,卷级口径(与文件级 PRIVATESIZE 不同源,拼图如实并列)。
    public var usedBytes: Int64

    public init(label: String, usedBytes: Int64) {
        self.label = label
        self.usedBytes = usedBytes
    }
}

/// 扫描树 → 显示树:Data firmlink 提升 + 密封折叠 + 零字节裁剪 + 大到小排序。
public enum SpaceMapTree {
    /// Data 卷挂载点(firmlink 目标;提升基准路径;也是生产扫描根——方案 A 后
    /// 扫描只走 Data 卷,系统/其他只读卷以 `SpaceMapVolumeSummary` 卷级注入)。
    public static let dataVolumePath = "/System/Volumes/Data"
    /// 密封系统卷上的顶层目录(只读;折叠为单块)。/System 走「提升 + 余量折叠」特例。
    public static let sealedPaths = ["/System", "/bin", "/sbin"]

    public static func buildTrees(from trees: [SpaceNode]) -> [SpaceMapNode] {
        trees.map { build(from: $0) }
    }

    public static func build(
        from root: SpaceNode,
        dataVolumePath: String = SpaceMapTree.dataVolumePath,
        sealedPaths: [String] = SpaceMapTree.sealedPaths,
        sealedVolumes: [SpaceMapVolumeSummary] = []
    ) -> SpaceMapNode {
        let dataPrefix = normalizedPrefix(dataVolumePath)
        // 方案 A 主路:树根本身就是 Data 卷(roots=[dataVolumePath] 的扫描产物)——
        // 子目录剥前缀即规范路径,不做提升;系统/其他只读卷按卷级字节注入为单块。
        if PathNormalization.normalize(root.path) == dataPrefix {
            return buildFromDataRoot(
                root,
                dataPrefix: dataPrefix,
                sealedPaths: sealedPaths,
                sealedVolumes: sealedVolumes
            )
        }

        let data = root.descendant(atPath: dataPrefix)
        var children: [SpaceMapNode] = []

        // ① Data 提升:其直接子目录拼回顶层,路径改写为规范名(/Users、/Applications…)。
        if let data {
            for child in data.children where child.kind == .directory {
                if let mapped = mapChild(child, dataPrefix: dataPrefix, sealedPaths: sealedPaths) {
                    children.append(mapped)
                }
            }
        }

        for child in root.children where child.kind == .directory {
            // ② System 特例:内容已提升,余量(SSV + Preboot/VM/Update 等系统卷)折为密封块。
            if child.path == "/System", let data {
                let remainder = child.accountedBytes - data.accountedBytes
                if remainder > 0 || child.isPartial {
                    children.append(SpaceMapNode(
                        name: "系统(密封)",
                        path: "/System",
                        bytes: max(0, remainder),
                        isPartial: child.isPartial,
                        isSealed: true
                    ))
                }
                continue
            }
            if let mapped = mapChild(child, dataPrefix: nil, sealedPaths: sealedPaths) {
                children.append(mapped)
            }
        }
        // ③ 卷级注入(方案 A 规范根扫描走这条:树里没有 System,只读系统卷全靠摘要;
        //    树里有 System 的旧形态 sealedVolumes 为空,不会双计)。
        if let sealed = sealedVolumeNode(sealedVolumes) {
            children.append(sealed)
        }

        return SpaceMapNode(
            name: root.name == "/" ? "整卷" : root.name,
            path: PathNormalization.normalize(root.path),
            bytes: root.accountedBytes + sealedVolumes.reduce(Int64(0)) { $0 + $1.usedBytes },
            isPartial: root.isPartial,
            children: sorted(children)
        )
    }

    /// 方案 A 主路:Data 根树 → 显示树。子目录剥 Data 前缀成规范路径;
    /// 卷级密封摘要合并为单块;根 = 整卷(文件级 + 卷级两截口径之和)。
    private static func buildFromDataRoot(
        _ root: SpaceNode,
        dataPrefix: String,
        sealedPaths: [String],
        sealedVolumes: [SpaceMapVolumeSummary]
    ) -> SpaceMapNode {
        var children: [SpaceMapNode] = []
        for child in root.children where child.kind == .directory {
            if let mapped = mapChild(child, dataPrefix: dataPrefix, sealedPaths: sealedPaths) {
                children.append(mapped)
            }
        }
        if let sealed = sealedVolumeNode(sealedVolumes) {
            children.append(sealed)
        }
        return SpaceMapNode(
            name: "整卷",
            path: "/",
            bytes: root.accountedBytes + sealedVolumes.reduce(Int64(0)) { $0 + $1.usedBytes },
            isPartial: root.isPartial,
            children: sorted(children)
        )
    }

    /// 卷级密封块:所有非数据系统卷(SSV / Preboot / VM / Update / Recovery…)一笔。
    private static func sealedVolumeNode(_ volumes: [SpaceMapVolumeSummary]) -> SpaceMapNode? {
        let sum = volumes.reduce(Int64(0)) { $0 + $1.usedBytes }
        guard sum > 0 else { return nil }
        return SpaceMapNode(name: "系统(密封)", path: "/System", bytes: sum, isSealed: true)
    }

    /// 单节点变换:零字节非部分裁剪、密封折叠、递归、逐层排序。
    /// 只认目录节点(地图目录粒度设计;retainedFilePrefixes 带进树的文件节点
    /// 在这里显式让路——它们是记账输入,不是地图块,p6-cleaner/02)。
    private static func mapChild(
        _ node: SpaceNode,
        dataPrefix: String?,
        sealedPaths: [String]
    ) -> SpaceMapNode? {
        guard node.kind == .directory else { return nil }
        if node.accountedBytes <= 0, !node.isPartial {
            return nil
        }
        let canonicalPath = node.path.withDataPrefixRemoved(dataPrefix)
        if sealedPaths.contains(node.path) {
            return SpaceMapNode(
                name: node.name,
                path: canonicalPath,
                bytes: node.accountedBytes,
                isPartial: node.isPartial,
                isSealed: true
            )
        }
        let children = sorted(node.children.compactMap {
            // Data 前缀只可能出现在 Data 子树内;其余层级照常递归。
            mapChild($0, dataPrefix: dataPrefix, sealedPaths: sealedPaths)
        })
        return SpaceMapNode(
            name: node.name,
            path: canonicalPath,
            bytes: node.accountedBytes,
            isPartial: node.isPartial,
            children: children
        )
    }

    private static func sorted(_ nodes: [SpaceMapNode]) -> [SpaceMapNode] {
        nodes.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path
        }
    }

    private static func normalizedPrefix(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }
}

private extension String {
    /// /System/Volumes/Data/Users → /Users(提升改写);不在前缀内原样返回。
    func withDataPrefixRemoved(_ dataPrefix: String?) -> String {
        guard let dataPrefix, !dataPrefix.isEmpty else { return self }
        if self == dataPrefix {
            return "/"
        }
        guard hasPrefix(dataPrefix + "/") else { return self }
        return "/" + dropFirst(dataPrefix.count + 1)
    }
}

/// 一段旭日弧(纯几何;视图只负责描边、配色与命中)。
public struct SunburstArc: Sendable, Equatable, Identifiable {
    public var id: String {
        "\(ring)|\(node.path)|\(start)"
    }

    /// 1 = 内环(子辈),2 = 外环(孙辈 / 叶子与密封块的延伸)。
    public var ring: Int
    public var node: SpaceMapNode
    /// 弧度;0 弧度 = 正上,顺时针增大(与 SwiftUI y 向下坐标系一致)。
    public var start: Double
    public var end: Double
    /// 占「当前钻入根」整体的份额(= bytes / root.bytes;悬浮百分比口径)。
    public var volumeFraction: Double
    /// 弧宽足够放得下名字(阈值由布局参数给出;视图按此开关标签)。
    public var isLabelReadable: Bool

    public init(
        ring: Int,
        node: SpaceMapNode,
        start: Double,
        end: Double,
        volumeFraction: Double,
        isLabelReadable: Bool
    ) {
        self.ring = ring
        self.node = node
        self.start = start
        self.end = end
        self.volumeFraction = volumeFraction
        self.isLabelReadable = isLabelReadable
    }
}

public extension SunburstArc {
    var span: Double {
        end - start
    }

    var midAngle: Double {
        (start + end) / 2
    }

    /// 左半圆的文字沿半径反着排会倒立——翻转 180° 保证外向可读。
    var flipsLabel: Bool {
        cos(midAngle) < 0
    }
}

/// 两环旭日布局:角度按字节份额分配、小份额尾部并入「其他」、叶子/密封块延伸占满外环。
public enum SunburstLayout {
    /// 满圆弧在 Path 里画不出来(起止重合),留一道细缝。
    static let fullCircleEpsilon = 0.001

    public static func layout(
        root: SpaceMapNode,
        maxChildren: Int = 12,
        minArcFraction: Double = 0.005,
        startAngle: Double = -.pi / 2,
        labelMinSpan: Double = 0.23
    ) -> [SunburstArc] {
        guard root.bytes > 0 else { return [] }
        let ring1 = merged(root.children, cap: maxChildren, minFraction: minArcFraction)
        let total = ring1.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return [] }

        let full = 2 * Double.pi
        var arcs: [SunburstArc] = []
        var cursor = startAngle

        func append(
            _ node: SpaceMapNode, ring: Int, _ a0: Double, _ a1: Double
        ) {
            arcs.append(SunburstArc(
                ring: ring,
                node: node,
                start: a0,
                end: a1,
                volumeFraction: Double(node.bytes) / Double(root.bytes),
                isLabelReadable: (a1 - a0) >= labelMinSpan
            ))
        }

        for item in ring1 {
            var span = Double(item.bytes) / Double(total) * full
            span = min(span, full - fullCircleEpsilon)
            let a0 = cursor
            let a1 = cursor + span
            cursor = a1
            append(item, ring: 1, a0, a1)

            // 外环:密封块与「其他」合成块不展开;无可见孙辈的叶子延伸占满同色。
            if item.isSealed || item.isAggregate || item.children.isEmpty {
                append(item, ring: 2, a0, a1)
                continue
            }
            let ring2 = merged(item.children, cap: maxChildren, minFraction: minArcFraction)
            let total2 = ring2.reduce(Int64(0)) { $0 + $1.bytes }
            if total2 <= 0 {
                append(item, ring: 2, a0, a1)
                continue
            }
            var inner = a0
            for child in ring2 {
                let span2 = Double(child.bytes) / Double(total2) * span
                append(child, ring: 2, inner, inner + span2)
                inner += span2
            }
        }
        return arcs
    }

    /// 大到小取前缀,超量 / 份额过小的尾部并入「其他」(合成块不再下钻)。
    private static func merged(
        _ children: [SpaceMapNode], cap: Int, minFraction: Double
    ) -> [SpaceMapNode] {
        let sorted = children.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path
        }
        let total = sorted.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0, !sorted.isEmpty else { return [] }

        var kept: [SpaceMapNode] = []
        var mergedBytes: Int64 = 0
        var mergedCount = 0
        for (index, node) in sorted.enumerated() {
            let fraction = Double(node.bytes) / Double(total)
            if index < cap, fraction >= minFraction {
                kept.append(node)
            } else {
                mergedBytes += node.bytes
                mergedCount += 1
            }
        }
        if mergedCount > 0, mergedBytes > 0 {
            kept.append(SpaceMapNode(
                name: "其他",
                path: "",
                bytes: mergedBytes,
                isAggregate: true,
                mergedCount: mergedCount
            ))
        }
        return kept
    }
}
