@testable import Pulse
@testable import PulseCore
import XCTest

/// 真机冒烟(评审 S6):LiveCoreTickSource 真实可用;每核 tick 口径 ≥
/// 旧进程累加口径(后者看不见 kernel_task / root 时间),静息态两者接近。
final class LiveCoreTickSourceSmokeTests: XCTestCase {
    func testLiveTickLoadIsSaneAndNotBelowProcessSummation() {
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
            return XCTFail(
                "每核 tick 样本应至少有一核,实际 busy \(secondTicks.busyTicks.count) / total \(secondTicks.totalTicks.count)"
            )
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
