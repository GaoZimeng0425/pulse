import Foundation
import PulseCore

// MARK: - Live 进程活动源(p4-cleaner/05,在用保护的输入)

/// 最近一轮采样快照的三元组投影板(HeartbeatRusageRelay 同款思路:心跳本就在采
/// cwd / argv / 可执行路径,这里只是把最新一轮转发给不挂 MonitorFeatures 调度的
/// 按需读者——清理页,零新采集)。SystemMonitor 每轮落地时 `update`,
/// LiveCleanActivitySource 读取时 `current`;锁一小段,读写都快。
/// 采样只在窗口可见时推进:清理页是主窗口 tab,用户能点「清理」时快照必然新鲜
/// (秒级);判定口径「删除前重查」由每次调用重新推导保证。
final class CleanActivityBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CleanActivitySample] = []

    func update(_ next: [CleanActivitySample]) {
        lock.lock()
        defer { lock.unlock() }
        samples = next
    }

    func current() -> [CleanActivitySample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

/// 活动源 Live 实现:板上的最新一轮 → 三元组推导(分类 / 合并原因)。
/// 每次调用重新推导,不做任何缓存(spec 在用保护:「判定永不缓存」)。
struct LiveCleanActivitySource: CleanActivitySource {
    let board: CleanActivityBoard

    func activeEntries() -> [CleanActivityEntry] {
        CleanActivityDerivation.entries(from: board.current())
    }
}
