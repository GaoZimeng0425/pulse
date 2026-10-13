import XCTest
@testable import Pulse

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

    // MARK: memory

    func testMemoryBelowOneGBShowsWholeMegabytes() {
        XCTAssertEqual(PulseFormat.memory(512_000_000), "512 MB")
    }

    func testMemoryAtOneGBOrAboveShowsSingleDecimalGB() {
        XCTAssertEqual(PulseFormat.memory(1_000_000_000), "1.0 GB")
        XCTAssertEqual(PulseFormat.memory(2_400_000_000), "2.4 GB")
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
}
