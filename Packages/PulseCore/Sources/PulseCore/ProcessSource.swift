import Foundation

/// 项目唯一的 OS 测试接缝:采集一次快照。
/// 协议之上全部纯逻辑;`LiveProcessSource` 为 Darwin 薄适配器,
/// `SyntheticProcessSource` 供测试与 SwiftUI 预览(spec 实现决策)。
public protocol ProcessSource: Sendable {
    /// 采集一次快照并返回。永不抛错:单进程查询失败在实现内部静默降级,
    /// 绝不中断整轮采集。
    func snapshot() -> ProcessSnapshot
}

/// 合成采集源:按调用顺序依次吐出注入的快照序列,耗尽后停在末张(稳定世界)。
/// 03(归组)用单张合成进程树;05(CPU 差分 / 出生登记)用快照序列模拟时间推进;
/// SwiftUI 预览接它获得确定性数据。线程安全,可跨并发域持有。
public final class SyntheticProcessSource: ProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [ProcessSnapshot]
    private var nextIndex = 0

    /// 注入完整快照序列(takenAt 自带时间轴,供差分类测试编排)。
    public init(snapshots: [ProcessSnapshot]) {
        precondition(!snapshots.isEmpty, "SyntheticProcessSource 需要至少一张快照")
        self.snapshots = snapshots
    }

    /// 便捷构造:只关心进程树、单张快照的场景。
    public convenience init(processes: [RawProcess], takenAt: Date = Date()) {
        self.init(snapshots: [ProcessSnapshot(takenAt: takenAt, processes: processes)])
    }

    public func snapshot() -> ProcessSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let current = snapshots[min(nextIndex, snapshots.count - 1)]
        nextIndex += 1
        return current
    }
}
