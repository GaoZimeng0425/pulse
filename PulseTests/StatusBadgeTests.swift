import XCTest
@testable import Pulse
@testable import PulseCore

/// 状态徽章阈值规则(工单 P0.6-04 语义,评审 F1 并入 05 的 chip 实现):
/// ✓正常 / 高负载 的判定边界。规则纯逻辑在此钉死;chip 外观(全圆 pill、
/// tint 14% 底)走 05 的 MetricCardView 家族,属预览 + 手动验收接缝。
final class StatusBadgeTests: XCTestCase {
    // MARK: 组卡高负载线(组 CPU% > 100%)

    func testGroupAboveThresholdGetsHighBadge() {
        XCTAssertEqual(StatusBadgeRules.groupBadge(cpuPercent: 100.5), .high)
        XCTAssertEqual(StatusBadgeRules.groupBadge(cpuPercent: 445), .high)
    }

    /// 边界(工单钉死):恰好 100%(单核满载)不算高负载。
    func testGroupAtOrBelowThresholdGetsNoBadge() {
        XCTAssertNil(StatusBadgeRules.groupBadge(cpuPercent: 100))
        XCTAssertNil(StatusBadgeRules.groupBadge(cpuPercent: 99.9))
        XCTAssertNil(StatusBadgeRules.groupBadge(cpuPercent: 0))
    }

    // MARK: 系统负载徽章(空载 ✓正常 / 高负载 / 中间静默)

    func testIdleSystemLoadGetsNormalBadge() {
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 0), .normal)
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 29.9), .normal)
    }

    /// 边界:恰好空载线(30%)不算空载——落入静默档,不挂 chip。
    func testSystemLoadAtIdleThresholdIsSilent() {
        XCTAssertNil(StatusBadgeRules.systemBadge(load: 30))
        XCTAssertNil(StatusBadgeRules.systemBadge(load: 50))
    }

    /// 高负载线与菜单栏变红同口径(> 70%);恰好 70% 不算。
    func testHighSystemLoadGetsHighBadge() {
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 70.1), .high)
        XCTAssertEqual(StatusBadgeRules.systemBadge(load: 100), .high)
        XCTAssertNil(StatusBadgeRules.systemBadge(load: 70))
    }

    /// 高负载线字面量与菜单栏变红线保持同一出处语义:两处必须相等
    /// (字面量直写是为绕开 redThreshold 的 MainActor 隔离,漂移由本断言拦截)。
    @MainActor
    func testSystemHighLoadThresholdMatchesMenuBarRedLine() {
        XCTAssertEqual(StatusBadgeRules.systemHighLoadThreshold, SystemMonitor.redThreshold)
    }

    // MARK: chip 映射(外观 = 05 的 MetricCardChip,唯一实现)

    func testBadgeChipsUseChineseTitles() {
        XCTAssertEqual(StatusBadge.normal.chip.title, "正常")
        XCTAssertEqual(StatusBadge.high.chip.title, "高负载")
    }

    func testBadgeChipSymbolsAreDistinct() {
        // ✓ 与警示三角互异,chip 才可辨。
        XCTAssertNotEqual(StatusBadge.normal.chip.systemImage, StatusBadge.high.chip.systemImage)
    }
}
