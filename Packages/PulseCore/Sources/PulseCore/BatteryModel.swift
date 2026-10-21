import Foundation

// 电池的纯值层:充电状态 / 原始读数 / 健康度 / 展示读数折叠与源接缝。IOPS / IORegistry 适配器与事件流在 app target(BatterySensor.swift)。

/// 充电状态(工单 02):「接着电但不充」映射为"优化充电已介入"——macOS 优化
/// 充电介入时正是这个表现,不做映射 UI 会误报故障(调研 §2.3:stats-ref :148-158)。
public enum BatteryChargeStatus: Equatable, Sendable {
    case charging
    case charged
    /// 接着电但不充:优化充电已介入(非故障)。
    case optimizedCharging
    case discharging

    /// 状态文案:chip 与卡片补充行共用。
    public var title: String {
        switch self {
        case .charging: "充电中"
        case .charged: "已充满"
        case .optimizedCharging: "优化充电已介入"
        case .discharging: "使用电池"
        }
    }
}

/// 电池原始读数:IOPS 三连 + IORegistry AppleSmartBattery 原样字段,未加工;
/// nil 字段 = 该项本次读不到(健康度回退链逐级兜底)。
public struct BatteryRawReading: Equatable, Sendable {
    // IOPS(IOPSGetPowerSourceDescription)
    /// 当前电量百分比(0–100)。
    public let capacityPercent: Int
    public let isCharging: Bool
    public let isCharged: Bool
    /// 剩余可用时间估计(分钟)。
    public let timeToEmptyMinutes: Int?
    /// 充满还需估计(分钟)。
    public let timeToFullMinutes: Int?
    // IORegistry AppleSmartBattery
    /// 设计容量(健康度分母,读数为 0 时钳 1 防除零);真机探针:macOS 26 /
    /// Apple Silicon 顶层可能没有,兜底进 BatteryData(见 batteryDataDesignCapacity)。
    public let designCapacity: Int?
    /// 满充容量回退链,arm64 主源起(Pulse arm64-only,不设 Intel 分支;真机
    /// 探针:顶层 `MaxCapacity` 在 Apple Silicon 上是百分比,不可当 mAh 用)。
    public let appleRawMaxCapacity: Int?
    public let nominalChargeCapacity: Int?
    /// BatteryData["DesignCapacity"](设计容量兜底;真机 2026-10-16:顶层缺席,
    /// BatteryData.DesignCapacity=6249 在)。
    public let batteryDataDesignCapacity: Int?
    public let batteryDataNominalChargeCapacity: Int?
    public let fullChargeCapacity: Int?
    public let cycleCount: Int?
    /// 电流(mA,放电为负)。
    public let amperageMilliamps: Int?
    /// 电压(mV)。
    public let voltageMillivolts: Int?
    /// ChargerData["NotChargingReason"](0 = 无特殊原因)。
    public let notChargingReasonRaw: Int?

    public init(
        capacityPercent: Int,
        isCharging: Bool,
        isCharged: Bool,
        timeToEmptyMinutes: Int? = nil,
        timeToFullMinutes: Int? = nil,
        designCapacity: Int? = nil,
        appleRawMaxCapacity: Int? = nil,
        nominalChargeCapacity: Int? = nil,
        batteryDataDesignCapacity: Int? = nil,
        batteryDataNominalChargeCapacity: Int? = nil,
        fullChargeCapacity: Int? = nil,
        cycleCount: Int? = nil,
        amperageMilliamps: Int? = nil,
        voltageMillivolts: Int? = nil,
        notChargingReasonRaw: Int? = nil
    ) {
        self.capacityPercent = capacityPercent
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.designCapacity = designCapacity
        self.appleRawMaxCapacity = appleRawMaxCapacity
        self.nominalChargeCapacity = nominalChargeCapacity
        self.batteryDataDesignCapacity = batteryDataDesignCapacity
        self.batteryDataNominalChargeCapacity = batteryDataNominalChargeCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.cycleCount = cycleCount
        self.amperageMilliamps = amperageMilliamps
        self.voltageMillivolts = voltageMillivolts
        self.notChargingReasonRaw = notChargingReasonRaw
    }
}

/// 健康度与满充容量:回退链与除零防护照 stats(MIT)翻译,合成夹具单测钉死。
public enum BatteryHealth {
    /// 满充容量回退链(stats-ref :102-116):`AppleRawMaxCapacity`(arm64 主源)
    /// → `NominalChargeCapacity` → `BatteryData["NominalChargeCapacity"]`
    /// → `FullChargeCapacity`,逐级取第一个读到的;全落空 = nil。
    public static func fullChargeCapacity(of raw: BatteryRawReading) -> Int? {
        raw.appleRawMaxCapacity
            ?? raw.nominalChargeCapacity
            ?? raw.batteryDataNominalChargeCapacity
            ?? raw.fullChargeCapacity
    }

    /// 健康度 = round(100 × 满充 / 设计)(stats-ref :120-123),结果钳 0–100;
    /// 设计容量为 0 时钳成 1 防除零(stats-ref :106-108);
    /// 任一容量缺失 → nil(UI 显示占位,不伪造)。
    public static func percent(designCapacity: Int?, fullChargeCapacity: Int?) -> Int? {
        guard let design = designCapacity, let full = fullChargeCapacity else { return nil }
        let denominator = max(design, 1)
        let percent = (Double(full) / Double(denominator) * 100).rounded()
        return min(100, max(0, Int(percent)))
    }

    /// 设计容量兜底(真机探针 2026-10-16):顶层 `DesignCapacity` 在
    /// macOS 26 / Apple Silicon 上可能缺席,容量键整体藏进 `BatteryData`
    /// (顶层 `MaxCapacity`=100 是百分比,不可当 mAh)——同样兜底进去取。
    public static func designCapacity(of raw: BatteryRawReading) -> Int? {
        raw.designCapacity ?? raw.batteryDataDesignCapacity
    }
}

/// 电池卡六项读数(工单 02):电量 / 状态 / 剩余时间 / 健康度 / 循环次数 / 功率。
public struct BatteryReading: Equatable, Sendable {
    /// 电量百分比(0–100)。
    public let capacityPercent: Int
    /// 充电状态(含"优化充电已介入"语义映射)。
    public let status: BatteryChargeStatus
    /// 剩余可用时间(分钟);nil = 系统未给估计,显示占位。
    public let timeToEmptyMinutes: Int?
    /// 充满还需(分钟);nil = 系统未给估计。
    public let timeToFullMinutes: Int?
    /// 健康度(0–100);回退链全落空为 nil。
    public let healthPercent: Int?
    /// 循环次数;nil = 读不到。
    public let cycleCount: Int?
    /// 功率(瓦,绝对值——方向由状态行表达);任一电学量缺失为 nil。
    public let powerWatts: Double?

    /// 原始读数 → 展示读数(全部纯逻辑在此折叠,单测即本接缝)。
    public static func make(from raw: BatteryRawReading) -> BatteryReading {
        BatteryReading(
            capacityPercent: raw.capacityPercent,
            status: chargeStatus(
                isCharging: raw.isCharging,
                isCharged: raw.isCharged,
                notChargingReasonRaw: raw.notChargingReasonRaw
            ),
            timeToEmptyMinutes: positive(raw.timeToEmptyMinutes),
            timeToFullMinutes: positive(raw.timeToFullMinutes),
            healthPercent: BatteryHealth.percent(
                designCapacity: BatteryHealth.designCapacity(of: raw),
                fullChargeCapacity: BatteryHealth.fullChargeCapacity(of: raw)
            ),
            cycleCount: raw.cycleCount,
            powerWatts: powerWatts(
                amperageMilliamps: raw.amperageMilliamps,
                voltageMillivolts: raw.voltageMillivolts
            )
        )
    }

    /// 充电状态映射(stats-ref :148-158):已充满 > 充电中 >
    /// 未充电且 NotChargingReason ≠ 0 = 优化充电已介入(接着电但不充,电量未满)
    /// > 使用电池。
    public static func chargeStatus(
        isCharging: Bool,
        isCharged: Bool,
        notChargingReasonRaw: Int?
    ) -> BatteryChargeStatus {
        if isCharged {
            return .charged
        }
        if isCharging {
            return .charging
        }
        if (notChargingReasonRaw ?? 0) != 0 {
            return .optimizedCharging
        }
        return .discharging
    }

    /// 功率 = 电流 × 电压(mA·mV / 1e6 = W;stats-ref :125-139)。SMC 精确
    /// 功率(PPBR)是 P2 增强项,先用 V×A。放电电流为负,取绝对值。
    public static func powerWatts(amperageMilliamps: Int?, voltageMillivolts: Int?) -> Double? {
        guard let amperage = amperageMilliamps, let voltage = voltageMillivolts else { return nil }
        return abs(Double(amperage) * Double(voltage)) / 1_000_000
    }

    /// 系统未给估计(IOPS 报 0 / 负值哨兵)→ nil,不伪造。
    private static func positive(_ minutes: Int?) -> Int? {
        minutes.flatMap { $0 > 0 ? $0 : nil }
    }

    public init(
        capacityPercent: Int,
        status: BatteryChargeStatus,
        timeToEmptyMinutes: Int? = nil,
        timeToFullMinutes: Int? = nil,
        healthPercent: Int? = nil,
        cycleCount: Int? = nil,
        powerWatts: Double? = nil
    ) {
        self.capacityPercent = capacityPercent
        self.status = status
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
        self.powerWatts = powerWatts
    }
}

/// 电池源接缝:一行 read 拿全部原始字段,缝上是纯逻辑。
/// nil = 本机无内建电池(IOPS 三连找不到 `kIOPSInternalBatteryType`,台式机
/// 常态,工单 02:整页隐藏);IORegistry 条目缺失等**部分**读失败返回字段
/// 可空的正常读数,由回退链与占位兜底——绝不因部分失败判"无电池"。
public protocol BatterySource: Sendable {
    func read() -> BatteryRawReading?
}

public extension BatteryRawReading {
    /// IORegistry AppleSmartBattery 的单字段集合(内部:read 与读数装配的中转)。
    struct SmartBatteryValues {
        public let designCapacity: Int?
        public let appleRawMaxCapacity: Int?
        public let nominalChargeCapacity: Int?
        public let batteryDataDesignCapacity: Int?
        public let batteryDataNominalChargeCapacity: Int?
        public let fullChargeCapacity: Int?
        public let cycleCount: Int?
        public let amperageMilliamps: Int?
        public let voltageMillivolts: Int?
        public let notChargingReasonRaw: Int?

        public init(
            designCapacity: Int? = nil,
            appleRawMaxCapacity: Int? = nil,
            nominalChargeCapacity: Int? = nil,
            batteryDataDesignCapacity: Int? = nil,
            batteryDataNominalChargeCapacity: Int? = nil,
            fullChargeCapacity: Int? = nil,
            cycleCount: Int? = nil,
            amperageMilliamps: Int? = nil,
            voltageMillivolts: Int? = nil,
            notChargingReasonRaw: Int? = nil
        ) {
            self.designCapacity = designCapacity
            self.appleRawMaxCapacity = appleRawMaxCapacity
            self.nominalChargeCapacity = nominalChargeCapacity
            self.batteryDataDesignCapacity = batteryDataDesignCapacity
            self.batteryDataNominalChargeCapacity = batteryDataNominalChargeCapacity
            self.fullChargeCapacity = fullChargeCapacity
            self.cycleCount = cycleCount
            self.amperageMilliamps = amperageMilliamps
            self.voltageMillivolts = voltageMillivolts
            self.notChargingReasonRaw = notChargingReasonRaw
        }
    }
}
