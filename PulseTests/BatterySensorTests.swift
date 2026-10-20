import XCTest
@testable import Pulse
@testable import PulseCore

/// p1-history/02 电池卡的 app 侧:BatterySensorProvider 的 lastGood、driver 交付与事件
/// 唤醒(spec 测试决策:事件挂接与通知只做冒烟)。纯逻辑在核心包 BatteryModelTests。
final class BatterySensorTests: XCTestCase {
    // MARK: - 夹具

    // MARK: - provider:lastGood(ADR-0004)

    func testProviderStoresLastGoodOnSuccess() async {
        let provider = BatterySensorProvider(
            source: ScriptedBatterySource([BatteryFixture.raw(capacity: 50), BatteryFixture.raw(capacity: 60)]),
            wakeups: { nil }
        )
        let first = await provider.snapshot()
        XCTAssertEqual(first?.capacityPercent, 50)
        XCTAssertEqual(provider.lastGood?.capacityPercent, 50)
        _ = await provider.snapshot()
        XCTAssertEqual(provider.lastGood?.capacityPercent, 60)
    }

    func testReadFailureKeepsLastGoodInsteadOfBlanking() async {
        // 读失败:返回 nil,但 lastGood 保留上次好值——UI 显示它,不白屏(ADR-0004)。
        let provider = BatterySensorProvider(
            source: ScriptedBatterySource([BatteryFixture.raw(capacity: 50), nil]),
            wakeups: { nil }
        )
        _ = await provider.snapshot()
        let failed = await provider.snapshot()
        XCTAssertNil(failed)
        XCTAssertEqual(provider.lastGood?.capacityPercent, 50)
    }

    // MARK: - driver:交付口径

    func testDriverDeliversReadingThenLastGoodOnFailure() async {
        // 交付口径:成功交付读数;失败交付 lastGood(同值重画,不白屏)。
        let provider = BatterySensorProvider(
            source: ScriptedBatterySource([BatteryFixture.raw(capacity: 50), nil, nil]),
            wakeups: { nil }
        )
        let box = ReadingBox()
        let driver = provider.driver { box.append($0) }
        await driver.tick()
        await driver.tick()
        await driver.tick()
        XCTAssertEqual(box.readings.compactMap { $0?.capacityPercent }, [50, 50, 50])
    }

    func testDriverDeliversNilOnlyWhenNeverAnyReading() async {
        // 从未有过读数(无内建电池的机器):交付 nil,消费方据此前提隐藏电池页。
        let provider = BatterySensorProvider(source: ScriptedBatterySource([nil]), wakeups: { nil })
        let box = ReadingBox()
        await provider.driver { box.append($0) }.tick()
        XCTAssertTrue(box.readings.count == 1 && box.readings[0] == nil)
    }

    // MARK: - 事件驱动挂接冒烟(工单 02:synthetic 唤醒流,不打真实通知)

    func testWakeupTriggersReadAndDelivery() async {
        // 电源状态变化 → 唤醒 → 读一次并交付:事件驱动档的冒烟验证。
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let provider = BatterySensorProvider(
            source: ScriptedBatterySource([BatteryFixture.raw(capacity: 40), BatteryFixture.raw(capacity: 90, isCharging: true)]),
            wakeups: { stream }
        )
        let box = ReadingBox()
        let scheduler = SensorScheduler(sleep: { _ in })
        let task = Task { await scheduler.run([provider.driver { box.append($0) }]) }
        continuation.yield() // 模拟:拔电 → 状态变化事件
        continuation.yield() // 模拟:再插回 → 又一次事件
        continuation.finish()
        await task.value
        XCTAssertEqual(box.readings.compactMap { $0?.capacityPercent }, [40, 90])
    }
}

/// 交付记录(线程安全):driver.tick 从调度 actor 上下文调用。
private final class ReadingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BatteryReading?] = []

    func append(_ reading: BatteryReading?) {
        lock.lock()
        defer { lock.unlock() }
        values.append(reading)
    }

    var readings: [BatteryReading?] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// 脚本化电池源:按序吐出注入读数(nil = 无电池),耗尽后停在末值。
final class ScriptedBatterySource: BatterySource, @unchecked Sendable {
    private let lock = NSLock()
    private let readings: [BatteryRawReading?]
    private var index = 0

    init(_ readings: [BatteryRawReading?]) {
        self.readings = readings
    }

    func read() -> BatteryRawReading? {
        lock.lock()
        defer { lock.unlock() }
        guard index < readings.count else { return readings.last ?? nil }
        defer { index += 1 }
        return readings[index]
    }
}
