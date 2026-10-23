import Foundation

// MARK: - 一轮落库入参(纯值)

/// 一轮采样进历史的全部入参(HistoryEngine.ingest 的参数包):纯值,由壳经串行
/// 写入者递交给引擎 actor。
public struct HistoryIngest: Equatable, Sendable {
    /// 采样时刻(壳在 MainActor 上现取,顺序即轮次顺序)。
    public let at: Date
    /// 系统 CPU 负载,0–100%(本轮心跳)。
    public let systemLoad: Double
    /// 本轮全部组的采样值(组 CPU% 降序,与主干同序)。
    public let groups: [GroupSample]
    /// 组展示名(组元数据落库)。
    public let displayNames: [GroupIdentity: String]
    /// 截至本轮累计的出生登记(增量持久化)。
    public let lineage: LineageRegistry
    /// 网络记账增量:rx = 下行,tx = 上行。丢弃轮差分本就为 0,读缺失轮 0——不伪造。
    public let netRxBytes: UInt64
    public let netTxBytes: UInt64
    /// 磁盘吞吐记账增量:自上一笔以来交付的新读数增量合计(字节)。
    public let diskReadBytes: UInt64
    public let diskWriteBytes: UInt64
    /// P2 传感器趋势量(p2-sensors/08,仪表型):本轮携带的最新值(传感器
    /// 广播进 feed 的暂存;从无样本 = nil,分钟聚合落 NULL 空段)。
    public let tempAverage: Double?
    public let tempMax: Double?
    public let gpuUtilization: Double?
    public let powerWatts: [PowerDomain: Double]?

    public init(
        at: Date,
        systemLoad: Double,
        groups: [GroupSample],
        displayNames: [GroupIdentity: String],
        lineage: LineageRegistry,
        netRxBytes: UInt64,
        netTxBytes: UInt64,
        diskReadBytes: UInt64,
        diskWriteBytes: UInt64,
        tempAverage: Double? = nil,
        tempMax: Double? = nil,
        gpuUtilization: Double? = nil,
        powerWatts: [PowerDomain: Double]? = nil
    ) {
        self.at = at
        self.systemLoad = systemLoad
        self.groups = groups
        self.displayNames = displayNames
        self.lineage = lineage
        self.netRxBytes = netRxBytes
        self.netTxBytes = netTxBytes
        self.diskReadBytes = diskReadBytes
        self.diskWriteBytes = diskWriteBytes
        self.tempAverage = tempAverage
        self.tempMax = tempMax
        self.gpuUtilization = gpuUtilization
        self.powerWatts = powerWatts
    }
}

public extension HistoryEngine {
    /// 一笔落库入参整包进引擎(参数逐一展开给既有入口);返回落库结果。
    @discardableResult
    func ingest(_ round: HistoryIngest) -> HistoryIngestOutcome {
        ingest(
            at: round.at,
            systemLoad: round.systemLoad,
            groups: round.groups,
            displayNames: round.displayNames,
            lineage: round.lineage,
            netRxBytes: round.netRxBytes,
            netTxBytes: round.netTxBytes,
            diskReadBytes: round.diskReadBytes,
            diskWriteBytes: round.diskWriteBytes,
            tempAverage: round.tempAverage,
            tempMax: round.tempMax,
            gpuUtilization: round.gpuUtilization,
            powerWatts: round.powerWatts
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
public struct HistoryFeed: Sendable {
    private var pendingDiskReadBytes: UInt64 = 0
    private var pendingDiskWriteBytes: UInt64 = 0
    /// P2 传感器趋势量的最新仪表值(08):广播样本覆盖暂存,每轮 takeIngest
    /// 整笔带走(轮间重复携带同一值 = 仪表携带前推,分钟均值口径不变)。
    /// 样本带时刻:超过 `gaugeMaxAge` 无新样本(传感器持续失败)即置 nil 出
    /// 空段,不把冻结值无限写进历史(2026-10-23 审计⑤)。
    private struct GaugeSample<Value: Sendable>: Sendable {
        var value: Value
        var at: Date
    }

    /// 仪表过期窗 = 3 个历史档周期(30s×3):容忍两个周期的读失败。
    private static let gaugeMaxAge: TimeInterval = 90

    private var latestTempAverage: GaugeSample<Double>?
    private var latestTempMax: GaugeSample<Double>?
    private var latestGpuUtilization: GaugeSample<Double>?
    private var latestPowerWatts: GaugeSample<[PowerDomain: Double]>?
    /// 磁盘吞吐交付进账本:新读数的增量逐笔 &+ 累计;重投的上次好值跳过。
    /// GPU 传感器交付(30s 历史档):fresh 才暂存(stale 是读失败重投的旧值,
    /// 历史不重复记);`at` = 壳侧注入钟的采样时刻(过期判定用)。
    public mutating func recordGpu(_ delivery: SensorDelivery<GpuReading>, at date: Date) {
        guard case let .fresh(reading) = delivery else { return }
        latestGpuUtilization = GaugeSample(value: reading.utilizationPercent, at: date)
    }

    /// SMC 传感器交付:温度派生口径 = CPU 均值 + 全机最热(cpu/gpu/soc 三最热取最大)。
    public mutating func recordSmc(_ delivery: SensorDelivery<SmcReading>, at date: Date) {
        guard case let .fresh(reading) = delivery else { return }
        latestTempAverage = reading.derived.cpuAverage.map { GaugeSample(value: $0, at: date) }
        latestTempMax = [
            reading.derived.cpuHottest,
            reading.derived.gpuHottest,
            reading.derived.socHottest,
        ].compactMap(\.self).max().map { GaugeSample(value: $0, at: date) }
    }

    /// 五路功率传感器交付:五域瓦数原样暂存(缺席域不伪造 0)。
    public mutating func recordPower(_ delivery: SensorDelivery<PowerReading>, at date: Date) {
        guard case let .fresh(reading) = delivery else { return }
        latestPowerWatts = reading.watts.isEmpty
            ? nil
            : GaugeSample(value: reading.watts, at: date)
    }

    /// 过期即 nil(样本时刻距今超窗);未过期取值。
    private func gauge<Value>(_ sample: GaugeSample<Value>?, at now: Date) -> Value? {
        guard let sample, now.timeIntervalSince(sample.at) <= Self.gaugeMaxAge else { return nil }
        return sample.value
    }

    public mutating func recordDiskThroughput(_ delivery: SensorDelivery<DiskThroughputReading>) {
        guard case let .fresh(reading) = delivery else { return }
        pendingDiskReadBytes &+= reading.readBytesDelta
        pendingDiskWriteBytes &+= reading.writeBytesDelta
    }

    /// 本轮落库入参:组采样 / 展示名 / 出生登记取本轮主干上下文,网络增量取本轮
    /// 心跳(nil 记 0),磁盘增量整笔带走账本并清零。`now` 由壳给(采样时刻口径)。
    public mutating func takeIngest(from context: RoundContext, at now: Date) -> HistoryIngest {
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
            diskWriteBytes: pendingDiskWriteBytes,
            tempAverage: gauge(latestTempAverage, at: now),
            tempMax: gauge(latestTempMax, at: now),
            gpuUtilization: gauge(latestGpuUtilization, at: now),
            powerWatts: gauge(latestPowerWatts, at: now)
        )
        pendingDiskReadBytes = 0
        pendingDiskWriteBytes = 0
        return ingest
    }

    public init() {}
}
