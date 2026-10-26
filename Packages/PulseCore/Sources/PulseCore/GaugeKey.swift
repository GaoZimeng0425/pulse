import Foundation

// MARK: - 历史仪表键(p2-review/09)

/// 历史仪表键:传感器读数经 `historyGauges` 自报进历史管线的量纲标识,
/// 即窄表 `gauge_min` / `gauge_hour` 的 key 列。rawValue = 存储键 = 迁移前
/// 的宽表列名(存量变换按名直搬)。**加一个新趋势量 = 加一个 case + 读数
/// 模型自报一行,全程零 schema 迁移**(票面验收①)。
public enum GaugeKey: String, CaseIterable, Hashable, Sendable {
    /// CPU 均值派生温度(°C)。
    case tempAverage = "temp_avg"
    /// 全机最热派生温度(CPU/GPU/SoC 三最热取最高,°C)。
    case tempMax = "temp_max"
    /// GPU 利用率(%)。
    case gpuUtilization = "gpu_util"
    /// 五路功率平均瓦数(CPU 域)。
    case powerCpu = "pow_cpu"
    /// 五路功率平均瓦数(GPU 域)。
    case powerGpu = "pow_gpu"
    /// 五路功率平均瓦数(ANE 域;缺席芯片不产行)。
    case powerAne = "pow_ane"
    /// 五路功率平均瓦数(RAM 域)。
    case powerRam = "pow_ram"
    /// 五路功率平均瓦数(SoC 域)。
    case powerSoc = "pow_soc"
    /// 全机 Energy Impact 合计(powermetrics 合成能耗影响分,无量纲;
    /// p3-root-mcp/03 特权助手采集,助手缺席不产行)。
    case energyImpact = "energy_impact"

    /// 五路功率域 ↔ 键。
    public static func power(_ domain: PowerDomain) -> GaugeKey {
        switch domain {
        case .cpu: .powerCpu
        case .gpu: .powerGpu
        case .ane: .powerAne
        case .ram: .powerRam
        case .soc: .powerSoc
        }
    }

    /// 五路功率全体键(合计查询与迁移共用)。
    public static let powerKeys: Set<GaugeKey> = Set(PowerDomain.allCases.map(GaugeKey.power))

    /// 窄表行写入与查询的聚合口径(小时卷积同款):最热是峰(max 列),
    /// 其余是均(avg 列)——不聚合的列落 NULL,口径单点。
    public var aggregation: Aggregation {
        self == .tempMax ? .max : .average
    }

    /// 聚合口径。
    public enum Aggregation: Sendable, Equatable {
        case average
        case max
    }
}

// MARK: - 读数模型自报(p2-review/09)

/// 传感器读数向历史管线自报仪表值:读数模型是口径的唯一出处(此前 SMC
/// 「全机最热」的折算住在 HistoryFeed,已随本票搬回模型)。缺席量不报键
/// (窄表不产行,查询空段不伪造 0)。
public extension GpuReading {
    var historyGauges: [GaugeKey: Double] {
        [.gpuUtilization: utilizationPercent]
    }
}

public extension SmcReading {
    /// 温度派生口径 = CPU 均值 + 全机最热(三最热取最高)。
    var historyGauges: [GaugeKey: Double] {
        var gauges: [GaugeKey: Double] = [:]
        if let cpuAverage = derived.cpuAverage {
            gauges[.tempAverage] = cpuAverage
        }
        let hottest = [derived.cpuHottest, derived.gpuHottest, derived.socHottest]
            .compactMap(\.self)
            .max()
        if let hottest {
            gauges[.tempMax] = hottest
        }
        return gauges
    }
}

public extension PowerReading {
    /// 五域瓦数原样(缺席域不报键,不伪造 0)。
    var historyGauges: [GaugeKey: Double] {
        Dictionary(
            watts.map { (GaugeKey.power($0.key), $0.value) },
            uniquingKeysWith: { _, rhs in rhs }
        )
    }
}
