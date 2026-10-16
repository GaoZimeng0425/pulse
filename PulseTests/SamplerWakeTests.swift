import XCTest
@testable import Pulse

/// 唤醒处理(工单 03,spec 唤醒处理):睡眠唤醒后第一轮差分作废。
/// 门闩时间轴让测试在采样轮之间插入 `invalidateDeltas()`——交付序列
/// 确定性,零真实等待。
final class SamplerWakeTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    /// 门闩时间轴:sleep 挂起到测试放行为止(放行同时推进时钟)——用于在
    /// 采样轮之间插入 actor 消息(唤醒清基线)。流关闭视为停机信号。
    private final class GatedTimeline: @unchecked Sendable {
        struct GateClosed: Error {}

        private let lock = NSLock()
        private var current: Date
        private var closed = false
        private var pending: CheckedContinuation<Void, Error>?

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
}
