@testable import Pulse
import PulseCore
import XCTest

/// AI 助手能耗聚合(p3-root-mcp/04):内置表识别与聚合口径(纯函数钉死)。
/// 干扰项实案来自真机快照(2026-10-27):CursorUIViewService / UserEventAgent /
/// ContextStoreAgent 是 Apple 系统进程,不许被前缀扫进助手。
final class AgentEnergyTableTests: XCTestCase {
    func testGroupAggregatesByAgentWithProcessCount() {
        let grouped = AgentEnergyTable.group([
            (name: "ZCode", impact: 0.34),
            (name: "ZCode Helper (Renderer)", impact: 2289.31),
            (name: "ZCode Helper", impact: 120.0),
            (name: "zap-oss", impact: 33.67),
        ])
        XCTAssertEqual(grouped.count, 2)
        XCTAssertEqual(grouped[0].agent, "ZCode") // 降序榜首
        XCTAssertEqual(grouped[0].impact, 2409.65, accuracy: 0.001)
        XCTAssertEqual(grouped[0].processCount, 3)
        XCTAssertEqual(grouped[1].agent, "zap")
        XCTAssertEqual(grouped[1].processCount, 1)
    }

    func testCursorExactMatchGuardsAgainstSystemLookalikes() {
        XCTAssertNil(AgentEnergyTable.agent(for: "CursorUIViewService")) // Apple 系统服务
        XCTAssertEqual(AgentEnergyTable.agent(for: "Cursor"), "Cursor")
        XCTAssertEqual(AgentEnergyTable.agent(for: "Cursor Helper (GPU)"), "Cursor")
    }

    func testRaycastBundleIdStyleNameMatches() {
        XCTAssertEqual(AgentEnergyTable.agent(for: "Raycast"), "Raycast")
        XCTAssertEqual(AgentEnergyTable.agent(for: "com.raycast.macos.Pasteboard"), "Raycast")
    }

    func testNonAgentProcessesAreExcluded() {
        let grouped = AgentEnergyTable.group([
            (name: "kernel_task", impact: 13.04),
            (name: "WindowServer", impact: 1656.98),
            (name: "UserEventAgent", impact: 5.0),
            (name: "ContextStoreAgent", impact: 4.0),
        ])
        XCTAssertTrue(grouped.isEmpty)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(AgentEnergyTable.agent(for: "OLLAMA"), "Ollama")
        XCTAssertEqual(AgentEnergyTable.agent(for: "Claude Helper"), "Claude")
    }

    func testRankingRowsUseLeaderNormalizationAndAdaptiveFormat() {
        let rows = AgentEnergyTable.rankingRows([
            AgentEnergyEntry(agent: "ZCode", impact: 2409.65, processCount: 3),
            AgentEnergyEntry(agent: "zap", impact: 33.67, processCount: 1),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].id, "agent:ZCode")
        XCTAssertEqual(rows[0].primaryText, "2410") // ≥100 取整
        XCTAssertEqual(rows[0].subtitle, "3 个进程")
        XCTAssertEqual(rows[0].meterFraction, 1, accuracy: 0.001) // 榜首满条
        XCTAssertEqual(rows[1].primaryText, "33.7") // <100 一位小数
        XCTAssertEqual(rows[1].meterFraction, 33.67 / 2409.65, accuracy: 0.001)
    }

    func testFormatBoundaryAt100() {
        XCTAssertEqual(AgentEnergyTable.format(99.96), "100.0")
        XCTAssertEqual(AgentEnergyTable.format(100), "100")
        XCTAssertEqual(AgentEnergyTable.format(0.34), "0.3")
    }
}
