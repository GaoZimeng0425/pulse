import Foundation
import Observation
import PulseCore

// MARK: - 清理页状态机(p4-cleaner/03)

//
// 用户触发的按需扫描(spec 实现决定):不挂 MonitorFeatures、无常驻采集、
// 结果只留内存——重进 tab 沿用,重新扫描才刷新;关窗随 MainWindowGate 销毁。
// 扫描跑在 .utility 低优先级 detached Task(探针 15:全卷 64 万项单线程约 31s,
// 不加并发);取消走 Task.cancel,引擎在目录入口消费(p4-cleaner/02 的取消语义:
// 已产出部分保留)。

@MainActor
@Observable
final class CleanerModel {
    enum Phase {
        case idle
        case scanning(ScanStats)
        case finished(SpaceScanResult)
    }

    private(set) var phase: Phase = .idle
    private(set) var scanStartedAt: Date?
    private(set) var scanFinishedAt: Date?

    private var scanTask: Task<Void, Never>?
    private let engine = SpaceScanEngine()

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
        let liveEnumerator = LiveCleanDirectoryEnumerator()
        let source = enumerator ?? liveEnumerator

        scanTask = Task.detached(priority: .utility) { [engine, weak self] in
            let result = await engine.scan(
                SpaceScanOptions(roots: roots),
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
    }
}
