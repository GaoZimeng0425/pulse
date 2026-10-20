import XCTest
@testable import PulseCore

/// 菜单栏徽标槽位配置(p1-history/09,纯值):默认态、四项可同时上屏、非法配置回默认、
/// rawValue 往返。配置 → 渲染输入的映射在 PulseTests/MenuBarBadgeTests。
final class MenuBarBadgeConfigurationTests: XCTestCase {
    /// 默认配置 = CPU + RAM(Round-2 共识:默认不变)。
    func testDefaultConfigurationIsCPURAM() {
        XCTAssertEqual(MenuBarBadgeConfiguration.default.slots, [.cpu, .ram])
        XCTAssertEqual(MenuBarBadgeConfiguration.default.rawValue, "cpu,ram")
    }

    /// 槽位上限 = 指标总数(四项可同时上屏,2026-10-20 用户要求);空与超上限按
    /// "非法配置回落默认"处置。
    func testAllFourMetricsFitAtOnceAndBeyondFallsBackToDefault() {
        let all: [MenuBarBadgeMetric] = [.cpu, .ram, .diskRemaining, .networkRate]
        XCTAssertEqual(MenuBarBadgeConfiguration(slots: all).slots, all)
        XCTAssertEqual(MenuBarBadgeConfiguration(rawValue: "cpu,ram,diskRemaining,networkRate")?.slots, all)
        XCTAssertEqual(MenuBarBadgeConfiguration(slots: []).slots, [.cpu, .ram])
        XCTAssertEqual(MenuBarBadgeConfiguration(slots: all + [.cpu]).slots, [.cpu, .ram])
    }

    /// rawValue 解码:未知指标 / 非法数量 → nil(调用方 `?? .default` 回默认)。
    func testInvalidRawValueDecodesToNil() {
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "bogus"))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: ""))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "cpu,ram,cpu,ram,cpu"))
        XCTAssertNil(MenuBarBadgeConfiguration(rawValue: "cpu,network,foo"))
    }

    /// 合法配置 rawValue 往返:设置页写什么,重启读回就是什么。
    func testRawValueRoundTrip() {
        let configuration = MenuBarBadgeConfiguration(slots: [.ram, .diskRemaining, .networkRate])
        XCTAssertEqual(MenuBarBadgeConfiguration(rawValue: configuration.rawValue)?.slots,
                       [.ram, .diskRemaining, .networkRate])
    }
}
