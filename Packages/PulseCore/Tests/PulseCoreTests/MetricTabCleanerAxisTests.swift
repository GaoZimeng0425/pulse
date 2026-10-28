@testable import PulseCore
import XCTest

/// 清理 tab 的轴与注册面(p4-cleaner/03):主窗口入列、弹窗排除(spec「弹窗不动」)、
/// 无传感器家族无排行闸(按需扫描页不沾常驻采集)、元数据与键盘轴序。
/// 登记面结构性断言(CODING_STANDARDS:直调 smoke 不背书装配可达性)。
final class MetricTabCleanerAxisTests: XCTestCase {
    func testCleanerOnMainWindowAxisNotOnPopover() {
        XCTAssertTrue(MetricTab.displayAxis(hasBattery: true).contains(.cleaner))
        XCTAssertTrue(MetricTab.displayAxis(hasBattery: false).contains(.cleaner))
        XCTAssertFalse(MetricTab.popoverAxis(hasBattery: true).contains(.cleaner), "spec:弹窗不动")
        XCTAssertFalse(MetricTab.popoverAxis(hasBattery: false).contains(.cleaner), "spec:弹窗不动")
    }

    func testPopoverAxisStillHandlesBattery() {
        XCTAssertTrue(MetricTab.popoverAxis(hasBattery: true).contains(.battery))
        XCTAssertFalse(MetricTab.popoverAxis(hasBattery: false).contains(.battery))
    }

    func testCleanerMetadataAndGating() {
        XCTAssertEqual(MetricTab.cleaner.title, "清理")
        XCTAssertEqual(MetricTab.cleaner.symbolName, "sparkles")
        XCTAssertEqual(MetricTab.cleaner.accent, .disk, "磁盘色族(spec 实现决定)")
        XCTAssertFalse(MetricTab.cleaner.hostsModuleRanking, "无排行采样闸")
        XCTAssertTrue(MetricTab.cleaner.displayedFamilies.isEmpty, "无常驻传感器家族——可见性闸不沾")
    }

    func testCleanerPositionedBeforeHistoryOnAxis() throws {
        let axis = MetricTab.displayAxis(hasBattery: true)
        let cleanerIndex = try XCTUnwrap(axis.firstIndex(of: .cleaner))
        let historyIndex = try XCTUnwrap(axis.firstIndex(of: .history))
        XCTAssertLessThan(cleanerIndex, historyIndex, "键盘 ←/→ 轴序:清理在历史前、电池后")
    }
}
