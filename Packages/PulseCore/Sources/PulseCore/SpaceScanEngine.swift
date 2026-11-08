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
    /// 规范根(方案 A 路径域修正):与 roots 一一对应;第 i 个非 nil 时,该根的
    /// **树路径**以它为前缀(如 "/" ),而**枚举仍走 roots[i] 物理路径**(如
    /// /System/Volumes/Data)。树上的路径因此与用户可见路径(/Users/…)同域,
    /// 白名单匹配 / 排除判定 / 候选展示零转换;台账错误路径保留物理路径(诊断用)。
    public var canonicalRoots: [String?]
    /// 并行 worker 数(p4-cleaner 性能票):1 = 串行,**与历史行为逐位一致**
    /// (双访先到先得、进度节奏、树形状都不因默认值漂移——引擎单测的确定性锚);
    /// >1 = petal 式子目录并行(长驻 worker 池吃共享目录栈,不为每目录起 Task)。
    /// 生产由调用方按核数开(CleanerModel 传 6);上限取活动核数,防过订阅。
    public var maxConcurrency: Int

    public init(
        roots: [String],
        excludedPathPrefixes: [String] = [],
        maxDepth: Int = 256,
        retainFileNodes: Bool = true,
        maxConcurrency: Int = 1,
        canonicalRoots: [String?]? = nil
    ) {
        self.roots = roots
        self.excludedPathPrefixes = excludedPathPrefixes
        self.maxDepth = maxDepth
        self.retainFileNodes = retainFileNodes
        self.maxConcurrency = maxConcurrency
        self.canonicalRoots = canonicalRoots ?? [String?](repeating: nil, count: roots.count)
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
    /// **本目录直属文件** mtime 的最大值(05 票项目年龄口径;不含子孙目录——
    /// 「产物该被年龄排除」靠匹配器 DFS 跳产物子树再逐层取本值,聚合反而会漏)。
    /// nil = 本目录没有已知 mtime 的直属文件。目录自身 mtime 有意不算——重装依赖
    /// (rm -rf node_modules 再装)会刷目录条目,而项目年龄不该被刷新(票面钉死)。
    /// 含 git 活动:.git 下的文件(FETCH_HEAD 等)也是直属文件,天然计入。
    public var newestChangeEpoch: Double?
    /// **目录自身**的 mtime(扫描时刻;p5-cleaner/03 删前复核快照):目录里增删改名
    /// 条目就会变。取自父目录列表里本条目的 `modifiedEpoch`(零额外 IO);扫描根没有
    /// 父列表 = nil,文件节点不填。与 `newestChangeEpoch` 两个口径互不替代——那个管
    /// 「多久没动」(年龄),这个管「扫描后动没动过」(复核)。
    public var ownModifiedEpoch: Double?
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
        newestChangeEpoch: Double? = nil,
        ownModifiedEpoch: Double? = nil,
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
        self.newestChangeEpoch = newestChangeEpoch
        self.ownModifiedEpoch = ownModifiedEpoch
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
    ///   - progress: 每 ~2048 项(按目录粒度跨越;及收尾)回调一次累计统计;03 票接进度条。
    ///   - isCancelled: 每进入一个目录检查一次;true 即停,产出标记 cancelled。
    public func scan(
        _ options: SpaceScanOptions,
        using enumerator: some CleanDirectoryEnumerator,
        progress: (@Sendable (ScanStats) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) async -> SpaceScanResult {
        let core = ScanCore(options: options, enumerator: enumerator, progress: progress, isCancelled: isCancelled)

        // 根重叠(一根是另一根的子孙):先到的赢,后到的整棵跳过——同一子树绝不重复入树。
        // 排除根:静默跳过——排除是用户意图,不进错误台账(GLOSSARY「排除目录」)。
        var claimedRoots: [String] = []
        var seeded: [(path: String, name: String, display: String)] = []
        for (index, root) in options.roots.enumerated() {
            let normalized = Self.norm(root)
            if claimedRoots.contains(where: { normalized.hasPrefix($0) }) {
                core.noteSkippedRoot()
                continue
            }
            claimedRoots.append(normalized)
            // 树路径域(方案 A 路径域修正):canonicalRoots 非 nil 的根,树以规范前缀
            // 落路径;物理路径只喂枚举器与台账。
            var display = normalized
            if index < options.canonicalRoots.count, let canonical = options.canonicalRoots[index] {
                display = Self.norm(canonical)
            }
            if core.isExcluded(display) {
                continue
            }
            seeded.append((path: normalized, name: Self.lastName(of: normalized), display: display))
        }
        core.enqueueRoots(seeded.map { ScanCore.PendingDir(path: $0.path, displayPath: $0.display, depth: 0) })

        // worker 池:maxConcurrency=1 走与历史递归 DFS 逐位一致的路径(LIFO 栈 +
        // 子目录逆序入栈 = 入口序处理);>1 时多 worker 共享目录栈并行。
        let workerCount = max(1, min(options.maxConcurrency, ProcessInfo.processInfo.activeProcessorCount))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< workerCount {
                group.addTask { await core.run() }
            }
        }
        core.finish()
        return core.result(rootMetas: seeded.map { (path: $0.display, name: $0.name) })
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

// MARK: - 遍历内核(p4-cleaner 性能票:worker 池 + 共享目录栈)

//
// maxConcurrency = 1 时与旧递归 DFS 逐位等价:LIFO 栈、子目录按入口序逆序入栈
// (弹出序 = 入口序)、先到先得的 (dev, fileID) 占坑、进度每 ~2048 项一发——
// 引擎既有单测的确定性锚全在默认路径上,零改动。
// > 1 时(petal 式并行):N 个长驻 worker 吃共享栈,不为 135 万个目录各起 Task;
// 每目录**先占坑再枚举**(firmlink/双挂载去重语义不变,谁先占由调度定);
// 文件硬链接去重集合按 fileID 哈希分 32 片(全卷千万级插入,单锁必排队);
// 统计/台账按目录批合并;树不在线拼——每目录记账(直属文件聚合 + 子目录序),
// 收工后自底向上拼装,并行/串行产出同形树。取消时缺口的祖先标 partial
// (与旧实现「取消点之后的子树消失、链上标 partial」同义)。
//
// 等待语义:栈空但还有 in-flight 目录时 worker 让出并小睡(200µs),不用
// 条件变量长阻塞——阻塞 Swift 协作线程池有饿死风险(枚举本身也在池上跑)。

private struct IdentityKey: Hashable {
    var device: UInt32
    var fileID: UInt64
}

/// 并行遍历内核:全部共享状态由锁保护,@unchecked Sendable 的前提即「只经锁碰」。
private final class ScanCore: @unchecked Sendable {
    struct PendingDir {
        /// 物理路径(喂枚举器;台账错误也用它——诊断要看真路径)。
        let path: String
        /// 规范路径(树上的路径域;无别名时与物理相同)。
        let displayPath: String
        let depth: Int
        /// 本目录自身 mtime(父列表里的条目值;根 = nil)——落成 `SpaceNode.ownModifiedEpoch`。
        var modifiedEpoch: Double?
    }

    /// 一份记录,等价于旧实现完成一个目录后的现场。
    private struct Record {
        var node: SpaceNode // 直属文件已聚合;children 空,拼装时补
        var childDirPaths: [String] // 子目录路径,按入口序(拼装顺序 = 旧 absorb 顺序)
    }

    let options: SpaceScanOptions
    let enumerator: any CleanDirectoryEnumerator
    let progress: (@Sendable (ScanStats) -> Void)?
    let isCancelled: (@Sendable () -> Bool)?

    private let stateLock = NSLock()
    private var stack: [PendingDir] = []
    private var inFlight = 0
    private var records: [String: Record] = [:]
    private var stats = ScanStats()
    private var ledger: [CleanEnumerateError] = []
    private var cancelled = false
    private var lastProgressAt = 0

    private let dirLock = NSLock()
    private var visitedDirs = Set<IdentityKey>()

    /// 文件去重分片:32 把锁按 fileID 哈希落片,互不相干。
    private final class FileShard {
        let lock = NSLock()
        var seen = Set<IdentityKey>()
    }

    private static let fileShardCount = 32
    private let fileShards: [FileShard]

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
        fileShards = (0 ..< Self.fileShardCount).map { _ in FileShard() }
    }

    // MARK: 种子与辅助

    func noteSkippedRoot() {
        stateLock.lock()
        stats.doubleVisitSkips += 1
        stateLock.unlock()
    }

    func isExcluded(_ path: String) -> Bool {
        // 与删除侧(CleanPlan)共用同一判定——"扫描与删除两处生效"靠一份代码而非两份抄写。
        CleanExclusions.isExcluded(path, by: options.excludedPathPrefixes)
    }

    func enqueueRoots(_ roots: [PendingDir]) {
        stateLock.lock()
        stack.append(contentsOf: roots)
        stateLock.unlock()
    }

    // MARK: worker 主循环

    func run() async {
        while true {
            if let job = pop() {
                await process(job)
            } else if isSettled() {
                return
            } else {
                // 栈空但仍有 in-flight(别的 worker 枚举完会补目录):让出 + 小睡。
                await Task.yield()
                try? await Task.sleep(nanoseconds: 200_000)
            }
        }
    }

    private func pop() -> PendingDir? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let job = stack.popLast() else { return nil }
        inFlight += 1
        return job
    }

    /// 全部工作了结 = 无在途、栈空。(取消时 worker 会清空在途并快速归零。)
    private func isSettled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inFlight == 0 && stack.isEmpty
    }

    private func settleOne() {
        stateLock.lock()
        inFlight -= 1
        stateLock.unlock()
    }

    // MARK: 单目录处理(语义与旧 scanDirectory 对齐)

    private func process(_ job: PendingDir) async {
        // 取消:不再产出该目录——拼装时其祖先会因缺口标 partial。
        if isCancelled?() == true {
            markCancelledAndDrain()
            settleOne()
            return
        }
        // 深度护栏:入台账 + 记一个空 partial 占位(与旧实现返回的空节点等价)。
        if job.depth >= options.maxDepth {
            recordPlaceholder(job: job, reason: .tooDeep)
            settleOne()
            return
        }

        let entries: [FsEntrySnapshot]
        do {
            entries = try await enumerator.entries(ofDirectory: job.path)
        } catch let error as CleanEnumerateError {
            recordPlaceholder(error: error, display: job.displayPath, ownModifiedEpoch: job.modifiedEpoch)
            settleOne()
            return
        } catch {
            // 边界实现只该抛 CleanEnumerateError;兜底入册不吞(CODING_STANDARDS:不伪造数据)。
            recordPlaceholder(job: job, reason: .other(errno: 0))
            settleOne()
            return
        }

        var node = SpaceNode(
            name: SpaceScanEngine.lastName(of: job.displayPath),
            path: job.displayPath,
            kind: .directory,
            ownModifiedEpoch: job.modifiedEpoch
        )
        var childDirs: [String] = []
        var childJobs: [PendingDir] = []
        var dirStats = ScanStats()

        for entry in entries {
            dirStats.entriesSeen += 1
            // 双路径域:物理路径继续喂枚举;规范路径进树/排除判定(与用户可见路径同域)。
            let childPath = job.path == "/" ? "/" + entry.name : job.path + "/" + entry.name
            let childDisplay = job.displayPath == "/" ? "/" + entry.name : job.displayPath + "/" + entry.name

            switch entry.kind {
            case .directory:
                // 探针 11 ⑤:firmlink 双路径同 (dev, fileID)——先到先得,同一子树只走一次。
                // (fileID 0 = 边界没给身份,不占坑不判重,与旧实现一致)
                let key = IdentityKey(device: entry.deviceID, fileID: entry.fileID)
                let alreadyVisited = entry.fileID != 0 && claimDirectory(key)
                guard !alreadyVisited else {
                    dirStats.doubleVisitSkips += 1
                    continue
                }

                if isExcluded(childDisplay) {
                    // 排除目录(GLOSSARY):不下潜、不计数——扫描与删除两处都收窄。
                    continue
                }
                dirStats.directories += 1
                childDirs.append(childDisplay)
                childJobs.append(PendingDir(
                    path: childPath,
                    displayPath: childDisplay,
                    depth: job.depth + 1,
                    modifiedEpoch: entry.modifiedEpoch
                ))

            case .file:
                // 硬链接同 (dev, fileID) 只计首个(dust §2.3;先到先得,并行下由分片锁定序)。
                if entry.fileID != 0 {
                    let key = IdentityKey(device: entry.deviceID, fileID: entry.fileID)
                    guard !claimFile(key) else {
                        dirStats.hardlinkSkips += 1
                        continue
                    }
                }
                dirStats.files += 1
                if entry.isDataless {
                    dirStats.datalessFiles += 1
                }
                node.fileCount += 1
                if entry.isDataless {
                    node.datalessCount += 1
                }
                let bytes = entry.reclaimableSize ?? entry.allocatedSize
                node.accountedBytes += bytes
                dirStats.accountedBytes += bytes
                if let reclaimable = entry.reclaimableSize {
                    node.reclaimableBytes += reclaimable
                } else {
                    node.allReclaimableAccounting = false
                }
                node.fallbackBytes += entry.allocatedSize
                // 文件 mtime 上卷进年龄聚合(目录 mtime 有意不计,见字段注释)。
                if let modified = entry.modifiedEpoch {
                    node.newestChangeEpoch = max(node.newestChangeEpoch ?? modified, modified)
                }
                // 文件节点可选不进树(内存量级,见 SpaceScanOptions.retainFileNodes)。
                if options.retainFileNodes {
                    node.children.append(SpaceNode(
                        name: entry.name,
                        path: childDisplay,
                        kind: .file,
                        accountedBytes: bytes,
                        reclaimableBytes: entry.reclaimableSize ?? 0,
                        fallbackBytes: entry.allocatedSize,
                        allReclaimableAccounting: entry.reclaimableSize != nil,
                        fileCount: 1,
                        datalessCount: entry.isDataless ? 1 : 0,
                        newestChangeEpoch: entry.modifiedEpoch
                    ))
                }

            case .symlink:
                // 不跟随(spec:dust 默认同款);链接本体字节可忽略,单独计数上屏。
                dirStats.symlinks += 1
                node.symlinkCount += 1

            case .other:
                break
            }
        }

        commit(displayPath: job.displayPath, node: node, childDirs: childDirs, childJobs: childJobs, dirStats: dirStats)
    }

    // MARK: 同步锁帮手(async 上下文禁直接 NSLock.lock,Swift 6;锁内无 await)

    /// 目录占坑:已在册返回 true(双访跳过),否则登记。
    private func claimDirectory(_ key: IdentityKey) -> Bool {
        dirLock.lock()
        defer { dirLock.unlock() }
        if visitedDirs.contains(key) {
            return true
        }
        visitedDirs.insert(key)
        return false
    }

    /// 文件占坑:同 (dev, fileID) 已见过返回 true(硬链接跳过),否则登记。
    private func claimFile(_ key: IdentityKey) -> Bool {
        let shard = fileShards[Int(key.fileID % UInt64(Self.fileShardCount))]
        shard.lock.lock()
        defer { shard.lock.unlock() }
        if shard.seen.contains(key) {
            return true
        }
        shard.seen.insert(key)
        return false
    }

    private func markCancelledAndDrain() {
        stateLock.lock()
        cancelled = true
        stack.removeAll()
        stateLock.unlock()
    }

    /// 空节点占位(超深 / 枚举失败):台账记物理路径(诊断),树记录挂规范路径。
    private func recordPlaceholder(job: PendingDir, reason: CleanEnumerateFailure) {
        recordPlaceholder(
            physical: job.path,
            display: job.displayPath,
            error: CleanEnumerateError(path: job.path, reason: reason),
            ownModifiedEpoch: job.modifiedEpoch
        )
    }

    private func recordPlaceholder(error: CleanEnumerateError, display: String, ownModifiedEpoch: Double?) {
        recordPlaceholder(physical: error.path, display: display, error: error, ownModifiedEpoch: ownModifiedEpoch)
    }

    /// 占位节点(读不了 / 超深)同样带目录自身 mtime 快照:部分扫描项照列成候选,
    /// 删前复核一视同仁(快照来自父列表,与本目录能否打开无关)。
    private func recordPlaceholder(
        physical: String,
        display: String,
        error: CleanEnumerateError,
        ownModifiedEpoch: Double?
    ) {
        stateLock.lock()
        ledger.append(error)
        records[display] = Record(
            node: SpaceNode(
                name: SpaceScanEngine.lastName(of: display),
                path: display,
                kind: .directory,
                isPartial: true,
                ownModifiedEpoch: ownModifiedEpoch
            ),
            childDirPaths: []
        )
        stateLock.unlock()
    }

    /// 单目录收工:记账 + 统计合并(含进度) + 子目录入栈 + 在途减一,一把锁内完成。
    private func commit(
        displayPath: String,
        node: SpaceNode,
        childDirs: [String],
        childJobs: [PendingDir],
        dirStats: ScanStats
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        records[displayPath] = Record(node: node, childDirPaths: childDirs)
        mergeStats(dirStats)
        // 子目录逆序入栈:单 worker 时弹出序 = 入口序(与旧递归 DFS 逐位一致)。
        stack.append(contentsOf: childJobs.reversed())
        inFlight -= 1
    }

    /// 必须持 stateLock 调用:统计合并 + 进度按目录粒度跨越 ~2048 项一发。
    private func mergeStats(_ delta: ScanStats) {
        stats.entriesSeen += delta.entriesSeen
        stats.files += delta.files
        stats.directories += delta.directories
        stats.symlinks += delta.symlinks
        stats.datalessFiles += delta.datalessFiles
        stats.hardlinkSkips += delta.hardlinkSkips
        stats.doubleVisitSkips += delta.doubleVisitSkips
        stats.accountedBytes += delta.accountedBytes
        if let cb = progress, stats.entriesSeen - lastProgressAt >= 2048 {
            lastProgressAt = stats.entriesSeen
            let snapshot = stats
            stateLock.unlock()
            cb(snapshot)
            stateLock.lock()
        }
    }

    // MARK: 收工:拼树 + 汇总

    func finish() {
        stateLock.lock()
        let snapshot = stats
        stateLock.unlock()
        progress?(snapshot)
    }

    func result(rootMetas: [(path: String, name: String)]) -> SpaceScanResult {
        stateLock.lock()
        let records = records
        let ledger = ledger
        let stats = stats
        let cancelled = cancelled
        stateLock.unlock()

        func absorb(_ child: SpaceNode, into node: inout SpaceNode) {
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

        // 自底向上拼装;记录缺口(取消点之后的目录)→ 祖先标 partial。
        func build(_ path: String) -> SpaceNode? {
            guard let record = records[path] else { return nil }
            var node = record.node
            var missingChild = false
            for childPath in record.childDirPaths {
                if let child = build(childPath) {
                    absorb(child, into: &node)
                } else {
                    missingChild = true
                }
            }
            if missingChild {
                node.isPartial = true
            }
            return node
        }

        var trees: [SpaceNode] = []
        for root in rootMetas {
            if let tree = build(root.path) {
                trees.append(tree)
            } else if cancelled {
                // 与旧实现一致:取消也保留(空 partial)根节点,已扫部分照常可用。
                trees.append(SpaceNode(name: root.name, path: root.path, kind: .directory, isPartial: true))
            }
        }
        return SpaceScanResult(trees: trees, ledger: ledger, stats: stats, cancelled: cancelled)
    }
}
