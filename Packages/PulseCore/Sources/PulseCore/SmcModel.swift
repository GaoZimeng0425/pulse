import Foundation

// MARK: - SMC 传感器(p2-sensors/04,ADR-0004 SensorProvider 接缝)

/// SMC 键的原始读数(Live 交回的原始载荷):键名 + dataType 原文 + 原始字节。
/// 解码(sp78÷256、fpe2 移位、{fds 字符串……)全部是纯逻辑,住本文件单测覆盖。
public struct SmcRawKey: Equatable, Sendable {
    public let key: String
    public let dataType: String
    public let bytes: [UInt8]

    public init(key: String, dataType: String, bytes: [UInt8]) {
        self.key = key
        self.dataType = dataType
        self.bytes = bytes
    }
}

/// 一次 SMC 采样的原始载荷:本轮读到的全部键(Live 决定读哪些——T 前缀温度、
/// F 前缀风扇、电池功率顺手键;过滤在 Live,折算在这里)。
public struct SmcSnapshot: Equatable, Sendable {
    public let keys: [SmcRawKey]
    public let takenAt: Date

    public init(keys: [SmcRawKey], takenAt: Date) {
        self.keys = keys
        self.takenAt = takenAt
    }
}

// MARK: - dataType 解码(纯逻辑)

/// SMC dataType → 数值解码。换算表移植自 stats(MIT)SMC/smc.swift:224-274
/// (sp78 ÷256、fpe2 (b0<<6)+(b1>>2)、sp 系列按指数位……);`{fds` 的字符串
/// 解码供风扇命名(F?ID)。解不出 → nil(占位语义,不崩不伪造)。
public enum SmcValueDecoder {
    public static func decode(dataType: String, bytes: [UInt8]) -> Double? {
        guard bytes.count >= 2 else {
            if bytes.count == 1, dataType == "ui8 " {
                return Double(bytes[0])
            }
            return nil
        }
        let b0 = Int(bytes[0])
        let b1 = Int(bytes[1])
        let pair = Double(b0 * 256 + b1)
        switch dataType {
        case "ui8 ": return Double(b0)
        case "ui16": return pair
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        case "sp1e": return pair / 16384
        case "sp3c": return pair / 4096
        case "sp4b": return pair / 2048
        case "sp5a": return pair / 1024
        case "sp69": return pair / 512
        case "sp78": return pair / 256
        case "sp87": return pair / 128
        case "sp96": return pair / 64
        case "spa5": return pair / 32
        case "spb4": return pair / 16
        case "spf0": return pair
        case "fpe2": return Double((b0 << 6) + (b1 >> 2))
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return bytes.withUnsafeBytes { Double($0.loadUnaligned(as: Float.self)) }
        default: return nil
        }
    }

    /// `{fds` 型(风扇命名 F?ID)的字符串解码:第 4…16 字节的可见字符
    /// (stats getStringValue 同款)。
    public static func decodeString(dataType: String, bytes: [UInt8]) -> String? {
        guard dataType == "{fds", bytes.count > 4 else { return nil }
        return bytes[4 ..< min(16, bytes.count)]
            .compactMap { $0 == 0 ? nil : UnicodeScalar($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - 折算后的读数

/// 单个温度读数:命名表命中(isKnown)带显示名与组;表外键归"未知"组折叠。
public struct SmcTempReading: Equatable, Identifiable, Sendable {
    public let key: String
    public let name: String
    public let group: SmcSensorGroup
    /// 摄氏度;坏值防御后的值(见 make)。
    public let value: Double
    public let isKnown: Bool

    public var id: String {
        key
    }

    /// 命名表条目给出的显示名;表外用键名原文。
    public var displayName: String {
        isKnown ? name : key
    }
}

/// 单个风扇:F?Ac 当前转速 + F?Mn/F?Mx 上下限(fpe2, rpm)。
public struct SmcFanReading: Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String?
    public let rpm: Int
    public let minRpm: Int
    public let maxRpm: Int
}

/// 派生传感器(GLOSSARY「派生传感器」):Average 只收命名表标 average 的
/// 传感器(stats 同口径——每核温度),Hottest 收组内全部在场温度。
public struct SmcDerivedTemps: Equatable, Sendable {
    public let cpuAverage: Double?
    public let cpuHottest: Double?
    public let gpuAverage: Double?
    public let gpuHottest: Double?
    public let socAverage: Double?
    public let socHottest: Double?
}

/// SMC 读数(折算后):温度(命名表内/表外分列)、风扇、派生值、电池顺手键。
public struct SmcReading: Equatable, Sendable {
    public let knownTemps: [SmcTempReading]
    public let unknownTemps: [SmcTempReading]
    public let fans: [SmcFanReading]
    public let derived: SmcDerivedTemps
    /// 电池功率 W(SMC PPBR,优先于 V×A——p2-sensors/04 顺手活)。
    public let batteryPowerWatts: Double?
    /// 适配器瓦数 W(SMC PDTR,展示备用)。
    public let adapterWatts: Double?
    public let takenAt: Date

    /// 全部温度(明细折叠区用;组序见视图)。
    public var allTemps: [SmcTempReading] {
        knownTemps + unknownTemps
    }
}

// MARK: - 折算入口

/// 原始载荷 → 读数。坏值防御两档(stats readers :128-135、:155-159,票面口径):
/// ① 0 以下或 >110 → 丢弃(冻死/哨兵值;探针⑤实测 Ta## 恒 6.2°C 属此类);
/// ② 1…10 的低温 → 沿用上一轮同键值(M2 坏传感器先例),没有旧值则丢弃。
/// 风扇转速为 fpe2 原值;PPBR/PDTR 数值直接当瓦数(stats 同口径)。
public enum SmcReadingBuilder {
    public static func make(from snapshot: SmcSnapshot, previous: SmcReading?) -> SmcReading? {
        var values: [String: Double] = [:]
        var strings: [String: String] = [:]
        for raw in snapshot.keys {
            if let value = SmcValueDecoder.decode(dataType: raw.dataType, bytes: raw.bytes) {
                values[raw.key] = value
            }
            if let string = SmcValueDecoder.decodeString(dataType: raw.dataType, bytes: raw.bytes) {
                strings[raw.key] = string
            }
        }

        var known: [SmcTempReading] = []
        var unknown: [SmcTempReading] = []
        // 温度候选键 = T 前缀(stats 同款过滤)∨ 命名表标温的表外前缀键
        // (SOC MTR / PMGR SOC Die 的 S/P 前缀——2026-10-23 审计④:此前 T 前缀
        // 单一闸把 SoC 派生键整个挡在门外)。V*/I*/P* 已归正 voltage/current/
        // power 类型,不进温度面。
        for raw in snapshot.keys
            where raw.key.hasPrefix("T") || SmcNamingTable.name(for: raw.key)?.type == .temperature {
            guard let decoded = values[raw.key] else { continue }
            let previousValue = previous?.allTemps.first(where: { $0.key == raw.key })?.value
            guard let value = sanitized(decoded, previous: previousValue) else { continue }
            let reading: SmcTempReading
            if let named = SmcNamingTable.name(for: raw.key), named.type == .temperature {
                reading = SmcTempReading(
                    key: raw.key, name: named.name, group: named.group, value: value, isKnown: true
                )
                known.append(reading)
            } else {
                reading = SmcTempReading(
                    key: raw.key, name: raw.key, group: .unknown, value: value, isKnown: false
                )
                unknown.append(reading)
            }
        }
        guard !known.isEmpty || !unknown.isEmpty || !values.isEmpty else { return nil }
        known.sort { ($0.value, $0.key) > ($1.value, $1.key) }
        unknown.sort { ($0.value, $0.key) > ($1.value, $1.key) }

        // 风扇:FNum 数量 + F?Ac/Mn/Mx/F?ID。
        var fans: [SmcFanReading] = []
        if let fanCount = values["FNum"] {
            // 坏 FNum(非 ui8 dataType 解出的大值)钳到 0…8,防超长循环。
            let clampedFanCount = min(max(Int(fanCount), 0), 8)
            for index in 0 ..< clampedFanCount {
                let prefix = "F\(index)"
                guard let rpm = values["\(prefix)Ac"] else { continue }
                fans.append(
                    SmcFanReading(
                        id: index,
                        name: strings["\(prefix)ID"],
                        rpm: Int(rpm),
                        minRpm: Int(values["\(prefix)Mn"] ?? 0),
                        maxRpm: Int(values["\(prefix)Mx"] ?? 0)
                    )
                )
            }
        }

        return SmcReading(
            knownTemps: known,
            unknownTemps: unknown,
            fans: fans,
            derived: derive(from: known),
            batteryPowerWatts: values["PPBR"],
            adapterWatts: values["PDTR"],
            takenAt: snapshot.takenAt
        )
    }

    /// 温度坏值两档防御(见类型注释)。
    static func sanitized(_ value: Double, previous: Double?) -> Double? {
        if value <= 0 || value > 110 {
            return nil
        }
        if value < 10 {
            return previous // 沿用旧值;nil(首轮)则丢弃
        }
        return value
    }

    /// 派生:Average 收组内 average 标记的温度;Hottest 收组内全部。
    static func derive(from temps: [SmcTempReading]) -> SmcDerivedTemps {
        func stats(for group: SmcSensorGroup) -> (average: Double?, hottest: Double?) {
            let inGroup = temps.filter { $0.group == group }
            guard !inGroup.isEmpty else { return (nil, nil) }
            let hottest = inGroup.map(\.value).max()
            // average 标记来自命名表;Pulse 的 SmcTempReading 不带它——
            // 由调用方(inGroup 的 isKnown 组)按命名表再过滤一次。
            let averageCandidates = inGroup.filter { candidate in
                SmcNamingTable.name(for: candidate.key)?.average == true
            }
            let average = averageCandidates.isEmpty
                ? nil
                : averageCandidates.map(\.value).reduce(0, +) / Double(averageCandidates.count)
            return (average, hottest)
        }

        let cpu = stats(for: .cpu)
        let gpu = stats(for: .gpu)
        // SoC 派生只收 .soc 组(SOC MTR / PMGR SOC Die,2026-10-23 审计④:此前
        // 误读 .system 组——算的是主板/电池/屏幕杂项,错值还进了 30 天历史)。
        let soc = stats(for: .soc)
        return SmcDerivedTemps(
            cpuAverage: cpu.average, cpuHottest: cpu.hottest,
            gpuAverage: gpu.average, gpuHottest: gpu.hottest,
            socAverage: soc.average, socHottest: soc.hottest
        )
    }
}

// MARK: - SMC 源协议(编译期测试接缝,ADR-0003 澄清条款同款)

/// SMC 源(ADR-0004 接缝):产品运行期唯一真实现 = app 的 Live 适配器
/// (AppleSMC 用户态连接,探针⑤实证免权限);测试注入假源。
public protocol SmcSource: Sendable {
    /// 读一次本轮键集(T*/F*/电池顺手键);nil = 读失败(无 SMC / 连接失败)。
    func read() -> SmcSnapshot?
}
