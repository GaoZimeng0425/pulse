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
    func testGateDrivesIntervalNotReads() async {
        // p2-review/06 分档单循环:闸只驱动节奏(可见 5s / 不可见 30s),不再挡读
        // ——lastGood 语义(读失败保留上次好值)不变。
        let source = FakeGpuSource()
        source.payload = GpuRawReading(deviceUtilizationPercent: 42, modelName: "Apple M4")
        let provider = GpuSensorProvider(source: source)

        provider.setVisible(false)
        XCTAssertEqual(provider.adaptiveInterval?(), 30)
        let hiddenRead = await provider.snapshot()
        XCTAssertEqual(hiddenRead?.utilizationPercent, 42, "闸关照样读(历史档同一条循环)")
        XCTAssertEqual(provider.lastGood?.modelName, "Apple M4")

        provider.setVisible(true)
        XCTAssertEqual(provider.adaptiveInterval?(), 5)
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

    @MainActor
    func testStaleRedeliveryDoesNotFillTrend() async {
        // 审计④:读失败时调度器重投 lastGood(stale)——走势环不被同一旧值
        // 灌满(否则 60 点窗 5 分钟全是假平线);显示值保留。
        // p2-review/06 起 stale 只来自读失败(分档单循环闸关照样读)。
        let source = FakeGpuSource()
        source.payload = GpuRawReading(deviceUtilizationPercent: 42, modelName: "Apple M4")
        let feature = GpuFeature(source: source)
        let drivers = feature.sensorDrivers()

        await drivers[0].tick() // fresh
        XCTAssertEqual(feature.trend, [42])

        source.payload = nil // 模拟读失败 → stale 重投
        await drivers[0].tick()
        XCTAssertEqual(feature.trend, [42], "stale 重投不追加走势")
        XCTAssertEqual(feature.reading?.utilizationPercent, 42, "显示保留上次好值")
    }

    @MainActor
    func testHistoryBroadcastThrottledToThirtySeconds() async {
        // p2-review/06 分档单循环:历史广播由 HistoryThrottle 节流——首轮放行,
        // 之后每满 30s 放行一次;fresh 才广播(基线/读失败轮不广播)。
        let source = FakeGpuSource()
        source.payload = GpuRawReading(deviceUtilizationPercent: 42, modelName: "Apple M4")
        let feature = GpuFeature(source: source)
        var broadcast: [Double] = []
        feature.start(MonitorHost(
            restoreBirths: { _ in },
            setLaunchdServiceExecutablePaths: { _ in },
            setRankingsActive: { _ in },
            broadcast: {
                if case let .gauges(values) = $0, let utilization = values[.gpuUtilization] {
                    broadcast.append(utilization)
                }
            }
        ))
        let drivers = feature.sensorDrivers()

        await drivers[0].tick()
        XCTAssertEqual(broadcast.count, 1, "首轮放行(旧历史档基线语义)")

        await drivers[0].tick()
        await drivers[0].tick()
        XCTAssertEqual(broadcast.count, 1, "30s 未满不放行")

        source.payload = nil
        await drivers[0].tick()
        XCTAssertEqual(broadcast.count, 1, "stale 轮不广播")
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
