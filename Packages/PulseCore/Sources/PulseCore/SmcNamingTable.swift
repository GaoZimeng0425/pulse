import Foundation

// MARK: - SMC 传感器命名表(p2-sensors/04,GLOSSARY「传感器命名表」)

/// 命名表条目:显示名(可带 % 单字符占位,与键同形)、组、类型、是否参与均值派生。
public struct SmcSensorName: Equatable, Sendable {
    public let name: String
    public let group: SmcSensorGroup
    public let type: SmcSensorType
    /// stats 同款标志:参与 Average 派生的传感器(如每核温度),v1 派生均值只收它们。
    public let average: Bool

    public init(name: String, group: SmcSensorGroup, type: SmcSensorType, average: Bool) {
        self.name = name
        self.group = group
        self.type = type
        self.average = average
    }
}

/// 传感器组(stats SensorGroup 同构):CPU/GPU/系统/传感器(其余)/未知(表外)。
public enum SmcSensorGroup: String, CaseIterable, Sendable {
    case cpu, gpu, soc, system, sensor, unknown

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .soc: "SoC"
        case .system: "系统"
        case .sensor: "传感器"
        case .unknown: "未知"
        }
    }
}

/// 读数类型(v1 展示温度与风扇;电压/电流/功率读得到但先不展示,表收录完整)。
public enum SmcSensorType: String, Sendable {
    case temperature, voltage, current, power, energy, fan
}

/// SMC 键 → 显示名映射表:条目与通配形(%% = 单字符占位)机械移植自
/// stats(MIT)Modules/Sensors/values.swift(2026-10-22 快照,212 条去重后;platforms
/// 字段不移植——不在场的键永远不会匹配,Intel 专属条目是死重无害)。
/// 表外键归"未知"组默认折叠,不丢弃(GLOSSARY)。
public enum SmcNamingTable {
    public static let entries: [String: SmcSensorName] = [
        "TA%P": SmcSensorName(name: "Ambient %", group: .sensor, type: .temperature, average: false),
        "Th%H": SmcSensorName(name: "Heatpipe %", group: .sensor, type: .temperature, average: false),
        "TZ%C": SmcSensorName(name: "Thermal zone %", group: .sensor, type: .temperature, average: false),
        "TC0D": SmcSensorName(name: "CPU diode", group: .cpu, type: .temperature, average: false),
        "TC0E": SmcSensorName(name: "CPU diode virtual", group: .cpu, type: .temperature, average: false),
        "TC0F": SmcSensorName(name: "CPU diode filtered", group: .cpu, type: .temperature, average: false),
        "TC0H": SmcSensorName(name: "CPU heatsink", group: .cpu, type: .temperature, average: false),
        "TC0P": SmcSensorName(name: "CPU proximity", group: .cpu, type: .temperature, average: false),
        "TCAD": SmcSensorName(name: "CPU package", group: .cpu, type: .temperature, average: false),
        "TCAC": SmcSensorName(name: "CPU A core die", group: .cpu, type: .temperature, average: true),
        "TCBC": SmcSensorName(name: "CPU B core die", group: .cpu, type: .temperature, average: true),
        "TCAH": SmcSensorName(name: "CPU A heatsink", group: .cpu, type: .temperature, average: false),
        "TCBH": SmcSensorName(name: "CPU B heatsink", group: .cpu, type: .temperature, average: false),
        "TC%c": SmcSensorName(name: "CPU core %", group: .cpu, type: .temperature, average: true),
        "TC%C": SmcSensorName(name: "CPU Core %", group: .cpu, type: .temperature, average: true),
        "TCGC": SmcSensorName(name: "GPU Intel Graphics", group: .gpu, type: .temperature, average: false),
        "TG0D": SmcSensorName(name: "GPU diode", group: .gpu, type: .temperature, average: false),
        "TGDD": SmcSensorName(name: "GPU AMD Radeon", group: .gpu, type: .temperature, average: false),
        "TG0H": SmcSensorName(name: "GPU heatsink", group: .gpu, type: .temperature, average: false),
        "TG0P": SmcSensorName(name: "GPU proximity", group: .gpu, type: .temperature, average: false),
        "Tm0P": SmcSensorName(name: "Mainboard", group: .system, type: .temperature, average: false),
        "Tp0P": SmcSensorName(name: "CPU performance core 6", group: .cpu, type: .temperature, average: true),
        "TB1T": SmcSensorName(name: "Battery 1", group: .system, type: .temperature, average: false),
        "TW0P": SmcSensorName(name: "Airport", group: .system, type: .temperature, average: false),
        "TL0P": SmcSensorName(name: "Display", group: .system, type: .temperature, average: false),
        "TI%P": SmcSensorName(name: "Thunderbolt %", group: .system, type: .temperature, average: false),
        "TH%A": SmcSensorName(name: "Disk % (A)", group: .system, type: .temperature, average: false),
        "TH%B": SmcSensorName(name: "Disk % (B)", group: .system, type: .temperature, average: false),
        "TH%C": SmcSensorName(name: "Disk % (C)", group: .system, type: .temperature, average: false),
        "TTLD": SmcSensorName(name: "Thunderbolt left", group: .system, type: .temperature, average: false),
        "TTRD": SmcSensorName(name: "Thunderbolt right", group: .system, type: .temperature, average: false),
        "TN0D": SmcSensorName(name: "Northbridge diode", group: .system, type: .temperature, average: false),
        "TN0H": SmcSensorName(name: "Northbridge heatsink", group: .system, type: .temperature, average: false),
        "TN0P": SmcSensorName(name: "Northbridge proximity", group: .system, type: .temperature, average: false),
        "TMA1": SmcSensorName(name: "Memory riser A slot 1", group: .system, type: .temperature, average: false),
        "TMA2": SmcSensorName(name: "Memory riser A slot 2", group: .system, type: .temperature, average: false),
        "TMA3": SmcSensorName(name: "Memory riser A slot 3", group: .system, type: .temperature, average: false),
        "TMA4": SmcSensorName(name: "Memory riser A slot 4", group: .system, type: .temperature, average: false),
        "TMB1": SmcSensorName(name: "Memory riser B slot 1", group: .system, type: .temperature, average: false),
        "TMB2": SmcSensorName(name: "Memory riser B slot 2", group: .system, type: .temperature, average: false),
        "TMB3": SmcSensorName(name: "Memory riser B slot 3", group: .system, type: .temperature, average: false),
        "TMB4": SmcSensorName(name: "Memory riser B slot 4", group: .system, type: .temperature, average: false),
        "Tp09": SmcSensorName(name: "CPU super core 3", group: .cpu, type: .temperature, average: true),
        "Tp0T": SmcSensorName(name: "CPU efficiency core 2", group: .cpu, type: .temperature, average: true),
        "Tp01": SmcSensorName(name: "CPU performance core 1", group: .cpu, type: .temperature, average: true),
        "Tp05": SmcSensorName(name: "CPU performance core 1", group: .cpu, type: .temperature, average: true),
        "Tp0D": SmcSensorName(name: "CPU performance core 2", group: .cpu, type: .temperature, average: true),
        "Tp0H": SmcSensorName(name: "CPU performance core 4", group: .cpu, type: .temperature, average: true),
        "Tp0L": SmcSensorName(name: "CPU performance core 2", group: .cpu, type: .temperature, average: true),
        "Tp0X": SmcSensorName(name: "CPU performance core 4", group: .cpu, type: .temperature, average: true),
        "Tp0b": SmcSensorName(name: "CPU performance core 7", group: .cpu, type: .temperature, average: true),
        "Tg05": SmcSensorName(name: "GPU 1", group: .gpu, type: .temperature, average: true),
        "Tg0D": SmcSensorName(name: "GPU 2", group: .gpu, type: .temperature, average: true),
        "Tg0L": SmcSensorName(name: "GPU 3", group: .gpu, type: .temperature, average: true),
        "Tg0T": SmcSensorName(name: "GPU 4", group: .gpu, type: .temperature, average: true),
        "Tm02": SmcSensorName(name: "Memory 1", group: .sensor, type: .temperature, average: false),
        "Tm06": SmcSensorName(name: "Memory 2", group: .sensor, type: .temperature, average: false),
        "Tm08": SmcSensorName(name: "Memory 3", group: .sensor, type: .temperature, average: false),
        "Tm09": SmcSensorName(name: "Memory 4", group: .sensor, type: .temperature, average: false),
        "Tp1h": SmcSensorName(name: "CPU efficiency core 1", group: .cpu, type: .temperature, average: true),
        "Tp1t": SmcSensorName(name: "CPU efficiency core 2", group: .cpu, type: .temperature, average: true),
        "Tp1p": SmcSensorName(name: "CPU efficiency core 3", group: .cpu, type: .temperature, average: true),
        "Tp1l": SmcSensorName(name: "CPU efficiency core 4", group: .cpu, type: .temperature, average: true),
        "Tp0f": SmcSensorName(name: "CPU performance core 7", group: .cpu, type: .temperature, average: true),
        "Tp0j": SmcSensorName(name: "CPU super core 1", group: .cpu, type: .temperature, average: true),
        "Tg0f": SmcSensorName(name: "GPU 1", group: .gpu, type: .temperature, average: true),
        "Tg0j": SmcSensorName(name: "GPU 5", group: .gpu, type: .temperature, average: true),
        "Te05": SmcSensorName(name: "CPU efficiency core 1", group: .cpu, type: .temperature, average: true),
        "Te0L": SmcSensorName(name: "CPU efficiency core 2", group: .cpu, type: .temperature, average: true),
        "Te0P": SmcSensorName(name: "CPU efficiency core 3", group: .cpu, type: .temperature, average: true),
        "Te0S": SmcSensorName(name: "CPU efficiency core 2", group: .cpu, type: .temperature, average: true),
        "Tf04": SmcSensorName(name: "CPU performance core 1", group: .cpu, type: .temperature, average: true),
        "Tf09": SmcSensorName(name: "CPU performance core 2", group: .cpu, type: .temperature, average: true),
        "Tf0A": SmcSensorName(name: "CPU performance core 3", group: .cpu, type: .temperature, average: true),
        "Tf0B": SmcSensorName(name: "CPU performance core 4", group: .cpu, type: .temperature, average: true),
        "Tf0D": SmcSensorName(name: "CPU performance core 5", group: .cpu, type: .temperature, average: true),
        "Tf0E": SmcSensorName(name: "CPU performance core 6", group: .cpu, type: .temperature, average: true),
        "Tf44": SmcSensorName(name: "CPU performance core 7", group: .cpu, type: .temperature, average: true),
        "Tf49": SmcSensorName(name: "CPU performance core 8", group: .cpu, type: .temperature, average: true),
        "Tf4A": SmcSensorName(name: "CPU performance core 9", group: .cpu, type: .temperature, average: true),
        "Tf4B": SmcSensorName(name: "CPU performance core 10", group: .cpu, type: .temperature, average: true),
        "Tf4D": SmcSensorName(name: "CPU performance core 11", group: .cpu, type: .temperature, average: true),
        "Tf4E": SmcSensorName(name: "CPU performance core 12", group: .cpu, type: .temperature, average: true),
        "Tf14": SmcSensorName(name: "GPU 1", group: .gpu, type: .temperature, average: true),
        "Tf18": SmcSensorName(name: "GPU 2", group: .gpu, type: .temperature, average: true),
        "Tf19": SmcSensorName(name: "GPU 3", group: .gpu, type: .temperature, average: true),
        "Tf1A": SmcSensorName(name: "GPU 4", group: .gpu, type: .temperature, average: true),
        "Tf24": SmcSensorName(name: "GPU 5", group: .gpu, type: .temperature, average: true),
        "Tf28": SmcSensorName(name: "GPU 6", group: .gpu, type: .temperature, average: true),
        "Tf29": SmcSensorName(name: "GPU 7", group: .gpu, type: .temperature, average: true),
        "Tf2A": SmcSensorName(name: "GPU 8", group: .gpu, type: .temperature, average: true),
        "Te09": SmcSensorName(name: "CPU efficiency core 3", group: .cpu, type: .temperature, average: true),
        "Te0H": SmcSensorName(name: "CPU efficiency core 4", group: .cpu, type: .temperature, average: true),
        "Tp0V": SmcSensorName(name: "CPU performance core 5", group: .cpu, type: .temperature, average: true),
        "Tp0Y": SmcSensorName(name: "CPU performance core 6", group: .cpu, type: .temperature, average: true),
        "Tp0e": SmcSensorName(name: "CPU performance core 8", group: .cpu, type: .temperature, average: true),
        "Tg0G": SmcSensorName(name: "GPU 1", group: .gpu, type: .temperature, average: true),
        "Tg0H": SmcSensorName(name: "GPU 2", group: .gpu, type: .temperature, average: true),
        "Tg1U": SmcSensorName(name: "GPU 1", group: .gpu, type: .temperature, average: true),
        "Tg1k": SmcSensorName(name: "GPU 2", group: .gpu, type: .temperature, average: true),
        "Tg0K": SmcSensorName(name: "GPU 3", group: .gpu, type: .temperature, average: true),
        "Tg0d": SmcSensorName(name: "GPU 2", group: .gpu, type: .temperature, average: true),
        "Tg0e": SmcSensorName(name: "GPU 4", group: .gpu, type: .temperature, average: true),
        "Tg0k": SmcSensorName(name: "GPU 8", group: .gpu, type: .temperature, average: true),
        "Tm0p": SmcSensorName(name: "Memory Proximity 1", group: .sensor, type: .temperature, average: false),
        "Tm1p": SmcSensorName(name: "Memory Proximity 2", group: .sensor, type: .temperature, average: false),
        "Tm2p": SmcSensorName(name: "Memory Proximity 3", group: .sensor, type: .temperature, average: false),
        "Tp00": SmcSensorName(name: "CPU super core 1", group: .cpu, type: .temperature, average: true),
        "Tp04": SmcSensorName(name: "CPU super core 2", group: .cpu, type: .temperature, average: true),
        "Tp08": SmcSensorName(name: "CPU super core 3", group: .cpu, type: .temperature, average: true),
        "Tp0C": SmcSensorName(name: "CPU super core 4", group: .cpu, type: .temperature, average: true),
        "Tp0G": SmcSensorName(name: "CPU performance core 6", group: .cpu, type: .temperature, average: true),
        "Tp0K": SmcSensorName(name: "CPU super core 6", group: .cpu, type: .temperature, average: true),
        "Tp0O": SmcSensorName(name: "CPU performance core 1", group: .cpu, type: .temperature, average: true),
        "Tp0R": SmcSensorName(name: "CPU performance core 2", group: .cpu, type: .temperature, average: true),
        "Tp0U": SmcSensorName(name: "CPU performance core 3", group: .cpu, type: .temperature, average: true),
        "Tp0a": SmcSensorName(name: "CPU performance core 5", group: .cpu, type: .temperature, average: true),
        "Tp0d": SmcSensorName(name: "CPU performance core 4", group: .cpu, type: .temperature, average: true),
        "Tp0g": SmcSensorName(name: "CPU super core 2", group: .cpu, type: .temperature, average: true),
        "Tp0m": SmcSensorName(name: "CPU performance core 1", group: .cpu, type: .temperature, average: true),
        "Tp0p": SmcSensorName(name: "CPU performance core 10", group: .cpu, type: .temperature, average: true),
        "Tp0u": SmcSensorName(name: "CPU performance core 11", group: .cpu, type: .temperature, average: true),
        "Tp0y": SmcSensorName(name: "CPU performance core 12", group: .cpu, type: .temperature, average: true),
        "Tg0U": SmcSensorName(name: "GPU 1", group: .gpu, type: .temperature, average: true),
        "Tg0X": SmcSensorName(name: "GPU 2", group: .gpu, type: .temperature, average: true),
        "Tg0g": SmcSensorName(name: "GPU 4", group: .gpu, type: .temperature, average: true),
        "Tg1Y": SmcSensorName(name: "GPU 6", group: .gpu, type: .temperature, average: true),
        "Tg1c": SmcSensorName(name: "GPU 5", group: .gpu, type: .temperature, average: true),
        "Tg1g": SmcSensorName(name: "GPU 11", group: .gpu, type: .temperature, average: true),
        "Tp07": SmcSensorName(name: "CPU super core 4", group: .cpu, type: .temperature, average: true),
        "Tp0I": SmcSensorName(name: "CPU performance core 3", group: .cpu, type: .temperature, average: true),
        "Tp0E": SmcSensorName(name: "CPU performance core 5", group: .cpu, type: .temperature, average: true),
        "Te07": SmcSensorName(name: "CPU efficiency core 1", group: .cpu, type: .temperature, average: true),
        "Te08": SmcSensorName(name: "CPU efficiency core 2", group: .cpu, type: .temperature, average: true),
        "Te0c": SmcSensorName(name: "CPU efficiency core 4", group: .cpu, type: .temperature, average: true),
        "Te0h": SmcSensorName(name: "CPU efficiency core 5", group: .cpu, type: .temperature, average: true),
        "Te0i": SmcSensorName(name: "CPU efficiency core 6", group: .cpu, type: .temperature, average: true),
        "Tg1e": SmcSensorName(name: "GPU 1", group: .gpu, type: .temperature, average: true),
        "Tg0c": SmcSensorName(name: "GPU 3", group: .gpu, type: .temperature, average: true),
        "Tg0b": SmcSensorName(name: "GPU 4", group: .gpu, type: .temperature, average: true),
        "Tg1d": SmcSensorName(name: "GPU 6", group: .gpu, type: .temperature, average: true),
        "Tg07": SmcSensorName(name: "GPU 7", group: .gpu, type: .temperature, average: true),
        "Tg1f": SmcSensorName(name: "GPU 8", group: .gpu, type: .temperature, average: true),
        "Tg09": SmcSensorName(name: "GPU 9", group: .gpu, type: .temperature, average: true),
        "Tg0a": SmcSensorName(name: "GPU 10", group: .gpu, type: .temperature, average: true),
        "Tg1h": SmcSensorName(name: "GPU 12", group: .gpu, type: .temperature, average: true),
        "TaLP": SmcSensorName(name: "Airflow left", group: .sensor, type: .temperature, average: false),
        "TaRF": SmcSensorName(name: "Airflow right", group: .sensor, type: .temperature, average: false),
        "TH0x": SmcSensorName(name: "NAND", group: .system, type: .temperature, average: false),
        "TB2T": SmcSensorName(name: "Battery 2", group: .system, type: .temperature, average: false),
        "VCAC": SmcSensorName(name: "CPU IA", group: .cpu, type: .voltage, average: false),
        "VCSC": SmcSensorName(name: "CPU System Agent", group: .cpu, type: .voltage, average: false),
        "VC%C": SmcSensorName(name: "CPU Core %", group: .cpu, type: .voltage, average: false),
        "VCTC": SmcSensorName(name: "GPU Intel Graphics", group: .gpu, type: .voltage, average: false),
        "VG0C": SmcSensorName(name: "GPU", group: .gpu, type: .voltage, average: false),
        "VM0R": SmcSensorName(name: "Memory", group: .system, type: .voltage, average: false),
        "Vb0R": SmcSensorName(name: "CMOS", group: .system, type: .voltage, average: false),
        "VD0R": SmcSensorName(name: "DC In", group: .sensor, type: .voltage, average: false),
        "VP0R": SmcSensorName(name: "12V rail", group: .sensor, type: .voltage, average: false),
        "Vp0C": SmcSensorName(name: "12V vcc", group: .sensor, type: .voltage, average: false),
        "VV2S": SmcSensorName(name: "3V", group: .sensor, type: .voltage, average: false),
        "VR3R": SmcSensorName(name: "3.3V", group: .sensor, type: .voltage, average: false),
        "VV1S": SmcSensorName(name: "5V", group: .sensor, type: .voltage, average: false),
        "VV9S": SmcSensorName(name: "12V", group: .sensor, type: .voltage, average: false),
        "VeES": SmcSensorName(name: "PCI 12V", group: .sensor, type: .voltage, average: false),
        "IC0R": SmcSensorName(name: "CPU High side", group: .sensor, type: .current, average: false),
        "IG0R": SmcSensorName(name: "GPU High side", group: .sensor, type: .current, average: false),
        "ID0R": SmcSensorName(name: "DC In", group: .sensor, type: .current, average: false),
        "IBAC": SmcSensorName(name: "Battery", group: .sensor, type: .current, average: false),
        "IDBR": SmcSensorName(name: "Brightness", group: .sensor, type: .current, average: false),
        "IU1R": SmcSensorName(name: "Thunderbolt Left", group: .sensor, type: .current, average: false),
        "IU2R": SmcSensorName(name: "Thunderbolt Right", group: .sensor, type: .current, average: false),
        "PC0C": SmcSensorName(name: "CPU Core", group: .cpu, type: .power, average: false),
        "PCAB": SmcSensorName(name: "CPU A core power (PCAB)", group: .cpu, type: .power, average: false),
        "PCAC": SmcSensorName(name: "CPU A core power (PCAC)", group: .cpu, type: .power, average: false),
        "PCBB": SmcSensorName(name: "CPU B core power (PCBB)", group: .cpu, type: .power, average: false),
        "PCBC": SmcSensorName(name: "CPU B core power (PCBC)", group: .cpu, type: .power, average: false),
        "PCAM": SmcSensorName(name: "CPU Core (IMON)", group: .cpu, type: .power, average: false),
        "PCPC": SmcSensorName(name: "CPU Package", group: .cpu, type: .power, average: false),
        "PCTR": SmcSensorName(name: "CPU Total", group: .cpu, type: .power, average: false),
        "PCPT": SmcSensorName(name: "CPU Package total", group: .cpu, type: .power, average: false),
        "PCPR": SmcSensorName(name: "CPU Package total (SMC)", group: .cpu, type: .power, average: false),
        "PC0R": SmcSensorName(name: "CPU Computing high side", group: .cpu, type: .power, average: false),
        "PC0G": SmcSensorName(name: "CPU GFX", group: .cpu, type: .power, average: false),
        "PCEC": SmcSensorName(name: "CPU VccEDRAM", group: .cpu, type: .power, average: false),
        "PCPG": SmcSensorName(name: "GPU Intel Graphics", group: .gpu, type: .power, average: false),
        "PG0C": SmcSensorName(name: "GPU", group: .gpu, type: .power, average: false),
        "PG0R": SmcSensorName(name: "GPU 1", group: .gpu, type: .power, average: false),
        "PG1R": SmcSensorName(name: "GPU 2", group: .gpu, type: .power, average: false),
        "PCGC": SmcSensorName(name: "Intel GPU", group: .gpu, type: .power, average: false),
        "PCGM": SmcSensorName(name: "Intel GPU (IMON)", group: .gpu, type: .power, average: false),
        "PC3C": SmcSensorName(name: "RAM", group: .sensor, type: .power, average: false),
        "PPBR": SmcSensorName(name: "Battery", group: .sensor, type: .power, average: false),
        "PDTR": SmcSensorName(name: "DC In", group: .sensor, type: .power, average: false),
        "PMTR": SmcSensorName(name: "Memory Total", group: .sensor, type: .power, average: false),
        "PSTR": SmcSensorName(name: "System Total", group: .sensor, type: .power, average: false),
        "PN0C": SmcSensorName(name: "Northbridge", group: .system, type: .power, average: false),
        "PU1R": SmcSensorName(name: "Thunderbolt Left", group: .sensor, type: .power, average: false),
        "PU2R": SmcSensorName(name: "Thunderbolt Right", group: .sensor, type: .power, average: false),
        "PDBR": SmcSensorName(name: "Power Delivery Brightness", group: .sensor, type: .power, average: false),
        "PBwo": SmcSensorName(name: "Display Backlight", group: .sensor, type: .power, average: false),
        "pACC MTR Temp Sensor%": SmcSensorName(
            name: "CPU performance core %",
            group: .cpu,
            type: .temperature,
            average: false
        ),
        "eACC MTR Temp Sensor%": SmcSensorName(
            name: "CPU efficiency core %",
            group: .cpu,
            type: .temperature,
            average: false
        ),
        "GPU MTR Temp Sensor%": SmcSensorName(name: "GPU core %", group: .gpu, type: .temperature, average: false),
        "SOC MTR Temp Sensor%": SmcSensorName(name: "SOC core %", group: .soc, type: .temperature, average: false),
        "ANE MTR Temp Sensor%": SmcSensorName(
            name: "Neural engine %",
            group: .sensor,
            type: .temperature,
            average: false
        ),
        "ISP MTR Temp Sensor%": SmcSensorName(
            name: "Image Signal Processor %",
            group: .sensor,
            type: .temperature,
            average: false
        ),
        "PMGR SOC Die Temp Sensor%": SmcSensorName(
            name: "Power manager die %",
            group: .soc,
            type: .temperature,
            average: false
        ),
        "PMU tdev%": SmcSensorName(
            name: "Power management unit dev %",
            group: .sensor,
            type: .temperature,
            average: false
        ),
        "PMU tdie%": SmcSensorName(
            name: "Power management unit die %",
            group: .sensor,
            type: .temperature,
            average: false
        ),
        "gas gauge battery": SmcSensorName(name: "Battery", group: .sensor, type: .temperature, average: false),
        "NAND CH% temp": SmcSensorName(name: "Disk %s", group: .gpu, type: .temperature, average: false),
    ]

    /// 键 → 命名:先精确,再按通配形(%% → 任意单字符)正则匹配;表外 → nil。
    public static func name(for key: String) -> SmcSensorName? {
        if let exact = entries[key] {
            return exact
        }
        for (pattern, value) in entries where pattern.contains("%") {
            let regex = "^" + NSRegularExpression.escapedPattern(for: pattern)
                .replacingOccurrences(of: "%", with: ".") + "$"
            if key.range(of: regex, options: .regularExpression) != nil {
                return value
            }
        }
        return nil
    }
}
