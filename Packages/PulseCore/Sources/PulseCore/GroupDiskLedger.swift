import Foundation

/// 一个组一轮的磁盘读写增量(字节)。
public struct GroupDiskDelta: Equatable, Sendable {
    public let readBytes: UInt64
    public let writeBytes: UInt64

    public static let zero = GroupDiskDelta(readBytes: 0, writeBytes: 0)

    public init(readBytes: UInt64, writeBytes: UInt64) {
        self.readBytes = readBytes
        self.writeBytes = writeBytes
    }
}

/// 组级磁盘账本(arch-review-2026-11-24/04 方案 C):进程快照本就带每进程累计
/// 读写字节(与 CPU 同一趟 rusage,零新增系统调用),这里逐 pid 记上一轮的累计,
/// 本轮差分后按组求和——sample_min.disk_r/disk_w 的唯一生产来源。
///
/// 口径(与模块排行账本同款纪律):
/// - 首次见到的进程只立基线,不记增量——否则会把进程终身累计当成一轮增量;
/// - 计数没读到(`countersAvailable == false`)的进程丢基线、本轮记 0,恢复那一轮重立基线;
/// - pid 复用(启动时刻变了)或计数回退 = 换了一个进程,重立基线、本轮记 0;
/// - 本轮不在场的 pid 逐出,账本不随历史进程增长。
public struct GroupDiskLedger: Sendable {
    private struct Baseline: Sendable {
        let startTime: Date?
        let read: UInt64
        let write: UInt64
    }

    private var baselines: [pid_t: Baseline] = [:]

    public init() {}

    /// 本轮各组增量(组内进程增量之和);同时把基线推进到本轮。
    public mutating func advance(groups: [ProcessGroup]) -> [GroupIdentity: GroupDiskDelta] {
        var next: [pid_t: Baseline] = [:]
        var deltas: [GroupIdentity: GroupDiskDelta] = [:]
        for group in groups {
            var read: UInt64 = 0
            var write: UInt64 = 0
            for process in group.processes where process.countersAvailable {
                let current = Baseline(
                    startTime: process.startTime,
                    read: process.diskBytesRead,
                    write: process.diskBytesWritten
                )
                next[process.pid] = current
                guard let previous = baselines[process.pid],
                      previous.startTime == current.startTime,
                      current.read >= previous.read,
                      current.write >= previous.write
                else { continue }
                read &+= current.read - previous.read
                write &+= current.write - previous.write
            }
            let delta = GroupDiskDelta(readBytes: read, writeBytes: write)
            deltas[group.id] = deltas[group.id].map {
                GroupDiskDelta(readBytes: $0.readBytes &+ read, writeBytes: $0.writeBytes &+ write)
            } ?? delta
        }
        baselines = next
        return deltas
    }
}
