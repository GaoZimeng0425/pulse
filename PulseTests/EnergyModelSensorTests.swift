@testable import Pulse
@testable import PulseCore
import XCTest

// 五路功率传感器测试(p2-sensors/03):provider 门控/差分接线用假源
// (零 IOReport 依赖),Live 源做"本机真采一次"冒烟(M4 Energy Model 组
// 探针④实证在场)。

/// 假功率源:可设载荷队列 + 时刻轴(差分逻辑在核心包已单测,这里只验接线:
/// provider 调 record 并交付)。
private final class FakePowerSource: PowerSource, @unchecked Sendable {
    var readings: [PowerRawReading] = []
    private(set) var readCount = 0
    private var index = 0

    func read() -> PowerRawReading? {
        readCount += 1
        guard index < readings.count else { return nil }
        defer { index += 1 }
        return readings[index]
    }
}

/// 并发探针源(p2-review/01 ①):每次读经 ReentryProbe,载荷按调用序号单调递增。
private final class ConcurrencyProbePowerSource: PowerSource, @unchecked Sendable {
    let probe = ReentryProbe()

    func read() -> PowerRawReading? {
        probe.measure { ordinal in
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: Double(ordinal) * 10)],
                takenAt: Date(timeIntervalSince1970: Double(ordinal))
            )
        }
    }
}

final class EnergyModelSensorTests: XCTestCase {
    func testGateBlocksReadsWhenInvisible() async {
        // 门控关:不读源;开:采一次——首读只记基线、不交读数(p2-review/01 拍板 B)。
        let source = FakePowerSource()
        source.readings = [
            PowerRawReading(channels: [
                PowerChannelSample(name: "CPU Energy", unitLabel: "mJ", rawValue: 100),
                PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 5),
            ], takenAt: Date(timeIntervalSince1970: 0)),
        ]
        let provider = EnergyModelSensorProvider(source: source)

        provider.setVisible(false)
        let blocked = await provider.snapshot()
        XCTAssertNil(blocked)
        XCTAssertEqual(source.readCount, 0, "闸关不碰源")

        provider.setVisible(true)
        let first = await provider.snapshot()
        XCTAssertEqual(source.readCount, 1, "闸开读源")
        XCTAssertNil(first, "首读只记基线")
        XCTAssertNil(provider.lastGood, "基线轮不成为 lastGood")
    }

    func testHistoryTierSkipsBaselineRound() async {
        // 历史档首轮(启动 / 唤醒)不交读数 → 历史 driver 不广播,不以 0 W 入历史。
        let source = FakePowerSource()
        source.readings = [
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 5)],
                takenAt: Date(timeIntervalSince1970: 0)
            ),
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 305)],
                takenAt: Date(timeIntervalSince1970: 30)
            ),
        ]
        let provider = EnergyModelSensorProvider(source: source)

        let baseline = await provider.historySnapshot()
        XCTAssertNil(baseline)
        let measured = await provider.historySnapshot()
        XCTAssertEqual(measured?.watts[.ane] ?? -1, 0.01, accuracy: 1e-9)
    }

    func testConcurrentTiersNeverReadSourceConcurrently() async {
        // 审计②补全(p2-review/01 ①):5s UI 档与 30s 历史档并发 tick 时,源的
        // 懒建订阅不得被并发进入——读源与折算同在一个锁段。
        let source = ConcurrencyProbePowerSource()
        let provider = EnergyModelSensorProvider(source: source)
        provider.setVisible(true)

        await withTaskGroup(of: Void.self) { group in
            for index in 0 ..< 8 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = await provider.snapshot()
                    } else {
                        _ = await provider.historySnapshot()
                    }
                }
            }
        }
        XCTAssertEqual(source.probe.peakInFlight, 1)
    }

    func testProviderDeliversDifferencedWatts() async {
        // 第二次采样出真差分:ANE 5 mJ → 15 mJ,间隔 2s = 5 mW。
        let source = FakePowerSource()
        source.readings = [
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 5)],
                takenAt: Date(timeIntervalSince1970: 0)
            ),
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 15)],
                takenAt: Date(timeIntervalSince1970: 2)
            ),
        ]
        let provider = EnergyModelSensorProvider(source: source)
        provider.setVisible(true)

        _ = await provider.snapshot()
        let second = await provider.snapshot()
        XCTAssertEqual(second?.watts[.ane] ?? -1, 0.005, accuracy: 1e-9)
    }

    func testSourceFailureKeepsLastGood() async {
        // 读失败(源 nil):不动 lastGood,下次成功前保留上次好值。
        let source = FakePowerSource()
        source.readings = [
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 5)],
                takenAt: Date(timeIntervalSince1970: 0)
            ),
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 15)],
                takenAt: Date(timeIntervalSince1970: 2)
            ),
        ]
        let provider = EnergyModelSensorProvider(source: source)
        provider.setVisible(true)

        _ = await provider.snapshot() // 基线
        _ = await provider.snapshot() // 0.005 W
        let failed = await provider.snapshot() // 队列耗尽 → nil
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.watts[.ane] ?? -1, 0.005, accuracy: 1e-9)
    }

    // MARK: - PowerFeature(ANE 卡的取数面)

    @MainActor
    func testAneAbsentLeavesPercentNilAndTrendEmpty() async {
        // ANE 通道缺席(p2-review/01 ④):百分比 nil → 卡片占位;走势不追加——
        // 不把"读不到"伪造成 0 W。基线轮同样不进走势。
        let source = FakePowerSource()
        source.readings = [
            PowerRawReading(
                channels: [PowerChannelSample(name: "CPU Energy", unitLabel: "mJ", rawValue: 100)],
                takenAt: Date(timeIntervalSince1970: 0)
            ),
            PowerRawReading(
                channels: [PowerChannelSample(name: "CPU Energy", unitLabel: "mJ", rawValue: 2100)],
                takenAt: Date(timeIntervalSince1970: 5)
            ),
        ]
        let feature = PowerFeature(source: source, chipName: "Apple M4")
        let drivers = feature.sensorDrivers()
        feature.visibilityChanged(MonitorVisibility(popoverTab: .gpu))

        await drivers[0].tick() // 基线轮
        XCTAssertNil(feature.reading)
        XCTAssertEqual(feature.aneTrend, [])

        await drivers[0].tick() // CPU 0.4 W,ANE 缺席
        XCTAssertEqual(feature.reading?.watts[.cpu] ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertNil(feature.aneNormalizedPercent)
        XCTAssertEqual(feature.aneTrend, [])
    }

    @MainActor
    func testAnePresentFillsPercentAndTrend() async {
        // ANE 在场:3 J / 5s = 0.6 W;M4 上限 6.0 W → 10%。
        let source = FakePowerSource()
        source.readings = [
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 0)],
                takenAt: Date(timeIntervalSince1970: 0)
            ),
            PowerRawReading(
                channels: [PowerChannelSample(name: "ANE", unitLabel: "mJ", rawValue: 3000)],
                takenAt: Date(timeIntervalSince1970: 5)
            ),
        ]
        let feature = PowerFeature(source: source, chipName: "Apple M4")
        let drivers = feature.sensorDrivers()
        feature.visibilityChanged(MonitorVisibility(popoverTab: .gpu))

        await drivers[0].tick()
        await drivers[0].tick()
        XCTAssertEqual(feature.aneTrend.count, 1)
        XCTAssertEqual(feature.aneTrend.first ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(feature.aneNormalizedPercent ?? -1, 10, accuracy: 1e-9)
    }

    func testCadenceIsFiveSeconds() {
        // 节奏(票面):与 GPU 同档 5s。
        let provider = EnergyModelSensorProvider(source: FakePowerSource())
        XCTAssertEqual(provider.cadence, .every(seconds: 5))
    }

    func testLiveSmokeOnThisMachine() async {
        // Live 冒烟:真订阅 + 采两轮(首轮记基线不交读数,次轮出瓦数);M4 的
        // Energy Model 组 175 通道(探针④),五路域至少 CPU/GPU/ANE 在场。
        let provider = EnergyModelSensorProvider(source: LiveEnergyModelSource())
        provider.setVisible(true)

        let first = await provider.snapshot()
        XCTAssertNil(first, "首轮只记基线")

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let second = await provider.snapshot()
        XCTAssertGreaterThan(second?.watts.count ?? 0, 2, "在场域应 ≥3(CPU/GPU/ANE)")
        let total = second?.totalWatts ?? -1
        XCTAssertTrue(total >= 0 && total < 100, "五路合计量级异常:\(total) W")
    }
}
