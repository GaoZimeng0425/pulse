import XCTest
@testable import Pulse

/// 状态徽章阈值规则(工单 P0.6-04,纯逻辑):✓正常 / 高负载 的判定边界。
/// chip 外观(7px 圆角、14% 派生底)属预览 + 手动验收,不在此接缝。
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

    // MARK: 文案

    func testBadgeTitlesAreChinese() {
        XCTAssertEqual(StatusBadge.normal.title, "正常")
        XCTAssertEqual(StatusBadge.high.title, "高负载")
    }

    func testBadgeSymbolsAreDistinct() {
        // ✓ 与警示三角互异,chip 才可辨。
        XCTAssertNotEqual(StatusBadge.normal.symbolName, StatusBadge.high.symbolName)
    }
}
