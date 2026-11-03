import Foundation
import Observation
import PulseCore

// MARK: - 卸载页模型(p4-uninstaller/01):无常驻采集,进 tab 才收集

//
// 状态机:idle → collecting(事实收集,秒级)→ sizing(大小聚合,复用空间扫描
// 引擎)→ finished。切走子药丸取消;重进空态才自动扫(loadIfNeeded),已有清单
// 不重复烧(与 CleanerModel 缓存装载同款「空态才动」纪律)。
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

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// 取消旗:扫描引擎的 isCancelled 回调在 worker 线程高频触发,不走 MainActor
    /// 属性(跨 actor 跳跃每目录一次会放大开销),用锁保护的 Bool 盒。
    @ObservationIgnored private let cancelFlag = CancelFlag()
    @ObservationIgnored private let catalogSource: LiveAppCatalogSource
    @ObservationIgnored private let activityBoard: CleanActivityBoard?

    init(
        catalogSource: LiveAppCatalogSource = LiveAppCatalogSource(),
        activityBoard: CleanActivityBoard? = nil
    ) {
        self.catalogSource = catalogSource
        self.activityBoard = activityBoard
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

    /// 子页 .task 进来时空态才扫(用户没点过时自动开;已有清单不动)。
    func loadIfNeeded() {
        guard phase == .idle else { return }
        startLoad()
    }

    /// 刷新按钮:强制重扫(签名 / 收据 / 运行态都可能变了)。
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

    private func startLoad() {
        loadTask?.cancel()
        cancelFlag.reset()
        phase = .collecting
        loadTask = Task.detached(priority: .userInitiated) { [weak self, catalogSource, cancelFlag] in
            let facts = catalogSource.collectFacts()
            guard let self, !Task.isCancelled, !cancelFlag.isSet() else {
                await MainActor.run { self?.finishIfCancelled() }
                return
            }
            // 只扫会进清单的 app(Apple / 判不了的不浪费遍历)。
            let listablePaths = facts.candidates
                .filter { !$0.isAppleSigned && !$0.signatureUnverifiable }
                .map(\.path)
            let sizes = await catalogSource.scanAppSizes(
                appPaths: listablePaths,
                progress: { stats in
                    // 引擎每 ~2048 项回调一次(十万项级 ≈ 50 次),直接落主线程不节流。
                    Task { @MainActor in
                        self.phase = .sizing(scannedEntries: stats.entriesSeen)
                    }
                },
                isCancelled: { cancelFlag.isSet() }
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
