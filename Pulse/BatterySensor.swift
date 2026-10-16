import Foundation
import IOKit
import IOKit.ps

// 健康度回退链、NotChargingReason 语义映射、除零防护与功率算法移植自
// stats(MIT)Modules/Battery/readers.swift(调研 docs/research/
// sensor-impl-comparison.md §2.3 逐条钉死;依 spec 移植代码纪律注明来源)。

// MARK: - 充电状态(纯逻辑)

/// 充电状态(工单 02):「接着电但不充」映射为"优化充电已介入"——macOS 优化
/// 充电介入时正是这个表现,不做映射 UI 会误报故障(调研 §2.3:stats-ref :148-158)。
enum BatteryChargeStatus: Equatable, Sendable {
    case charging
    case charged
    /// 接着电但不充:优化充电已介入(非故障)。
    case optimizedCharging
    case discharging

    /// 状态文案:chip 与卡片补充行共用。
    var title: String {
        switch self {
        case .charging: "充电中"
        case .charged: "已充满"
        case .optimizedCharging: "优化充电已介入"
        case .discharging: "使用电池"
        }
    }
}

// MARK: - 原始读数(OS 边界形状)

/// 电池原始读数:IOPS 三连 + IORegistry AppleSmartBattery 原样字段,未加工;
/// nil 字段 = 该项本次读不到(健康度回退链逐级兜底)。
struct BatteryRawReading: Equatable, Sendable {
    // IOPS(IOPSGetPowerSourceDescription)
    /// 当前电量百分比(0–100)。
    let capacityPercent: Int
    let isCharging: Bool
    let isCharged: Bool
    /// 剩余可用时间估计(分钟)。
    let timeToEmptyMinutes: Int?
    /// 充满还需估计(分钟)。
    let timeToFullMinutes: Int?
    // IORegistry AppleSmartBattery
    /// 设计容量(健康度分母,读数为 0 时钳 1 防除零);真机探针:macOS 26 /
    /// Apple Silicon 顶层可能没有,兜底进 BatteryData(见 batteryDataDesignCapacity)。
    let designCapacity: Int?
    /// 满充容量回退链,arm64 主源起(Pulse arm64-only,不设 Intel 分支;真机
    /// 探针:顶层 `MaxCapacity` 在 Apple Silicon 上是百分比,不可当 mAh 用)。
    let appleRawMaxCapacity: Int?
    let nominalChargeCapacity: Int?
    /// BatteryData["DesignCapacity"](设计容量兜底;真机 2026-10-16:顶层缺席,
    /// BatteryData.DesignCapacity=6249 在)。
    let batteryDataDesignCapacity: Int?
    let batteryDataNominalChargeCapacity: Int?
    let fullChargeCapacity: Int?
    let cycleCount: Int?
    /// 电流(mA,放电为负)。
    let amperageMilliamps: Int?
    /// 电压(mV)。
    let voltageMillivolts: Int?
    /// ChargerData["NotChargingReason"](0 = 无特殊原因)。
    let notChargingReasonRaw: Int?
}

// MARK: - 健康度(纯逻辑)

/// 健康度与满充容量:回退链与除零防护照 stats(MIT)翻译,合成夹具单测钉死。
enum BatteryHealth {
    /// 满充容量回退链(stats-ref :102-116):`AppleRawMaxCapacity`(arm64 主源)
    /// → `NominalChargeCapacity` → `BatteryData["NominalChargeCapacity"]`
    /// → `FullChargeCapacity`,逐级取第一个读到的;全落空 = nil。
    static func fullChargeCapacity(of raw: BatteryRawReading) -> Int? {
        raw.appleRawMaxCapacity
            ?? raw.nominalChargeCapacity
            ?? raw.batteryDataNominalChargeCapacity
            ?? raw.fullChargeCapacity
    }

    /// 健康度 = round(100 × 满充 / 设计)(stats-ref :120-123),结果钳 0–100;
    /// 设计容量为 0 时钳成 1 防除零(stats-ref :106-108);
    /// 任一容量缺失 → nil(UI 显示占位,不伪造)。
    static func percent(designCapacity: Int?, fullChargeCapacity: Int?) -> Int? {
        guard let design = designCapacity, let full = fullChargeCapacity else { return nil }
        let denominator = max(design, 1)
        let percent = (Double(full) / Double(denominator) * 100).rounded()
        return min(100, max(0, Int(percent)))
    }

    /// 设计容量兜底(真机探针 2026-10-16):顶层 `DesignCapacity` 在
    /// macOS 26 / Apple Silicon 上可能缺席,容量键整体藏进 `BatteryData`
    /// (顶层 `MaxCapacity`=100 是百分比,不可当 mAh)——同样兜底进去取。
    static func designCapacity(of raw: BatteryRawReading) -> Int? {
        raw.designCapacity ?? raw.batteryDataDesignCapacity
    }
}

// MARK: - 展示读数(纯逻辑折叠)

/// 电池卡六项读数(工单 02):电量 / 状态 / 剩余时间 / 健康度 / 循环次数 / 功率。
struct BatteryReading: Equatable, Sendable {
    /// 电量百分比(0–100)。
    let capacityPercent: Int
    /// 充电状态(含"优化充电已介入"语义映射)。
    let status: BatteryChargeStatus
    /// 剩余可用时间(分钟);nil = 系统未给估计,显示占位。
    let timeToEmptyMinutes: Int?
    /// 充满还需(分钟);nil = 系统未给估计。
    let timeToFullMinutes: Int?
    /// 健康度(0–100);回退链全落空为 nil。
    let healthPercent: Int?
    /// 循环次数;nil = 读不到。
    let cycleCount: Int?
    /// 功率(瓦,绝对值——方向由状态行表达);任一电学量缺失为 nil。
    let powerWatts: Double?

    /// 原始读数 → 展示读数(全部纯逻辑在此折叠,单测即本接缝)。
    static func make(from raw: BatteryRawReading) -> BatteryReading {
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
    static func chargeStatus(isCharging: Bool, isCharged: Bool, notChargingReasonRaw: Int?) -> BatteryChargeStatus {
        if isCharged { return .charged }
        if isCharging { return .charging }
        if (notChargingReasonRaw ?? 0) != 0 { return .optimizedCharging }
        return .discharging
    }

    /// 功率 = 电流 × 电压(mA·mV / 1e6 = W;stats-ref :125-139)。SMC 精确
    /// 功率(PPBR)是 P2 增强项,先用 V×A。放电电流为负,取绝对值。
    static func powerWatts(amperageMilliamps: Int?, voltageMillivolts: Int?) -> Double? {
        guard let amperage = amperageMilliamps, let voltage = voltageMillivolts else { return nil }
        return abs(Double(amperage) * Double(voltage)) / 1_000_000
    }

    /// 系统未给估计(IOPS 报 0 / 负值哨兵)→ nil,不伪造。
    private static func positive(_ minutes: Int?) -> Int? {
        minutes.flatMap { $0 > 0 ? $0 : nil }
    }
}

// MARK: - 电池源接缝(OS 边界,spec 六缝之电池源)

/// 电池源接缝:一行 read 拿全部原始字段,缝上是纯逻辑。
/// nil = 本机无内建电池(IOPS 三连找不到 `kIOPSInternalBatteryType`,台式机
/// 常态,工单 02:整页隐藏);IORegistry 条目缺失等**部分**读失败返回字段
/// 可空的正常读数,由回退链与占位兜底——绝不因部分失败判"无电池"。
protocol BatterySource: Sendable {
    func read() -> BatteryRawReading?
}

// MARK: - Live 电池源

/// Darwin 薄适配器:IOPS 三连(IOPSCopyPowerSourcesInfo → List → Description)
/// + IORegistry `AppleSmartBattery` 条目。IOPS 决定"有没有电池"与电量/状态/
/// 剩余时间;IORegistry 供健康度容量链、循环数、电流电压与 NotChargingReason。
struct LiveBatterySource: BatterySource {
    func read() -> BatteryRawReading? {
        guard let iops = Self.iopsReading() else { return nil } // 无内建电池
        let smart = Self.smartBatteryReading()
        return BatteryRawReading(
            capacityPercent: iops.capacityPercent,
            isCharging: iops.isCharging,
            isCharged: iops.isCharged,
            timeToEmptyMinutes: iops.timeToEmptyMinutes,
            timeToFullMinutes: iops.timeToFullMinutes,
            designCapacity: smart?.designCapacity,
            appleRawMaxCapacity: smart?.appleRawMaxCapacity,
            nominalChargeCapacity: smart?.nominalChargeCapacity,
            batteryDataDesignCapacity: smart?.batteryDataDesignCapacity,
            batteryDataNominalChargeCapacity: smart?.batteryDataNominalChargeCapacity,
            fullChargeCapacity: smart?.fullChargeCapacity,
            cycleCount: smart?.cycleCount,
            amperageMilliamps: smart?.amperageMilliamps,
            voltageMillivolts: smart?.voltageMillivolts,
            notChargingReasonRaw: smart?.notChargingReasonRaw
        )
    }

    /// IOPS 三连挑内建电池(stats-ref :61-94);UPS 不认(工单 02 口径:内建电池)。
    private static func iopsReading() -> (
        capacityPercent: Int, isCharging: Bool, isCharged: Bool,
        timeToEmptyMinutes: Int?, timeToFullMinutes: Int?
    )? {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?
                    .takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return (
                capacityPercent: description[kIOPSCurrentCapacityKey] as? Int ?? 0,
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                timeToEmptyMinutes: description[kIOPSTimeToEmptyKey] as? Int,
                timeToFullMinutes: description[kIOPSTimeToFullChargeKey] as? Int
            )
        }
        return nil
    }

    /// IORegistry AppleSmartBattery 单字段集合(stats-ref :16, :100-140);
    /// 条目缺失 → nil(健康度等走占位,不影响"有电池"判定)。
    private static func smartBatteryReading() -> BatteryRawReading.SmartBatteryValues? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any]
        else { return nil }

        let batteryData = properties["BatteryData"] as? [String: Any]
        let chargerData = properties["ChargerData"] as? [String: Any]
        return BatteryRawReading.SmartBatteryValues(
            designCapacity: intValue(properties["DesignCapacity"]),
            appleRawMaxCapacity: intValue(properties["AppleRawMaxCapacity"]),
            nominalChargeCapacity: intValue(properties["NominalChargeCapacity"]),
            batteryDataDesignCapacity: intValue(batteryData?["DesignCapacity"]),
            batteryDataNominalChargeCapacity: intValue(batteryData?["NominalChargeCapacity"]),
            fullChargeCapacity: intValue(properties["FullChargeCapacity"]),
            cycleCount: intValue(properties["CycleCount"]),
            amperageMilliamps: intValue(properties["Amperage"]),
            voltageMillivolts: intValue(properties["Voltage"]),
            notChargingReasonRaw: intValue(chargerData?["NotChargingReason"])
        )
    }

    /// 宽容取整:多数键是 CFNumber,个别(如 BatteryData 内层)可能以 CFData
    /// 裸字节存——按小端整数解(字节可能不对齐,用 loadUnaligned);
    /// 解不出 = nil,交给占位,不崩。
    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data {
            switch data.count {
            case 4: return data.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
            case 8: return data.withUnsafeBytes { Int($0.loadUnaligned(as: Int64.self)) }
            default: return nil
            }
        }
        return nil
    }
}

extension BatteryRawReading {
    /// IORegistry AppleSmartBattery 的单字段集合(内部:read 与读数装配的中转)。
    struct SmartBatteryValues {
        let designCapacity: Int?
        let appleRawMaxCapacity: Int?
        let nominalChargeCapacity: Int?
        let batteryDataDesignCapacity: Int?
        let batteryDataNominalChargeCapacity: Int?
        let fullChargeCapacity: Int?
        let cycleCount: Int?
        let amperageMilliamps: Int?
        let voltageMillivolts: Int?
        let notChargingReasonRaw: Int?
    }
}

// MARK: - 电源状态事件(事件驱动档的 OS 边界)

/// IOPS 电源状态通知 → 唤醒流(stats-ref :34-48):电源状态变化(插拔 /
/// 满充 / 低电)才唤醒读数,**不轮询**。构造即先发一个首唤醒——首帧就有数
/// (调研 §1.2);流被丢弃/取消时摘除 RunLoop source,不泄漏。
enum IOPSWakeupStream {
    /// 桥接 C 回调上下文:@unchecked Sendable 盒子持有 continuation 与
    /// run loop source,onTermination 只捕获盒子(Swift 6 Sendable 边界)。
    private final class Box: @unchecked Sendable {
        let continuation: AsyncStream<Void>.Continuation
        var runLoopSource: CFRunLoopSource?

        init(continuation: AsyncStream<Void>.Continuation) {
            self.continuation = continuation
        }

        func teardown() {
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            }
            Unmanaged.passUnretained(self).release()
        }
    }

    static func make() -> AsyncStream<Void> {
        AsyncStream { continuation in
            continuation.yield() // 首唤醒:启动即读一轮
            let box = Box(continuation: continuation)
            let context = Unmanaged.passRetained(box).toOpaque()
            let callback: IOPowerSourceCallbackType = { context in
                guard let context else { return }
                let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
                box.continuation.yield()
            }
            guard let unmanaged = IOPSNotificationCreateRunLoopSource(callback, context) else {
                Unmanaged.passUnretained(box).release()
                continuation.finish()
                return
            }
            let runLoopSource = unmanaged.takeRetainedValue()
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            box.runLoopSource = runLoopSource
            continuation.onTermination = { _ in box.teardown() }
        }
    }
}

// MARK: - 电池传感器 provider(ADR-0004 第一个真 provider)

/// 电池传感器(工单 02):事件驱动(`.onEvent`,IOPS 电源状态通知,不轮询);
/// 读数 = 原始读数经纯逻辑折叠(健康回退链 / 状态映射 / 功率)。读失败保留
/// lastGood(ADR-0004);无内建电池的机器源恒返 nil → 永无交付,消费方
/// (SystemMonitor.hasBattery)保持电池页整页隐藏。
final class BatterySensorProvider: SensorProvider {
    typealias Reading = BatteryReading

    let cadence: SensorCadence = .onEvent

    private let source: any BatterySource
    private let makeWakeups: @Sendable () -> AsyncStream<Void>?
    private let slot = SensorLastGoodBox<BatteryReading>()

    var lastGood: BatteryReading? { slot.current }

    init(
        source: any BatterySource = LiveBatterySource(),
        wakeups: @escaping @Sendable () -> AsyncStream<Void>? = { IOPSWakeupStream.make() }
    ) {
        self.source = source
        self.makeWakeups = wakeups
    }

    func snapshot() async -> BatteryReading? {
        guard let raw = source.read() else { return nil } // 无内建电池:不动 lastGood
        let reading = BatteryReading.make(from: raw)
        slot.store(reading)
        return reading
    }

    func wakeups() -> AsyncStream<Void>? { makeWakeups() }
}
