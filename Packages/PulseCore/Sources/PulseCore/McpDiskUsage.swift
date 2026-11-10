import Foundation

// MARK: - mcp-disk-usage(mcp-disk-usage/01:上次扫描快照的目录占用)

//
// 数据 = 清理页扫描落盘的目录大小树(SpaceScanCache,~/.Pulse/scan-cache-v1.bin);
// 只读快照、绝不现场扫描。口径:accountedBytes = 子树「实际占用」;部分枚举
// (isPartial)与扫描取消如实标注;扫描后已进废纸篓的路径(meta.cleanedPaths)
// 仍在快照里,读侧注记一句不静默。

/// 快照目录占用查询(纯函数;夹具手搭树,单测同款纪律)。
public enum DiskUsageQuery {
    /// `path` 的子树占用:精确命中该节点,或(节点不在树里——被排除/枚举失败)
    /// 前缀聚合覆盖到的子孙。两者都空 = 路径不在快照范围。
    /// (SpaceNode 无 Equatable,整体不可比——测试逐字段断言。)
    public struct Subtree: Sendable {
        /// 精确命中的节点(nil = 只做了前缀聚合)。
        public let node: SpaceNode?
        /// 前缀聚合的占用字节(精确命中时 = node.accountedBytes,不重复聚合)。
        public let aggregatedBytes: Int64
        /// 前缀聚合命中的节点数(>0 且 node == nil = 路径本身没扫全,只算盖到的)。
        public let matchedDescendantCount: Int
    }

    public static func subtree(path rawPath: String, in trees: [SpaceNode]) -> Subtree? {
        let path = PathNormalization.normalize(rawPath)
        if let node = find(path: path, in: trees) {
            return Subtree(node: node, aggregatedBytes: node.accountedBytes, matchedDescendantCount: 0)
        }
        // 前缀聚合:路径本身不在树里,但子孙有盖到的(典型:路径被排除、其下部分
        // 子目录经别的入口枚举到;或路径比扫描根深且被跳过)。
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var bytes: Int64 = 0
        var count = 0
        for node in trees {
            walk(node) { candidate in
                if candidate.path.hasPrefix(prefix) {
                    // 只计"叶子级"命中会低估、全计会重复——计「以 prefix 开头且
                    // 父不在命中集」的节点:等价于取命中子树的顶层。简单可靠版:
                    // 只计路径恰好 = prefix + name 一层的首个命中层,由 walk 剪枝实现。
                    bytes += candidate.accountedBytes
                    count += 1
                    return false // 不再下钻,避免子孙重复计
                }
                return true
            }
        }
        guard count > 0 else { return nil }
        return Subtree(node: nil, aggregatedBytes: bytes, matchedDescendantCount: count)
    }

    /// 直接子目录降序 top(文件不入列——问的是"哪些目录";直属文件数在文案里报)。
    public static func topChildren(of node: SpaceNode, limit: Int) -> [SpaceNode] {
        node.children
            .filter { $0.kind == .directory }
            .sorted {
                $0.accountedBytes != $1.accountedBytes
                    ? $0.accountedBytes > $1.accountedBytes : $0.path < $1.path
            }
            .prefix(limit)
            .map(\.self)
    }

    /// 各扫描根的一级子目录合并排行(多根各自带路径前缀,天然不混)。
    public static func topLevel(in trees: [SpaceNode], limit: Int) -> [SpaceNode] {
        trees.flatMap { topChildren(of: $0, limit: .max) }
            .sorted {
                $0.accountedBytes != $1.accountedBytes
                    ? $0.accountedBytes > $1.accountedBytes : $0.path < $1.path
            }
            .prefix(limit)
            .map(\.self)
    }

    /// 各根合计(上下文行用)。
    public static func totalBytes(in trees: [SpaceNode]) -> Int64 {
        trees.reduce(0) { $0 + $1.accountedBytes }
    }

    private static func find(path: String, in trees: [SpaceNode]) -> SpaceNode? {
        for root in trees {
            var stack = [root]
            while let node = stack.popLast() {
                if node.path == path {
                    return node
                }
                stack.append(contentsOf: node.children)
            }
        }
        return nil
    }

    /// 先序走树;返回 false = 剪掉该子树。
    private static func walk(_ root: SpaceNode, _ visit: (SpaceNode) -> Bool) {
        var stack = [root]
        while let node = stack.popLast() {
            if !visit(node) {
                continue
            }
            stack.append(contentsOf: node.children)
        }
    }
}

/// disk_usage 的中文输出(单出处;pulse-mcp 只接线)。
public enum McpDiskUsageText {
    /// 有 path 的完整回答。
    public static func usage(
        path: String,
        subtree: DiskUsageQuery.Subtree,
        topChildren: [SpaceNode],
        scanFinishedAt: Date?,
        cancelled: Bool,
        cleanedPathCount: Int,
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append(header(
            scanFinishedAt: scanFinishedAt,
            cancelled: cancelled,
            cleanedPathCount: cleanedPathCount,
            now: now
        ))
        if let node = subtree.node {
            lines.append(
                "\(node.path) 共 \(PulseFormat.memory(UInt64(max(0, node.accountedBytes))))(\(node.fileCount) 个文件"
                    + (node.isPartial ? ",部分子目录没扫到,实际只多不少" : "")
                    + (node.allReclaimableAccounting ? "" : ",部分按 block 口径回退计")
                    + ")"
            )
        } else {
            lines.append(
                "\(PathNormalization.normalize(path)) 本身不在快照里(被排除或没扫到),只算到盖到的 \(subtree.matchedDescendantCount) 个子目录:共 \(PulseFormat.memory(UInt64(max(0, subtree.aggregatedBytes))))——这是下限,不是全量"
            )
        }
        if topChildren.isEmpty {
            lines.append("下面没有(能看到的)子目录。")
        } else {
            lines.append("直接子目录占用 top \(topChildren.count):")
            lines.append(contentsOf: topChildren.map { child in
                "- \(child.name) — \(PulseFormat.memory(UInt64(max(0, child.accountedBytes))))\(child.isPartial ? "(部分扫描)" : "")"
            })
        }
        return lines.joined(separator: "\n")
    }

    /// 无 path 的顶层总览。
    public static func overview(
        roots: [String],
        totalBytes: Int64,
        top: [SpaceNode],
        scanFinishedAt: Date?,
        cancelled: Bool,
        cleanedPathCount: Int,
        now: Date
    ) -> String {
        var lines: [String] = []
        lines.append(header(
            scanFinishedAt: scanFinishedAt,
            cancelled: cancelled,
            cleanedPathCount: cleanedPathCount,
            now: now
        ))
        lines.append("扫描范围:\(roots.joined(separator: "、")),合计 \(PulseFormat.memory(UInt64(max(0, totalBytes))))。目录排行:")
        for (index, node) in top.enumerated() {
            lines
                .append(
                    "\(index + 1). \(node.path) — \(PulseFormat.memory(UInt64(max(0, node.accountedBytes))))\(node.isPartial ? "(部分扫描)" : "")"
                )
        }
        lines.append("要看某目录下面谁大,传 path 再问。")
        return lines.joined(separator: "\n")
    }

    private static func header(
        scanFinishedAt: Date?,
        cancelled: Bool,
        cleanedPathCount: Int,
        now: Date
    ) -> String {
        var parts: [String] = []
        if let finished = scanFinishedAt {
            let minutes = max(0, Int(now.timeIntervalSince(finished) / 60))
            parts.append(minutes < 1 ? "数据来自刚刚完成的扫描" : "数据来自 \(ageText(minutes: minutes))的扫描快照(不是实时)")
        } else {
            parts.append("数据来自扫描快照(时刻未知)")
        }
        if cancelled {
            parts.append("那次扫描被中途取消,只盖到一部分目录")
        }
        if cleanedPathCount > 0 {
            parts.append("扫描后已清理 \(cleanedPathCount) 个目录,下列数字略偏高")
        }
        return parts.joined(separator: ";") + ":"
    }

    private static func ageText(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes) 分钟前"
        }
        if minutes < 24 * 60 {
            return "\(minutes / 60) 小时前"
        }
        return "\(minutes / 1440) 天前"
    }
}
