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
}
