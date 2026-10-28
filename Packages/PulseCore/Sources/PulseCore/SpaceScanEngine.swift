import Foundation

// MARK: - 空间扫描引擎(p4-cleaner/02)

//
// 口径(GLOSSARY「实际占用」):每文件取 reclaimableSize(PRIVATESIZE,删即释放——
// 克隆 / 快照共享已被文件系统扣除,探针 11 ④);缺席时回退 allocatedSize(block 口径,
// 克隆会重复计),并在节点上如实标记「非全量真实口径」,界面据此标注。
// 防双计:探针 11 ⑤ 证实根卷与 Data 卷 st_dev 相同,st_dev 剪枝不成立——
// 目录按 (deviceID, fileID) 访问集只走一次(firmlink 双路径),文件硬链接同键只计首个。
// 台账:目录枚举失败分类入册不中断,子树标 partial;绝不伪造 0(防御性数据纪律)。

/// 扫描选项。
public struct SpaceScanOptions: Sendable, Equatable {
    public var roots: [String]
    /// 排除目录前缀(GLOSSARY「排除目录」):只收窄,永不扩大;目录命中则整个子树不下潜。
    public var excludedPathPrefixes: [String]
    /// 深度护栏(dust 教训的递归防御位)。超深目录入台账、标 partial,不崩。
    public var maxDepth: Int
    /// 文件节点是否进树(`children`)。false = 文件只聚合进父目录的计数与字节,
    /// 树里只留目录节点。真机全卷 ≈340 万项、文件级节点约 278 B/个,全量驻留 ≈900 MB,
    /// 只留目录(≈10%)≈90 MB(p4-cleaner/04 合成探针 /tmp/p4-mem-probe.swift 实测)。
    /// 开发者垃圾(规则只认目录)与空间地图(目录粒度)都不需要文件节点;默认 true
    /// 保持 02 票的树形状不变,按需关。
    public var retainFileNodes: Bool

    public init(
        roots: [String],
        excludedPathPrefixes: [String] = [],
        maxDepth: Int = 256,
        retainFileNodes: Bool = true
    ) {
        self.roots = roots
        self.excludedPathPrefixes = excludedPathPrefixes
        self.maxDepth = maxDepth
        self.retainFileNodes = retainFileNodes
    }
}

/// 空间树节点。树 = 空间地图与开发者垃圾共用的数据源(spec:一次扫描喂两个子页)。
public struct SpaceNode: Sendable {
    public var name: String
    public var path: String
    public var kind: FsEntrySnapshot.Kind

    /// 全子树的「真实可回收」求和(每文件 reclaimableSize ?? allocatedSize)。
    public var accountedBytes: Int64
    /// 其中来自 PRIVATESIZE 的部分(口径透明:两者之差 = 回退计的部分)。
    public var reclaimableBytes: Int64
    /// 全子树 block 口径求和,对照展示用。
    public var fallbackBytes: Int64
    /// 子树所有文件都拿到了 PRIVATESIZE;false = 混了回退口径,界面须标注。
    public var allReclaimableAccounting: Bool

    public var fileCount: Int
    public var directoryCount: Int
    public var symlinkCount: Int
    public var datalessCount: Int
    /// 子树内有目录枚举失败 / 超深(部分扫描,如实标记不假装完整)。
    public var isPartial: Bool
    public var children: [SpaceNode]

    public init(
        name: String,
        path: String,
        kind: FsEntrySnapshot.Kind,
        accountedBytes: Int64 = 0,
        reclaimableBytes: Int64 = 0,
        fallbackBytes: Int64 = 0,
        allReclaimableAccounting: Bool = true,
        fileCount: Int = 0,
        directoryCount: Int = 0,
        symlinkCount: Int = 0,
        datalessCount: Int = 0,
        isPartial: Bool = false,
        children: [SpaceNode] = []
    ) {
        self.name = name
        self.path = path
        self.kind = kind
        self.accountedBytes = accountedBytes
        self.reclaimableBytes = reclaimableBytes
        self.fallbackBytes = fallbackBytes
        self.allReclaimableAccounting = allReclaimableAccounting
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.symlinkCount = symlinkCount
        self.datalessCount = datalessCount
        self.isPartial = isPartial
        self.children = children
    }
}

public extension SpaceNode {
    /// 从本节点出发按路径分量下钻(只走目录 children,按 `name` 精确匹配)。
    /// `path` 须等于本节点路径或在其之下;任一层缺席返回 nil(不猜、不创建)。
    func descendant(atPath path: String) -> SpaceNode? {
        let target = PathNormalization.normalize(path)
        let base = PathNormalization.normalize(self.path)
        if target == base {
            return self
        }
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix) else { return nil }
        let remainder = target.dropFirst(prefix.count)
        var node = self
        for component in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            guard let next = node.children.first(where: { $0.name == component && $0.kind == .directory }) else {
                return nil
            }
            node = next
        }
        return node
    }

    /// 在一组扫描根里定位路径:取能覆盖该路径的那棵树再下钻(根重叠已由引擎去重,最多命中一棵)。
    static func locate(path: String, in trees: [SpaceNode]) -> SpaceNode? {
        for tree in trees {
            if let hit = tree.descendant(atPath: path) {
                return hit
            }
        }
        return nil
    }
}

/// 扫描统计(进度条与收口复盘的数字)。
public struct ScanStats: Sendable, Equatable {
    public var entriesSeen = 0
    public var files = 0
    public var directories = 0
    public var symlinks = 0
    public var datalessFiles = 0
    public var hardlinkSkips = 0
    public var doubleVisitSkips = 0
    public var accountedBytes: Int64 = 0

    public init() {}
}

/// 一次扫描的全部产出。
public struct SpaceScanResult: Sendable {
    /// 每个根一棵(根被排除或取消时可能缺席)。
    public var trees: [SpaceNode]
    /// 错误台账:逐目录分类入册。
    public var ledger: [CleanEnumerateError]
    public var stats: ScanStats
    /// 到达取消点提前停止(已产出部分照常可用,标记不完整)。
    public var cancelled: Bool

    public init(trees: [SpaceNode], ledger: [CleanEnumerateError], stats: ScanStats, cancelled: Bool = false) {
        self.trees = trees
        self.ledger = ledger
        self.stats = stats
        self.cancelled = cancelled
    }
}

/// 纯值扫描引擎:驱动 `CleanDirectoryEnumerator`,产出空间树 + 台账。自身无状态、无 IO。
public struct SpaceScanEngine: Sendable {
    public init() {}

    /// - Parameters:
    ///   - progress: 每 2048 项(及收尾)回调一次累计统计;03 票接进度条。
    ///   - isCancelled: 每进入一个目录检查一次;true 即停,产出标记 cancelled。
    public func scan(
        _ options: SpaceScanOptions,
        using enumerator: some CleanDirectoryEnumerator,
        progress: (@Sendable (ScanStats) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> SpaceScanResult {
        let walker = Walker(options: options, enumerator: enumerator, progress: progress, isCancelled: isCancelled)
        var trees: [SpaceNode] = []
        var cancelled = false
        // 根重叠(一根是另一根的子孙):先到的赢,后到的整棵跳过——同一子树绝不重复入树。
        var claimedRoots: [String] = []
        for root in options.roots {
            let normalized = Self.norm(root)
            if claimedRoots.contains(where: { normalized.hasPrefix($0) }) {
                walker.noteSkippedRoot()
                continue
            }
            claimedRoots.append(normalized)
            // 排除根:静默跳过——排除是用户意图,不进错误台账(GLOSSARY「排除目录」)。
            if walker.isExcluded(normalized) {
                continue
            }
            let node = await walker.scanDirectory(path: normalized, name: Self.lastName(of: normalized), depth: 0)
            // 取消也保留已产出(部分)树——取消点之后不再枚举,已扫部分照常可用。
            trees.append(node)
            if walker.cancelled {
                cancelled = true
                break
            }
        }
        walker.finish()
        return SpaceScanResult(
            trees: trees,
            ledger: walker.ledger,
            stats: walker.stats,
            cancelled: cancelled || walker.cancelled
        )
    }

    static func norm(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") {
            s.removeLast()
        }
        return s == "" ? "/" : s
    }

    static func lastName(of path: String) -> String {
        (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
    }
}

// MARK: - 单趟遍历内核(单 Task 内串行使用,非 Sendable 不跨并发域)

private struct IdentityKey: Hashable {
    var device: UInt32
    var fileID: UInt64
}

private final class Walker {
    let options: SpaceScanOptions
    let enumerator: any CleanDirectoryEnumerator
    let progress: (@Sendable (ScanStats) -> Void)?
    let isCancelled: (@Sendable () -> Bool)?

    var stats = ScanStats()
    var ledger: [CleanEnumerateError] = []
    var cancelled = false

    private var visitedDirs = Set<IdentityKey>()
    private var seenFiles = Set<IdentityKey>()
    private var progressCounter = 0

    init(
        options: SpaceScanOptions,
        enumerator: any CleanDirectoryEnumerator,
        progress: (@Sendable (ScanStats) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) {
        self.options = options
        self.enumerator = enumerator
        self.progress = progress
        self.isCancelled = isCancelled
    }

    func noteSkippedRoot() {
        stats.doubleVisitSkips += 1
    }

    func isExcluded(_ path: String) -> Bool {
        // 与删除侧(CleanPlan)共用同一判定——"扫描与删除两处生效"靠一份代码而非两份抄写。
        CleanExclusions.isExcluded(path, by: options.excludedPathPrefixes)
    }

    func finish() {
        progress?(stats)
    }

    func scanDirectory(path: String, name: String, depth: Int) async -> SpaceNode {
        var node = SpaceNode(name: name, path: path, kind: .directory)

        if isCancelled?() == true {
            cancelled = true
            node.isPartial = true
            return node
        }
        if depth >= options.maxDepth {
            ledger.append(CleanEnumerateError(path: path, reason: .tooDeep))
            node.isPartial = true
            return node
        }

        let entries: [FsEntrySnapshot]
        do {
            entries = try await enumerator.entries(ofDirectory: path)
        } catch let error as CleanEnumerateError {
            ledger.append(error)
            node.isPartial = true
            return node
        } catch {
            // 边界实现只该抛 CleanEnumerateError;兜底入册不吞(CODING_STANDARDS:不伪造数据)。
            ledger.append(CleanEnumerateError(path: path, reason: .other(errno: 0)))
            node.isPartial = true
            return node
        }

        for entry in entries {
            stats.entriesSeen += 1
            if progressCounter >= 2048 {
                progressCounter = 0
                progress?(stats)
            } else {
                progressCounter += 1
            }
            let childPath = path == "/" ? "/" + entry.name : path + "/" + entry.name

            switch entry.kind {
            case .directory:
                let key = IdentityKey(device: entry.deviceID, fileID: entry.fileID)
                // 探针 11 ⑤:firmlink 双路径同 (dev, fileID)——访问集防双计,先到先得。
                guard entry.fileID != 0, !visitedDirs.contains(key) else {
                    stats.doubleVisitSkips += 1
                    continue
                }
                visitedDirs.insert(key)

                if isExcluded(childPath) {
                    // 排除目录(GLOSSARY):不下潜、不计数——扫描与删除两处都收窄(04 票复用同判定)。
                    continue
                }
                stats.directories += 1
                let child = await scanDirectory(path: childPath, name: entry.name, depth: depth + 1)
                if cancelled {
                    node.isPartial = true
                    return node
                }
                absorb(child, into: &node)

            case .file:
                let key = IdentityKey(device: entry.deviceID, fileID: entry.fileID)
                // 硬链接同 (dev, fileID) 只计首个(dust §2.3 的内联等价;先到先得,枚举序决定)。
                if entry.fileID != 0 {
                    guard !seenFiles.contains(key) else {
                        stats.hardlinkSkips += 1
                        continue
                    }
                    seenFiles.insert(key)
                }
                stats.files += 1
                if entry.isDataless {
                    stats.datalessFiles += 1
                }
                node.fileCount += 1
                if entry.isDataless {
                    node.datalessCount += 1
                }
                let bytes = entry.reclaimableSize ?? entry.allocatedSize
                node.accountedBytes += bytes
                stats.accountedBytes += bytes
                if let reclaimable = entry.reclaimableSize {
                    node.reclaimableBytes += reclaimable
                } else {
                    node.allReclaimableAccounting = false
                }
                node.fallbackBytes += entry.allocatedSize
                // 文件节点可选不进树(内存量级,见 SpaceScanOptions.retainFileNodes);
                // 上面的计数与字节已聚合进父目录,树的数字不因此改变。
                if options.retainFileNodes {
                    node.children.append(SpaceNode(
                        name: entry.name,
                        path: childPath,
                        kind: .file,
                        accountedBytes: bytes,
                        reclaimableBytes: entry.reclaimableSize ?? 0,
                        fallbackBytes: entry.allocatedSize,
                        allReclaimableAccounting: entry.reclaimableSize != nil,
                        fileCount: 1,
                        datalessCount: entry.isDataless ? 1 : 0
                    ))
                }

            case .symlink:
                // 不跟随(spec:dust 默认同款);链接本体字节可忽略,单独计数上屏。
                stats.symlinks += 1
                node.symlinkCount += 1

            case .other:
                break
            }
        }
        return node
    }

    private func absorb(_ child: SpaceNode, into node: inout SpaceNode) {
        node.children.append(child)
        node.accountedBytes += child.accountedBytes
        node.reclaimableBytes += child.reclaimableBytes
        node.fallbackBytes += child.fallbackBytes
        node.fileCount += child.fileCount
        node.directoryCount += child.directoryCount + 1
        node.symlinkCount += child.symlinkCount
        node.datalessCount += child.datalessCount
        node.isPartial = node.isPartial || child.isPartial
        node.allReclaimableAccounting = node.allReclaimableAccounting && child.allReclaimableAccounting
    }
}
