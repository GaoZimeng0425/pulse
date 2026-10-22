@testable import PulseCore
import XCTest

/// 接缝:GPU 读数折算(p2-sensors/02,纯逻辑)。只测外部行为(载荷进 → 读数出),
/// 防御分支全部合成载荷覆盖——钳位 / AGC 关电 / 回退键序 / 关电文案位。
/// 键名与回退序的出处:stats(MIT)Modules/GPU/reader.swift:139、:205
/// (docs/research/sensor-impl-comparison.md §2.4)。
final class GpuModelTests: XCTestCase {
    func testUtilizationPrefersDeviceKeyFallsBackToActivity() {
        // 利用率首选 "Device Utilization %",缺键回退 "GPU Activity(%)"。
        let primary = GpuReading.make(from: GpuRawReading(deviceUtilizationPercent: 42, gpuActivityPercent: 99))
        XCTAssertEqual(primary.utilizationPercent, 42)

        let fallback = GpuReading.make(from: GpuRawReading(gpuActivityPercent: 37))
        XCTAssertEqual(fallback.utilizationPercent, 37)

        let neither = GpuReading.make(from: GpuRawReading(modelName: "Apple M4"))
        XCTAssertEqual(neither.utilizationPercent, 0)
    }

    func testZeroPrimaryBeatsFallback() {
        // 首选键为 0 是真读数,不是缺键——不回退。
        let reading = GpuReading.make(from: GpuRawReading(
            deviceUtilizationPercent: 0,
            gpuActivityPercent: 55
        ))
        XCTAssertEqual(reading.utilizationPercent, 0)
    }

    func testClampingAbove100AndBelow0() {
        // 越界钳位(stats reader.swift:209-226 同款防御):>100 钳 100,负值钳 0。
        let over = GpuReading.make(from: GpuRawReading(
            deviceUtilizationPercent: 180,
            rendererUtilizationPercent: 250,
            tilerUtilizationPercent: 101
        ))
        XCTAssertEqual(over.utilizationPercent, 100)
        XCTAssertEqual(over.rendererPercent, 100)
        XCTAssertEqual(over.tilerPercent, 100)

        let negative = GpuReading.make(from: GpuRawReading(deviceUtilizationPercent: -1))
        XCTAssertEqual(negative.utilizationPercent, 0)
    }

    func testAGCPowerOffZerosUtilizationAndFlagsState() {
        // AGC 关电:利用率归 0 是正常态,poweredOff 保留供文案区分"空闲 0"与"关电 0"。
        let poweredOff = GpuReading.make(from: GpuRawReading(
            deviceUtilizationPercent: 73,
            poweredOffByAGC: true
        ))
        XCTAssertEqual(poweredOff.utilizationPercent, 0)
        XCTAssertTrue(poweredOff.poweredOff)

        let awake = GpuReading.make(from: GpuRawReading(deviceUtilizationPercent: 0))
        XCTAssertFalse(awake.poweredOff)
    }

    func testStaticInfoAndMemoryPassthrough() {
        // 静态信息与显存透传,不折算;缺的细分键保持 nil。
        let reading = GpuReading.make(from: GpuRawReading(
            allocatedBytes: 7_734_542_336,
            inUseBytes: 3_231_170_560,
            modelName: "Apple M4",
            coreCount: 10
        ))
        XCTAssertEqual(reading.allocatedBytes, 7_734_542_336)
        XCTAssertEqual(reading.inUseBytes, 3_231_170_560)
        XCTAssertEqual(reading.modelName, "Apple M4")
        XCTAssertEqual(reading.coreCount, 10)
        XCTAssertNil(reading.rendererPercent)
        XCTAssertNil(reading.tilerPercent)
    }
}
