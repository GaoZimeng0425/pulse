import XCTest
@testable import PulseCore

/// 工单 02 电池卡:核心层 BatteryModel 的合成夹具单测(健康度回退链 /
/// NotChargingReason 映射 / 除零防护 / 功率)。Provider 与事件挂接在
/// PulseTests/BatterySensorTests。
final class BatteryModelTests: XCTestCase {
    // MARK: - 夹具

    /// 原始读数夹具:缺省一台健康电池,测试只覆写关注的字段。
    private func raw(
        capacity: Int = 80,
        isCharging: Bool = false,
        isCharged: Bool = false,
        timeToEmpty: Int? = nil,
        timeToFull: Int? = nil,
        design: Int? = 5_000,
        rawMax: Int? = nil,
        nominal: Int? = nil,
        batteryDataDesign: Int? = nil,
        batteryDataNominal: Int? = nil,
        fullCharge: Int? = 4_500,
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

    // MARK: - 健康度回退链(调研 §2.3:stats-ref :102-123)

    func testFullChargeCapacityFallsBackLevelByLevel() {
        // 回退链逐级:AppleRawMaxCapacity(arm64 主源)→ NominalChargeCapacity
        // → BatteryData["NominalChargeCapacity"] → FullChargeCapacity。
        XCTAssertEqual(
            BatteryHealth.fullChargeCapacity(
                of: raw(rawMax: 90, nominal: 80, batteryDataNominal: 70, fullCharge: 60)
            ),
            90
        )
        XCTAssertEqual(
            BatteryHealth.fullChargeCapacity(of: raw(rawMax: nil, nominal: 80, batteryDataNominal: 70, fullCharge: 60)),
            80
        )
        XCTAssertEqual(
            BatteryHealth.fullChargeCapacity(of: raw(rawMax: nil, nominal: nil, batteryDataNominal: 70, fullCharge: 60)),
            70
        )
        XCTAssertEqual(
            BatteryHealth.fullChargeCapacity(of: raw(rawMax: nil, nominal: nil, batteryDataNominal: nil, fullCharge: 60)),
            60
        )
        // 全落空:nil(健康度显示占位,不伪造)。
        XCTAssertNil(BatteryHealth.fullChargeCapacity(of: raw(fullCharge: nil)))
    }

    func testHealthPercentRoundsFromDesignRatio() {
        XCTAssertEqual(BatteryHealth.percent(designCapacity: 5_000, fullChargeCapacity: 4_600), 92)
        XCTAssertEqual(BatteryHealth.percent(designCapacity: 1_000, fullChargeCapacity: 455), 46)
    }

    func testHealthPercentClampsTo100WhenFullExceedsDesign() {
        // 满充高于设计(个别机器标定):健康度不超 100。
        XCTAssertEqual(BatteryHealth.percent(designCapacity: 100, fullChargeCapacity: 120), 100)
    }

    func testHealthPercentClampsZeroDesignToOneAgainstDivideByZero() {
        // 设计容量为 0 钳成 1(stats-ref :106-108):分母至少 1,绝不除零;
        // 负值同理走钳位。满充 3/设计 1 = 300% → 钳 100;满充 0 → 0。
        XCTAssertEqual(BatteryHealth.percent(designCapacity: 0, fullChargeCapacity: 3), 100)
        XCTAssertEqual(BatteryHealth.percent(designCapacity: -5, fullChargeCapacity: 3), 100)
        XCTAssertEqual(BatteryHealth.percent(designCapacity: 0, fullChargeCapacity: 0), 0)
    }

    func testHealthPercentIsNilWhenEitherCapacityMissing() {
        // 任一容量缺失:健康度未知,显示占位(nil)。
        XCTAssertNil(BatteryHealth.percent(designCapacity: nil, fullChargeCapacity: 4_000))
        XCTAssertNil(BatteryHealth.percent(designCapacity: 5_000, fullChargeCapacity: nil))
    }

    func testDesignCapacityFallsBackIntoBatteryData() {
        // 真机探针(macOS 26 / Apple Silicon):顶层无 DesignCapacity,容量键藏在
        // BatteryData 内(顶层 MaxCapacity=100 是百分比,不可当 mAh 用)——
        // 设计容量同样兜底进 BatteryData。
        let withTopLevel = raw(design: 5_000, batteryDataDesign: 6_249, batteryDataNominal: 5_798)
        XCTAssertEqual(BatteryHealth.designCapacity(of: withTopLevel), 5_000)
        let batteryDataOnly = raw(design: nil, batteryDataDesign: 6_249, batteryDataNominal: 5_798)
        XCTAssertEqual(BatteryHealth.designCapacity(of: batteryDataOnly), 6_249)
        // 本机同刻对照:BatteryData 全量 → 健康 = round(100 × 5798 / 6249) = 93。
        XCTAssertEqual(
            BatteryHealth.percent(
                designCapacity: 6_249,
                fullChargeCapacity: BatteryHealth.fullChargeCapacity(
                    of: raw(design: nil, batteryDataDesign: 6_249, batteryDataNominal: 5_798)
                )
            ),
            93
        )
    }

    // MARK: - 充电状态映射(调研 §2.3:stats-ref :148-158)

    func testChargeStatusMapping() {
        // 已充满(含仍插电)压过一切。
        XCTAssertEqual(BatteryReading.chargeStatus(isCharging: false, isCharged: true, notChargingReasonRaw: 0), .charged)
        XCTAssertEqual(BatteryReading.chargeStatus(isCharging: true, isCharged: true, notChargingReasonRaw: 0), .charged)
        // 充电中。
        XCTAssertEqual(BatteryReading.chargeStatus(isCharging: true, isCharged: false, notChargingReasonRaw: nil), .charging)
        // 「接着电但不充」+ NotChargingReason ≠ 0 = 优化充电已介入(非故障)。
        XCTAssertEqual(BatteryReading.chargeStatus(isCharging: false, isCharged: false, notChargingReasonRaw: 4), .optimizedCharging)
        // 常规放电(reason = 0 或缺失)。
        XCTAssertEqual(BatteryReading.chargeStatus(isCharging: false, isCharged: false, notChargingReasonRaw: 0), .discharging)
        XCTAssertEqual(BatteryReading.chargeStatus(isCharging: false, isCharged: false, notChargingReasonRaw: nil), .discharging)
    }

    // MARK: - 功率 = 电流 × 电压(调研 §2.3:stats-ref :125-139;SMC PPBR 属 P2)

    func testPowerWattsMultipliesAmperageAndVoltage() {
        XCTAssertEqual(
            BatteryReading.powerWatts(amperageMilliamps: 3_000, voltageMillivolts: 11_500)!,
            34.5,
            accuracy: 1e-9
        )
    }

    func testPowerWattsTakesAbsoluteValueForDischarge() {
        // IORegistry 的 Amperage 放电为负:功率取绝对值,方向由状态行表达。
        XCTAssertEqual(
            BatteryReading.powerWatts(amperageMilliamps: -1_500, voltageMillivolts: 11_600)!,
            17.4,
            accuracy: 1e-9
        )
    }

    func testPowerWattsIsNilWhenEitherValueMissing() {
        XCTAssertNil(BatteryReading.powerWatts(amperageMilliamps: nil, voltageMillivolts: 11_500))
        XCTAssertNil(BatteryReading.powerWatts(amperageMilliamps: 3_000, voltageMillivolts: nil))
    }

    // MARK: - 原始读数 → 展示读数折叠

    func testMakeFoldsRawIntoReading() {
        let reading = BatteryReading.make(from: raw(
            capacity: 66,
            isCharging: true,
            timeToEmpty: 0,
            timeToFull: 45,
            design: 5_000,
            rawMax: 4_600,
            cycles: 312,
            amperage: 2_000,
            voltage: 9_000
        ))
        XCTAssertEqual(reading.capacityPercent, 66)
        XCTAssertEqual(reading.status, .charging)
        XCTAssertEqual(reading.timeToFullMinutes, 45)
        XCTAssertNil(reading.timeToEmptyMinutes, "≤0 = 系统未给估计,不伪造")
        XCTAssertEqual(reading.healthPercent, 92)
        XCTAssertEqual(reading.cycleCount, 312)
        XCTAssertEqual(reading.powerWatts!, 18.0, accuracy: 1e-9)
    }
}
