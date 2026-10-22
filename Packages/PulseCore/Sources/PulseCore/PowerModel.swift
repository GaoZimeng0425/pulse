import Foundation

// MARK: - 五路功率(p2-sensors/03,GLOSSARY「五路功率」)

/// 功率域(五路,口径见 GLOSSARY):CPU/GPU/ANE/RAM/SoC 各自的瞬时瓦数,
/// 同一 IOReport "Energy Model" 订阅一次采样差分得出。
public enum PowerDomain: String, CaseIterable, Sendable {
    case cpu
    case gpu
    case ane
    case ram
    case soc

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ane: "ANE"
        case .ram: "RAM"
        case .soc: "SoC"
        }
    }

    /// 通道名候选(2026-10-22 探针④实证 M4 = AppleT8132PMGR 的通道名;按序取
    /// 在场通道,**候选内多通道求和**(SoC 的 SOC_REST + SOC_AON 两域都在时
    /// 合计)。gpu 备选 "GPU Energy"(单位 nJ,与主键 mJ 不同——单位按通道
    /// 标签逐个换算,不按域假设)。
    public var channelNames: [String] {
        switch self {
        case .cpu: ["CPU Energy"]
        case .gpu: ["GPU", "GPU Energy"]
        case .ane: ["ANE"]
        case .ram: ["DRAM", "DCS"]
        case .soc: ["SOC_REST", "SOC_AON"]
        }
    }
}

// MARK: - 原始载荷(Live 交回,折算在核心包)

/// 单个能耗通道的一次读数:通道名原文 + 单位标签原文 + 无量纲整数。
/// IOReport 的能量计数器是累计量,功率由差分得出(见 PowerAccumulator)。
public struct PowerChannelSample: Equatable, Sendable {
    public let name: String
    public let unitLabel: String
    public let rawValue: Double

    public init(name: String, unitLabel: String, rawValue: Double) {
        self.name = name
        self.unitLabel = unitLabel
        self.rawValue = rawValue
    }
}

/// 一次 Energy Model 采样的原始载荷:全部通道(Live 不过滤——通道名 → 域的
/// 映射是纯逻辑,留在核心包单测覆盖)+ 采样时刻(差分用时差,不用标称间隔)。
public struct PowerRawReading: Equatable, Sendable {
    public let channels: [PowerChannelSample]
    public let takenAt: Date

    public init(channels: [PowerChannelSample], takenAt: Date) {
        self.channels = channels
        self.takenAt = takenAt
    }
}

/// 单位标签 → 每 raw 单位的焦耳数。换算表移植自 stats(MIT)
/// Modules/GPU/reader.swift:349-359(mJ/nJ 相差 10⁶ 不许错);未知标签按
/// nJ——stats 同款默认(Energy 通道族的实际单位域就是 pJ–J)。
public enum EnergyUnitScale {
    public static func joulesPerRaw(_ label: String) -> Double {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "j": 1
        case "mj": 1e-3
        case "uj", "µj": 1e-6
        case "nj": 1e-9
        case "pj": 1e-12
        default: 1e-9
        }
    }
}

// MARK: - 折算后的读数

/// 五路功率读数:在场域各一瓦数(通道缺席的域**缺席**,不伪造 0 之外的信息);
/// 差分首读 / 间隔超限重置时各在场域记 0(首读 0 语义)。
public struct PowerReading: Equatable, Sendable {
    public let watts: [PowerDomain: Double]
    public let takenAt: Date

    /// 在场域瓦数合计(不是整机墙功率,GLOSSARY「五路功率」的 Avoid 注)。
    public var totalWatts: Double {
        watts.values.reduce(0, +)
    }

    public init(watts: [PowerDomain: Double], takenAt: Date) {
        self.watts = watts
        self.takenAt = takenAt
    }
}

// MARK: - 五路差分器(纯值)

/// 能量差分器:ΔE(焦耳)÷ 实测时差(秒)→ 瓦数。三条防御(stats
/// readANEPower 同款 + 票面口径):
/// ① **首次记录记基线、各在场域返 0**(没有基线,首读 0);
/// ② **间隔超 maxGap 视为断档**(典型:系统睡眠、门控长停后复采)——重置
///    基线、本轮作废(唤醒丢首轮,防假尖峰;间隔在 5s 档下正常 ≤ 数秒,
///    50s 上限 = 10 倍节奏);
/// ③ **负差钳 0**(计数器回绕/重置)。
public struct PowerAccumulator: Sendable {
    public let maxGap: TimeInterval
    /// 基线的换算后焦耳(按通道名)+ 基线时刻。
    private var baselineJoules: [String: Double]?
    private var baselineAt: Date?

    public init(maxGap: TimeInterval = 50) {
        self.maxGap = maxGap
    }

    /// 记一次采样:返回折算读数(读失败在 provider 层挡,这里不返 nil)。
    public mutating func record(_ raw: PowerRawReading) -> PowerReading {
        let joules = Self.joulesByChannel(raw)

        guard let baselineAt, let baselineJoules else {
            store(joules, at: raw.takenAt)
            return PowerReading(watts: zeros(for: raw), takenAt: raw.takenAt)
        }

        let elapsed = raw.takenAt.timeIntervalSince(baselineAt)
        guard elapsed > 0, elapsed <= maxGap else {
            // 断档(睡眠/长停):丢本轮、重置基线——唤醒丢首轮。
            store(joules, at: raw.takenAt)
            return PowerReading(watts: zeros(for: raw), takenAt: raw.takenAt)
        }

        var watts: [PowerDomain: Double] = [:]
        for domain in PowerDomain.allCases {
            let names = domain.channelNames
            let now = names.reduce(0.0) { $0 + (joules[$1] ?? 0) }
            let was = names.reduce(0.0) { $0 + (baselineJoules[$1] ?? 0) }
            let hasChannel = names.contains { joules[$0] != nil }
            guard hasChannel else { continue } // 通道缺席的域缺席,不伪造
            let delta = max(0, now - was) // 负差钳 0
            watts[domain] = delta / elapsed
        }
        store(joules, at: raw.takenAt)
        return PowerReading(watts: watts, takenAt: raw.takenAt)
    }

    /// 全部在场域记 0(首读/断档轮的交付形状)。
    private func zeros(for raw: PowerRawReading) -> [PowerDomain: Double] {
        var watts: [PowerDomain: Double] = [:]
        let present = Set(raw.channels.map(\.name))
        for domain in PowerDomain.allCases where domain.channelNames.contains(where: { present.contains($0) }) {
            watts[domain] = 0
        }
        return watts
    }

    private mutating func store(_ joules: [String: Double], at date: Date) {
        baselineJoules = joules
        baselineAt = date
    }

    /// 逐通道换算成焦耳,同名通道求和(按名字聚合,超脱通道顺序)。
    private static func joulesByChannel(_ raw: PowerRawReading) -> [String: Double] {
        var joules: [String: Double] = [:]
        for channel in raw.channels {
            joules[channel.name, default: 0] += channel.rawValue * EnergyUnitScale.joulesPerRaw(channel.unitLabel)
        }
        return joules
    }
}

// MARK: - ANE 归一化

/// ANE 按芯片最大功耗表的归一化上限(进度条比例;stats reader.swift:27-41
/// 同表,MIT)。表值错只影响比例不崩;未知芯片兜底 8.0(stats 同款)。
public enum AnePowerCap {
    /// 键 = 芯片名规整("Apple M4 Pro" → "m4pro")。
    static let table: [String: Double] = [
        "m1": 2.0, "m1pro": 2.0, "m1max": 2.0, "m1ultra": 4.0,
        "m2": 2.5, "m2pro": 2.5, "m2max": 2.5, "m2ultra": 5.0,
        "m3": 3.0, "m3pro": 3.0, "m3max": 3.0, "m3ultra": 6.0,
        "m4": 6.0, "m4pro": 6.0, "m4max": 6.0,
        "m5": 8.0, "m5pro": 8.0, "m5max": 8.0, "m5ultra": 16.0,
        "m6": 16.0, "m6pro": 16.0, "m6max": 16.0,
    ]

    /// 规整芯片名("Apple M4" / "apple m4 pro" → "m4pro")→ 归一化百分比,钳 0…100。
    public static func normalizedPercent(watts: Double, chipName: String) -> Double {
        let key = chipName
            .lowercased()
            .replacingOccurrences(of: "apple", with: "")
            .replacingOccurrences(of: " ", with: "")
        let cap = table[key] ?? 8.0
        return min(max(watts / cap * 100, 0), 100)
    }
}

// MARK: - 功率源协议(编译期测试接缝,ADR-0003 澄清条款同款)

/// 功率源(ADR-0004 接缝):产品运行期唯一真实现 = app 的 Energy Model
/// Live 适配器;测试注入假源;缝上全部纯逻辑(本文件的换算/差分/映射)。
public protocol PowerSource: Sendable {
    /// 采一次;nil = 读失败(订阅缺席 / 采样失败)。
    func read() -> PowerRawReading?
}
