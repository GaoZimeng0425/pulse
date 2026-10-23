@testable import PulseCore
import XCTest

/// 接缝:五路功率折算(p2-sensors/03,纯逻辑)。单位换算(mJ/nJ 相差 10⁶)、
/// 域映射(主备通道/多通道求和)、差分三防御(首读 0/断档丢首轮/负差钳 0)、
/// ANE 归一化表——全部合成载荷覆盖。通道名与单位实证:探针④(2026-10-22,M4)。
final class PowerModelTests: XCTestCase {
    // MARK: - 单位换算

    func testUnitScaleMagnitudes() {
        // mJ 与 nJ 相差 10⁶,不许错(票面验收点)。
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("mJ"), 1e-3)
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("nJ"), 1e-9)
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("mJ") / EnergyUnitScale.joulesPerRaw("nJ"), 1e6)
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("µJ"), 1e-6)
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("uJ"), 1e-6)
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("pJ"), 1e-12)
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("J"), 1)
        // 未知标签按 nJ(stats 默认);前后空白容错。
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("MJ "), 1e-3)
        XCTAssertEqual(EnergyUnitScale.joulesPerRaw("weird"), 1e-9)
    }

    // MARK: - 差分器

    func testFirstRecordReturnsZeroWatts() {
        // 首次记录:只记基线,在场域全 0(首读 0 语义,stats readANEPower 同款)。
        var accumulator = PowerAccumulator()
        let reading = accumulator.record(sample([
            ("CPU Energy", "mJ", 1000),
            ("ANE", "mJ", 500),
        ], at: Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(reading.watts[.cpu], 0)
        XCTAssertEqual(reading.watts[.ane], 0)
        XCTAssertNil(reading.watts[.gpu])
    }

    func testDeltaOverElapsedIsWatts() {
        // ΔE ÷ 实测时差:CPU 1000 mJ → 2000 mJ,间隔 2s = 500 mW。
        var accumulator = PowerAccumulator()
        _ = accumulator.record(sample([("CPU Energy", "mJ", 1000)], at: Date(timeIntervalSince1970: 0)))
        let reading = accumulator.record(sample([("CPU Energy", "mJ", 2000)], at: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(reading.watts[.cpu] ?? -1, 0.5, accuracy: 1e-9)
    }

    func testMidStreamNewChannelDoesNotSpike() {
        // 订阅中途新增通道(审计⑤):GPU 通道第二轮才出现——首差不得把开机
        // 累计量当增量出巨刺,该域本轮缺席;基线补齐后下一轮恢复正常差分。
        var accumulator = PowerAccumulator()
        _ = accumulator.record(sample([("CPU Energy", "mJ", 1000)], at: Date(timeIntervalSince1970: 0)))
        let spiked = accumulator.record(sample([
            ("CPU Energy", "mJ", 1100),
            ("GPU", "mJ", 5_000_000), // 中途出现:若按 0 基线差分会算出巨瓦
        ], at: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(spiked.watts[.cpu] ?? -1, 0.1, accuracy: 1e-9, "老通道差分照常")
        XCTAssertNil(spiked.watts[.gpu], "中途新增通道的域本轮缺席,不出巨刺")

        let recovered = accumulator.record(sample([
            ("CPU Energy", "mJ", 1200),
            ("GPU", "mJ", 5_001_000),
        ], at: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(recovered.watts[.gpu] ?? -1, 1.0, accuracy: 1e-9, "基线补齐后恢复差分")
    }

    func testMixedUnitsPerChannel() {
        // 同读数里 GPU(mJ)与 GPU Energy(nJ)共存时按各通道标签换算:
        // GPU +1000 mJ = 1 J;间隔 1s → GPU 域 = 1 W + 0.001 W(nJ 通道 1e6 raw = 1 mJ)。
        var accumulator = PowerAccumulator()
        _ = accumulator.record(sample([
            ("GPU", "mJ", 1000),
            ("GPU Energy", "nJ", 0),
        ], at: Date(timeIntervalSince1970: 0)))
        let reading = accumulator.record(sample([
            ("GPU", "mJ", 2000),
            ("GPU Energy", "nJ", 1_000_000),
        ], at: Date(timeIntervalSince1970: 1)))
        XCTAssertEqual(reading.watts[.gpu] ?? -1, 1.001, accuracy: 1e-9)
    }

    func testGapBeyondMaxGapDropsRoundAndResetsBaseline() {
        // 断档(睡眠/长停)超 maxGap:本轮作废(全 0),基线重置——
        // 下一轮从新基线正常差分,不出现跨睡眠巨刺。
        var accumulator = PowerAccumulator(maxGap: 50)
        _ = accumulator.record(sample([("ANE", "mJ", 100)], at: Date(timeIntervalSince1970: 0)))
        let afterSleep = accumulator.record(sample([("ANE", "mJ", 500)], at: Date(timeIntervalSince1970: 3600)))
        XCTAssertEqual(afterSleep.watts[.ane], 0)
        let next = accumulator.record(sample([("ANE", "mJ", 600)], at: Date(timeIntervalSince1970: 3602)))
        XCTAssertEqual(next.watts[.ane] ?? -1, 0.05, accuracy: 1e-9)
    }

    func testNegativeDeltaClampsToZero() {
        // 计数器回绕/重置(能量倒退)→ 0,不出负瓦数。
        var accumulator = PowerAccumulator()
        _ = accumulator.record(sample([("DRAM", "mJ", 5000)], at: Date(timeIntervalSince1970: 0)))
        let reading = accumulator.record(sample([("DRAM", "mJ", 100)], at: Date(timeIntervalSince1970: 5)))
        XCTAssertEqual(reading.watts[.ram], 0)
    }

    func testDomainMappingFallsBackAndSums() {
        // 主键缺席走备键:gpu 用 "GPU Energy";soc 两候选都在 → 求和;
        // 通道缺席的域(如本例 ane)在 watts 里缺席,不伪造。
        var accumulator = PowerAccumulator()
        _ = accumulator.record(sample([
            ("GPU Energy", "nJ", 0),
            ("SOC_REST", "mJ", 0),
            ("SOC_AON", "mJ", 0),
        ], at: Date(timeIntervalSince1970: 0)))
        let reading = accumulator.record(sample([
            ("GPU Energy", "nJ", 1_000_000_000), // 1 J
            ("SOC_REST", "mJ", 1000), // 1 J
            ("SOC_AON", "mJ", 500), // 0.5 J
        ], at: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(reading.watts[.gpu] ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(reading.watts[.soc] ?? -1, 0.75, accuracy: 1e-9)
        XCTAssertNil(reading.watts[.ane])
        XCTAssertNil(reading.watts[.cpu])
    }

    func testTotalWattsSumsPresentDomains() {
        let reading = PowerReading(
            watts: [.cpu: 1.5, .gpu: 2.0, .soc: 0.5],
            takenAt: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(reading.totalWatts, 4.0, accuracy: 1e-9)
    }

    // MARK: - ANE 归一化

    func testAneNormalizationTableAndClamp() {
        // M4 = 6.0W 上限;超过钳 100;未知芯片兜底 8.0W。
        XCTAssertEqual(AnePowerCap.normalizedPercent(watts: 3.0, chipName: "Apple M4"), 50)
        XCTAssertEqual(
            AnePowerCap.normalizedPercent(watts: 0.8, chipName: "Apple M4 Pro"),
            8 * 100 / 60,
            accuracy: 1e-9
        )
        XCTAssertEqual(AnePowerCap.normalizedPercent(watts: 99, chipName: "Apple M4"), 100)
        XCTAssertEqual(AnePowerCap.normalizedPercent(watts: 8, chipName: "Apple M99"), 100) // 兜底 8W
        XCTAssertEqual(AnePowerCap.normalizedPercent(watts: 0, chipName: "Apple M4"), 0)
    }

    // MARK: - 助手

    private func sample(
        _ channels: [(String, String, Double)],
        at date: Date
    ) -> PowerRawReading {
        PowerRawReading(
            channels: channels.map { PowerChannelSample(name: $0.0, unitLabel: $0.1, rawValue: $0.2) },
            takenAt: date
        )
    }
}
