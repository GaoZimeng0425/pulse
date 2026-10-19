import XCTest
@testable import Pulse

/// 架构审查票 A 高2:模块排行两本账本住心跳循环(Sampler),可见性门控降级为
/// 「推进 / 暂停差分」——门关不推进、关即清账,唤醒清基线同轨;每轮快照发布到
/// 心跳中继(求和回退源的唯一取数口)。门闩时间轴逐轮放行,零真实等待。
final class SamplerRankingTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    /// p10 每 5s 烧 0.5s CPU、唤醒 +10(五张快照,5s 间隔)。
    private lazy var snapshots: [ProcessSnapshot] = (0..<5).map { round in
        ProcessSnapshot(
            takenAt: base.addingTimeInterval(TimeInterval(round) * 5),
            processes: [
                RawProcess(
                    pid: 10,
                    parentPID: 1,
                    cpuTimeNanoseconds: UInt64(round) * 500_000_000,
                    wakeups: UInt64(round) * 10
                ),
            ]
        )
    }

    private struct Harness {
        let sampler: Sampler
        let timeline: SamplerWakeTests.GatedTimeline
        let box: SamplerTests.DeliveryBox
        let task: Task<Void, Never>

        func stop() {
            timeline.close()
            task.cancel()
        }
    }

    /// 先设门、后起循环:首轮采样不等测试消息即开跑,门若在 run 之后才开,
    /// 负载高时首轮会落在门关一侧,基线整体后移一轮(代码审查 L4)。
    private func start(
        relay: HeartbeatRusageRelay? = nil,
        rankingsActive: Bool = false
    ) async -> Harness {
        let timeline = SamplerWakeTests.GatedTimeline(start: base)
        let sampler = Sampler(
            source: SyntheticProcessSource(snapshots: snapshots),
            coreTicks: SyntheticCoreTickSource(samples: [
                CoreTickSample(busyTicks: [0], totalTicks: [100], takenAt: base),
            ]),
            heartbeatRelay: relay,
            clock: timeline.clock,
            sleep: timeline.sleeper,
            maxSleepSlice: .infinity
        )
        if rankingsActive {
            await sampler.setRankingsActive(true)
        }
        let box = SamplerTests.DeliveryBox()
        let task = Task { await sampler.run { box.append($0) } }
        return Harness(sampler: sampler, timeline: timeline, box: box, task: task)
    }

    /// 轮询等待交付数达标(真实挂起点让 actor 推进);超时返回 false。
    private func waitFor(_ box: SamplerTests.DeliveryBox, count target: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while box.delivered.count < target && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return box.delivered.count >= target
    }

    /// 放行一轮并等其交付。
    private func nextRound(_ harness: Harness, expecting count: Int) async {
        harness.timeline.pass(seconds: 5)
        let ready = await waitFor(harness.box, count: count)
        XCTAssertTrue(ready, "第 \(count) 轮未交付")
    }

    func testRankingsInactiveByDefaultDeliverNothing() async {
        // 默认门关(无窗口在看):账本不推进,每轮排行产出为空。
        let harness = await start()
        defer { harness.stop() }
        let firstReady = await waitFor(harness.box, count: 1)
        XCTAssertTrue(firstReady)
        await nextRound(harness, expecting: 2)
        XCTAssertEqual(harness.box.delivered.map(\.rankings), [.empty, .empty])
    }

    func testActiveRankingsDeliverEnergyAfterWindow() async {
        // 门开:首轮记基线,满 5s 窗出能耗差分(ΔCPU 0.5s、Δ唤醒 10)。
        let harness = await start(rankingsActive: true)
        defer { harness.stop() }
        let firstReady = await waitFor(harness.box, count: 1)
        XCTAssertTrue(firstReady)
        await nextRound(harness, expecting: 2)

        let delivered = harness.box.delivered
        XCTAssertEqual(delivered[0].rankings, .empty, "基线轮")
        XCTAssertEqual(delivered[1].rankings.energyImpacts?[10]?.cpuNanosDelta, 500_000_000)
        XCTAssertEqual(delivered[1].rankings.energyImpacts?[10]?.wakeupsDelta, 10)
    }

    func testDeactivationResetsSoReactivationStartsWithBaseline() async {
        // 关门 = 暂停并清账:门关轮不出数;重开首轮只记基线(不出横跨
        // 关门期的巨差),再满窗恢复正常差分。
        let harness = await start(rankingsActive: true)
        defer { harness.stop() }
        let firstReady = await waitFor(harness.box, count: 1)
        XCTAssertTrue(firstReady)
        await nextRound(harness, expecting: 2)                 // 5s:出数
        await harness.sampler.setRankingsActive(false)
        await nextRound(harness, expecting: 3)                 // 10s:门关
        await harness.sampler.setRankingsActive(true)
        await nextRound(harness, expecting: 4)                 // 15s:重开基线
        await nextRound(harness, expecting: 5)                 // 20s:恢复

        let rankings = harness.box.delivered.map(\.rankings)
        XCTAssertNotNil(rankings[1].energyImpacts)
        XCTAssertEqual(rankings[2], .empty, "门关不推进")
        XCTAssertEqual(rankings[3], .empty, "重开首轮只记基线")
        XCTAssertEqual(rankings[4].energyImpacts?[10]?.cpuNanosDelta, 500_000_000, "按 15→20s 窗差分")
    }

    func testInvalidateDeltasResetsRankingLedgers() async {
        // 唤醒清基线与进程/tick/网络同轨:唤醒后首轮排行只记基线。
        let harness = await start(rankingsActive: true)
        defer { harness.stop() }
        let firstReady = await waitFor(harness.box, count: 1)
        XCTAssertTrue(firstReady)
        await nextRound(harness, expecting: 2)
        await harness.sampler.invalidateDeltas()
        await nextRound(harness, expecting: 3)
        await nextRound(harness, expecting: 4)

        let rankings = harness.box.delivered.map(\.rankings)
        XCTAssertEqual(rankings[2], .empty, "唤醒后首轮只记基线")
        XCTAssertEqual(rankings[3].energyImpacts?[10]?.cpuNanosDelta, 500_000_000)
    }

    func testEachRoundPublishesSnapshotToRelay() async {
        // 心跳中继每轮更新(门控无关):求和回退源读到的是最新一轮快照。
        let relay = HeartbeatRusageRelay()
        let harness = await start(relay: relay)
        defer { harness.stop() }
        let firstReady = await waitFor(harness.box, count: 1)
        XCTAssertTrue(firstReady)
        XCTAssertEqual(relay.latest()?.snapshot.takenAt, base)
        await nextRound(harness, expecting: 2)
        XCTAssertEqual(relay.latest()?.snapshot.takenAt, base.addingTimeInterval(5))
    }
}
