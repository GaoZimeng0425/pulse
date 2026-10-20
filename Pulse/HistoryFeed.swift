import Foundation

// MARK: - 一轮落库入参(纯值)

/// 一轮采样进历史的全部入参(HistoryEngine.ingest 的参数包):纯值,由壳经串行
/// 写入者递交给引擎 actor。
struct HistoryIngest: Equatable, Sendable {
    /// 采样时刻(壳在 MainActor 上现取,顺序即轮次顺序)。
    let at: Date
    /// 系统 CPU 负载,0–100%(本轮心跳)。
    let systemLoad: Double
    /// 本轮全部组的采样值(组 CPU% 降序,与主干同序)。
    let groups: [GroupSample]
    /// 组展示名(组元数据落库)。
    let displayNames: [GroupIdentity: String]
    /// 截至本轮累计的出生登记(增量持久化)。
    let lineage: LineageRegistry
    /// 网络记账增量:rx = 下行,tx = 上行。丢弃轮差分本就为 0,读缺失轮 0——不伪造。
    let netRxBytes: UInt64
    let netTxBytes: UInt64
    /// 磁盘吞吐记账增量:自上一笔以来交付的新读数增量合计(字节)。
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
}

extension HistoryEngine {
    /// 一笔落库入参整包进引擎(参数逐一展开给既有入口);返回是否写了分钟行。
    @discardableResult
    func ingest(_ round: HistoryIngest) -> Bool {
        ingest(
            at: round.at,
            systemLoad: round.systemLoad,
            groups: round.groups,
            displayNames: round.displayNames,
            lineage: round.lineage,
            netRxBytes: round.netRxBytes,
            netTxBytes: round.netTxBytes,
            diskReadBytes: round.diskReadBytes,
            diskWriteBytes: round.diskWriteBytes
        )
    }
}

// MARK: - 纯值内核

/// 历史喂料纯内核(HistoryFeature 的值内核,单测见 HistoryFeedTests):两轮之间
/// 交付的磁盘吞吐读数进账本;每轮主干上下文到来时,连同账本整笔折成一份落库入参
/// 并清账。网络增量随心跳同轮到达(`context.update.network`),不进账本。
///
/// 磁盘记账恰好一次(arch-review-2026-10-18 甲5):吞吐 driver 读失败时重投**上次
/// 好值**,交付带新鲜度标记(SensorDelivery)——只记 `.fresh`,`.stale` 跳过。新鲜度
/// 看标记不看值:两份逐字段全等的新读数也各记一次。
struct HistoryFeed: Sendable {
    private var pendingDiskReadBytes: UInt64 = 0
    private var pendingDiskWriteBytes: UInt64 = 0
    /// 磁盘吞吐交付进账本:新读数的增量逐笔 &+ 累计;重投的上次好值跳过。
    mutating func recordDiskThroughput(_ delivery: SensorDelivery<DiskThroughputReading>) {
        guard case .fresh(let reading) = delivery else { return }
        pendingDiskReadBytes &+= reading.readBytesDelta
        pendingDiskWriteBytes &+= reading.writeBytesDelta
    }

    /// 本轮落库入参:组采样 / 展示名 / 出生登记取本轮主干上下文,网络增量取本轮
    /// 心跳(nil 记 0),磁盘增量整笔带走账本并清零。`now` 由壳给(采样时刻口径)。
    mutating func takeIngest(from context: RoundContext, at now: Date) -> HistoryIngest {
        let ingest = HistoryIngest(
            at: now,
            systemLoad: context.update.systemCPULoad,
            groups: context.groups.map(GroupSample.init(group:)),
            displayNames: Dictionary(
                context.groups.map { ($0.id, $0.name) },
                uniquingKeysWith: { _, rhs in rhs }
            ),
            lineage: context.lineage,
            netRxBytes: context.update.network?.downBytesDelta ?? 0,
            netTxBytes: context.update.network?.upBytesDelta ?? 0,
            diskReadBytes: pendingDiskReadBytes,
            diskWriteBytes: pendingDiskWriteBytes
        )
        pendingDiskReadBytes = 0
        pendingDiskWriteBytes = 0
        return ingest
    }
}
