import XCTest
@testable import Pulse
@testable import PulseCore

/// 接缝:每核 tick 差分器(评审 S6,纯逻辑)。系统 CPU 负载 =
/// 相邻两样本的忙 tick 差 ÷ 总 tick 差(总含 idle),与活动监视器 / Stats
/// 同源——kernel_task 与 root 属主进程的 CPU 时间也计入,修复进程累加口径
/// 的结构性少计。期望值全部是手工推演的字面量。
final class CoreTickDifferTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    private func sample(
        busy: [UInt64],
        total: [UInt64],
        at seconds: TimeInterval
    ) -> CoreTickSample {
        CoreTickSample(
            busyTicks: busy,
            totalTicks: total,
            takenAt: base.addingTimeInterval(seconds)
        )
    }

    func testFirstSampleHasNoLoadYet() {
        // 首采无前值:负载 0,不伪造。
        let load = CoreTickDiffer.systemCPULoad(
            previous: nil,
            current: sample(busy: [120], total: [400], at: 0)
        )

        XCTAssertEqual(load, 0, accuracy: 0.0001)
    }

    func testBusyOverTotalTicksGivesLoad() {
        // 忙 30 / 总 120 → 25%:tick 自带时间基准,不看墙钟。
        let load = CoreTickDiffer.systemCPULoad(
            previous: sample(busy: [10], total: [100], at: 0),
            current: sample(busy: [40], total: [220], at: 2)
        )

        XCTAssertEqual(load, 25, accuracy: 0.0001)
    }

    func testLoadAggregatesAcrossCores() {
        // 多核聚合:核 0 忙 10/总 100、核 1 忙 30/总 100 → 40/200 = 20%。
        let load = CoreTickDiffer.systemCPULoad(
            previous: sample(busy: [0, 0], total: [100, 100], at: 0),
            current: sample(busy: [10, 30], total: [200, 200], at: 1)
        )

        XCTAssertEqual(load, 20, accuracy: 0.0001)
    }

    func testFullBusyLoadIs100AndClampsThere() {
        // 全部新 tick 都忙 → 100%;即使忙差因计数异常超总差也封顶 100。
        let full = CoreTickDiffer.systemCPULoad(
            previous: sample(busy: [0, 0], total: [50, 50], at: 0),
            current: sample(busy: [100, 100], total: [150, 150], at: 1)
        )
        XCTAssertEqual(full, 100, accuracy: 0.0001)
    }

    func testZeroTickDeltaDegradesToZero() {
        // 两次读数完全相同(如同一时刻)→ 总差 0,负载按 0 计,不除零。
        let load = CoreTickDiffer.systemCPULoad(
            previous: sample(busy: [7, 9], total: [90, 95], at: 0),
            current: sample(busy: [7, 9], total: [90, 95], at: 0)
        )

        XCTAssertEqual(load, 0, accuracy: 0.0001)
    }

    func testCounterRegressionClampsToZeroInsteadOfCrashing() {
        // 单核计数回退按 0 差值处理(UInt 下溢会崩溃):
        // 核 0 忙回退 → 0;核 1 正常忙 50/总 100 → 总负载 50/200 = 25%。
        let load = CoreTickDiffer.systemCPULoad(
            previous: sample(busy: [80, 0], total: [100, 100], at: 0),
            current: sample(busy: [20, 50], total: [200, 200], at: 1)
        )

        XCTAssertEqual(load, 25, accuracy: 0.0001)
    }

    func testCoreCountMismatchUsesShorterPrefix() {
        // 核数变化(极罕见)按两侧较短的核前缀对齐:只算核 0(忙 40/总 100)。
        let load = CoreTickDiffer.systemCPULoad(
            previous: sample(busy: [10], total: [100], at: 0),
            current: sample(busy: [50, 999], total: [200, 1000], at: 1)
        )

        XCTAssertEqual(load, 40, accuracy: 0.0001)
    }
}

/// 真机冒烟(评审 S6):LiveCoreTickSource 真实可用;每核 tick 口径 ≥
/// 旧进程累加口径(后者看不见 kernel_task / root 时间),静息态两者接近。
final class CoreTickLiveSmokeTests: XCTestCase {
    func testLiveTickLoadIsSaneAndNotBelowProcessSummation() throws {
        let tickSource = LiveCoreTickSource()
        let processSource = LiveProcessSource()

        // 同一窗口内各取两读:每核 tick 口径与旧进程累加口径同期可比。
        let firstTicks = tickSource.sample()
        let firstSnapshot = processSource.snapshot()
        Thread.sleep(forTimeInterval: 1.1)
        let secondTicks = tickSource.sample()
        let secondSnapshot = processSource.snapshot()

        let tickLoad = CoreTickDiffer.systemCPULoad(previous: firstTicks, current: secondTicks)
        // 旧口径(仅用于对照):全部进程 CPU% 之和 ÷ 逻辑核数,封顶 100。
        var totalPercent = 0.0
        var previousCPU: [pid_t: UInt64] = [:]
        for process in firstSnapshot.processes {
            previousCPU[process.pid] = process.cpuTimeNanoseconds
        }
        let wall = secondSnapshot.takenAt.timeIntervalSince(firstSnapshot.takenAt)
        if wall > 0 {
            for process in secondSnapshot.processes {
                guard let before = previousCPU[process.pid] else { continue }
                let delta = process.cpuTimeNanoseconds >= before
                    ? process.cpuTimeNanoseconds - before
                    : 0
                totalPercent += Double(delta) / (wall * 1_000_000_000) * 100
            }
        }
        let cores = max(1, secondTicks.busyTicks.count)
        let summationLoad = min(100, totalPercent / Double(cores))
        print(
            "[smoke] 系统 CPU 负载:每核 tick 口径 \(String(format: "%.1f", tickLoad))%"
                + " vs 旧进程累加口径 \(String(format: "%.1f", summationLoad))%"
                + "(核数 \(cores),进程 \(secondSnapshot.processes.count))"
        )

        guard secondTicks.busyTicks.count >= 1, secondTicks.totalTicks.count >= 1 else {
            return XCTFail("每核 tick 样本应至少有一核,实际 busy \(secondTicks.busyTicks.count) / total \(secondTicks.totalTicks.count)")
        }
        XCTAssertGreaterThanOrEqual(
            secondTicks.totalTicks[0], secondTicks.busyTicks[0],
            "总 tick 应不小于忙 tick"
        )
        XCTAssertGreaterThanOrEqual(tickLoad, -0.0001)
        XCTAssertLessThanOrEqual(tickLoad, 100)
        // tick 口径可见内核与 root 时间:不应低于旧口径(留 2% 噪声容差);
        // 静息态两者接近——差距巨大说明口径接错了线。
        XCTAssertGreaterThanOrEqual(
            tickLoad, summationLoad - 2,
            "每核 tick 口径不应低于进程累加口径(少计 kernel_task/root 即为该口径的修复目标)"
        )
        XCTAssertLessThan(
            tickLoad - summationLoad, 60,
            "静息态两种口径应接近(差 \(tickLoad - summationLoad))"
        )
    }
}
