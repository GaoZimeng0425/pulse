@testable import PulseCore
import XCTest

/// 接缝:Sampler 采样 actor——驱动 ProcessSource(进程明细)与
/// CoreTickSource(每核 tick,评审 S6 的系统负载口径)、按节奏等待、产出差分。
/// 时钟与睡眠全部注入假实现(推进即瞬时),整条管线确定性跑完,零真实等待;
/// 假 sleep 在预算耗尽时抛错结束循环,测试 await 任务值即拿到自然终止的完整结果。
final class SamplerTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1000)

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
                lock.lock()
                defer { lock.unlock() }
                return current
            }
        }

        /// 同步临界区:锁不落在 async 词法上下文里(NSLock 在 async 中禁用)。
        private func recordAndAdvance(_ seconds: TimeInterval) throws {
            lock.lock()
            defer { lock.unlock() }
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
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    /// 线程安全的交付记录(deliver 从 actor 上下文同步调用)。
    /// internal:SamplerWakeTests(工单 03 唤醒)共用同一份。
    final class DeliveryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var updates: [SamplingUpdate] = []

        func append(_ update: SamplingUpdate) {
            lock.lock()
            defer { lock.unlock() }
            updates.append(update)
        }

        var delivered: [SamplingUpdate] {
            lock.lock()
            defer { lock.unlock() }
            return updates
        }
    }

    // MARK: 夹具

    private func proc(_ pid: pid_t, cpuNanos: UInt64) -> RawProcess {
        RawProcess(pid: pid, parentPID: 1, cpuTimeNanoseconds: cpuNanos)
    }

    /// 三张快照(5s 间隔):首采无前值;第二张 p10 烧 0.5s → 10%;
    /// 第三张 p10 再 0.5s、p20(上张新出生)烧 0.5s → 10% + 10%。
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

    /// 配套的每核 tick 序列(两核,与快照同取):系统负载 0 → 25% → 75%
    /// —— 与进程 CPU 无关的独立口径(评审 S6:系统总数不再从进程推导)。
    private lazy var tickSequence: [CoreTickSample] = [
        CoreTickSample(busyTicks: [0, 0], totalTicks: [100, 100], takenAt: base),
        CoreTickSample(busyTicks: [50, 0], totalTicks: [200, 200], takenAt: base.addingTimeInterval(5)),
        CoreTickSample(busyTicks: [100, 100], totalTicks: [300, 300], takenAt: base.addingTimeInterval(10)),
    ]

    private func makeSampler(
        timeline: FakeTimeline,
        maxSleepSlice: TimeInterval = .infinity
    ) -> Sampler {
        Sampler(
            source: SyntheticProcessSource(snapshots: snapshotSequence),
            coreTicks: SyntheticCoreTickSource(samples: tickSequence),
            memoryStats: SyntheticMemoryStatsSource(),
            networkCounters: ScriptedNetworkCountersSource(samples: [nil]),
            clock: timeline.clock,
            sleep: timeline.sleeper,
            maxSleepSlice: maxSleepSlice
        )
    }

    /// 跑到假时钟预算耗尽(run 自然返回),返回全部交付与时间轴。
    private func drain(
        _ sampler: Sampler,
        timeline: FakeTimeline
    ) async -> (delivered: [SamplingUpdate], timeline: FakeTimeline) {
        let box = DeliveryBox()
        let task = Task { await sampler.run { box.append($0) } }
        await task.value
        return (box.delivered, timeline)
    }

    // MARK: 管线与节奏

    func testPipelineDeliversDiffAndLoadSequenceAtClosedCadence() async {
        // 弹窗关闭:首采立即、之后每 5s 一采。
        // 进程 CPU:首采 nil → 10% → 20%;系统负载(每核 tick):0 → 25% → 75%。
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        let (delivered, clock) = await drain(makeSampler(timeline: timeline), timeline: timeline)
        let loads = delivered.map(\.systemCPULoad)
        let p10 = delivered.map { update in
            update.diff.processCPU.first { $0.pid == 10 }?.cpuPercent ?? -1
        }

        XCTAssertEqual(loads.count, 3)
        XCTAssertEqual(loads[0], 0, accuracy: 0.0001)
        XCTAssertEqual(loads[1], 25, accuracy: 0.0001)
        XCTAssertEqual(loads[2], 75, accuracy: 0.0001)
        XCTAssertEqual(clock.sleepRequests, [5, 5])

        XCTAssertNil(delivered[0].diff.processCPU.first { $0.pid == 10 }?.cpuPercent)
        XCTAssertEqual(p10[1], 10, accuracy: 0.0001)
        XCTAssertEqual(p10[2], 10, accuracy: 0.0001)
    }

    /// 每轮交付携带采出该差分的快照本身(工单 05:出生登记与归组的输入)。
    func testDeliveredUpdateCarriesTheSampledSnapshot() async {
        let timeline = FakeTimeline(start: base, sleepBudget: 2)

        let (delivered, _) = await drain(makeSampler(timeline: timeline), timeline: timeline)

        XCTAssertEqual(delivered.count, 3)
        for update in delivered {
            XCTAssertEqual(update.diff.takenAt, update.snapshot.takenAt)
            XCTAssertEqual(update.diff.processCPU.count, update.snapshot.processes.count)
        }
        // 第二轮快照含 p10/p20 两个进程,差分条目一一致。
        XCTAssertEqual(delivered[1].snapshot.processes.map(\.pid), [10, 20])
        XCTAssertEqual(delivered[1].diff.processCPU.map(\.pid), [10, 20])
    }

    func testOpenPopoverCadenceWaitsOneSecond() async {
        // 弹窗打开:等待间隔切换为 1s。预算 3 次睡眠 → 4 次交付;
        // 源耗尽后停在末张(tick 不再前进)→ 负载退化路径为 0。
        let timeline = FakeTimeline(start: base, sleepBudget: 3)
        let sampler = makeSampler(timeline: timeline)
        await sampler.setPopoverVisible(true)

        let (delivered, clock) = await drain(sampler, timeline: timeline)
        let loads = delivered.map(\.systemCPULoad)

        XCTAssertEqual(loads.count, 4)
        XCTAssertEqual(loads[0], 0, accuracy: 0.0001)
        XCTAssertEqual(loads[1], 25, accuracy: 0.0001)
        XCTAssertEqual(loads[2], 75, accuracy: 0.0001)
        XCTAssertEqual(loads[3], 0, accuracy: 0.0001)
        XCTAssertEqual(clock.sleepRequests, [1, 1, 1])
    }

    func testLongWaitIsSlicedByMaxSleepSliceForResponsiveness() async {
        // 5s 等待按 2s 切片 → [2, 2, 1]:节奏变化最多延迟一个切片就能被察觉。
        let timeline = FakeTimeline(start: base, sleepBudget: 3)

        let (delivered, clock) = await drain(
            makeSampler(timeline: timeline, maxSleepSlice: 2),
            timeline: timeline
        )
        let loads = delivered.map(\.systemCPULoad)

        XCTAssertEqual(loads.count, 2)
        XCTAssertEqual(loads[0], 0, accuracy: 0.0001)
        XCTAssertEqual(loads[1], 25, accuracy: 0.0001)
        XCTAssertEqual(clock.sleepRequests, [2, 2, 1])
    }

    // MARK: 采样统计(工单 11:诊断报告取数)

    func testSamplingStatsAccumulateAcrossRounds() async {
        // 三轮交付后统计:轮数 = 交付数;峰值取最大快照进程数(2);
        // 运行起点 = 首轮采样时刻。假时钟同一轮内不走秒,轮耗时累计 0
        // (均值口径在 SamplingStats 纯值测试里另测)。
        let timeline = FakeTimeline(start: base, sleepBudget: 2)
        let sampler = makeSampler(timeline: timeline)
        _ = await drain(sampler, timeline: timeline)

        let stats = await sampler.samplingStats()

        XCTAssertEqual(stats.sampleCount, 3)
        XCTAssertEqual(stats.peakProcessCount, 2)
        XCTAssertEqual(stats.startedAt, base)
        XCTAssertEqual(stats.averageRoundDuration ?? -1, 0, accuracy: 0.0001)
    }

    // MARK: 分阶段耗时(resident-cost/01)

    func testRoundRecordsSamplerSideStagesPerRound() async {
        // 三轮交付后:采样侧三阶段各记 3 次;排行门关着,rankingsLedger 不产生条目
        // (次数独立于轮数是设计语义)。假时钟同一轮内不走秒,时长为 0——
        // 累计与均值口径在 SamplingStageStatsTests 纯值测试里钉。
        let timeline = FakeTimeline(start: base, sleepBudget: 2)
        let sampler = makeSampler(timeline: timeline)
        _ = await drain(sampler, timeline: timeline)

        let stats = await sampler.samplingStats()

        XCTAssertEqual(stats.stageTimings[.processSnapshot]?.sampleCount, 3)
        XCTAssertEqual(stats.stageTimings[.systemCounters]?.sampleCount, 3)
        XCTAssertEqual(stats.stageTimings[.diff]?.sampleCount, 3)
        XCTAssertNil(stats.stageTimings[.rankingsLedger], "排行门关着不产生条目")
        XCTAssertNil(stats.stageTimings[.spineAdvance], "主线程阶段在 SystemMonitor 侧的账本里")
    }
}
