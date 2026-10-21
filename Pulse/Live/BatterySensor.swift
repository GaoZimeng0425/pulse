import Foundation
import IOKit
import IOKit.ps
import PulseCore

// 健康度回退链、NotChargingReason 语义映射、除零防护与功率算法移植自
// stats(MIT)Modules/Battery/readers.swift(调研 docs/research/
// sensor-impl-comparison.md §2.3 逐条钉死;依 spec 移植代码纪律注明来源)。

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
        if let number = value as? NSNumber {
            return number.intValue
        }
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

    var lastGood: BatteryReading? {
        slot.current
    }

    init(
        source: any BatterySource = LiveBatterySource(),
        wakeups: @escaping @Sendable () -> AsyncStream<Void>? = { IOPSWakeupStream.make() }
    ) {
        self.source = source
        makeWakeups = wakeups
    }

    func snapshot() async -> BatteryReading? {
        guard let raw = source.read() else { return nil } // 无内建电池:不动 lastGood
        let reading = BatteryReading.make(from: raw)
        slot.store(reading)
        return reading
    }

    func wakeups() -> AsyncStream<Void>? {
        makeWakeups()
    }
}
