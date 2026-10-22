@testable import Pulse
@testable import PulseCore
import XCTest

// GPU 传感器测试(p2-sensors/02):provider 门控行为用假源(零 IORegistry 依赖),
// Live 源只做"本机真读一次不崩 + 结构健全"冒烟(既有 Live 适配器测试同款纪律)。

/// 假 GPU 源:固定载荷 + 开关(测门控的可见/不可见两态)。
private final class FakeGpuSource: GpuSource, @unchecked Sendable {
    var payload: GpuRawReading?

    func read() -> GpuRawReading? {
        payload
    }
}

final class GpuSensorTests: XCTestCase {
    func testGateBlocksReadsWhenInvisible() async {
        // 门控关:不读源,lastGood 不动;门控开:读并折算。
        let source = FakeGpuSource()
        source.payload = GpuRawReading(deviceUtilizationPercent: 42, modelName: "Apple M4")
        let provider = GpuSensorProvider(source: source)

        provider.setVisible(false)
        let blocked = await provider.snapshot()
        XCTAssertNil(blocked)
        XCTAssertNil(provider.lastGood)

        provider.setVisible(true)
        let read = await provider.snapshot()
        XCTAssertEqual(read?.utilizationPercent, 42)
        XCTAssertEqual(provider.lastGood?.modelName, "Apple M4")
    }

    func testLastGoodSurvivesFailure() async {
        // 读失败(nil)不动 lastGood:下次成功前保留上次好值。
        let source = FakeGpuSource()
        source.payload = GpuRawReading(deviceUtilizationPercent: 10)
        let provider = GpuSensorProvider(source: source)
        provider.setVisible(true)

        _ = await provider.snapshot()
        source.payload = nil // 模拟读失败
        let failed = await provider.snapshot()
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.utilizationPercent, 10)
    }

    func testCadenceIsFiveSeconds() {
        // 节奏登记(票面口径):5s 档。
        let provider = GpuSensorProvider(source: FakeGpuSource())
        XCTAssertEqual(provider.cadence, .every(seconds: 5))
    }

    func testLiveSmokeOnThisMachine() {
        // Live 冒烟:本机真读一次(Apple Silicon 必有加速器);钳位在核心包,
        // 这里只验原始值量级与静态信息在场。
        let reading = LiveGpuSource().read()
        XCTAssertNotNil(reading)
        if let utilization = reading?.deviceUtilizationPercent {
            XCTAssertTrue(utilization >= -1 && utilization <= 101, "原始利用率量级异常:\(utilization)")
        }
        XCTAssertEqual(reading?.modelName?.isEmpty, false)
    }
}
