import XCTest
@testable import Pulse

/// 接缝:SensorScheduler 单一调度器 actor(ADR-0004)——按各 provider 的
/// cadence 驱动"读一次并交付"。睡眠与唤醒流全部注入,零真实等待;
/// 心跳型不归它管(住 Sampler),登记进来安静忽略。
final class SensorSchedulerTests: XCTestCase {

    // MARK: - 测试替身

    /// 读数次数(线程安全计数)。
    private final class TickBox: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func tick() {
            lock.lock()
            defer { lock.unlock() }
            count += 1
        }

        var ticks: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    // MARK: - 低频定时档

    func testEveryCadenceTicksImmediatelyThenPerInterval() async {
        // 启动即读一轮(首帧就有数),此后按间隔睡 → 读;假睡眠预算耗尽自然收尾。
        let sleeper = FakeSleeper(budget: 2)
        let scheduler = SensorScheduler(sleep: sleeper.sleeping)
        let box = TickBox()
        let driver = SensorDriver(cadence: .every(seconds: 30), tick: { box.tick() }, wakeups: nil)

        await scheduler.run([driver])

        XCTAssertEqual(box.ticks, 3, "启动 1 轮 + 间隔 2 轮")
        XCTAssertEqual(sleeper.recorded, [30, 30], "睡眠时长 = 登记间隔")
    }

    // MARK: - 心跳档(防御)

    func testHeartbeatIsIgnoredByScheduler() async {
        // 心跳型指标住 Sampler 单一循环节拍(ADR-0004):登记进调度器属
        // 编程错误,安静忽略——不产生读数、不等待。
        let scheduler = SensorScheduler(sleep: { _ in throw CancellationError() })
        let box = TickBox()
        let driver = SensorDriver(cadence: .heartbeat, tick: { box.tick() }, wakeups: nil)

        await scheduler.run([driver])

        XCTAssertEqual(box.ticks, 0)
    }

    // MARK: - 事件档

    func testOnEventTicksPerWakeupUntilStreamEnds() async {
        // 每次唤醒读一次;流结束(而非靠取消)循环退出。
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        let scheduler = SensorScheduler(sleep: { _ in })
        let box = TickBox()
        let driver = SensorDriver(cadence: .onEvent, tick: { box.tick() }, wakeups: { stream })

        let task = Task { await scheduler.run([driver]) }
        continuation.yield()
        continuation.yield()
        continuation.finish()
        await task.value

        XCTAssertEqual(box.ticks, 2)
    }

    func testOnEventWithoutWakeupsDoesNotTick() async {
        // 事件档缺唤醒流:无法驱动,安静退出且不读(编程错误防御)。
        let scheduler = SensorScheduler(sleep: { _ in })
        let box = TickBox()
        let driver = SensorDriver(cadence: .onEvent, tick: { box.tick() }, wakeups: nil)

        await scheduler.run([driver])

        XCTAssertEqual(box.ticks, 0)
    }
}

/// 假睡眠:预算内记录请求,耗尽抛错让循环自然终止(零真实等待)。
/// 同步临界区锁不落在 async 词法上下文里(与 SamplerTests.FakeTimeline 同款)。
private final class FakeSleeper: @unchecked Sendable {
    struct Exhausted: Error {}

    private let lock = NSLock()
    private var requests: [TimeInterval] = []
    private var budget: Int

    init(budget: Int) {
        self.budget = budget
    }

    var recorded: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var sleeping: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in
            await Task.yield() // 真实挂起点:让调度器有机会处理其他消息
            try record(seconds)
        }
    }

    private func record(_ seconds: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        guard requests.count < budget else { throw Exhausted() }
        requests.append(seconds)
    }
}
