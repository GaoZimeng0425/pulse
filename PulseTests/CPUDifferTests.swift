import XCTest
@testable import Pulse

/// 接缝:CPU 差分器(纯逻辑)。spec 实现决策——与活动监视器同算法:
/// 相邻两次快照的累计 CPU 时间差 ÷ 墙钟 = 进程 CPU%(单核 100%);
/// 系统 CPU 负载 = 全部进程之和 ÷ 逻辑核数,0–100%。
/// 期望值全部是手工推演的字面量(工单:"构造两次累计值,断言 CPU% 正确、核数换算正确")。
final class CPUDifferTests: XCTestCase {
    // 时间轴基准:2001-01-01,测试内全部用相对秒,便于推演。
    private func snapshot(at seconds: TimeInterval, processes: [RawProcess]) -> ProcessSnapshot {
        ProcessSnapshot(
            takenAt: Date(timeIntervalSinceReferenceDate: seconds),
            processes: processes
        )
    }

    private func proc(_ pid: pid_t, cpuNanos: UInt64) -> RawProcess {
        RawProcess(pid: pid, parentPID: 1, cpuTimeNanoseconds: cpuNanos)
    }

    private func percent(of pid: pid_t, in result: CPUDiffResult) -> Double?? {
        result.processCPU.first { $0.pid == pid }?.cpuPercent
    }

    // MARK: 进程 CPU%(单核 100% 累加)

    func testFirstSampleHasNoCPUPercentYet() {
        // 首采无前值:CPU% 尚不存在(nil),不是 0——不能伪造除法。
        let result = CPUDiffer.diff(
            previous: nil,
            current: snapshot(at: 0, processes: [proc(10, cpuNanos: 1_000_000)]),
            logicalCoreCount: 4
        )

        XCTAssertEqual(result.processCPU.map(\.pid), [10])
        XCTAssertEqual(percent(of: 10, in: result), .some(.none))
        XCTAssertEqual(result.systemCPULoad, 0)
    }

    func testCumulativeDeltaOverWallClockGivesSingleCorePercent() {
        // 5s 墙钟里烧了 0.5s CPU → 10%(单核口径)。
        let previous = snapshot(at: 0, processes: [proc(10, cpuNanos: 0)])
        let current = snapshot(at: 5, processes: [proc(10, cpuNanos: 500_000_000)])

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 4)

        XCTAssertEqual(percent(of: 10, in: result), .some(10))
        XCTAssertEqual(result.systemCPULoad, 2.5, accuracy: 0.0001)
    }

    func testProcessCanExceed100PercentWhenUsingMultipleCores() {
        // 1s 墙钟里烧了 2s CPU(两个核并行)→ 200%。组/进程 CPU% 合法超 100。
        let previous = snapshot(at: 0, processes: [proc(10, cpuNanos: 0)])
        let current = snapshot(at: 1, processes: [proc(10, cpuNanos: 2_000_000_000)])

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 8)

        XCTAssertEqual(percent(of: 10, in: result), .some(200))
    }

    func testIdleProcessIsZeroPercent() {
        // 累计值没动 → 0%。
        let previous = snapshot(at: 0, processes: [proc(10, cpuNanos: 700)])
        let current = snapshot(at: 5, processes: [proc(10, cpuNanos: 700)])

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 4)

        XCTAssertEqual(percent(of: 10, in: result), .some(0))
    }

    func testCumulativeCounterRegressionClampsToZeroInsteadOfCrashing() {
        // 计数器回退(如任务重建)时不能下溢崩溃:按 0 差值处理。
        let previous = snapshot(at: 0, processes: [proc(10, cpuNanos: 20_000_000_000)])
        let current = snapshot(at: 5, processes: [proc(10, cpuNanos: 10_000_000_000)])

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 4)

        XCTAssertEqual(percent(of: 10, in: result), .some(0))
    }

    // MARK: 两次采样间的进程进出

    func testVanishedProcessIsExcludedByIntersection() {
        // 两次采样间消失的 pid 999:差分只按存活交集计算,结果里没有它,不崩不报。
        let previous = snapshot(at: 0, processes: [proc(10, cpuNanos: 0), proc(999, cpuNanos: 1_000_000_000)])
        let current = snapshot(at: 1, processes: [proc(10, cpuNanos: 1_000_000_000)])

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 4)

        XCTAssertEqual(result.processCPU.map(\.pid), [10])
        XCTAssertEqual(percent(of: 10, in: result), .some(100))
    }

    func testNewProcessHasNoPercentYetAndDoesNotInflateSystemLoad() {
        // 新出生进程(无前值)显式记 nil,不参与系统负载求和,也不伪造 0 除。
        let previous = snapshot(at: 0, processes: [proc(10, cpuNanos: 0)])
        let current = snapshot(
            at: 1,
            processes: [proc(10, cpuNanos: 1_000_000_000), proc(20, cpuNanos: 500_000_000)]
        )

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 4)

        XCTAssertEqual(percent(of: 20, in: result), .some(.none))
        // 负载只算有前值的进程:100% ÷ 4 核 = 25%,新进程不贡献。
        XCTAssertEqual(result.systemCPULoad, 25, accuracy: 0.0001)
    }

    // MARK: 系统 CPU 负载(0–100%)

    func testSystemLoadSumsAllProcessesThenDividesByLogicalCores() {
        // 两个进程各烧满一个核(各 100%),4 逻辑核 → 系统 CPU 负载 50%。
        let previous = snapshot(at: 0, processes: [proc(10, cpuNanos: 0), proc(11, cpuNanos: 0)])
        let current = snapshot(at: 1, processes: [proc(10, cpuNanos: 1_000_000_000), proc(11, cpuNanos: 1_000_000_000)])

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 4)

        XCTAssertEqual(result.systemCPULoad, 50, accuracy: 0.0001)
    }

    func testSystemLoadClampsAt100WhenOversubscribed() {
        // 2 逻辑核上三个进程共烧 250% → 系统 CPU 负载封顶 100,不越界。
        let previous = snapshot(
            at: 0,
            processes: [proc(10, cpuNanos: 0), proc(11, cpuNanos: 0), proc(12, cpuNanos: 0)]
        )
        let current = snapshot(
            at: 1,
            processes: [
                proc(10, cpuNanos: 1_000_000_000),
                proc(11, cpuNanos: 1_000_000_000),
                proc(12, cpuNanos: 500_000_000),
            ]
        )

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 2)

        XCTAssertEqual(result.systemCPULoad, 100)
    }

    // MARK: 退化输入

    func testNonPositiveWallTimeDegradesToNoPercent() {
        // 两张快照同一时刻(墙钟为 0):无法除,显式退化——全部无 CPU%、负载 0。
        let previous = snapshot(at: 7, processes: [proc(10, cpuNanos: 0)])
        let current = snapshot(at: 7, processes: [proc(10, cpuNanos: 1_000_000_000)])

        let result = CPUDiffer.diff(previous: previous, current: current, logicalCoreCount: 4)

        XCTAssertEqual(percent(of: 10, in: result), .some(.none))
        XCTAssertEqual(result.systemCPULoad, 0)
    }
}
