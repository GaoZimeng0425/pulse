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
    private var index = 0

    func read() -> PowerRawReading? {
        guard index < readings.count else { return nil }
        defer { index += 1 }
        return readings[index]
    }
}

final class EnergyModelSensorTests: XCTestCase {
    func testGateBlocksReadsWhenInvisible() async {
        // 门控关:不读源;开:采一次,首读 = 在场域全 0(差分首读 0 语义)。
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

        provider.setVisible(true)
        let first = await provider.snapshot()
        XCTAssertEqual(first?.watts[.cpu], 0)
        XCTAssertEqual(first?.watts[.ane], 0)
        XCTAssertNil(first?.watts[.gpu])
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
        ]
        let provider = EnergyModelSensorProvider(source: source)
        provider.setVisible(true)

        _ = await provider.snapshot()
        let failed = await provider.snapshot() // 队列耗尽 → nil
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.watts[.ane], 0) // 首读的 0 也是好值
    }

    func testCadenceIsFiveSeconds() {
        // 节奏(票面):与 GPU 同档 5s。
        let provider = EnergyModelSensorProvider(source: FakePowerSource())
        XCTAssertEqual(provider.cadence, .every(seconds: 5))
    }

    func testLiveSmokeOnThisMachine() async {
        // Live 冒烟:真订阅 + 采两轮(首轮记基线,次轮出瓦数);M4 的
        // Energy Model 组 175 通道(探针④),五路域至少 CPU/GPU/ANE 在场。
        let provider = EnergyModelSensorProvider(source: LiveEnergyModelSource())
        provider.setVisible(true)

        let first = await provider.snapshot()
        XCTAssertNotNil(first)
        XCTAssertGreaterThan(first?.watts.count ?? 0, 2, "在场域应 ≥3(CPU/GPU/ANE)")

        try? await Task.sleep(nanoseconds: 1_200_000_000)
        let second = await provider.snapshot()
        let total = second?.totalWatts ?? -1
        XCTAssertTrue(total >= 0 && total < 100, "五路合计量级异常:\(total) W")
    }
}
