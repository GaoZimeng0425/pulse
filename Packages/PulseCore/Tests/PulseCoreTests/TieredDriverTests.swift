@testable import PulseCore
import XCTest

// MARK: - 分档单循环构件(p2-review/06):历史节流 / 走势环 / 分档间隔

/// `HistoryThrottle`:分档单循环下历史广播的节流器——首轮放行,之后每满
/// interval 秒放行一次。时间可注入,零真实等待。
final class HistoryThrottleTests: XCTestCase {
    func testFirstPassIsImmediate() {
        let throttle = HistoryThrottle(interval: 30)
        XCTAssertTrue(throttle.shouldPass(now: Date(timeIntervalSince1970: 0)))
    }

    func testSubsequentPassRequiresFullInterval() {
        let throttle = HistoryThrottle(interval: 30)
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(throttle.shouldPass(now: start))
        // 29.999s:不放行;30s:放行并记账。
        XCTAssertFalse(throttle.shouldPass(now: start.addingTimeInterval(29.999)))
        XCTAssertTrue(throttle.shouldPass(now: start.addingTimeInterval(30)))
        XCTAssertFalse(throttle.shouldPass(now: start.addingTimeInterval(35)))
    }
}

/// `TrendRing`:定长窗口,溢出丢最旧(三处手写环收编,p2-review/06)。
final class TrendRingTests: XCTestCase {
    func testAppendsUpToLimitThenDropsOldest() {
        var ring = TrendRing<Double>(limit: 3)
        for value in [1.0, 2.0, 3.0] {
            ring.append(value)
        }
        XCTAssertEqual(ring.values, [1.0, 2.0, 3.0])
        ring.append(4.0)
        XCTAssertEqual(ring.values, [2.0, 3.0, 4.0], "溢出丢最旧")
        XCTAssertEqual(ring.last, 4)
        XCTAssertEqual(ring.count, 3)
    }

    func testZeroLimitRingSwallowsValues() {
        var ring = TrendRing<Double>(limit: 0)
        ring.append(1)
        XCTAssertTrue(ring.isEmpty)
    }

    func testTypedValuesRing() {
        // 网络速率环(NetworkTrendBuffer 内部)是同型的类型值环。
        var ring = TrendRing<NetworkRates>(limit: 2)
        ring.append(NetworkRates(upBytesPerSecond: 1, downBytesPerSecond: 2))
        ring.append(NetworkRates(upBytesPerSecond: 3, downBytesPerSecond: 4))
        ring.append(NetworkRates(upBytesPerSecond: 5, downBytesPerSecond: 6))
        XCTAssertEqual(ring.values.count, 2)
        XCTAssertEqual(ring.values.first?.upBytesPerSecond, 3)
    }
}

/// SensorDriver 分档间隔:调度器每轮休眠前求值,可见性切换 ≤1 轮内生效。
final class AdaptiveIntervalDriverTests: XCTestCase {
    func testDriverCarriesAdaptiveIntervalAndSchedulerConsultsItEachRound() async {
        // 假 sleep 记录每轮求值出的间隔;间隔中途切换,下一轮即用新值。
        actor Recorder {
            var intervals: [TimeInterval] = []
            func record(_ interval: TimeInterval) {
                intervals.append(interval)
            }
        }
        let recorder = Recorder()
        let visibility = SensorVisibilityGate()
        visibility.setVisible(true)

        let driver = SensorDriver(
            cadence: .every(seconds: 5),
            tick: {},
            wakeups: nil,
            adaptiveInterval: { visibility.isVisible ? 5 : 30 }
        )
        let scheduler = SensorScheduler(
            sleep: { interval in
                await recorder.record(interval)
                // 第二轮休眠后关闸,第三轮即应取 30s。
                if await recorder.intervals.count == 2 {
                    visibility.setVisible(false)
                }
            }
        )
        // run 不会自然结束:跑三轮间隔后取消。
        let task = Task { await scheduler.run([driver]) }
        // 等三轮记录落账(注入 sleep 不真等,轮次很快)。
        for _ in 0 ..< 100 {
            if await recorder.intervals.count >= 3 {
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        let intervals = await recorder.intervals
        XCTAssertGreaterThanOrEqual(intervals.count, 3)
        XCTAssertEqual(intervals[0], 5, "可见走 UI 档")
        XCTAssertEqual(intervals[2], 30, "关闸后下一轮即走历史档")
    }

    func testStaticCadenceDriverUnaffected() {
        // 不分档的 provider(默认 nil)沿用 cadence 静态档——既有登记不受影响。
        let driver = SensorDriver(cadence: .every(seconds: 60), tick: {}, wakeups: nil)
        XCTAssertNil(driver.adaptiveInterval)
    }
}
