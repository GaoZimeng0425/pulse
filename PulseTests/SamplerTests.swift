import XCTest
@testable import Pulse

/// 接缝:Sampler 采样 actor——驱动 ProcessSource、按节奏等待、产出差分。
/// 时钟与睡眠全部注入假实现(推进即瞬时),整条管线确定性跑完,零真实等待;
/// 假 sleep 在预算耗尽时抛错结束循环,测试 await 任务值即拿到自然终止的完整结果。
final class SamplerTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: 测试替身

    /// 假时间轴:now 由 sleep 推进;记录每次请求的睡眠时长;预算耗尽抛错停机。
    private final class FakeTimeline: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        private var requests: [TimeInterval] = []
        private let budget: Int
        struct Exhausted: Error {}

        init(start: Date, sleepBudget: Int) {
            current = start
            budget = sleepBudget
        }

        var clock: @Sendable () -> Date {
            { [self] in
                lock.lock(); defer { lock.unlock() }
                return current
            }
        }

        /// 同步临界区:锁不落在 async 词法上下文里(NSLock 在 async 中禁用)。
        private func recordAndAdvance(_ seconds: TimeInterval) throws {
            lock.lock(); defer { lock.unlock() }
            guard requests.count < budget else { throw Exhausted() }
            requests.append(seconds)
            current = current.addingTimeInterval(seconds)
        }

        var sleeper: @Sendable (TimeInterval) async throws -> Void {
            { [self] seconds in
                // 真实挂起点:让 actor 有机会处理 setPopoverVisible 等消息。
                await Task.yield()
                try recordAndAdvance(seconds)
            }
        }

        var sleepRequests: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return requests
        }
    }

    /// 线程安全的交付记录(deliver 从 actor 上下文同步调用)。
    private final class LoadBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []

        func append(_ value: Double) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }

        var delivered: [Double] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    // MARK: 夹具

    private func proc(_ pid: pid_t, cpuNanos: UInt64) -> RawProcess {
        RawProcess(pid: pid, parentPID: 1, cpuTimeNanoseconds: cpuNanos)
    }

    /// 三张快照(5s 间隔,4 逻辑核):
    /// 首采无前值 → 0;第二张:p10 烧 0.5s → 10%,负载 10/4 = 2.5;
    /// 第三张:p10 再 0.5s、p20(上张新出生)烧 0.5s → 合计 20%,负载 5。
    private lazy var snapshotSequence: [ProcessSnapshot] = [
        ProcessSnapshot(takenAt: base, processes: [proc(10, cpuNanos: 0)]),
        ProcessSnapshot(
            takenAt: base.addingTimeInterval(5),
            processes: [proc(10, cpuNanos: 500_000_000), proc(20, cpuNanos: 0)]
        ),
        ProcessSnapshot(
            takenAt: base.addingTimeInterval(10),
            processes: [proc(10, cpuNanos: 1_000_000_000), proc(20, cpuNanos: 500_000_000)]
        ),
    ]

    private func makeSampler(
        timeline: FakeTimeline,
        maxSleepSlice: TimeInterval = .infinity
    ) -> Sampler {
        Sampler(
            source: SyntheticProcessSource(snapshots: snapshotSequence),
            logicalCoreCount: 4,
            clock: timeline.clock,
            sleep: timeline.sleeper,
            maxSleepSlice: maxSleepSlice
        )
    }

    /// 跑到假时钟预算耗尽(run 自然返回),返回全部交付与时间轴。
    private func drain(
        _ sampler: Sampler,
        timeline: FakeTimeline
    ) async -> (delivered: [Double], timeline: FakeTimeline) {
        let box = LoadBox()
        let task = Task { await sampler.run { box.append($0.systemCPULoad) } }
        await task.value
        return (box.delivered, timeline)
    }

    // MARK: 管线与节奏

    func testPipelineDeliversDiffSequenceAtClosedCadence() async {
        // 弹窗关闭:首采立即、之后每 5s 一采;交付 0 → 2.5% → 5%。
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        let (delivered, clock) = await drain(makeSampler(timeline: timeline), timeline: timeline)

        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered[0], 0, accuracy: 0.0001)
        XCTAssertEqual(delivered[1], 2.5, accuracy: 0.0001)
        XCTAssertEqual(delivered[2], 5, accuracy: 0.0001)
        XCTAssertEqual(clock.sleepRequests, [5, 5])
    }

    func testOpenPopoverCadenceWaitsOneSecond() async {
        // 弹窗打开:等待间隔切换为 1s。预算 3 次睡眠 → 4 次交付;
        // 源耗尽后停在末张,墙钟为 0 → 负载退化路径为 0。
        let timeline = FakeTimeline(start: base, sleepBudget: 3)
        let sampler = makeSampler(timeline: timeline)
        await sampler.setPopoverVisible(true)

        let (delivered, clock) = await drain(sampler, timeline: timeline)

        XCTAssertEqual(delivered.count, 4)
        XCTAssertEqual(delivered[0], 0, accuracy: 0.0001)
        XCTAssertEqual(delivered[1], 2.5, accuracy: 0.0001)
        XCTAssertEqual(delivered[2], 5, accuracy: 0.0001)
        XCTAssertEqual(delivered[3], 0, accuracy: 0.0001)
        XCTAssertEqual(clock.sleepRequests, [1, 1, 1])
    }

    func testLongWaitIsSlicedByMaxSleepSliceForResponsiveness() async {
        // 5s 等待按 2s 切片 → [2, 2, 1]:节奏变化最多延迟一个切片就能被察觉。
        let timeline = FakeTimeline(start: base, sleepBudget: 3)

        let (delivered, clock) = await drain(
            makeSampler(timeline: timeline, maxSleepSlice: 2),
            timeline: timeline
        )

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered[0], 0, accuracy: 0.0001)
        XCTAssertEqual(delivered[1], 2.5, accuracy: 0.0001)
        XCTAssertEqual(clock.sleepRequests, [2, 2, 1])
    }
}
