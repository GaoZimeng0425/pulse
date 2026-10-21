@testable import Pulse
@testable import PulseCore
import XCTest

/// p1-history/05 磁盘卡的 app 侧:容量 / 吞吐 Provider 的节奏、lastGood 与标记交付,
/// Live 源只做构造冒烟,不打真实磁盘语义断言。纯逻辑在核心包 DiskModelTests。
final class DiskSensorTests: XCTestCase {
    // MARK: - 容量对账夹具(合成,不读真实卷)

    // MARK: - ④ 吞吐差分(stats ActivityReader 同款防护)

    // MARK: - Provider:lastGood 与分档(ADR-0004 / 工单 05 验收框)

    func testCapacityProviderCadenceIsLowFrequency() {
        // 容量 provider 走低频档(30s),不进 1s 心跳;吞吐节奏随源路径
        // (主路径 5s 短档 / rusage 回退 30s 低频档)——调度器体现分档。
        XCTAssertEqual(DiskCapacityProvider(source: NilCapacitySource()).cadence, .every(seconds: 30))
        XCTAssertEqual(
            DiskThroughputProvider(source: NilThroughputSource(cadenceSeconds: 5)).cadence,
            .every(seconds: 5)
        )
        XCTAssertEqual(
            DiskThroughputProvider(source: NilThroughputSource(cadenceSeconds: 30)).cadence,
            .every(seconds: 30)
        )
    }

    func testCapacityProviderKeepsLastGoodOnFailure() async {
        // 读失败:交付 nil(driver 层换 lastGood),lastGood 保留上次好值。
        let provider = DiskCapacityProvider(source: ScriptedCapacitySource([DiskFixture.raw(), nil]))
        let first = await provider.snapshot()
        XCTAssertEqual(first?.containerUsedBytes, 300_000_000_000)
        let failed = await provider.snapshot()
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.containerUsedBytes, 300_000_000_000)
    }

    func testThroughputProviderFoldsCountersIntoRatesAndTrend() async {
        // 计数序列 → 速率读数:差分在 provider 内完成,读数自带走势。
        let provider = DiskThroughputProvider(source: ScriptedThroughputSource([
            DiskFixture.counters(read: 0, write: 0, uptime: 1_000_000_000),
            DiskFixture.counters(read: 900, write: 300, uptime: 2_000_000_000),
        ]))
        let first = await provider.snapshot()
        XCTAssertEqual(first?.current, .zero)
        let second = await provider.snapshot()
        XCTAssertEqual(second?.current.readBytesPerSecond ?? -1, 900, accuracy: 1e-9)
        XCTAssertEqual(second?.current.writeBytesPerSecond ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(second?.trend.count, 2)
        XCTAssertNotNil(provider.lastGood)
    }

    func testMarkedDriverTellsFreshReadingsFromLastGoodRedelivery() async {
        // 读成功 → 新读数(fresh);读失败 → 重投上次好值并标 stale——磁盘记账据此
        // 只记 fresh,恰好一次不再靠读数逐字段比较(arch-review-2026-10-18 甲5)。
        let provider = DiskThroughputProvider(source: ScriptedThroughputSource([
            DiskFixture.counters(read: 0, write: 0, uptime: 1_000_000_000),
            DiskFixture.counters(read: 900, write: 300, uptime: 2_000_000_000),
            nil,
        ]))
        let box = MarkedDeliveryBox()
        let driver = provider.markedDriver { box.append($0) }
        await driver.tick()
        await driver.tick()
        await driver.tick()

        let deliveries = box.deliveries
        XCTAssertEqual(deliveries.map { $0?.isFresh }, [true, true, false])
        XCTAssertEqual(deliveries[2]?.reading, deliveries[1]?.reading, "stale = 上次好值原样")
    }

    func testMarkedDriverDeliversNilWhenThereWasNeverAGoodReading() async {
        let provider = DiskThroughputProvider(source: NilThroughputSource(cadenceSeconds: 5))
        let box = MarkedDeliveryBox()
        await provider.markedDriver { box.append($0) }.tick()

        XCTAssertEqual(box.deliveries.count, 1)
        XCTAssertNil(box.deliveries[0])
    }

    // MARK: - Live 源冒烟(只验构造与可调用,不做语义断言)

    func testLiveSourcesConstructAndRespond() {
        // IORegistry 源:构造 + 一次读(nil 或真计数均可——本机探针③应非 nil)。
        let registry = IORegistryDiskThroughputSource()
        if let counters = registry.readCounters() {
            XCTAssertGreaterThan(counters.readBytes + counters.writeBytes, 0, "本机 NVMe 计数器应有累计值(探针③)")
        }
        // 快照解析器对空缓冲的防御已由纯逻辑用例覆盖;此处只验枚举语义:
        XCTAssertEqual(DiskSnapshotListing.listing([]), DiskSnapshotListing.listing([]))
        XCTAssertNotEqual(DiskSnapshotListing.unavailable, DiskSnapshotListing.listing([]))
    }
}

// MARK: - 测试替身

/// 标记交付收件箱(调度上下文写、测试读)。
private final class MarkedDeliveryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SensorDelivery<DiskThroughputReading>?] = []

    func append(_ delivery: SensorDelivery<DiskThroughputReading>?) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(delivery)
    }

    var deliveries: [SensorDelivery<DiskThroughputReading>?] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// 恒 nil 容量源(节奏断言用)。
private struct NilCapacitySource: DiskCapacitySource {
    func read() -> DiskCapacityRawReading? {
        nil
    }
}

/// 恒 nil 吞吐源(节奏断言用,cadenceSeconds 可注入)。
private struct NilThroughputSource: DiskThroughputSource {
    let cadenceSeconds: TimeInterval
    func readCounters() -> DiskIOCounters? {
        nil
    }
}

/// 脚本化容量源:按序吐出注入读数,耗尽后停在 nil(读失败路径)。
private final class ScriptedCapacitySource: DiskCapacitySource, @unchecked Sendable {
    private let lock = NSLock()
    private let readings: [DiskCapacityRawReading?]
    private var index = 0

    init(_ readings: [DiskCapacityRawReading?]) {
        self.readings = readings
    }

    func read() -> DiskCapacityRawReading? {
        lock.lock()
        defer { lock.unlock() }
        guard index < readings.count else { return nil }
        defer { index += 1 }
        return readings[index]
    }
}

/// 脚本化吞吐源:按序吐出注入计数,耗尽后停在 nil。
private final class ScriptedThroughputSource: DiskThroughputSource, @unchecked Sendable {
    let cadenceSeconds: TimeInterval = 5
    private let lock = NSLock()
    private let counters: [DiskIOCounters?]
    private var index = 0

    init(_ counters: [DiskIOCounters?]) {
        self.counters = counters
    }

    func readCounters() -> DiskIOCounters? {
        lock.lock()
        defer { lock.unlock() }
        guard index < counters.count else { return nil }
        defer { index += 1 }
        return counters[index]
    }
}
