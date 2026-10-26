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

    func testAggregateEmptyInputReturnsEmpty() {
        XCTAssertTrue(EnergyImpactFeature.aggregate([]).isEmpty)
    }

    func testReadingRowIdentityIsName() {
        let row = EnergyImpactReading.Row(name: "Arc", impact: 5.0)
        XCTAssertEqual(row.id, "Arc")
    }
}
