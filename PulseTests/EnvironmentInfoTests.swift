import XCTest
@testable import Pulse

/// 头部环境信息格式化(工单 P0.6-04,纯逻辑):主窗口副标题(芯片 · 核数 · 内存)
/// 与弹窗 uptime("已运行 3 天 4 小时"式复合)。实时读取(sysctl / ProcessInfo)
/// 不在此接缝,以实机走查验收。
final class EnvironmentInfoTests: XCTestCase {
    private let gib: Double = 1_073_741_824

    // MARK: 主窗口副标题

    func testSubtitleJoinsChipCoresMemory() {
        // 工单锚点形态:"Apple M4 · 10 核 · 32 GB"。
        XCTAssertEqual(
            EnvironmentInfoFormat.subtitle(chipName: "Apple M4", coreCount: 10, memoryBytes: UInt64(32 * gib)),
            "Apple M4 · 10 核 · 32 GB"
        )
    }

    func testSubtitleSkipsEmptyChipName() {
        // 读不到芯片名(sysctl 失败兜底)不硬凑空段。
        XCTAssertEqual(
            EnvironmentInfoFormat.subtitle(chipName: "", coreCount: 8, memoryBytes: UInt64(16 * gib)),
            "8 核 · 16 GB"
        )
    }

    // MARK: 物理内存取整

    func testMemoryRoundsToWholeGigabytes() {
        // 装机容量为 2 的幂 GiB,直读即整。
        XCTAssertEqual(EnvironmentInfoFormat.memoryGigabytes(UInt64(32 * gib)), 32)
        XCTAssertEqual(EnvironmentInfoFormat.memoryGigabytes(UInt64(8 * gib)), 8)
        // 防御非幂值:四舍五入到最近的整 GB。
        XCTAssertEqual(EnvironmentInfoFormat.memoryGigabytes(UInt64(12.4 * gib)), 12)
        XCTAssertEqual(EnvironmentInfoFormat.memoryGigabytes(UInt64(12.6 * gib)), 13)
    }

    // MARK: 系统 uptime(复合时长)

    func testUptimeBelowOneMinuteShowsSeconds() {
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(0), "已运行 0 秒")
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(59), "已运行 59 秒")
    }

    func testUptimeBelowOneHourShowsMinutes() {
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(60), "已运行 1 分钟")
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(3599), "已运行 59 分钟")
    }

    func testUptimeBelowOneDayShowsHoursAndMinutes() {
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(3600), "已运行 1 小时")
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(3 * 3600 + 25 * 60), "已运行 3 小时 25 分钟")
    }

    func testUptimeAboveOneDayShowsDaysAndHours() {
        // 工单锚点形态:"已运行 3 天 4 小时"。
        XCTAssertEqual(
            EnvironmentInfoFormat.systemUptime(Double(3 * 86_400 + 4 * 3_600 + 15 * 60)),
            "已运行 3 天 4 小时"
        )
        // 次级单位为 0:省掉后半,不出现"0 小时"。
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(Double(3 * 86_400)), "已运行 3 天")
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(86_400), "已运行 1 天")
    }

    func testUptimeClampsNegativeToZero() {
        // 时钟异常防御:负时长按 0 夹紧。
        XCTAssertEqual(EnvironmentInfoFormat.systemUptime(-5), "已运行 0 秒")
    }
}
