import Foundation
import PulseCore

/// 清理 / 卸载的唯一组装点(arch-clean/01):Live 执行器、扫描器、清点源与落库都在这里注入。
/// 窗口版模型随主窗口创建、关窗即销毁,所以这里给工厂而不是实例;AI 清理的影子模型
/// 从同一工厂取——两处依赖同源,不再各写一份。
@MainActor
struct CleanAssembly {
    let monitor: SystemMonitor
    /// 排除目录 / 扫描根:app 级单实例,与设置页「清理」同源。
    let exclusions: CleanExclusionsStore
    let scanRoots: CleanScanRootsStore

    func makeCleanerModel() -> CleanerModel {
        var enumerator = LiveCleanDirectoryEnumerator()
        // 批粒度取消(cleaner-scan-hang/02):闭包在 worker 任务上下文求值,
        // 与引擎的目录入口检查同源(取消自 scanTask 传播)。
        enumerator.isCancelled = { Task.isCancelled }
        return CleanerModel(
            exclusions: exclusions,
            scanRoots: scanRoots,
            history: monitor.features.history.cleanHistory,
            trash: LiveCleanTrashExecutor(),
            // 系统级条目的授权通道(p7-cleaner/05;ADR-0012):用户点了「移入废纸篓」且清单里
            // 有系统级条目时,才弹系统管理员密码框。
            systemTrash: LiveCleanSystemTrashExecutor(),
            directoryEnumerator: enumerator,
            activity: LiveCleanActivitySource(board: monitor.activityBoard),
            volumeSummaries: { LiveCleanVolumeSummaries().internalSystemVolumes() },
            // 目录建不了时 init 返回 nil,功能优雅降级。
            scanCache: CleanScanResultStore(),
            installedAppInventory: {
                LiveInstalledAppInventory.collect(trees: $0, scanCancelled: $1, home: $2)
            },
            runningApps: { LiveRunningApps.collect() },
            trashInventory: { await LiveCleanTrashExecutor().inventory() }
        )
    }

    func makeUninstallModel() -> UninstallModel {
        // 先取值再捕获(monitor 属性带 actor 隔离,闭包里直读过不了并发检查)。
        let cleanHistory = monitor.features.history.cleanHistory
        return UninstallModel(
            collectFacts: { LiveAppCatalogSource().collectFacts() },
            scanSizes: { paths, progress, isCancelled in
                await LiveAppCatalogSource().scanAppSizes(
                    appPaths: paths, progress: progress, isCancelled: isCancelled
                )
            },
            activityBoard: monitor.activityBoard,
            prober: { await LiveAppCatalogSource().probeLeftovers($0) },
            recycle: { await LiveCleanTrashExecutor().recycleToTrash($0) },
            deletePermanently: { await LiveCleanPermanentDeleter().deletePermanently($0) },
            brewUninstall: { cask, zap in await LiveBrewUninstaller().uninstall(cask: cask, zap: zap) },
            crossCheckCasks: { LiveAppCatalogSource().collectFacts().brewAppNames },
            // 删前复核探针(p5-cleaner/03):与 CleanRunner 的执行器探针同款 lstat(零副作用)。
            leftoverState: { await LiveCleanTrashExecutor().currentState(ofPath: $0) },
            recordHistory: { report in
                // 与一期清理同库同表(CleanHistoryStore actor 串行化);落库失败
                // 记日志不阻断横幅——历史缺行可追,静默吞错不可追。
                guard let cleanHistory else {
                    LogService.warn("卸载历史落库跳过:历史库未初始化", category: "Cleaner")
                    return
                }
                do {
                    try await cleanHistory.record(report)
                } catch {
                    LogService.error("卸载历史落库失败:\(error.localizedDescription)", category: "Cleaner")
                }
            }
        )
    }

    /// 预览用:排除目录 / 扫描根不读不写用户设置。
    static func preview(monitor: SystemMonitor) -> CleanAssembly {
        CleanAssembly(
            monitor: monitor,
            exclusions: CleanExclusionsStore(load: { [] }, persist: { _ in }),
            scanRoots: CleanScanRootsStore(load: { [] }, persist: { _ in })
        )
    }
}
