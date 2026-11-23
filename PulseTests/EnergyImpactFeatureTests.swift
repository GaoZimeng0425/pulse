@testable import Pulse
import XCTest

/// 特权助手功能模块(p3-root-mcp/03):名字聚合口径(纯函数钉死)与
/// 读数结构;XPC/60s 循环走真机验收(探针 09 同族,合成单测不设缝)。
final class EnergyImpactFeatureTests: XCTestCase {
    func testAggregateSumsByProcessNameAndDropsZeroImpact() {
        let samples: [(pid: Int, name: String, impact: Double)] = [
            (1, "zap-oss", 33.67),
            (2, "zap-oss", 10.0), // 同名进程(多 pid)求和
            (3, "ZCode", 0.34),
            (4, "kernel_task", 0.0), // 零影响不进聚合
            (5, "kernel_task", 13.04),
        ]
        let aggregated = EnergyImpactFeature.aggregate(samples)
        let byName = Dictionary(uniqueKeysWithValues: aggregated.map { ($0.name, $0.impact) })
        XCTAssertEqual(byName["zap-oss"] ?? 0, 43.67, accuracy: 0.001)
        XCTAssertEqual(byName["ZCode"] ?? 0, 0.34, accuracy: 0.001)
        XCTAssertEqual(byName["kernel_task"] ?? 0, 13.04, accuracy: 0.001)
        XCTAssertNil(byName["不存在的名字"])
    }

    /// 真机首日实案(2026-10-27):powermetrics 尾部 ALL_TASKS/DEAD_TASKS 是
    /// 汇总伪行(pid 为负),混进聚合会让全机合计虚高约 2.4 倍(双重计数)。
    func testAggregateDropsPseudoRowsWithNegativePid() {
        let samples: [(pid: Int, name: String, impact: Double)] = [
            (-2, "ALL_TASKS", 15239.14),
            (-1, "DEAD_TASKS", 4060.16),
            (769, "sentineld_helper", 3675.54),
            (415, "WindowServer", 1656.98),
        ]
        let byName = Dictionary(uniqueKeysWithValues: EnergyImpactFeature.aggregate(samples)
            .map { ($0.name, $0.impact) })
        XCTAssertNil(byName["ALL_TASKS"])
        XCTAssertNil(byName["DEAD_TASKS"])
        XCTAssertEqual(byName["sentineld_helper"] ?? 0, 3675.54, accuracy: 0.001)
        XCTAssertEqual(byName["WindowServer"] ?? 0, 1656.98, accuracy: 0.001)
    }

    func testAggregateEmptyInputReturnsEmpty() {
        XCTAssertTrue(EnergyImpactFeature.aggregate([]).isEmpty)
    }

    func testReadingRowIdentityIsName() {
        let row = EnergyImpactReading.Row(name: "Arc", impact: 5.0)
        XCTAssertEqual(row.id, "Arc")
    }

    /// 等待期加密轮询(btm-lwcr-fix/04):已登记但拉取失败(等系统批准/助手
    /// 未跑起)时 5s 一档——「点完批准 5s 内跟上」的反馈窗口钉死。
    @MainActor
    func testPollIntervalFastWhileRegisteredButFailing() {
        XCTAssertEqual(
            EnergyImpactFeature.pollInterval(fetchFailed: true, status: .requiresApproval),
            .seconds(5)
        )
        XCTAssertEqual(
            EnergyImpactFeature.pollInterval(fetchFailed: true, status: .enabled),
            .seconds(5)
        )
    }

    @MainActor
    func testPollIntervalRegularWhenHealthyOrNotRegistered() {
        XCTAssertEqual(
            EnergyImpactFeature.pollInterval(fetchFailed: false, status: .enabled),
            .seconds(60)
        )
        // 未登记没人等,不 5s 空转。
        XCTAssertEqual(
            EnergyImpactFeature.pollInterval(fetchFailed: true, status: .notRegistered),
            .seconds(60)
        )
    }
}
