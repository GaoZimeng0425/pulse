@testable import Pulse
@testable import PulseCore
import XCTest

/// 状态徽章的 app 侧缝:chip 映射(SwiftUI 外观 = 05 的 MetricCardChip)与
/// 高负载线 = 菜单栏红线的同口径断言。阈值规则本身在核心包 StatusBadgeTests。
final class StatusBadgeChipTests: XCTestCase {
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
