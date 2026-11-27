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
//   清单 = JunkMatcher 跑在扫描树上(白名单命中才有;ADR-0008)+ 项目产物 / 卸载残留
//     + 通用发现(名单外的缓存与日志,一律「先检查」;ADR-0013);
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
    /// 扫描代数(cleaner-scan-hang):startScan 递增,任务侧捕获自己的代数;落位
    /// (进度/finish)前比对——被强制放弃或被重扫取代的孤儿任务,迟到的结果与
    /// 进度一律拒收,不污染界面状态。
    @ObservationIgnored private var scanGeneration = 0
    /// 取消硬兜底时限:点取消后后台最多这么久没自己收尾,界面就强制退出扫描态。
    /// 生产默认 5s = 真机正常取消收尾(拼树 + 在途目录 settle)上限之上;测试注入短值。
    @ObservationIgnored private let scanCancelForceTimeout: TimeInterval
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

    /// 各组展示排序(08:统一 Core 的 JunkSortOrder;项目产物沿用 05 拍板
    /// 默认大小、可切新旧;组间互不影响)。p6-cleaner/01 新组各自表态,不蹭别组。
    var artifactSort: JunkSortOrder = .size
    var toolCacheSort: JunkSortOrder = .size
    /// 卸载残留组排序(p5-cleaner/02:组头同款 seg)。
    var orphanSort: JunkSortOrder = .size
    /// 浏览器 / 应用缓存 / AI 模型(p6-cleaner/01;AI 组规则在 02 落地,状态先备好)。
    var browserSort: JunkSortOrder = .size
    var appCacheSort: JunkSortOrder = .size
    var aiModelsSort: JunkSortOrder = .size
    /// 系统级 / 安装包(p7-cleaner/01;规则由 04 / 06 票落地,状态先备好)。
    var systemLevelSort: JunkSortOrder = .size
    var installersSort: JunkSortOrder = .size

    /// 组排序读写(穷举 switch:新增分组必须在这里表态,不会静默蹭别组的排序)。
    func sortOrder(for group: JunkGroup) -> JunkSortOrder {
        switch group {
        case .globalToolCache: toolCacheSort
        case .browserCache: browserSort
        case .appCache: appCacheSort
        case .projectArtifacts: artifactSort
        case .aiModels: aiModelsSort
        case .uninstallLeftovers: orphanSort
        case .systemLevel: systemLevelSort
        case .installers: installersSort
        }
    }

    func setSortOrder(_ order: JunkSortOrder, for group: JunkGroup) {
        switch group {
        case .globalToolCache: toolCacheSort = order
        case .browserCache: browserSort = order
        case .appCache: appCacheSort = order
        case .projectArtifacts: artifactSort = order
        case .aiModels: aiModelsSort = order
        case .uninstallLeftovers: orphanSort = order
        case .systemLevel: systemLevelSort = order
        case .installers: installersSort = order
        }
    }

    /// - Parameters:
    ///   - exclusions: 排除目录(设置页同一实例;默认不落盘的空表给预览 / 测试)。
    ///   - scanRoots: 清理扫描根(05;与归组项目根两套配置,零共享;设置页同一实例)。
    ///   - history: 清理历史(`monitor.features.history.cleanHistory`;nil = 历史库不可用)。
    ///   - trash: 废纸篓执行器(生产 Live;测试 spy——核心测试纪律:绝不真删)。
    ///   - activity: 进程活动源(在用保护输入;生产 = monitor 的采样快照投影,
    ///     测试 FakeCleanActivitySource;nil = 无活动源,在用保护按无活动处理)。
    ///   - volumeSummaries: 只读系统卷卷级摘要源(生产 statfs;测试固定值)。
    ///   - homeDirectory: 规则表相对它展开;测试注入假家目录。
    ///   - markerExists: 项目产物标记探测(cleaner-hardening/02;生产查盘,测试注入假集合)。
    ///   - directoryEnumerator: 生产扫描用的目录枚举器(arch-clean/01:必传,组装点在
    ///     `CleanAssembly`);测试可另经 `startScan(using:)` 单次覆盖。
    ///   - installedAppInventory / runningApps / trashInventory: **必传**(arch-clean/01)——
    ///     无默认值比「默认 Live」更强:装配点漏传直接编译失败(票 11 scanCache 实案的病)。
    ///     runningApps = 运行中应用采集(p7-cleaner/02,通用发现「在运行就跳过」的输入)。
    ///   - aiManifestReader: 读一个 Ollama manifest 文件的 UTF-8 内容
    ///     (p6-cleaner/02 内容寻址记账;生产 FileManager,测试注入字典)。
    ///   - trash: **必传,无默认值**(2026-11-21 收账:曾有默认 Live 真执行器,
    ///     新测试漏传又调清空 = 清空用户真废纸篓——编译期挡住;生产传
    ///     LiveCleanTrashExecutor,测试传 FakeCleanTrashExecutor;同
    ///     AlertCenter 发送器必传纪律)。
    ///   - runningAppsFreshness: 运行中应用读数多久内算新鲜(生产 1s;测试注入)。
    init(
        exclusions: CleanExclusionsStore = CleanExclusionsStore(load: { [] }, persist: { _ in }),
        scanRoots: CleanScanRootsStore = CleanScanRootsStore(load: { [] }, persist: { _ in }),
        history: CleanHistoryStore? = nil,
        trash: any CleanTrashExecutor,
        directoryEnumerator: any CleanDirectoryEnumerator,
        activity: (any CleanActivitySource)? = nil,
        volumeSummaries: (@Sendable () -> [SpaceMapVolumeSummary])? = nil,
        scanCache: CleanScanResultStore? = nil,
        homeDirectory: String = NSHomeDirectory(),
        markerExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        installedAppInventory: @escaping @Sendable ([SpaceNode], Bool, String) -> InstalledAppInventory,
        runningApps: @escaping @Sendable () -> [RunningAppIdentity],
        trashInventory: @escaping @Sendable () async -> TrashInventory?,
        aiManifestReader: @escaping (String) -> String? = { path in
            try? String(contentsOfFile: path, encoding: .utf8)
        },
        scanCancelForceTimeout: TimeInterval = 5,
        runningAppsFreshness: TimeInterval = 1
    ) {
        self.scanCancelForceTimeout = scanCancelForceTimeout
        self.exclusions = exclusions
        self.scanRoots = scanRoots
        self.history = history
        self.trash = trash
        self.directoryEnumerator = directoryEnumerator
        self.activity = activity
        self.volumeSummaries = volumeSummaries
        self.scanCache = scanCache
        self.installedAppInventory = installedAppInventory
        runningAppsSource = runningApps
        runningAppsReading = RunningAppsReading(freshness: runningAppsFreshness)
        self.homeDirectory = PathNormalization.normalize(homeDirectory)
        self.markerExists = markerExists
        self.aiManifestReader = aiManifestReader
        trashInventorySource = trashInventory
        overviewTrashCounter = OverviewTrashCounter(source: trashInventory)
    }

    @ObservationIgnored private let directoryEnumerator: any CleanDirectoryEnumerator
    @ObservationIgnored private let markerExists: (String) -> Bool
    @ObservationIgnored private let trashInventorySource: @Sendable () async -> TrashInventory?
    /// 运行中应用采集(p7-cleaner/02):生产 Live(系统工作区的应用列表);测试注入固定结果。
    /// 只读、同步,读清单时在主线程调;采集一次约两毫秒,所以新鲜期内、版本号没变的
    /// 重复读共用一份(`RunningAppsReading`)。
    @ObservationIgnored private let runningAppsSource: @Sendable () -> [RunningAppIdentity]
    @ObservationIgnored private var runningAppsReading: RunningAppsReading
    /// 「谁在运行」的版本号:应用启动 / 退出、生成确认清单前 +1。清单 getter 读它——读即
    /// 登记,版本一变,读着清单的视图重读。
    private(set) var runningAppsRevision = 0
    /// 总览废纸篓清点子状态机(solid-split/02 步骤 2 抽出;对外经下方转发面,零调用点变化)。
    let overviewTrashCounter: OverviewTrashCounter
    /// Ollama manifest 读取器(p6-cleaner/02 内容寻址记账的 IO 接缝,注入以便测试)。
    @ObservationIgnored private let aiManifestReader: (String) -> String?

    /// 点「清空废纸篓」:先清点(数字进确认弹窗);空废纸篓给短提示不弹窗。
    /// 清点读不到(nil)= 如实提示、回 idle——绝不当成「空」(读不到 ≠ 空),也不带着
    /// 残缺数字进确认单。清点结果顺手落到总览读数(同一次 IO,不为显示多读一遍)。
    func beginEmptyTrash() {
        guard trashPhase == .idle else { return }
        trashPhase = .inventorying
        Task.detached(priority: .userInitiated) { [weak self, trashInventorySource] in
            let inventory = await trashInventorySource()
            await MainActor.run {
                guard let self else { return }
                self.overviewTrashCounter.apply(inventory)
                guard let inventory else {
                    self.trashPhase = .idle
                    self.trashNotice = "废纸篓读不到(权限不足或宗卷不可用),什么都没删"
                    return
                }
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
                // 总览废纸篓卡还挂着旧读数,清空后原地刷新(p6-cleaner/03)。清空是用户
                // 刚确认的动作,走显式入口不过门卫。
                self.refreshOverviewTrash()
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

    /// 总览聚合(Hero / 模块大卡数据面,纯值):在用判定每次现查活动源(永不缓存),
    /// 与清单行 / 删除计划同一 `CleanInUse` 口径。
    var junkOverview: JunkOverview {
        JunkOverviewAggregator.overview(
            candidates: candidates,
            activityEntries: currentActivityEntries()
        )
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

    // MARK: 总览读数(p6-cleaner/03;读数四态与授权门卫 = p6-review-fixes;

    // solid-split/02 步骤 2:清点子状态机抽 OverviewTrashCounter,此处只留转发面)

    var overviewTrashPhase: OverviewTrashPhase {
        overviewTrashCounter.phase
    }

    /// Hero 图例「另有废纸篓 X」的读数通道(nil → 「—」)。
    var overviewTrash: TrashInventory? {
        overviewTrashCounter.reading
    }

    /// 自动入口(进总览页的可见性切换):门卫放行才清点(详见 OverviewTrashCounter)。
    func refreshOverviewTrashIfUnlocked() {
        overviewTrashCounter.refreshIfUnlocked()
    }

    /// 显式入口:清点一次废纸篓,只为总览显示。**只许挂在用户动作上**
    /// (废纸篓卡「清点」按钮、清空完成后的原地刷新);详见 OverviewTrashCounter。
    func refreshOverviewTrash() {
        overviewTrashCounter.refresh()
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
                  !CleanPathDomain.isUserDomain(entry.path)
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

    /// - Parameter enumerator: 不传 = 构造时注入的枚举器;测试可单次覆盖为 TestSupport 假实现
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
        let source = enumerator ?? directoryEnumerator
        scanGeneration &+= 1
        let generation = scanGeneration
        // 方案 A 路径域修正:物理根喂枚举器,树路径以规范根("/")落——匹配/排除/展示同域。
        // 测试注入自定义 roots 时保持原样(夹具路径即规范路径)。
        let canonical = scanRoots == [Self.productionScanRoot] ? ["/"] : nil
        let options = SpaceScanOptions(
            roots: scanRoots,
            excludedPathPrefixes: exclusions.paths,
            retainFileNodes: false,
            // p6-cleaner/02:Ollama 模型库定向保留文件节点(内容寻址记账要逐文件
            // 字节;前缀出处单一 = OllamaStoreAccounting.retainedFilePrefixes)。
            retainedFilePrefixes: OllamaStoreAccounting.retainedFilePrefixes(home: homeDirectory),
            // petal 式并行(性能票):真机 Data 卷 ≈500 万项,6 个长驻 worker
            // 吃共享目录栈(注:注释史上的「测试注入假枚举器保持串行」豁免
            // 已不成立——并发恒 6,假枚举器测试只断计数不断请求序,2026-11-11 核)。
            maxConcurrency: Self.productionScanConcurrency,
            canonicalRoots: canonical
        )

        let collectApps = appInventoryCollector()
        // userInitiated(自 utility 升档,cleaner-scan-hang):用户亲手点的扫描不被
        // 满载机器压制——utility 在系统 100% 负载下被 OS 调度挤到停摆(2026-11-10
        // 实案:7 分钟零输出、取消无响应),与缓存装载 21s 先例同病;purge 同款定策。
        scanTask = Task.detached(priority: .userInitiated) { [
            engine,
            volumeSummaries,
            scanCache,
            collectApps,
            weak self
        ] in
            let scanBegin = Date()
            let result = await engine.scan(
                options,
                using: source,
                progress: { stats in
                    // 引擎每 2048 项发一次(≈10 次/s @2.1 万项/s),直接跳 MainActor
                    // 足够;迟到的进度跳块由 isScanning 守门,不会盖掉 finished。
                    // 代数守卫:被强制放弃的孤儿任务不再把 .idle 拉回 .scanning。
                    Task { @MainActor in
                        guard let self, self.isScanning, self.scanGeneration == generation else { return }
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
            // 代数守卫(cleaner-scan-hang):被强制放弃/取代的孤儿任务即使跑完也
            // 不落盘——晚到的旧结果倒灌覆盖新扫描的缓存。
            if let scanCache, !result.cancelled,
               await MainActor.run(body: { self?.scanGeneration == generation }) {
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
            await MainActor.run { self?.finish(generation, result, mapTrees: mapTrees, inventory: inventory) }
        }
    }

    /// 已装全集采集器绑上家目录(扫描 / 装载两条后台任务共用;与清单同一家目录口径)。
    private func appInventoryCollector() -> @Sendable ([SpaceNode], Bool) -> InstalledAppInventory {
        let collect = installedAppInventory
        let home = homeDirectory
        return { collect($0, $1, home) }
    }

    func cancelScan() {
        guard let task = scanTask else { return }
        task.cancel()
        // 硬兜底(cleaner-scan-hang):协作取消只在引擎目录入口被消费,worker 停摆
        // (高负载压制 / 不可中断枚举)时长时间无人应门——2026-11-10 实案点了取消
        // 全无反应直到杀 app。到时仍未收尾 = 界面强制退出扫描态,孤儿任务断线。
        let generation = scanGeneration
        let timeout = scanCancelForceTimeout
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.abandonScanIfStuck(generation)
        }
    }

    /// 取消兜底落点:同一轮扫描仍在 .scanning = 协作取消超时未被消费,放弃它。
    /// 代数先跳一级把孤儿任务(进度 / finish)断线,再退界面;正常路径若已先
    /// finish,isScanning 为假,此处零动作。
    private func abandonScanIfStuck(_ generation: Int) {
        guard generation == scanGeneration, isScanning else { return }
        LogService.warn(
            "取消扫描:\(scanCancelForceTimeout) 秒未收尾,强制放弃本次扫描(后台任务停摆)",
            category: "Cleaner"
        )
        scanGeneration &+= 1
        scanTask = nil
        phase = .idle
        scanStartedAt = nil
        selection.retain(in: candidates)
    }

    private func finish(
        _ generation: Int,
        _ result: SpaceScanResult,
        mapTrees: [SpaceMapNode],
        inventory: InstalledAppInventory
    ) {
        guard generation == scanGeneration else {
            LogService.info("扫描落位:代数已过期(被强制放弃/重扫取代),拒收迟到结果", category: "Cleaner")
            return
        }
        scanFinishedAt = Date()
        installedApps = inventory // 先于 phase:清单首读即带全集
        phase = .finished(result)
        self.mapTrees = mapTrees
        scanTask = nil
        selection.retain(in: candidates)
    }

    // MARK: 清单(04 全局缓存 + 05 项目产物)

    /// 可删单元:全局缓存(04)+ 项目产物(05)+ 卸载残留 + 通用发现(p7-cleaner/02)都跑在
    /// 同一棵扫描树上,排除目录与本会话已回收的项不列。仍是计算属性——读 `phase` /
    /// `exclusions.paths` / `scanRoots.paths` / `recycledPaths` 照常登记观察,设置页改动
    /// 即时反映、不必重扫;但按这四样输入记忆化(cleaner-hardening/05):一次渲染读好几
    /// 次、点勾选整卡重绘,输入不变就不重跑匹配器(项目产物要整棵 DFS + 查标记文件)。
    /// 唯一不进备忘的是「所属应用此刻在运行」:备忘跟扫描结果走,而谁在运行随时间变。
    var candidates: [JunkCandidate] {
        let key = CandidatesKey(
            phaseGeneration: phaseGeneration,
            excluded: exclusions.paths,
            roots: scanRoots.paths,
            recycled: recycledPaths
        )
        // 先读 phase 再判缓存:保证观察登记与未命中时一致。
        guard let result else { return [] }
        let listed: [JunkCandidate]
        if let candidatesMemo, candidatesMemo.key == key {
            listed = candidatesMemo.value
        } else {
            listed = computeCandidates(in: result, key: key)
            candidatesMemo = (key, listed)
        }
        // 通用发现里所属应用在运行的条目此刻不出现:每次读都现查现滤。读
        // `runningAppsRevision` 即登记观察——应用启动 / 退出时视图一戳
        // (`noteRunningAppsMayHaveChanged`),读着清单的视图重读。
        return GenericDiscovery.excludingRunningApps(
            listed,
            runningApps: runningAppsReading.value(
                at: Date(), revision: runningAppsRevision, collect: runningAppsSource
            )
        )
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
        // Ollama 内容寻址重算(p6-cleaner/02):manifest 只决定「哪些文件计入」,
        // 字节仍取扫描树节点——实际占用口径不变;清单不可用 → 整目录兜底 + 标注。
        // 纯值在 PulseCore,这里只是接线(reader 注入)。旧缓存(无文件节点)自动走兜底。
        let global = OllamaStoreAccounting.applied(
            to: JunkMatcher.candidates(
                in: result.trees,
                home: homeDirectory,
                excludedPathPrefixes: excluded
            ),
            in: result.trees,
            readManifest: aiManifestReader
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
        // 通用发现(p7-cleaner/02):三处里前面三个域都没认领的目录,一律「先检查」。
        // 这一层只判「名单外、不受保护、没被认领」——随扫描结果记忆;「所属应用在运行」
        // 不在这层,见 `candidates`。
        let generic = GenericDiscovery.detect(
            in: result.trees,
            home: homeDirectory,
            claimedBy: claimed + leftovers,
            excludedPathPrefixes: excluded
        )

        // 不过滤亚兆条目(2026-11-06 用户拍板:0 KB 产物也是该清的东西,照列;
        // 显示层由 memory() 的 KB 档给出真实读数)。
        return (claimed + leftovers + generic)
            .filter { !key.recycled.contains($0.path) }
    }

    // MARK: 运行中应用(p7-cleaner/02;判定不进扫描结果)

    /// 「谁在运行」可能变了:应用启动 / 退出(主窗口视图收到系统通知时调),或即将
    /// 生成确认清单。下一次读清单时重采运行中应用,读着清单的视图随之重读。
    func noteRunningAppsMayHaveChanged() {
        runningAppsRevision &+= 1
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
    /// 组感知版(p6-cleaner/02):AI 组额外吃第四路 .aiService 标记。
    func inUseReasons(
        for candidate: JunkCandidate,
        entries: [CleanActivityEntry]
    ) -> CleanActivityReason? {
        CleanInUse.reasons(for: candidate, entries: entries)
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

    /// 整组勾选的三态。`safeCandidates` = 该组里「可安全清理」档的项——整组勾选
    /// 只看、只动这些;「先检查」项永远要用户单独点,不参与组勾选。
    /// (深查甄别:产品视图不直读,是 CleanerModelTests 钉组勾选语义的口——非死码。)
    func groupState(of safeCandidates: [JunkCandidate]) -> JunkSelection.GroupState {
        selection.state(of: safeCandidates)
    }

    /// 整组勾选:none / mixed → 全勾;all → 全清。只动传入的候选。入口是品类组头的
    /// 「全选安全项」文字按钮(下钻态并入返回行)与项目大卡卡头的三态勾选框。
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
            CleanInUse.reasons(for: $0, entries: entries) == nil
        }
        return CleanPlan.make(selection: selection, candidates: usable, excludedPathPrefixes: exclusions.paths)
    }

    /// 右键排除:持久化进设置,清单即时收窄,勾选随之收敛。
    func exclude(_ path: String) {
        exclusions.add(path)
        selection.retain(in: candidates)
    }

    /// mcp-clean/01:AI 经 MCP 提交的外部勾选——**替换**全量勾选为求交后的
    /// 安全档项(McpCleanMatching 已滤掉先检查/在用,这里不重复判);确认单
    /// 展示的就是这份勾选,用户仍可逐项反悔。busy/为空拦截在 McpCleanBridge。
    func applyExternalSelection(_ matched: [JunkCandidate]) {
        selection.clear()
        for candidate in matched {
            selection.set(candidate, selected: true)
        }
    }

    /// 总览 Hero「一键清理 X 安全项…」(p6-cleaner/03,spec 定案 6):勾选**替换**为
    /// 全部「可安全清理」且非在用的候选(纯值单出处 `safeAutoSelection`;「先检查」与
    /// 在用项绝不在内),随即走既有 `requestClean` → 确认单——确认单里逐行可见、可取消,
    /// 安全边界零变化。默认勾选仍全不勾:一键是显式按钮,不改默认态。
    /// 落地页切清单(由视图做,同原型:选完跳「全部清单」直接弹确认单)。
    func selectAllSafeAndRequestClean() {
        let matched = JunkOverviewAggregator.safeAutoSelection(
            candidates: candidates,
            activityEntries: currentActivityEntries()
        )
        guard !matched.isEmpty else { return }
        applyExternalSelection(matched)
        requestClean()
    }

    // MARK: 清理流程(04)

    func requestClean() {
        // 确认清单按此刻谁在运行来:刚启动的应用,它的缓存不进清单。
        noteRunningAppsMayHaveChanged()
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
        // 点「移入废纸篓」这一刻重采:确认单挂着的时候启动的应用,它的缓存不跟着走。
        noteRunningAppsMayHaveChanged()
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
