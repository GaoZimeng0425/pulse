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

    private(set) var phase: Phase = .idle
    private(set) var scanStartedAt: Date?
    private(set) var scanFinishedAt: Date?

    private(set) var cleanPhase: CleanPhase = .idle
    private(set) var selection = JunkSelection()
    /// 本会话已移入废纸篓的路径:树里还挂着(不重扫),清单里不再列。
    private(set) var recycledPaths: Set<String> = []

    /// 清理历史列表(nil = 尚未加载或不可用;见 `historyAvailable`)。
    private(set) var historyRuns: [CleanRunRecord]?
    private(set) var historyItems: [Int64: [CleanItemRecord]] = [:]
    private(set) var historyLoadFailed = false

    private var scanTask: Task<Void, Never>?
    private let engine = SpaceScanEngine()
    private let exclusions: CleanExclusionsStore
    private let history: CleanHistoryStore?
    private let trash: any CleanTrashExecutor
    private let homeDirectory: String

    /// - Parameters:
    ///   - exclusions: 排除目录(设置页同一实例;默认不落盘的空表给预览 / 测试)。
    ///   - history: 清理历史(`monitor.history.cleanHistory`;nil = 历史库不可用)。
    ///   - trash: 废纸篓执行器(生产 Live;测试 spy——核心测试纪律:绝不真删)。
    ///   - homeDirectory: 规则表相对它展开;测试注入假家目录。
    init(
        exclusions: CleanExclusionsStore = CleanExclusionsStore(load: { [] }, persist: { _ in }),
        history: CleanHistoryStore? = nil,
        trash: any CleanTrashExecutor = LiveCleanTrashExecutor(),
        homeDirectory: String = NSHomeDirectory()
    ) {
        self.exclusions = exclusions
        self.history = history
        self.trash = trash
        self.homeDirectory = PathNormalization.normalize(homeDirectory)
    }

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

    /// 权限拒了的目录数——FDA 引导横幅的判据(spec:未授时能扫的照扫、受限如实
    /// 标注,不报错;判据来自台账而非预探测,零额外 IO)。
    var permissionDeniedCount: Int {
        guard let result else { return 0 }
        return result.ledger.count { $0.reason == .permissionDenied }
    }

    var permissionHint: String? {
        let count = permissionDeniedCount
        guard count > 0 else { return nil }
        return "\(count) 个目录因权限未能扫到(含受 TCC 保护的文件夹)"
    }

    // MARK: 扫描

    /// - Parameter enumerator: 生产不传 = Live 扫描器;测试传 TestSupport 假实现
    ///   (协议注入,p4-cleaner/02 的接缝约定)。
    func startScan(
        using enumerator: (any CleanDirectoryEnumerator)? = nil,
        roots: [String] = ["/"]
    ) {
        guard scanTask == nil else { return }
        scanStartedAt = Date()
        scanFinishedAt = nil
        phase = .scanning(ScanStats())
        // 重扫 = 新一轮真相:已回收集合清空(树会重新反映磁盘),勾选随清单收敛。
        recycledPaths = []
        if case .finished = cleanPhase {
            cleanPhase = .idle
        }
        let liveEnumerator = LiveCleanDirectoryEnumerator()
        let source = enumerator ?? liveEnumerator
        let options = SpaceScanOptions(
            roots: roots,
            excludedPathPrefixes: exclusions.paths,
            retainFileNodes: false
        )

        scanTask = Task.detached(priority: .utility) { [engine, weak self] in
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
            await MainActor.run { self?.finish(result) }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func finish(_ result: SpaceScanResult) {
        scanFinishedAt = Date()
        phase = .finished(result)
        scanTask = nil
        selection.retain(in: candidates)
    }

    // MARK: 清单(04)

    /// 白名单命中的可删单元:跑在扫描树上,排除目录与本会话已回收的项不列。
    /// 计算属性——读 `exclusions.paths` 让设置页加的排除即时反映,不必重扫。
    var candidates: [JunkCandidate] {
        guard let result else { return [] }
        return JunkMatcher.candidates(
            in: result.trees,
            home: homeDirectory,
            excludedPathPrefixes: exclusions.paths
        ).filter { !recycledPaths.contains($0.path) }
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

    /// 确认清单 = 选中 ∩ 清单 ∩ 非排除(CleanPlan 在此二次判定排除)。
    var plan: CleanPlan {
        CleanPlan.make(selection: selection, candidates: candidates, excludedPathPrefixes: exclusions.paths)
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
        Task { [trash, history] in
            let report = await CleanRunner.run(plan, using: trash)
            var recorded = false
            if let history {
                do {
                    recorded = try await history.record(report) != nil
                } catch {
                    LogService.error("清理历史落库失败:\(error)", category: "Cleaner")
                }
            }
            self.applyCleanReport(report, historyRecorded: recorded)
        }
    }

    private func applyCleanReport(_ report: CleanRunReport, historyRecorded: Bool) {
        recycledPaths.formUnion(report.recycledPaths)
        selection.retain(in: candidates)
        cleanPhase = .finished(report, historyRecorded: historyRecorded)
        if historyRecorded, historyRuns != nil {
            Task { await loadHistory() }
        }
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
