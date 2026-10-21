import Foundation
import PulseCore

/// 电池原始读数夹具:核心包 BatteryModelTests 与 app 侧 BatterySensorTests 共用(p1-history/02)。
public enum BatteryFixture {
    /// 原始读数夹具:缺省一台健康电池,测试只覆写关注的字段。
    public static func raw(
        capacity: Int = 80,
        isCharging: Bool = false,
        isCharged: Bool = false,
        timeToEmpty: Int? = nil,
        timeToFull: Int? = nil,
        design: Int? = 5000,
        rawMax: Int? = nil,
        nominal: Int? = nil,
        batteryDataDesign: Int? = nil,
        batteryDataNominal: Int? = nil,
        fullCharge: Int? = 4500,
        cycles: Int? = 312,
        amperage: Int? = nil,
        voltage: Int? = nil,
        notChargingReason: Int? = 0
    ) -> BatteryRawReading {
        BatteryRawReading(
            capacityPercent: capacity,
            isCharging: isCharging,
            isCharged: isCharged,
            timeToEmptyMinutes: timeToEmpty,
            timeToFullMinutes: timeToFull,
            designCapacity: design,
            appleRawMaxCapacity: rawMax,
            nominalChargeCapacity: nominal,
            batteryDataDesignCapacity: batteryDataDesign,
            batteryDataNominalChargeCapacity: batteryDataNominal,
            fullChargeCapacity: fullCharge,
            cycleCount: cycles,
            amperageMilliamps: amperage,
            voltageMillivolts: voltage,
            notChargingReasonRaw: notChargingReason
        )
    }
}
