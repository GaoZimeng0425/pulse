import XCTest
@testable import PulseCore

/// 接缝:PulseFormat 纯显示格式化(本工单唯一可单测的纯逻辑,UI 不写单元测试)。
/// 期望值是独立约定的显示文案字面量,不经过实现同源计算。
final class PulseFormatTests: XCTestCase {
    // MARK: cpuPercent

    func testCPUPercentFormatsWholeGroupCPUWithPercentSign() {
        XCTAssertEqual(PulseFormat.cpuPercent(445), "445%")
    }

    func testCPUPercentRoundsFractionalToNearestWholePercent() {
        XCTAssertEqual(PulseFormat.cpuPercent(42.4), "42%")
        XCTAssertEqual(PulseFormat.cpuPercent(42.6), "43%")
    }

    // MARK: cpuPercentNumber(工单 P0.6-02:大数字与单位分层的数字部分)

    func testCPUPercentNumberStripsUnitForFigureTypography() {
        XCTAssertEqual(PulseFormat.cpuPercentNumber(445), "445")
        XCTAssertEqual(PulseFormat.cpuPercentNumber(0), "0")
        XCTAssertEqual(PulseFormat.cpuPercentNumber(42.6), "43")
    }

    // MARK: memory

    func testMemoryBelowOneGBShowsWholeMegabytes() {
        XCTAssertEqual(PulseFormat.memory(512_000_000), "512 MB")
    }

    func testMemoryAtOneGBOrAboveShowsSingleDecimalGB() {
        XCTAssertEqual(PulseFormat.memory(1_000_000_000), "1.0 GB")
        XCTAssertEqual(PulseFormat.memory(2_400_000_000), "2.4 GB")
    }

    // MARK: memoryFigure(工单 P0.6-03:内存大数字与单位分层)

    func testMemoryFigureSplitsValueAndUnitForFigureTypography() {
        // 内存 tab 组卡大数字:数字走圆体大字,单位("GB"/"MB")小一号基线对齐。
        let gb = PulseFormat.memoryFigure(2_400_000_000)
        XCTAssertEqual(gb.value, "2.4")
        XCTAssertEqual(gb.unit, "GB")

        let mb = PulseFormat.memoryFigure(512_000_000)
        XCTAssertEqual(mb.value, "512")
        XCTAssertEqual(mb.unit, "MB")
    }

    func testMemoryFigureOfZeroSplitsIntoZeroAndMB() {
        // 零内存:"0" + "MB"(空态由调用方先兜底,这里只钉不崩、可拆)。
        let zero = PulseFormat.memoryFigure(0)
        XCTAssertEqual(zero.value, "0")
        XCTAssertEqual(zero.unit, "MB")
    }

    // MARK: uptime(工单 06:启动时长,"已 25 分钟")

    private let now = Date(timeIntervalSinceReferenceDate: 10_000_000)

    private func started(_ secondsAgo: TimeInterval) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    func testUptimeBelowOneMinuteShowsSeconds() {
        XCTAssertEqual(PulseFormat.uptime(startedAt: started(40), now: now), "已 40 秒")
        XCTAssertEqual(PulseFormat.uptime(startedAt: now, now: now), "已 0 秒")
    }

    func testUptimeBelowOneHourShowsWholeMinutes() {
        XCTAssertEqual(PulseFormat.uptime(startedAt: started(25 * 60), now: now), "已 25 分钟")
        XCTAssertEqual(PulseFormat.uptime(startedAt: started(59 * 60 + 59), now: now), "已 59 分钟")
    }

    func testUptimeBelowOneDayShowsWholeHours() {
        XCTAssertEqual(PulseFormat.uptime(startedAt: started(3 * 3600 + 25 * 60), now: now), "已 3 小时")
        XCTAssertEqual(PulseFormat.uptime(startedAt: started(23 * 3600 + 59 * 60), now: now), "已 23 小时")
    }

    func testUptimeAtOneDayOrAboveShowsWholeDays() {
        // 用户故事 13:"常驻 3 天"的遗忘进程。
        XCTAssertEqual(PulseFormat.uptime(startedAt: started(3 * 86_400 + 4 * 3600), now: now), "已 3 天")
        XCTAssertEqual(PulseFormat.uptime(startedAt: started(30 * 86_400), now: now), "已 30 天")
    }

    func testUptimeWithUnknownStartTimeShowsPlaceholder() {
        XCTAssertEqual(PulseFormat.uptime(startedAt: nil, now: now), "启动时刻未知")
    }

    func testUptimeWithFutureStartTimeClampsToZero() {
        XCTAssertEqual(PulseFormat.uptime(startedAt: now.addingTimeInterval(5), now: now), "已 0 秒")
    }

    // MARK: processName(工单 06:进程行与父链面包屑的显示名)

    func testProcessNameUsesExecutablePathBasename() {
        XCTAssertEqual(
            PulseFormat.processName(
                executablePath: "/Users/x/.rustup/toolchains/stable/bin/rustc",
                argv: ["ignored"],
                pid: 100
            ),
            "rustc"
        )
    }

    func testProcessNameFallsBackToArgvZeroBasenameWhenPathRestricted() {
        XCTAssertEqual(
            PulseFormat.processName(executablePath: nil, argv: ["vitest", "run"], pid: 42),
            "vitest"
        )
    }

    func testProcessNameFallsBackToPIDWhenBothPathAndArgvUnavailable() {
        XCTAssertEqual(PulseFormat.processName(executablePath: nil, argv: [], pid: 999), "pid 999")
    }

    // MARK: duration / milliseconds(工单 11:诊断报告的采样统计文案)

    func testDurationTakesLargestTwoUnits() {
        // 与 systemUptime 同一取级策略(最大两级),但不带"已运行"前缀(报告字段值)。
        XCTAssertEqual(PulseFormat.duration(seconds: 40), "40 秒")
        XCTAssertEqual(PulseFormat.duration(seconds: 90), "1 分 30 秒")
        XCTAssertEqual(PulseFormat.duration(seconds: 5_400), "1 小时 30 分")
        XCTAssertEqual(PulseFormat.duration(seconds: 3 * 86_400 + 2 * 3_600), "3 天 2 小时")
    }

    func testDurationClampsNegativeToZero() {
        XCTAssertEqual(PulseFormat.duration(seconds: -5), "0 秒")
    }

    func testMillisecondsShowsOneDecimalAndSubdecimalFloor() {
        XCTAssertEqual(PulseFormat.milliseconds(2), "2000.0 ms")
        XCTAssertEqual(PulseFormat.milliseconds(0.0032), "3.2 ms")
        // 过小但非零:如实标下限,不圆整成 0。
        XCTAssertEqual(PulseFormat.milliseconds(0.00004), "<0.1 ms")
        XCTAssertEqual(PulseFormat.milliseconds(0), "0 ms")
    }

    // MARK: 能耗影响排行(工单 01)

    func testCPUSecondsAndWakeupsPerSecondShowOneDecimal() {
        XCTAssertEqual(PulseFormat.cpuSeconds(0), "0.0 秒")
        XCTAssertEqual(PulseFormat.cpuSeconds(3.14159), "3.1 秒")
        XCTAssertEqual(PulseFormat.wakeupsPerSecond(0), "0.0 次/秒")
        XCTAssertEqual(PulseFormat.wakeupsPerSecond(2.46), "2.5 次/秒")
    }

    func testCPUSecondsAndWakeupsClampNegativeToZero() {
        XCTAssertEqual(PulseFormat.cpuSeconds(-1), "0.0 秒")
        XCTAssertEqual(PulseFormat.wakeupsPerSecond(-0.5), "0.0 次/秒")
    }
}
