import Foundation

/// 最近一轮采样快照的三元组投影板(HeartbeatRusageRelay 同款思路:心跳本就在采
/// cwd / argv / 可执行路径,这里只是把最新一轮转发给不挂 MonitorFeatures 调度的
/// 按需读者——清理页,零新采集)。SystemMonitor 每轮落地时 `update`,
/// 活动源读取时 `current`;锁一小段,读写都快。不碰 IO(arch-clean/02 挪入核心包)。
/// 采样只在窗口可见时推进:清理页是主窗口 tab,用户能点「清理」时快照必然新鲜
/// (秒级);判定口径「删除前重查」由每次调用重新推导保证。
public final class CleanActivityBoard: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [CleanActivitySample] = []

    public init() {}

    public func update(_ next: [CleanActivitySample]) {
        lock.lock()
        defer { lock.unlock() }
        samples = next
    }

    public func current() -> [CleanActivitySample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
