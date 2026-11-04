import Foundation
import Observation
import PulseCore

// MARK: - 卸载页模型(p4-uninstaller/01+02):无常驻采集,进 tab 才收集

//
// 状态机:idle → collecting(事实收集,秒级)→ sizing(大小聚合,复用空间扫描
// 引擎)→ finished。切走子药丸取消;重进空态才自动扫(loadIfNeeded),已有清单
// 不重复烧(与 CleanerModel 缓存装载同款「空态才动」纪律)。
// IO 全部闭包注入(collectFacts / scanSizes / prober)——测试全假实现零真盘,
// 02 票选择 / 排序 / 搜索语义因此可在模型层直接断言。
// 运行中判定输入 = 活动板最新快照(CleanActivityBoard 自带 NSLock,任意线程可读);
// 判定不缓存——每次构建清单现取,03 票删除前还要再重查一次。
@MainActor @Observable
final class UninstallModel {
    enum Phase: Equatable {
        case idle
        case collecting
        case sizing(scannedEntries: Int)
        case finished(AppCatalogOutput)
    }

    private(set) var phase: Phase = .idle

    // MARK: 展示态(2026-11-04 拍板:Q5 排序搜索 / 原型裁决:点行选中)

    /// 应用清单展示序,默认占用降序(腾空间第一动机)。
    var sortOrder: AppSortOrder = .sizeDescending
    /// 子页内搜索过滤(应用名 / 路径子串,大小写不敏感;Core 的 filtered 实现)。
    var searchQuery = ""
    /// 点行选中的 app 本体(checkbox 语义;灰行不可选——rowState != normal 拒绝)。
    private(set) var appSelection: Set<String> = []
    /// 「彻底删除」勾选(Q6:默认不勾、**每次展开重置**;03 票执行消费)。
    private(set) var permanentDelete: Set<String> = []

    /// 残留结果缓存(展开过就有,重展开零成本;刷新清空)。
    private(set) var leftoverCache: [String: [AppLeftoverRow]] = [:]
    private(set) var leftoverLoading: Set<String> = []
    /// 被勾选的残留路径(默认全不勾,spec;03 票卸载执行消费)。
    private(set) var leftoverSelection: Set<String> = []

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// 取消旗:扫描引擎的 isCancelled 回调在 worker 线程高频触发,不走 MainActor
    /// 属性(跨 actor 跳跃每目录一次会放大开销),用锁保护的 Bool 盒。
    @ObservationIgnored private let cancelFlag = CancelFlag()
    @ObservationIgnored private let collectFacts: @Sendable () async -> LiveAppCatalogFacts
    @ObservationIgnored private let scanSizes:
        @Sendable (
            [String],
            (@Sendable (ScanStats) -> Void)?,
            (@Sendable () -> Bool)?
        ) async -> [String: (bytes: Int64, partial: Bool)]
    @ObservationIgnored private let activityBoard: CleanActivityBoard?
    /// 残留探测器(02 票):默认 Live(逐条 stat + 批量聚合);测试注入假实现。
    @ObservationIgnored private let prober: @Sendable ([LeftoverProbe]) async -> [AppLeftoverRow]
    /// cask 名 → zap 路径(清单落地时从 facts 存下,展开残留时按徽标取)。
    @ObservationIgnored private var brewZapPaths: [String: [String]] = [:]

    init(
        collectFacts: @escaping @Sendable () async -> LiveAppCatalogFacts = {
            await LiveAppCatalogSource().collectFacts()
        },
        scanSizes: @escaping @Sendable (
            [String],
            (@Sendable (ScanStats) -> Void)?,
            (@Sendable () -> Bool)?
        ) async -> [String: (bytes: Int64, partial: Bool)] = { paths, progress, isCancelled in
            await LiveAppCatalogSource().scanAppSizes(
                appPaths: paths, progress: progress, isCancelled: isCancelled
            )
        },
        activityBoard: CleanActivityBoard? = nil,
        prober: @escaping @Sendable ([LeftoverProbe]) async -> [AppLeftoverRow] = { probes in
            await LiveAppCatalogSource().probeLeftovers(probes)
        }
    ) {
        self.collectFacts = collectFacts
        self.scanSizes = scanSizes
        self.activityBoard = activityBoard
        self.prober = prober
    }

    var isBusy: Bool {
        !isIdleOrFinished
    }

    private var isIdleOrFinished: Bool {
        switch phase {
        case .idle, .finished: true
        case .collecting, .sizing: false
        }
    }

    var output: AppCatalogOutput? {
        if case let .finished(output) = phase {
            return output
        }
        return nil
    }

    /// 展示序清单:搜索过滤 + 当前排序(Core 纯值,可测)。
    var displayedEntries: [UninstallAppEntry] {
        guard let output else { return [] }
        return AppCatalog.sorted(
            AppCatalog.filtered(output.entries, query: searchQuery),
            by: sortOrder
        )
    }

    /// 子页 .task 进来时空态才扫(用户没点过时自动开;已有清单不动)。
    func loadIfNeeded() {
        guard phase == .idle else { return }
        startLoad()
    }

    /// 刷新按钮:强制重扫(签名 / 收据 / 运行态都可能变了)。
    /// 搜索词与排序保留(用户输入不灭);选择集作废(旧清单路径失效)。
    func refresh() {
        startLoad()
    }

    /// 切走子页 / 关窗:停任务。已完成的清单保留(回来还在)。
    func cancel() {
        guard loadTask != nil else { return }
        cancelFlag.set()
        loadTask?.cancel()
        loadTask = nil
        // 收集 / 扫描中途取消回空态;已完成的清单保留。
        if !isIdleOrFinished {
            phase = .idle
        }
    }

    // MARK: 选中与展开(原型裁决:点行选中,箭头展开)

    /// 点行 = 选中 / 取消选中 app 本体;灰行(先退出 / 无权限)点不选中。
    /// 取消选中不动残留勾选(两者独立,03 票执行时以「选中 ∨ 残留勾」合并消费)。
    func toggleSelect(_ entry: UninstallAppEntry) {
        guard entry.rowState == .normal else { return }
        if !appSelection.insert(entry.path).inserted {
            appSelection.remove(entry.path)
        }
    }

    func isSelected(_ entry: UninstallAppEntry) -> Bool {
        appSelection.contains(entry.path)
    }

    /// 展开动作:残留按需探测 + 「彻底删除」勾选重置(Q6:每次展开重置,不记忆跨次)。
    func onExpand(_ entry: UninstallAppEntry) {
        permanentDelete.remove(entry.path)
        loadLeftovers(for: entry)
    }

    func togglePermanentDelete(_ entry: UninstallAppEntry) {
        if !permanentDelete.insert(entry.path).inserted {
            permanentDelete.remove(entry.path)
        }
    }

    func isPermanentDeleteSelected(_ entry: UninstallAppEntry) -> Bool {
        permanentDelete.contains(entry.path)
    }

    // MARK: 残留(02 票)

    /// 展开一行时按需探测该 app 的残留(通用位置 + brew zap);无 bundle id 的
    /// app 不探测(02 票口径:只剩名字一把键,误中风险高于收益),界面给标注。
    private func loadLeftovers(for entry: UninstallAppEntry) {
        guard entry.bundleID != nil,
              leftoverCache[entry.path] == nil,
              !leftoverLoading.contains(entry.path)
        else { return }
        leftoverLoading.insert(entry.path)
        let probes = AppLeftovers.probes(
            bundleID: entry.bundleID,
            appName: entry.name,
            brewZapPaths: entry.brewCaskName.flatMap { brewZapPaths[$0] } ?? []
        )
        Task.detached(priority: .userInitiated) { [weak self, prober] in
            let rows = await prober(probes)
            await MainActor.run {
                guard let self else { return }
                self.leftoverLoading.remove(entry.path)
                self.leftoverCache[entry.path] = rows
            }
        }
    }

    func toggleLeftover(_ row: AppLeftoverRow) {
        if !leftoverSelection.insert(row.path).inserted {
            leftoverSelection.remove(row.path)
        }
    }

    func isLeftoverSelected(_ row: AppLeftoverRow) -> Bool {
        leftoverSelection.contains(row.path)
    }

    /// 「全选残留」(Q4):只收通用位置残留——LaunchAgents 恒「先检查」不进全选
    /// (但可手动勾)。重复点 = 幂等全选,不做反选。
    func selectAllLeftovers(for entry: UninstallAppEntry) {
        guard let rows = leftoverCache[entry.path] else { return }
        for row in rows where !row.isCheckFirst {
            leftoverSelection.insert(row.path)
        }
    }

    private func startLoad() {
        loadTask?.cancel()
        cancelFlag.reset()
        phase = .collecting
        loadTask = Task.detached(priority: .userInitiated) { [weak self, collectFacts, scanSizes, cancelFlag] in
            let facts = await collectFacts()
            guard let self, !Task.isCancelled, !cancelFlag.isSet() else {
                await MainActor.run { self?.finishIfCancelled() }
                return
            }
            // 只扫会进清单的 app(Apple / 判不了的不浪费遍历)。
            let listablePaths = facts.candidates
                .filter { !$0.isAppleSigned && !$0.signatureUnverifiable }
                .map(\.path)
            let sizes = await scanSizes(
                listablePaths,
                { stats in
                    // 引擎每 ~2048 项回调一次(十万项级 ≈ 50 次),直接落主线程不节流。
                    Task { @MainActor in
                        self.phase = .sizing(scannedEntries: stats.entriesSeen)
                    }
                },
                { cancelFlag.isSet() }
            )
            guard !Task.isCancelled, !cancelFlag.isSet() else {
                await MainActor.run { self.finishIfCancelled() }
                return
            }
            // 运行态在此刻取板(board 线程安全,worker 线程直读零 MainActor 开销)。
            let running = activityBoard?.current().compactMap(\.executablePath) ?? []
            let output = AppCatalog.build(
                candidates: facts.candidates,
                appSizes: sizes,
                brewAppNames: facts.brewAppNames,
                runningExecutablePaths: running
            )
            await MainActor.run {
                guard !cancelFlag.isSet() else {
                    self.phase = .idle
                    return
                }
                self.phase = .finished(output)
                // 旧清单的选择 / 残留缓存 / 勾选全部作废(签名、收据、盘上事实都可能变了);
                // 搜索词与排序保留。
                self.brewZapPaths = facts.brewZapPaths
                self.appSelection = []
                self.permanentDelete = []
                self.leftoverCache = [:]
                self.leftoverLoading = []
                self.leftoverSelection = []
                LogService.info(
                    "应用清单:收集完成 · 可卸载 \(output.entries.count) · 隐藏 Apple \(output.ledger.excludedAppleSigned) / 判不了 \(output.ledger.excludedUnverifiableSignature)",
                    category: "Cleaner"
                )
            }
        }
    }

    private func finishIfCancelled() {
        if !isIdleOrFinished {
            phase = .idle
        }
    }
}

/// 锁保护的一次性取消旗(NSLock 同步方法,不涉 async——并发纪律)。
/// @unchecked Sendable 前提:单一 Bool,全部读写经 NSLock 串行化。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flagged = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        flagged = true
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        flagged = false
    }

    func isSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flagged
    }
}
