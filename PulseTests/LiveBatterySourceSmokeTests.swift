import XCTest
@testable import Pulse

/// 接缝:LiveBatterySource 冒烟(spec 测试决策:OS 边界只证明真实可用,
/// 不深测——纯逻辑已在 BatterySensorTests 钉死)。只读观察,真机走查用;
/// 无内建电池的环境(台式机)整页跳过,不断言。
final class LiveBatterySourceSmokeTests: XCTestCase {
    private let source = LiveBatterySource()

    func testLiveReadDeliversSixReadingsOnBatteryMachines() async throws {
        guard let raw = source.read() else {
            throw XCTSkip("本机无内建电池(台式机):电池页整页隐藏口径,跳过真读冒烟")
        }
        let reading = BatteryReading.make(from: raw)
        print(
            "[smoke] battery: \(reading.capacityPercent)% \(reading.status.title)"
            + " 剩余=\(reading.timeToEmptyMinutes.map(String.init) ?? "—")min"
            + " 充满=\(reading.timeToFullMinutes.map(String.init) ?? "—")min"
            + " 健康=\(reading.healthPercent.map(String.init) ?? "—")%"
            + " 循环=\(reading.cycleCount.map(String.init) ?? "—")"
            + " 功率=\(reading.powerWatts.map { PulseFormat.watts($0) } ?? "—")"
        )
        XCTAssertTrue((0...100).contains(reading.capacityPercent), "电量应为 0–100")
        // 健康度可占位,但凡读到了就应在合法域内(除零防护不产生伪数)。
        if let health = reading.healthPercent {
            XCTAssertTrue((0...100).contains(health), "健康度应为 0–100,实际 \(health)")
        }
    }

    func testWakeupStreamEmitsFirstWakeImmediately() async {
        // 事件驱动挂接冒烟(工单 02):首唤醒立即发出(启动即读一轮),
        // 随后只有电源状态变化才再发。取首个唤醒即退出,流被丢弃时自动摘源。
        let stream = IOPSWakeupStream.make()
        let first = await stream.first { _ in true }
        XCTAssertNotNil(first, "首唤醒应立即发出,而非等真实电源事件")
    }
}
