import XCTest
@testable import Pulse

/// 接缝:采样节奏决策(纯逻辑)。GLOSSARY:采样节奏 = 弹窗关闭 5s / 打开 1s。
/// 全部用合成时间轴推演,不真睡(spec 测试决策:注入时钟,不写 sleep 测试)。
final class SamplingSchedulerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testFreshSchedulerSamplesImmediatelyAtStartup() {
        // 启动后第一次采样不等待:菜单栏数字尽快从假变真。
        let scheduler = SamplingScheduler()

        XCTAssertEqual(scheduler.delay(until: t0), 0)
    }

    func testClosedPopoverWaitsFiveSeconds() {
        var scheduler = SamplingScheduler()
        scheduler.recordSample(at: t0)

        // 5s 节奏:采后 2s,还差 3s;正好 5s,立刻到期。
        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(2)), 3, accuracy: 0.0001)
        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(5)), 0, accuracy: 0.0001)
    }

    func testOpenPopoverWaitsOneSecond() {
        var scheduler = SamplingScheduler()
        scheduler.setPopoverVisible(true)
        scheduler.recordSample(at: t0)

        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(0.2)), 0.8, accuracy: 0.0001)
        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(1)), 0, accuracy: 0.0001)
    }

    func testOverdueWaitStaysAtZeroNeverNegative() {
        var scheduler = SamplingScheduler()
        scheduler.recordSample(at: t0)

        // 错过的等待不累计成负数: overdue 恒为 0(立即应采)。
        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(9)), 0)
    }

    func testOpeningPopoverAfterClosedIntervalIsDueImmediately() {
        // 关闭节奏下等了 2s(超过 1s 间隔)才打开弹窗:切到 1s 节奏即到期,
        // 弹窗一打开就能尽快拿到新数据。
        var scheduler = SamplingScheduler()
        scheduler.recordSample(at: t0)

        scheduler.setPopoverVisible(true)

        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(2)), 0)
    }

    func testClosingPopoverExtendsRemainingWaitToFiveSecondRhythm() {
        // 打开节奏下等了 0.2s 后关闭:剩余等待按 5s 节奏重算(5 - 0.2 = 4.8)。
        var scheduler = SamplingScheduler()
        scheduler.setPopoverVisible(true)
        scheduler.recordSample(at: t0)

        scheduler.setPopoverVisible(false)

        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(0.2)), 4.8, accuracy: 0.0001)
    }

    func testRecordSampleReschedulesFromTheSampleMoment() {
        var scheduler = SamplingScheduler()
        scheduler.recordSample(at: t0)

        // 在 t0+2 完成一采:下一等待从 t0+2 重新起算 5s。
        scheduler.recordSample(at: t0.addingTimeInterval(2))

        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(2)), 5, accuracy: 0.0001)
        XCTAssertEqual(scheduler.delay(until: t0.addingTimeInterval(6)), 1, accuracy: 0.0001)
    }
}
