import Foundation
import Observation
import PulseCore

// MARK: - 清理页状态机(p4-cleaner/03 扫描 + p4-cleaner/04 删除管线)

//
// 用户触发的按需扫描(spec 实现决定):不挂 MonitorFeatures、无常驻采集、
// 结果只留内存——重进 tab 沿用,重新扫描才刷新;关窗随 MainWindowGate 销毁。
// 扫描跑在 .utility 低优先级 detached Task(探针 15 复测:全卷 ≈340 万项 ≈155s,
// 不加并发);取消走 Task.cancel,引擎在目录入口消费(p4-cleaner/02 的取消语义:
// 已产出部分保留)。树只留目录节点(SpaceScanOptions.retainFileNodes = false):
// 文件级节点全量驻留 ≈900 MB,目录粒度 ≈90 MB,清单与地图都只认目录。
//
// 删除管线(04)全部由 PulseCore 纯值驱动,本类只做粘合与发布:
//   清单 = JunkMatcher 跑在扫描树上(白名单命中才有;ADR-0008);
//   勾选 = JunkSelection(默认全不勾);计划 = CleanPlan(删前排除二次判定);
//   执行 = CleanRunner → CleanTrashExecutor(唯一删除出口;生产 Live、测试 spy);
//   历史 = CleanHistoryStore(历史库缺席照常删,只是不记,界面如实说)。

@MainActor
@Observable
final class CleanerModel {
    enum Phase {
        case idle
        case scanning(ScanStats)
        case finished(SpaceScanResult)
    }

    /// 删除管线的阶段:确认清单只在 confirming 出现;finished 带战报供结果卡展示。
    enum CleanPhase: Equatable {
        case idle
        case confirming
        case running
        /// `historyRecorded` = 本次已写进清理历史(库缺席 / 写失败为 false,结果卡如实说)。
        case finished(CleanRunReport, historyRecorded: Bool)
    }

    private(set) var phase: Phase = .idle {
        didSet { phaseGeneration &+= 1 }
    }

    /// phase 每次赋值 +1:清单快照的「扫描结果换了没有」判据(结果是大值类型,不比内容)。
    @ObservationIgnored private var phaseGeneration = 0
    private(set) var scanStartedAt: Date?
    private(set) var scanFinishedAt: Date?

    /// 空间地图显示树(07):firmlink 提升 + 密封折叠后的每根一棵;扫描任务侧构建,
    /// 与 `result` 同时落位。重进 tab 沿用,重新扫描才刷新(与 03 缓存同寿命)。
    private(set) var mapTrees: [SpaceMapNode] = []

    /// 已装 bundle id 全集(p5-cleaner/02,判卸载残留的权威源):扫描完成 / 缓存装载
    /// 各采一次,**先于** phase 落位——清单备忘键的 phaseGeneration 天然覆盖,不另立键。
    /// nil = 尚无结果;只有 `.complete` 判孤儿,失败态整组不出(fail-closed)并如实提示。
    private(set) var installedApps: InstalledAppInventory?

    private(set) var cleanPhase: CleanPhase = .idle
    private(set) var selection = JunkSelection()
    /// 本会话已移入废纸篓的路径:树里还挂着(不重扫),清单里不再列。
    private(set) var recycledPaths: Set<String> = []

    /// 当前结果是否来自落盘缓存(重启后装载)。真实扫描(含重扫)置回 false。
    private(set) var loadedFromCache = false
    /// 装载时的元信息(时间戳给页头「上次扫描 X 前」;排除快照给过期判定)。
    private(set) var loadedCacheMeta: SpaceScanMeta?
    /// 最近一次落盘的元信息(清理后增量更新 cleanedPaths 用;扫描/装载时刷新)。
    private(set) var lastSavedMeta: SpaceScanMeta?
    /// 本会话亲手清理的项数(页头「本次已清理」只认它,不含缓存带来的历史清理)。
    private(set) var sessionCleanedCount = 0

    // MARK: 清空废纸篓(p4-uninstaller/04,自 08 摘出;Q3 腾空间闭环)

    enum TrashPhase: Equatable {
        case idle
        case inventorying
        case confirming(TrashInventory)
        case running
        case finished(TrashEmptySummary)
    }

    private(set) var trashPhase: TrashPhase = .idle
    /// 短提示(空废纸篓等;横幅可关)。
    private(set) var trashNotice: String?
    /// 缓存恢复进行中(空态卡的「正在恢复…」文案判据;常态亚秒,满载数秒)。
    private(set) var isRestoringCache = false

    /// 清理活动变化广播(quit 门卫订阅):userInfo["running"] = Bool。
    /// nonisolated:Notification.Name 是不可值,门卫(nonisolated 类)直接引用。
    nonisolated static let cleanActivityNotification = Notification.Name("cleanerCleanActivityChanged")

    /// 清理历史列表(nil = 尚未加载或不可用;见 `historyAvailable`)。
    private(set) var historyRuns: [CleanRunRecord]?
    private(set) var historyItems: [Int64: [CleanItemRecord]] = [:]
    private(set) var historyLoadFailed = false

    private var scanTask: Task<Void, Never>?
    private let engine = SpaceScanEngine()
    private let exclusions: CleanExclusionsStore
    private let scanRoots: CleanScanRootsStore
    private let history: CleanHistoryStore?
    private let trash: any CleanTrashExecutor
    private let activity: (any CleanActivitySource)?
    /// 只读系统卷的卷级字节(方案 A:SSV/Preboot/VM 等不逐文件走,statfs 一笔;
    /// 生产 Live,测试注固定值;nil = 不注入,地图无密封块——不伪造)。
    private let volumeSummaries: (@Sendable () -> [SpaceMapVolumeSummary])?
    /// 扫描结果落盘缓存(p4-cleaner/11):扫完写、开清理页时若无内存结果则读。
    /// nil = 不落盘(预览 / 旧测试)。读 = 打开清理页一次(后台),写 = 扫完一次;
    /// 常驻稳态零——不挂调度,关窗照旧释放内存树。
    private let scanCache: CleanScanResultStore?
    /// 已装全集采集器(p5-cleaner/02):生产 Live(树内 bundle ∪ 标准目录 ∪ 运行中);
    /// 测试注入固定结果。同步重活,只在扫描 / 装载的后台任务里调。
    private let installedAppInventory: @Sendable (
        _ trees: [SpaceNode],
        _ scanCancelled: Bool,
        _ home: String
    ) -> InstalledAppInventory
    private let homeDirectory: String

    /// 两组展示排序(08:统一 Core 的 JunkSortOrder;项目产物沿用 05 拍板
    /// 默认大小、可切新旧;工具缓存排序为 08 新增,两组互不影响)。
    var artifactSort: JunkSortOrder = .size
    var toolCacheSort: JunkSortOrder = .size
    /// 卸载残留组排序(p5-cleaner/02:组头同款 seg,三组互不影响)。
    var orphanSort: JunkSortOrder = .size

    /// 组排序读写(穷举 switch:新增分组必须在这里表态,不会静默蹭别组的排序)。
    func sortOrder(for group: JunkGroup) -> JunkSortOrder {
        switch group {
        case .globalToolCache: toolCacheSort
        case .projectArtifacts: artifactSort
        case .uninstallLeftovers: orphanSort
        }
    }

    func setSortOrder(_ order: JunkSortOrder, for group: JunkGroup) {
        switch group {
        case .globalToolCache: toolCacheSort = order
        case .projectArtifacts: artifactSort = order
        case .uninstallLeftovers: orphanSort = order
        }
    }

    /// - Parameters:
    ///   - exclusions: 排除目录(设置页同一实例;默认不落盘的空表给预览 / 测试)。
    ///   - scanRoots: 清理扫描根(05;与归组项目根两套配置,零共享;设置页同一实例)。
    ///   - history: 清理历史(`monitor.history.cleanHistory`;nil = 历史库不可用)。
    ///   - trash: 废纸篓执行器(生产 Live;测试 spy——核心测试纪律:绝不真删)。
    ///   - activity: 进程活动源(在用保护输入;生产 = monitor 的采样快照投影,
    ///     测试 FakeCleanActivitySource;nil = 无活动源,在用保护按无活动处理)。
    ///   - volumeSummaries: 只读系统卷卷级摘要源(生产 statfs;测试固定值)。
    ///   - homeDirectory: 规则表相对它展开;测试注入假家目录。
    ///   - markerExists: 项目产物标记探测(cleaner-hardening/02;生产查盘,测试注入假集合)。
    ///   - installedAppInventory: 已装 bundle id 全集采集(p5-cleaner/02;默认 Live——
    ///     装配点漏传即功能静默死亡的病(票 11 scanCache 实案)不再给机会)。
    init(
        exclusions: CleanExclusionsStore = CleanExclusionsStore(load: { [] }, persist: { _ in }),
        scanRoots: CleanScanRootsStore = CleanScanRootsStore(load: { [] }, persist: { _ in }),
        history: CleanHistoryStore? = nil,
        trash: any CleanTrashExecutor = LiveCleanTrashExecutor(),
        activity: (any CleanActivitySource)? = nil,
        volumeSummaries: (@Sendable () -> [SpaceMapVolumeSummary])? = nil,
        scanCache: CleanScanResultStore? = nil,
        homeDirectory: String = NSHomeDirectory(),
        markerExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        installedAppInventory: @escaping @Sendable ([SpaceNode], Bool, String) -> InstalledAppInventory = {
            LiveInstalledAppInventory.collect(trees: $0, scanCancelled: $1, home: $2)
        },
        trashInventory: @escaping @Sendable () async -> TrashInventory = {
            await LiveCleanTrashExecutor().inventory()
        }
    ) {
        self.exclusions = exclusions
        self.scanRoots = scanRoots
        self.history = history
        self.trash = trash
        self.activity = activity
        self.volumeSummaries = volumeSummaries
        self.scanCache = scanCache
        self.installedAppInventory = installedAppInventory
        self.homeDirectory = PathNormalization.normalize(homeDirectory)
        self.markerExists = markerExists
        trashInventorySource = trashInventory
    }

    @ObservationIgnored private let markerExists: (String) -> Bool
    @ObservationIgnored private let trashInventorySource: @Sendable () async -> TrashInventory

    /// 点「清空废纸篓」:先清点(数字进确认弹窗);空废纸篓给短提示不弹窗。
    func beginEmptyTrash() {
        guard trashPhase == .idle else { return }
        trashPhase = .inventorying
        Task.detached(priority: .userInitiated) { [weak self, trashInventorySource] in
            let inventory = await trashInventorySource()
            await MainActor.run {
                guard let self else { return }
                if inventory.isEmpty {
                    self.trashPhase = .idle
                    self.trashNotice = "废纸篓是空的"
                } else {
                    self.trashPhase = .confirming(inventory)
                }
            }
        }
    }

    func cancelEmptyTrash() {
        guard case .confirming = trashPhase else { return }
        trashPhase = .idle
    }

    func confirmEmptyTrash() {
        guard case .confirming = trashPhase else { return }
        trashPhase = .running
        Task.detached(priority: .userInitiated) { [weak self, trash] in
            let summary = await trash.emptyTrash()
            await MainActor.run {
                guard let self else { return }
                self.trashPhase = .finished(summary)
                LogService.info(
                    "清空废纸篓:释放 \(PulseFormat.memory(UInt64(max(0, summary.totalFreedBytes)))) · 清空 \(summary.totalItems) 项 · 跳过 \(summary.totalSkipped) 项",
                    category: "Cleaner"
                )
            }
        }
    }

    /// 结果横幅 / 短提示的关闭。
    func dismissTrashFeedback() {
        if case .finished = trashPhase {
            trashPhase = .idle
            return
        }
        trashNotice = nil
    }

    /// 生产扫描并发:6 个 worker(元数据密集型遍历,留核给 UI;引擎侧再按活动核数封顶)。
    static let productionScanConcurrency = 6

    /// 生产扫描根(方案 A,票 10):只对 Data 卷做文件级扫描(用户数据/缓存/项目
    /// 全在这,路径天然规范);SSV/Preboot/VM 等只读卷以卷级字节进地图密封块,
    /// 不再逐文件走——真机 Data 并行扫描 56s(vs 全卷 86s / 旧串行 234s)。
    /// 测试仍可经 startScan(roots:) 注入任意根。
    static let productionScanRoot = SpaceMapTree.dataVolumePath

    var isScanning: Bool {
        if case .scanning = phase {
            return true
        }
        return false
    }

    var result: SpaceScanResult? {
        if case let .finished(result) = phase {
            return result
        }
        return nil
    }

    /// TCC 拒绝的目录数——FDA 引导横幅的判据(EPERM,授权可解;2026-11-03 拆分:
    /// root/他属主的 EACCES 不再引导授权——FDA 帮不了它们,引导是误导)。
    var permissionDeniedCount: Int {
        guard let result else { return 0 }
        return result.ledger.count { $0.reason == .tccDenied }
    }

    var permissionHint: String? {
        let count = permissionDeniedCount
        guard count > 0 else { return nil }
        return "\(count) 个目录因 macOS 隐私保护未能扫到,授权全盘访问后重扫可收进来"
    }

    /// 缓存结果的过期提示:扫描后排除配置变了 → 数字可能偏大(被排除的目录还在
    /// 旧树里),建议重扫;配置一致则 nil。真实扫描永远无此提示。
    var cacheStalenessHint: String? {
        guard loadedFromCache, let meta = loadedCacheMeta,
              meta.excludedPathPrefixes != exclusions.paths else { return nil }
        return "上次扫描后排除配置已变——清单可能多列了新排除的目录,建议重新扫描"
    }

    // MARK: 缓存装载(p4-cleaner/11:开清理页时若无内存结果则读盘一次)

    /// 空态才装(有扫描在跑 / 已有结果都不动);后台解码,落主线程后照常出清单/地图。
    func loadCachedScan() {
        guard case .idle = phase, scanTask == nil else {
            LogService.info("缓存装载:跳过(phase 非空态或扫描在跑)", category: "Cleaner")
            return
        }
        guard let scanCache else {
            LogService.warn("缓存装载:无 store(装配缺失?)", category: "Cleaner")
            return
        }
        isRestoringCache = true
        LogService.info("缓存装载:开始读盘+解码", category: "Cleaner")
        // userInitiated:用户点开清理页正在等这个结果(真机实锤 2026-11-03:满载下
        // utility 解码被饿 21s,空态期被当成了「没缓存」;同文件常态 0.6s)。
        let collectApps = appInventoryCollector()
        Task.detached(priority: .userInitiated) { [weak self, scanCache, volumeSummaries, collectApps] in
            guard let payload = scanCache.load() else {
                LogService.warn("缓存装载:文件缺失或解码失败", category: "Cleaner")
                await MainActor.run { self?.isRestoringCache = false }
                return
            }
            let sealedVolumes = volumeSummaries?() ?? []
            let mapTrees = payload.result.trees.map {
                SpaceMapTree.build(from: $0, sealedVolumes: sealedVolumes)
            }
            // 已装全集现采(p5-cleaner/02):树是缓存快照,标准目录与运行中取此刻——
            // 比落盘一份扫描时的全集更保守(装机后新装的 app 立即受保护)。
            let inventory = collectApps(payload.result.trees, payload.result.cancelled)
            await MainActor.run { self?.applyCached(payload, mapTrees: mapTrees, inventory: inventory) }
        }
    }

    private func applyCached(
        _ payload: SpaceScanCachePayload,
        mapTrees: [SpaceMapNode],
        inventory: InstalledAppInventory
    ) {
        isRestoringCache = false
        guard case .idle = phase, scanTask == nil else {
            LogService.warn("缓存装载:解码完成但状态已变,放弃套用", category: "Cleaner")
            return
        }
        // 旧账纠正:EPERM=TCC 的分类已收窄为「仅用户域」;缓存里扫描时记下的系统域
        // tccDenied(/private/var、com.apple.* 守护缓存)在此归位,重开即消横幅,
        // 不必重扫。
        var result = payload.result
        result.ledger = result.ledger.map { entry in
            guard case .tccDenied = entry.reason,
                  !LiveCleanDirectoryEnumerator.isUserDomain(entry.path)
            else { return entry }
            return CleanEnumerateError(path: entry.path, reason: .permissionDenied)
        }
        LogService.info(
            "缓存装载:已套用 · 项 \(payload.result.stats.entriesSeen) · 扫描于 \(payload.meta.finishedAt)",
            category: "Cleaner"
        )
        installedApps = inventory // 先于 phase:清单首读即带全集
        phase = .finished(result)
        self.mapTrees = mapTrees
        scanStartedAt = payload.meta.startedAt
        scanFinishedAt = payload.meta.finishedAt
        loadedFromCache = true
        loadedCacheMeta = payload.meta
        lastSavedMeta = payload.meta
        // 落盘后的清理记录照旧过滤(树是快照,这些路径已进废纸篓)。
        recycledPaths.formUnion(payload.meta.cleanedPaths)
    }

    // MARK: 扫描

    /// - Parameter enumerator: 生产不传 = Live 扫描器;测试传 TestSupport 假实现
    ///   (协议注入,p4-cleaner/02 的接缝约定)。
    func startScan(
        using enumerator: (any CleanDirectoryEnumerator)? = nil,
        roots: [String]? = nil
    ) {
        // 生产默认 = Data 卷(方案 A);测试注入假枚举器时常配合显式 roots。
        let scanRoots = roots ?? [Self.productionScanRoot]
        guard scanTask == nil else { return }
        scanStartedAt = Date()
        scanFinishedAt = nil
        phase = .scanning(ScanStats())
        mapTrees = []
        installedApps = nil
        // 重扫 = 新一轮真相:已回收集合清空(树会重新反映磁盘),勾选随清单收敛;
        // 缓存态一并复位(真实扫描覆盖装载态)。
        recycledPaths = []
        sessionCleanedCount = 0
        loadedFromCache = false
        loadedCacheMeta = nil
        if case .finished = cleanPhase {
            cleanPhase = .idle
        }
        let liveEnumerator = LiveCleanDirectoryEnumerator()
        let source = enumerator ?? liveEnumerator
        // 方案 A 路径域修正:物理根喂枚举器,树路径以规范根("/")落——匹配/排除/展示同域。
        // 测试注入自定义 roots 时保持原样(夹具路径即规范路径)。
        let canonical = scanRoots == [Self.productionScanRoot] ? ["/"] : nil
        let options = SpaceScanOptions(
            roots: scanRoots,
            excludedPathPrefixes: exclusions.paths,
            retainFileNodes: false,
            // petal 式并行(性能票):真机 Data 卷 ≈500 万项,6 个长驻 worker
            // 吃共享目录栈;测试注入假枚举器时保持默认串行(请求序断言依赖确定性)。
            maxConcurrency: Self.productionScanConcurrency,
            canonicalRoots: canonical
        )

        let collectApps = appInventoryCollector()
        scanTask = Task.detached(priority: .utility) { [engine, volumeSummaries, scanCache, collectApps, weak self] in
            let scanBegin = Date()
            let result = await engine.scan(
                options,
                using: source,
                progress: { stats in
                    // 引擎每 2048 项发一次(≈10 次/s @2.1 万项/s),直接跳 MainActor
                    // 足够;迟到的进度跳块由 isScanning 守门,不会盖掉 finished。
                    Task { @MainActor in
                        guard let self, self.isScanning else { return }
                        self.phase = .scanning(stats)
                    }
                },
                isCancelled: { Task.isCancelled }
            )
            // 显示树变换(Data 根规范路径 + 卷级密封块注入)整树一次,放在扫描
            // 任务里,不占主线程;地图子页直接消费(03 缓存的第二读者)。
            let sealedVolumes = volumeSummaries?() ?? []
            let mapBegin = Date()
            let mapTrees = result.trees.map {
                SpaceMapTree.build(from: $0, sealedVolumes: sealedVolumes)
            }
            // 已装全集(p5-cleaner/02):随结果一次采集,与 phase 同时落位;取消的扫描
            // 是半棵树 → fail-closed(卸载残留整组不出,采集器内判)。
            let inventory = collectApps(result.trees, result.cancelled)
            // 分段计时(诊断用,票 10):真机基准 Data+6worker ≈56s;偏离时看三段各占多少。
            LogService.info(
                "扫描计时:walk \(Int(Date().timeIntervalSince(scanBegin)))s"
                    + " · map \(Int(Date().timeIntervalSince(mapBegin) * 1000))ms"
                    + " · 项 \(result.stats.entriesSeen) · 错误 \(result.ledger.count)",
                category: "Cleaner"
            )
            // 落盘缓存(票 11):写一次,失败只记日志不影响扫描结果;体积/耗时实测
            // 见票面(真机 60 万节点 Release 基准)。取消的扫描是半棵树,不落盘——
            // 否则覆盖掉上一份完整缓存,重开看到残缺地图(cleaner-hardening/04)。
            if let scanCache, !result.cancelled {
                let started = await MainActor.run { self?.scanStartedAt ?? Date() }
                let excluded = await MainActor.run { self?.exclusions.paths ?? [] }
                let meta = SpaceScanMeta(
                    startedAt: started,
                    finishedAt: Date(),
                    roots: scanRoots,
                    excludedPathPrefixes: excluded
                )
                let payload = SpaceScanCachePayload(meta: meta, result: result)
                await MainActor.run { self?.lastSavedMeta = meta }
                let encodeBegin = Date()
                scanCache.save(payload)
                LogService.info(
                    "扫描缓存:写入 \(Int(Date().timeIntervalSince(encodeBegin) * 1000))ms",
                    category: "Cleaner"
                )
            }
            await MainActor.run { self?.finish(result, mapTrees: mapTrees, inventory: inventory) }
        }
    }

    /// 已装全集采集器绑上家目录(扫描 / 装载两条后台任务共用;与清单同一家目录口径)。
    private func appInventoryCollector() -> @Sendable ([SpaceNode], Bool) -> InstalledAppInventory {
        let collect = installedAppInventory
        let home = homeDirectory
        return { collect($0, $1, home) }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func finish(_ result: SpaceScanResult, mapTrees: [SpaceMapNode], inventory: InstalledAppInventory) {
        scanFinishedAt = Date()
        installedApps = inventory // 先于 phase:清单首读即带全集
        phase = .finished(result)
        self.mapTrees = mapTrees
        scanTask = nil
        selection.retain(in: candidates)
    }

    // MARK: 清单(04 全局缓存 + 05 项目产物)

    /// 白名单命中的可删单元:全局缓存(04)+ 项目产物(05)都跑在同一棵扫描树上,
    /// 排除目录与本会话已回收的项不列。仍是计算属性——读 `phase` / `exclusions.paths` /
    /// `scanRoots.paths` / `recycledPaths` 照常登记观察,设置页改动即时反映、不必重扫;
    /// 但按这四样输入记忆化(cleaner-hardening/05):一次渲染读好几次、点勾选整卡重绘,
    /// 输入不变就不重跑匹配器(项目产物要整棵 DFS + 查标记文件)。
    var candidates: [JunkCandidate] {
        let key = CandidatesKey(
            phaseGeneration: phaseGeneration,
            excluded: exclusions.paths,
            roots: scanRoots.paths,
            recycled: recycledPaths
        )
        // 先读 phase 再判缓存:保证观察登记与未命中时一致。
        guard let result else { return [] }
        if let candidatesMemo, candidatesMemo.key == key {
            return candidatesMemo.value
        }
        let value = computeCandidates(in: result, key: key)
        candidatesMemo = (key, value)
        return value
    }

    private struct CandidatesKey: Equatable {
        let phaseGeneration: Int
        let excluded: [String]
        let roots: [String]
        let recycled: Set<String>
    }

    @ObservationIgnored private var candidatesMemo: (key: CandidatesKey, value: [JunkCandidate])?

    private func computeCandidates(in result: SpaceScanResult, key: CandidatesKey) -> [JunkCandidate] {
        let excluded = key.excluded
        let global = JunkMatcher.candidates(
            in: result.trees,
            home: homeDirectory,
            excludedPathPrefixes: excluded
        )
        let artifacts = ProjectArtifactMatcher.artifacts(
            in: result.trees,
            roots: key.roots,
            excludedPathPrefixes: excluded,
            fileExists: markerExists
        )
        // 卸载残留(p5-cleaner/02):全集完整才判;采集失败 / 扫描取消 = 整组不出
        // (fail-closed,`orphanDetectionUnavailableReason` 如实说)。全集随 phase 落位,
        // 备忘键不必另带。
        let orphans = installedApps?.bundleIDs.map {
            OrphanLeftoverDetector.detect(
                in: result.trees,
                home: homeDirectory,
                installedBundleIDs: $0,
                excludedPathPrefixes: excluded,
                now: Date().timeIntervalSince1970
            )
        } ?? []
        // 与规则表 / 项目产物重叠的孤儿让位(org.swift.swiftpm 真案:CLI 缓存无 .app)。
        let claimed = global + artifacts
        let leftovers = OrphanLeftoverDetector.excludingOverlaps(orphans, claimedBy: claimed)

        // 不过滤亚兆条目(2026-11-06 用户拍板:0 KB 产物也是该清的东西,照列;
        // 显示层由 memory() 的 KB 档给出真实读数)。
        return (claimed + leftovers)
            .filter { !key.recycled.contains($0.path) }
    }

    /// 配置了项目扫描根没有(设置页引导文案与项目产物空态的判据)。
    var hasScanRoots: Bool {
        !scanRoots.paths.isEmpty
    }

    // MARK: 卸载残留(p5-cleaner/02)

    /// 本次结果做了卸载残留检测(已装全集完整)——页头注记「含卸载残留检测」的判据。
    var orphanDetectionActive: Bool {
        result != nil && installedApps?.bundleIDs != nil
    }

    /// 卸载残留**没检测**的原因(全集采集失败 / 扫描取消;nil = 检测了或尚无结果)。
    /// 「没查」与「查了没有」严格分开:前者如实说,后者按空态规则整组不出(spec §13)。
    var orphanDetectionUnavailableReason: String? {
        guard result != nil else { return nil }
        return installedApps?.unavailableReason
    }

    /// 空间地图「这块能清」角标判定(p4-uninstaller/05 + p5-cleaner/02):白名单规则表 ∪
    /// 本次卸载残留候选(孤儿目录本身及其内部)。返回判定闭包——孤儿路径集合每次渲染
    /// 建一次,逐块只查表。与清单同源:清单里没有的孤儿(已回收 / 被排除 / 让位规则表)
    /// 地图也不标。
    func mapCleanableResolver() -> (String) -> JunkGroup? {
        let home = homeDirectory
        let orphanPaths = Set(candidates.filter { $0.group == .uninstallLeftovers }.map(\.path))
        return { path in
            if let group = JunkRuleTable.cleanableGroup(for: path, home: home) {
                return group
            }
            var current = path
            while !orphanPaths.isEmpty, current.count > 1 {
                if orphanPaths.contains(current) {
                    return .uninstallLeftovers
                }
                current = (current as NSString).deletingLastPathComponent
            }
            return nil
        }
    }

    // MARK: 在用保护(05:判定永不缓存,删除前重查)

    /// 活动条目现查(清单视图一次渲染取一份逐行复用;`plan` 与单查接口各自现查)。
    func currentActivityEntries() -> [CleanActivityEntry] {
        activity?.activeEntries() ?? []
    }

    /// 候选的在用原因(nil = 不在用)。每次调用现查活动源——扫描时判定一次影响
    /// 展示,删除前(经 `plan`)再查一次,两查之间活动变化如实反映。
    func inUseReasons(for candidate: JunkCandidate) -> CleanActivityReason? {
        inUseReasons(for: candidate, entries: currentActivityEntries())
    }

    /// 带现成活动条目的重载(同一次渲染里逐行复用,判定仍然来自当次现查)。
    func inUseReasons(
        for candidate: JunkCandidate,
        entries: [CleanActivityEntry]
    ) -> CleanActivityReason? {
        CleanInUse.reasons(protectingPath: protectionPath(of: candidate), entries: entries)
    }

    /// 保护路径:项目产物按**项目目录**判(终端在项目根 = 保护整个项目的产物),
    /// 其余按候选自身路径判(活动落在候选之内 = 在用)。
    private func protectionPath(of candidate: JunkCandidate) -> String {
        candidate.group == .projectArtifacts
            ? (candidate.path as NSString).deletingLastPathComponent
            : candidate.path
    }

    var excludedPathPrefixes: [String] {
        exclusions.paths
    }

    func isSelected(_ candidate: JunkCandidate) -> Bool {
        selection.contains(candidate)
    }

    func toggle(_ candidate: JunkCandidate) {
        selection.toggle(candidate)
    }

    func clearSelection() {
        selection.clear()
    }

    // MARK: 整组勾选(2026-10-30 用户拍板 B)

    /// 组头 checkbox 的三态。`safeCandidates` = 该组里「可安全清理」档的项——
    /// 整组勾选只看、只动这些;「先检查」项永远要用户单独点,不参与组勾选。
    func groupState(of safeCandidates: [JunkCandidate]) -> JunkSelection.GroupState {
        selection.state(of: safeCandidates)
    }

    /// 组头 checkbox 点击:none / mixed → 全勾;all → 全清。只动传入的候选。
    func toggleGroup(_ safeCandidates: [JunkCandidate]) {
        let selectAll = selection.state(of: safeCandidates) != .all
        selection.set(selectAll, for: safeCandidates)
    }

    /// 确认清单 = 选中 ∩ 清单 ∩ 非排除 ∩ **非在用**(CleanPlan 在此二次判定排除;
    /// 在用判定此刻现查活动源——spec「删除前重查一次、判定永不缓存」的落点,
    /// requestClean → confirmClean 各查一次)。
    var plan: CleanPlan {
        guard let activity else {
            return CleanPlan.make(selection: selection, candidates: candidates, excludedPathPrefixes: exclusions.paths)
        }
        let entries = activity.activeEntries()
        let usable = candidates.filter {
            CleanInUse.reasons(protectingPath: protectionPath(of: $0), entries: entries) == nil
        }
        return CleanPlan.make(selection: selection, candidates: usable, excludedPathPrefixes: exclusions.paths)
    }

    /// 右键排除:持久化进设置,清单即时收窄,勾选随之收敛。
    func exclude(_ path: String) {
        exclusions.add(path)
        selection.retain(in: candidates)
    }

    // MARK: 清理流程(04)

    func requestClean() {
        guard !plan.isEmpty, cleanPhase == .idle || isFinishedPhase else { return }
        cleanPhase = .confirming
    }

    func cancelClean() {
        guard cleanPhase == .confirming else { return }
        cleanPhase = .idle
    }

    /// 用户在确认清单上点了「移入废纸篓」:计划在此刻重新生成(排除二次判定),执行、
    /// 记历史、清单收敛。执行期间清单不可再动(UI 按 running 禁用)。
    func confirmClean() {
        guard cleanPhase == .confirming else { return }
        let plan = plan
        guard !plan.isEmpty else {
            cleanPhase = .idle
            return
        }
        cleanPhase = .running
        Self.postCleanActivity(true)
        Task { [trash, history, weak self] in
            let report = await CleanRunner.run(plan, using: trash)
            var recorded = false
            if let history {
                do {
                    recorded = try await history.record(report) != nil
                } catch {
                    LogService.error("清理历史落库失败:\(error)", category: "Cleaner")
                }
            }
            self?.applyCleanReport(report, historyRecorded: recorded)
        }
    }

    private static func postCleanActivity(_ running: Bool) {
        NotificationCenter.default.post(
            name: cleanActivityNotification,
            object: nil,
            userInfo: ["running": running]
        )
    }

    private func applyCleanReport(_ report: CleanRunReport, historyRecorded: Bool) {
        recycledPaths.formUnion(report.recycledPaths)
        sessionCleanedCount += report.recycledPaths.count
        selection.retain(in: candidates)
        cleanPhase = .finished(report, historyRecorded: historyRecorded)
        updateCacheAfterClean(recycled: Array(report.recycledPaths))
        Self.postCleanActivity(false)
        if historyRecorded, historyRuns != nil {
            Task { await loadHistory() }
        }
    }

    /// 清理后把 cleanedPaths 增量写回缓存(重开不再回列表;关窗不影响——后台任务
    /// 持 self,报告落地即写,185ms 级,不挡任何东西)。
    private func updateCacheAfterClean(recycled: [String]) {
        guard let scanCache, let result, let saved = lastSavedMeta else { return }
        let merged = Array(Set(saved.cleanedPaths).union(recycled)).sorted()
        let meta = SpaceScanMeta(
            startedAt: saved.startedAt,
            finishedAt: saved.finishedAt,
            roots: saved.roots,
            excludedPathPrefixes: exclusions.paths,
            cleanedPaths: merged
        )
        lastSavedMeta = meta
        let payload = SpaceScanCachePayload(meta: meta, result: result)
        Task.detached(priority: .utility) { scanCache.save(payload) }
    }

    func dismissCleanReport() {
        guard isFinishedPhase else { return }
        cleanPhase = .idle
    }

    private var isFinishedPhase: Bool {
        if case .finished = cleanPhase {
            return true
        }
        return false
    }

    // MARK: 清理历史(04;独立入口 = 第三子药丸)

    var historyAvailable: Bool {
        history != nil
    }

    func loadHistory() async {
        guard let history else { return }
        do {
            historyRuns = try await history.runs()
            historyLoadFailed = false
        } catch {
            historyLoadFailed = true
            LogService.error("清理历史读取失败:\(error)", category: "Cleaner")
        }
    }

    func loadHistoryItems(runID: Int64) async {
        guard let history, historyItems[runID] == nil else { return }
        do {
            historyItems[runID] = try await history.items(runID: runID)
        } catch {
            LogService.error("清理历史明细读取失败(run \(runID)):\(error)", category: "Cleaner")
        }
    }
}
