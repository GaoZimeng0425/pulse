import XCTest
@testable import PulseCore

/// 唤醒处理(工单 03,spec 唤醒处理):睡眠唤醒后第一轮差分作废。
/// 门闩时间轴让测试在采样轮之间插入 `invalidateDeltas()`——交付序列
/// 确定性,零真实等待。
final class SamplerWakeTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    /// 门闩时间轴:sleep 挂起到测试放行为止(放行同时推进时钟)——用于在
    /// 采样轮之间插入 actor 消息(唤醒清基线)。流关闭视为停机信号。
    /// internal:SamplerRankingTests(排行门控)共用同一份。
    final class GatedTimeline: @unchecked Sendable {
        struct GateClosed: Error {}

        private let lock = NSLock()
        private var current: Date
        private var closed = false
        private var pending: CheckedContinuation<Void, Error>?
        /// 放行许可:pass 时尚无挂起的 sleep(循环刚交付、还没走到 sleep)
        /// 就攒一个,下一次 sleep 直接放行——否则这次唤醒会丢,测试空等到超时。
        /// 多余许可只造成一次空醒(时钟未推进 → wait > 0 → 再睡),不会多采一轮。
        private var permits = 0

        init(start: Date) {
            current = start
        }

        var clock: @Sendable () -> Date {
            { [self] in
                lock.lock()
                defer { lock.unlock() }
                return current
            }
        }

        var sleeper: @Sendable (TimeInterval) async throws -> Void {
            { [self] _ in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    defer { lock.unlock() }
                    if closed {
                        continuation.resume(throwing: GateClosed())
                    } else if permits > 0 {
                        permits -= 1
                        continuation.resume()
                    } else {
                        pending = continuation
                    }
                }
            }
        }

        /// 放行一轮:推进 seconds 并唤醒挂起中的 sleep。
        func pass(seconds: TimeInterval) {
            lock.lock()
            current = current.addingTimeInterval(seconds)
            let resumed = pending
            pending = nil
            if resumed == nil {
                permits += 1
            }
            lock.unlock()
            resumed?.resume()
        }

        func close() {
            lock.lock()
            closed = true
            let resumed = pending
            pending = nil
            lock.unlock()
            resumed?.resume(throwing: GateClosed())
        }
    }

    /// 轮询等待交付数达标(真实挂起点让 actor 推进);超时返回 false。
    /// 交付箱复用 SamplerTests.DeliveryBox(target 内 internal)。
    private func waitFor(_ box: SamplerTests.DeliveryBox, count target: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while box.delivered.count < target && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return box.delivered.count >= target
    }

    /// 唤醒后第一轮差分作废:invalidateDeltas 清基线,下一轮无前值——
    /// 系统负载 0、全部进程 CPU% nil(CPUDiffer/CoreTickDiffer 的首采口径),
    /// 不产生横跨睡眠的巨大尖刺。
    func testInvalidateDeltasDropsTheFirstDiffAfterWake() async {
        // 三张快照/三份 tick(与 SamplerTests 同形夹具):两核,
        // 系统负载 0 → 25% → 75%,p10 稳定烧 10%。
        let snapshots = [
            ProcessSnapshot(takenAt: base, processes: [RawProcess(pid: 10, parentPID: 1, cpuTimeNanoseconds: 0)]),
            ProcessSnapshot(
                takenAt: base.addingTimeInterval(5),
                processes: [RawProcess(pid: 10, parentPID: 1, cpuTimeNanoseconds: 500_000_000)]
            ),
            ProcessSnapshot(
                takenAt: base.addingTimeInterval(10),
                processes: [RawProcess(pid: 10, parentPID: 1, cpuTimeNanoseconds: 1_000_000_000)]
            ),
        ]
        let ticks = [
            CoreTickSample(busyTicks: [0, 0], totalTicks: [100, 100], takenAt: base),
            CoreTickSample(busyTicks: [50, 0], totalTicks: [200, 200], takenAt: base.addingTimeInterval(5)),
            CoreTickSample(busyTicks: [100, 100], totalTicks: [300, 300], takenAt: base.addingTimeInterval(10)),
        ]
        let timeline = GatedTimeline(start: base)
        let sampler = Sampler(
            source: SyntheticProcessSource(snapshots: snapshots),
            coreTicks: SyntheticCoreTickSource(samples: ticks),
            memoryStats: SyntheticMemoryStatsSource(),
            networkCounters: ScriptedNetworkCountersSource(samples: [nil]),
            clock: timeline.clock,
            sleep: timeline.sleeper,
            maxSleepSlice: .infinity
        )
        let box = SamplerTests.DeliveryBox()
        let task = Task { await sampler.run { box.append($0) } }
        defer {
            timeline.close()
            task.cancel()
        }

        // 第 1 轮:首采,无前值。
        let firstReady = await waitFor(box, count: 1)
        XCTAssertTrue(firstReady)
        // 第 2 轮:正常差分——系统负载 25%,p10 = 10%。
        timeline.pass(seconds: 5)
        let secondReady = await waitFor(box, count: 2)
        XCTAssertTrue(secondReady)
        XCTAssertEqual(box.delivered[1].systemCPULoad, 25, accuracy: 0.0001)
        // 模拟唤醒:清基线后第 3 轮无前值 → 0 / nil,无尖刺。
        await sampler.invalidateDeltas()
        timeline.pass(seconds: 5)
        let thirdReady = await waitFor(box, count: 3)
        XCTAssertTrue(thirdReady)
        XCTAssertEqual(box.delivered[2].systemCPULoad, 0, accuracy: 0.0001)
        for entry in box.delivered[2].diff.processCPU {
            XCTAssertNil(entry.cpuPercent)
        }
    }

    /// 网络心跳轮(工单 06)与唤醒作废同轨:首轮(无基线)丢弃为 0 → 正常
    /// 差分出速率 → invalidateDeltas 后首轮再次丢弃——睡眠期累计量不出尖刺。
    func testNetworkHeartbeatDropsFirstRoundAfterWake() async {
        let timeline = GatedTimeline(start: base)
        let sampler = Sampler(
            source: SyntheticProcessSource(snapshots: [
                ProcessSnapshot(takenAt: base, processes: []),
            ]),
            coreTicks: SyntheticCoreTickSource(samples: [
                CoreTickSample(busyTicks: [0], totalTicks: [100], takenAt: base),
            ]),
            memoryStats: SyntheticMemoryStatsSource(),
            networkCounters: ScriptedNetworkCountersSource(samples: [
                counters(up: 1_000, down: 2_000, at: 0),                    // 首读:立基线
                counters(up: 6_000, down: 7_000, at: 5_000_000_000),        // 5s 差分
                counters(up: 9_000, down: 12_000, at: 10_000_000_000),      // 唤醒后首轮
            ]),
            clock: timeline.clock,
            sleep: timeline.sleeper,
            maxSleepSlice: .infinity
        )
        let box = SamplerTests.DeliveryBox()
        let task = Task { await sampler.run { box.append($0) } }
        defer {
            timeline.close()
            task.cancel()
        }

        // 第 1 轮:网络首读 → 丢弃(速率 0,不出开机累计)。
        let firstReady = await waitFor(box, count: 1)
        XCTAssertTrue(firstReady)
        XCTAssertEqual(box.delivered[0].network?.rates, .zero)

        // 第 2 轮:正常差分(1 Gbps 链路内)→ 1000 B/s 双向。
        timeline.pass(seconds: 5)
        let secondReady = await waitFor(box, count: 2)
        XCTAssertTrue(secondReady)
        XCTAssertEqual(box.delivered[1].network?.rates.upBytesPerSecond ?? -1, 1_000, accuracy: 0.0001)
        XCTAssertEqual(box.delivered[1].network?.rates.downBytesPerSecond ?? -1, 1_000, accuracy: 0.0001)

        // 模拟唤醒:基线作废 → 第 3 轮丢弃,睡眠期累计不出速率。
        await sampler.invalidateDeltas()
        timeline.pass(seconds: 5)
        let thirdReady = await waitFor(box, count: 3)
        XCTAssertTrue(thirdReady)
        XCTAssertEqual(box.delivered[2].network?.rates, .zero)
    }

    /// 读缺失(nil 计数)轮交付 nil 网络结果,且旧基线保留——下一轮恢复读数
    /// 时差分跨过缺失轮照常成立,不把缺口算成尖峰。
    func testMissingNetworkReadingKeepsBaselineAndDeliversNil() async {
        let timeline = GatedTimeline(start: base)
        let sampler = Sampler(
            source: SyntheticProcessSource(snapshots: [
                ProcessSnapshot(takenAt: base, processes: []),
            ]),
            coreTicks: SyntheticCoreTickSource(samples: [
                CoreTickSample(busyTicks: [0], totalTicks: [100], takenAt: base),
            ]),
            memoryStats: SyntheticMemoryStatsSource(),
            networkCounters: ScriptedNetworkCountersSource(samples: [
                unknownLink(up: 1_000, down: 1_000, at: 0),                 // 首读
                nil,                                                        // 读缺失
                unknownLink(up: 6_000, down: 6_000, at: 10_000_000_000),    // 恢复
            ]),
            clock: timeline.clock,
            sleep: timeline.sleeper,
            maxSleepSlice: .infinity
        )
        let box = SamplerTests.DeliveryBox()
        let task = Task { await sampler.run { box.append($0) } }
        defer {
            timeline.close()
            task.cancel()
        }

        let firstReady = await waitFor(box, count: 1)
        XCTAssertTrue(firstReady)
        XCTAssertNotNil(box.delivered[0].network)

        timeline.pass(seconds: 5)
        let secondReady = await waitFor(box, count: 2)
        XCTAssertTrue(secondReady)
        XCTAssertNil(box.delivered[1].network, "读缺失轮交付 nil,UI 占位")

        timeline.pass(seconds: 5)
        let thirdReady = await waitFor(box, count: 3)
        XCTAssertTrue(thirdReady)
        // 缺失轮没动基线:第 3 轮对首读基线差分(10s 窗)→ 500 B/s,非尖峰。
        XCTAssertEqual(box.delivered[2].network?.rates.upBytesPerSecond ?? -1, 500, accuracy: 0.0001)
    }
}

/// 网络心跳夹具(两用例共享,链路已知 1 Gbps)。
private func counters(up: UInt64, down: UInt64, at: UInt64) -> NetworkCounters {
    NetworkCounters(
        interface: "en0",
        upBytes: up,
        downBytes: down,
        upPackets: 1_000,
        downPackets: 1_000,
        linkBaudrateBitsPerSecond: 1_000_000_000,
        atUptimeNanos: at
    )
}

/// 同上,线速未知口径(隧道/死表链路的兜底上限路径)。
private func unknownLink(up: UInt64, down: UInt64, at: UInt64) -> NetworkCounters {
    NetworkCounters(
        interface: "en0",
        upBytes: up,
        downBytes: down,
        upPackets: 1_000,
        downPackets: 1_000,
        linkBaudrateBitsPerSecond: nil,
        atUptimeNanos: at
    )
}
